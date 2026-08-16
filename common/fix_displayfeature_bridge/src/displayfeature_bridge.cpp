#include "hardware_compat.h"
#include "platform_binder_compat.h"

#include <android/binder_ibinder.h>
#include <android/binder_parcel.h>
#include <android/log.h>
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

struct QtiPccCoeffData {
    uint8_t flags;
    uint8_t reserved[7];
    double coefficients[3][11];
};

struct QtiUserColorBalanceConfig {
    int32_t enabled;
    int32_t reserved;
    double red;
    double green;
    double blue;
};

extern "C" {

AIBinder* AServiceManager_checkService(const char* instance);

int disp_api_init(uint64_t* handle, int flags);
int disp_api_deinit(uint64_t handle, int flags);
int disp_api_set_global_pcc_config(uint64_t handle, int display_id, int enable,
                                   const QtiPccCoeffData* config);
int disp_api_set_usr_color_balance_config(uint64_t handle, int display_id,
                                          const QtiUserColorBalanceConfig* config);

}

namespace {

constexpr char kLogTag[] = "DisplayFeatureBridge";
constexpr char kModuleId[] = "displayfeature";
constexpr char kDeviceName[] = "displayfeature-color";
constexpr char kQServiceName[] = "display.qservice";
constexpr char kQServiceDescriptor[] = "android.display.IQService";
constexpr char kSurfaceFlingerServiceName[] = "SurfaceFlinger";
constexpr char kSurfaceComposerDescriptor[] = "android.ui.ISurfaceComposer";
constexpr char kBpBinderTransactSymbol[] =
        "_ZN7android8BpBinder8transactEjRKNS_6ParcelEPS1_j";
constexpr uint32_t kSetColorModeWithRenderIntentCommand = 39;
constexpr uint32_t kSetSurfaceFlingerColorMatrixCommand = 1015;
constexpr int32_t kPrimaryDisplayId = 0;
constexpr int32_t kSrgbColorMode = 7;
constexpr int32_t kDeadObjectStatus = -EPIPE;
constexpr int32_t kEyeCareMode = 3;
constexpr int32_t kColorTemperatureMode = 23;
constexpr int32_t kPaperTextureColorMode = 31;
constexpr int32_t kBrightnessNotifyMessageId = 5;
constexpr uint32_t kMessageIdMask = 0xffU;
constexpr uint32_t kMessageDisplayIdShift = 16U;
constexpr int32_t kMinimumWarmth = -100;
constexpr int32_t kMaximumWarmth = 100;
constexpr int32_t kMinimumEyeCareValue = 0;
constexpr int32_t kMaximumEyeCareValue = 255;
constexpr int32_t kPccCoefficientCount = 11;
constexpr int32_t kPccRedCoefficient = 1;
constexpr int32_t kPccGreenCoefficient = 2;
constexpr int32_t kPccBlueCoefficient = 3;
constexpr long kPendingRetryIntervalNanoseconds = 500000000L;
constexpr double kPccComparisonTolerance = 0.0005;
constexpr int32_t kUnlimitedCtStrength = 55;
constexpr int32_t kUnlimitedCtUiParamMin = 100;
constexpr int32_t kUnlimitedCtParamMax = 255;
constexpr double kColorTemperatureStrength = 0.50;
constexpr double kFullMaximumWarmGreen = 0.85;
constexpr double kFullMaximumWarmBlue = 0.55;
constexpr double kFullMaximumCoolRed = 0.70;
constexpr double kFullMaximumCoolGreen = 0.90;

static_assert(sizeof(QtiPccCoeffData) == 272, "QTI PCC 配置 ABI 大小不匹配");
static_assert(offsetof(QtiPccCoeffData, coefficients) == 8,
              "QTI PCC 系数起始偏移不匹配");
static_assert(offsetof(QtiPccCoeffData, coefficients) +
                              (0 * kPccCoefficientCount + kPccRedCoefficient) * sizeof(double) ==
                      0x10,
              "QTI PCC 红色对角系数偏移不匹配");
static_assert(offsetof(QtiPccCoeffData, coefficients) +
                              (1 * kPccCoefficientCount + kPccGreenCoefficient) *
                                      sizeof(double) ==
                      0x70,
              "QTI PCC 绿色对角系数偏移不匹配");
static_assert(offsetof(QtiPccCoeffData, coefficients) +
                              (2 * kPccCoefficientCount + kPccBlueCoefficient) * sizeof(double) ==
                      0xd0,
              "QTI PCC 蓝色对角系数偏移不匹配");
static_assert(sizeof(QtiUserColorBalanceConfig) == 32,
              "QTI 用户色彩平衡配置 ABI 大小不匹配");
static_assert(offsetof(QtiUserColorBalanceConfig, red) == 8,
              "QTI 用户色彩平衡红色系数偏移不匹配");
static_assert(offsetof(QtiUserColorBalanceConfig, green) == 16,
              "QTI 用户色彩平衡绿色系数偏移不匹配");
static_assert(offsetof(QtiUserColorBalanceConfig, blue) == 24,
              "QTI 用户色彩平衡蓝色系数偏移不匹配");

enum RequestStage : int32_t {
    kStageIdle = 0,
    kStageResolveTransact = 1,
    kStageGetServiceManager = 2,
    kStageCheckService = 3,
    kStageServiceReady = 4,
    kStageMarkParcel = 5,
    kStageWriteInterfaceToken = 6,
    kStageWriteDisplayId = 7,
    kStageWriteColorMode = 8,
    kStageWriteRenderIntent = 9,
    kStageTransact = 10,
    kStageComplete = 11,
    kStageQtiInit = 12,
    kStageQtiSetPcc = 13,
    kStageQtiComplete = 14,
    kStageQtiDeinit = 15,
};

struct PccDiagonal {
    double red;
    double green;
    double blue;
};

struct displayfeature_device_t;
using DisplayFeatureListener = void (*)(int, int, float, float, float);

using SetFeatureFn = int (*)(displayfeature_device_t*, int, int, int, int);
using SetFunctionFn = int (*)(displayfeature_device_t*, int, int, int, int);
using SendMessageFn = void (*)(displayfeature_device_t*, int, int, const void*);
using SetListenerFn = void (*)(displayfeature_device_t*, DisplayFeatureListener);
using DumpFn = void (*)(displayfeature_device_t*, bool, void*);
using SetGamePkgNameFn = void (*)(displayfeature_device_t*, int, int, int, const void*);
using BpBinderTransactFn = int32_t (*)(android::IBinder*, uint32_t,
                                      const android::Parcel&, android::Parcel*, uint32_t);

struct displayfeature_device_t {
    hw_device_t common;
    void (*get_capabilities)(displayfeature_device_t*, uint32_t*, int*);
    void* (*get_function)(displayfeature_device_t*, int);
};

static_assert(offsetof(displayfeature_device_t, get_capabilities) == 120,
              "getCapabilities ABI 偏移不匹配");
static_assert(offsetof(displayfeature_device_t, get_function) == 128,
              "getFunction ABI 偏移不匹配");
static_assert(sizeof(displayfeature_device_t) == 136, "DisplayFeature 设备 ABI 不匹配");

struct BridgeState {
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    BpBinderTransactFn bp_binder_transact = nullptr;
    android::sp<android::IBinder> qservice;
    DisplayFeatureListener listener = nullptr;
    uint64_t qti_handle = 0;
    bool qti_initialized = false;
    bool legacy_global_pcc_cleared = false;
    bool legacy_user_color_balance_cleared = false;
    bool pcc_configured = false;
    bool pcc_enabled = false;
    bool pcc_apply_pending = false;
    int color_temperature_value = 2;
    int eye_care_value = 0;
    int eye_care_warmth = 0;
    PccDiagonal color_temperature_pcc = {1.0, 1.0, 1.0};
    PccDiagonal eye_care_pcc = {1.0, 1.0, 1.0};
    PccDiagonal desired_pcc = {1.0, 1.0, 1.0};
    bool actual_pcc_valid = false;
    bool actual_pcc_enabled = false;
    PccDiagonal actual_pcc = {1.0, 1.0, 1.0};
    int current_xiaomi_mode = -1;
    int current_render_intent = -1;
    int last_request_mode = -1;
    int last_stage = kStageIdle;
    int last_display_id = -1;
    int last_value = -1;
    int last_cookie = -1;
    int last_status = -ENODEV;
    int last_qti_status = -ENODEV;
    int last_surface_flinger_status = -ENODEV;
    int last_brightness = -1;
    int last_brightness_status = -ENODEV;
    uint32_t brightness_notifications = 0;
    uint32_t ignored_messages = 0;
    uint32_t ignored_game_packages = 0;
    uint32_t pcc_pending_retry_polls = 0;
    uint32_t surface_flinger_color_matrix_applies = 0;
    pthread_t retry_thread = {};
    bool retry_thread_started = false;
    bool retry_thread_stop = false;
    int retry_thread_status = -ENODEV;
    AIBinder_Class* surface_composer_class = nullptr;
    AIBinder* surface_flinger = nullptr;
};

BridgeState g_state;

int clamp_warmth(int warmth) {
    if (warmth < kMinimumWarmth) {
        return kMinimumWarmth;
    }
    if (warmth > kMaximumWarmth) {
        return kMaximumWarmth;
    }
    return warmth;
}

int clamp_eye_care_value(int value) {
    if (value < kMinimumEyeCareValue) {
        return kMinimumEyeCareValue;
    }
    if (value > kMaximumEyeCareValue) {
        return kMaximumEyeCareValue;
    }
    return value;
}

int normalize_qti_status(int status) {
    if (status == 0) {
        return 0;
    }
    return status < 0 ? status : -EIO;
}

int map_eye_care_to_warmth(int value) {
    const int clamped_value = clamp_eye_care_value(value);
    return (clamped_value * kMaximumWarmth + 127) / 255;
}

double maximum_coefficient(const PccDiagonal& diagonal) {
    double maximum = diagonal.red;
    if (diagonal.green > maximum) {
        maximum = diagonal.green;
    }
    if (diagonal.blue > maximum) {
        maximum = diagonal.blue;
    }
    return maximum;
}

PccDiagonal normalize_pcc_diagonal(const PccDiagonal& diagonal) {
    const double maximum = maximum_coefficient(diagonal);
    if (!(maximum > 0.0)) {
        return {1.0, 1.0, 1.0};
    }
    return {
            diagonal.red / maximum,
            diagonal.green / maximum,
            diagonal.blue / maximum,
    };
}

double scale_pcc_coefficient(double coefficient) {
    return 1.0 - (1.0 - coefficient) * kColorTemperatureStrength;
}

PccDiagonal scale_pcc_strength(const PccDiagonal& diagonal) {
    return normalize_pcc_diagonal({
            scale_pcc_coefficient(diagonal.red),
            scale_pcc_coefficient(diagonal.green),
            scale_pcc_coefficient(diagonal.blue),
    });
}

double interpolate_pcc_coefficient(double full_strength_minimum, int magnitude) {
    const double strength = kColorTemperatureStrength * static_cast<double>(magnitude) /
                            static_cast<double>(kMaximumWarmth);
    return 1.0 - (1.0 - full_strength_minimum) * strength;
}

PccDiagonal calculate_warmth_pcc_diagonal(int warmth) {
    const int clamped_warmth = clamp_warmth(warmth);
    if (clamped_warmth > 0) {
        return {
                1.0,
                interpolate_pcc_coefficient(kFullMaximumWarmGreen, clamped_warmth),
                interpolate_pcc_coefficient(kFullMaximumWarmBlue, clamped_warmth),
        };
    }
    if (clamped_warmth < 0) {
        const int magnitude = -clamped_warmth;
        return {
                interpolate_pcc_coefficient(kFullMaximumCoolRed, magnitude),
                interpolate_pcc_coefficient(kFullMaximumCoolGreen, magnitude),
                1.0,
        };
    }
    return {1.0, 1.0, 1.0};
}

int map_unlimited_ct_channel(int channel) {
    int clamped_channel = channel;
    if (clamped_channel > kUnlimitedCtParamMax) {
        clamped_channel = kUnlimitedCtParamMax;
    }
    const int channel_delta = clamped_channel > kUnlimitedCtUiParamMin
                                      ? clamped_channel - kUnlimitedCtUiParamMin
                                      : 0;
    return kUnlimitedCtParamMax - kUnlimitedCtStrength +
           channel_delta * kUnlimitedCtStrength /
                   (kUnlimitedCtParamMax - kUnlimitedCtUiParamMin);
}

PccDiagonal calculate_unlimited_ct_rgb_pcc(int red, int green, int blue) {
    // 对齐原包 setPCCConfigCT 的任意 RGB 分支，再统一使用最终确认的 50% 强度。
    const PccDiagonal full_strength = normalize_pcc_diagonal({
            static_cast<double>(map_unlimited_ct_channel(red)),
            static_cast<double>(map_unlimited_ct_channel(green)),
            static_cast<double>(map_unlimited_ct_channel(blue)),
    });
    return scale_pcc_strength(full_strength);
}

PccDiagonal map_color_temperature_to_pcc(int value) {
    switch (value) {
        case 1:
            return calculate_warmth_pcc_diagonal(kMaximumWarmth);
        case 2:
            return {1.0, 1.0, 1.0};
        case 3:
            return calculate_warmth_pcc_diagonal(kMinimumWarmth);
        default:
            break;
    }

    const uint32_t argb = static_cast<uint32_t>(value);
    const int red = static_cast<int>((argb >> 16U) & 0xffU);
    const int green = static_cast<int>((argb >> 8U) & 0xffU);
    const int blue = static_cast<int>(argb & 0xffU);
    return calculate_unlimited_ct_rgb_pcc(red, green, blue);
}

PccDiagonal combine_pcc_diagonals(const PccDiagonal& first,
                                  const PccDiagonal& second) {
    return normalize_pcc_diagonal({
            first.red * second.red,
            first.green * second.green,
            first.blue * second.blue,
    });
}

bool pcc_coefficient_matches(double actual, double expected) {
    if (actual != actual || expected != expected) {
        return false;
    }
    double difference = actual - expected;
    if (difference < 0.0) {
        difference = -difference;
    }
    return difference <= kPccComparisonTolerance;
}

bool is_identity_pcc(const PccDiagonal& diagonal) {
    return pcc_coefficient_matches(diagonal.red, 1.0) &&
           pcc_coefficient_matches(diagonal.green, 1.0) &&
           pcc_coefficient_matches(diagonal.blue, 1.0);
}

int deinit_qti_locked() {
    if (!g_state.qti_initialized) {
        g_state.qti_handle = 0;
        return 0;
    }

    const uint64_t handle = g_state.qti_handle;
    g_state.qti_handle = 0;
    g_state.qti_initialized = false;
    return normalize_qti_status(disp_api_deinit(handle, 0));
}

int ensure_qti_initialized_locked() {
    if (g_state.qti_initialized) {
        return 0;
    }

    g_state.last_stage = kStageQtiInit;
    uint64_t handle = 0;
    const int status = normalize_qti_status(disp_api_init(&handle, 0));
    g_state.last_qti_status = status;
    if (status != 0) {
        g_state.qti_handle = 0;
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "QTI Display API 初始化失败：status=%d", status);
        return status;
    }

    g_state.qti_handle = handle;
    g_state.qti_initialized = true;

    if (!g_state.legacy_global_pcc_cleared) {
        g_state.last_stage = kStageQtiSetPcc;
        const int clear_status = normalize_qti_status(disp_api_set_global_pcc_config(
                g_state.qti_handle, kPrimaryDisplayId, 0, nullptr));
        g_state.last_qti_status = clear_status;
        if (clear_status != 0) {
            const int deinit_status = deinit_qti_locked();
            __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                                "清除旧 global PCC 失败：status=%d deinitStatus=%d",
                                clear_status, deinit_status);
            g_state.last_qti_status = clear_status;
            return clear_status;
        }
        g_state.legacy_global_pcc_cleared = true;
    }
    return 0;
}

int clear_legacy_user_color_balance_locked() {
    if (g_state.legacy_user_color_balance_cleared) {
        return 0;
    }

    int status = ensure_qti_initialized_locked();
    if (status != 0) {
        return status;
    }

    const QtiUserColorBalanceConfig identity_config = {
            0,
            0,
            1.0,
            1.0,
            1.0,
    };
    status = normalize_qti_status(disp_api_set_usr_color_balance_config(
            g_state.qti_handle, kPrimaryDisplayId, &identity_config));
    g_state.last_qti_status = status;
    if (status != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "清除旧 QTI 用户色彩平衡失败：status=%d", status);
        return status;
    }

    g_state.legacy_user_color_balance_cleared = true;
    return 0;
}

int ensure_bp_binder_transact_locked() {
    if (g_state.bp_binder_transact != nullptr) {
        return 0;
    }

    g_state.last_stage = kStageResolveTransact;
    g_state.bp_binder_transact = reinterpret_cast<BpBinderTransactFn>(
            dlsym(RTLD_DEFAULT, kBpBinderTransactSymbol));
    if (g_state.bp_binder_transact == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "无法解析 Vendor BpBinder::transact");
        return -ENOSYS;
    }
    return 0;
}

void* surface_composer_on_create(void*) {
    return nullptr;
}

void surface_composer_on_destroy(void*) {}

binder_status_t surface_composer_on_transact(AIBinder*, transaction_code_t,
                                               const AParcel*, AParcel*) {
    return STATUS_UNKNOWN_TRANSACTION;
}

int ensure_surface_composer_class_locked() {
    if (g_state.surface_composer_class != nullptr) {
        return 0;
    }

    g_state.surface_composer_class = AIBinder_Class_define(
            kSurfaceComposerDescriptor, surface_composer_on_create,
            surface_composer_on_destroy, surface_composer_on_transact);
    if (g_state.surface_composer_class == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "无法定义 SurfaceComposer Binder NDK 接口类");
        return -ENOMEM;
    }
    return 0;
}

void release_surface_flinger_locked() {
    if (g_state.surface_flinger != nullptr) {
        AIBinder_decStrong(g_state.surface_flinger);
        g_state.surface_flinger = nullptr;
    }
}

AIBinder* get_surface_flinger_locked() {
    if (g_state.surface_flinger != nullptr) {
        return g_state.surface_flinger;
    }

    const int status = ensure_surface_composer_class_locked();
    if (status != 0) {
        return nullptr;
    }

    g_state.last_stage = kStageCheckService;
    AIBinder* surface_flinger =
            AServiceManager_checkService(kSurfaceFlingerServiceName);
    if (surface_flinger == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "System ServiceManager 中不存在或不允许访问 SurfaceFlinger");
        return nullptr;
    }

    if (!AIBinder_associateClass(surface_flinger, g_state.surface_composer_class)) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "SurfaceFlinger 无法关联 android.ui.ISurfaceComposer 接口类");
        AIBinder_decStrong(surface_flinger);
        return nullptr;
    }

    g_state.surface_flinger = surface_flinger;
    g_state.last_stage = kStageServiceReady;
    return g_state.surface_flinger;
}

int transact_surface_flinger_color_matrix_locked(const PccDiagonal& diagonal) {
    AIBinder* binder = get_surface_flinger_locked();
    if (binder == nullptr) {
        g_state.last_surface_flinger_status = -ENODEV;
        return -ENODEV;
    }

    AParcel* input = nullptr;
    g_state.last_stage = kStageWriteInterfaceToken;
    binder_status_t binder_status = AIBinder_prepareTransaction(binder, &input);
    if (binder_status != STATUS_OK) {
        g_state.last_surface_flinger_status =
                binder_status < 0 ? binder_status : -EIO;
        return g_state.last_surface_flinger_status;
    }

    const bool enable = !is_identity_pcc(diagonal);
    binder_status = AParcel_writeInt32(input, enable ? 1 : 0);
    if (binder_status == STATUS_OK && enable) {
        const float matrix[16] = {
                static_cast<float>(diagonal.red), 0.0f, 0.0f, 0.0f,
                0.0f, static_cast<float>(diagonal.green), 0.0f, 0.0f,
                0.0f, 0.0f, static_cast<float>(diagonal.blue), 0.0f,
                0.0f, 0.0f, 0.0f, 1.0f,
        };
        for (float coefficient : matrix) {
            binder_status = AParcel_writeFloat(input, coefficient);
            if (binder_status != STATUS_OK) {
                break;
            }
        }
    }
    if (binder_status != STATUS_OK) {
        AParcel_delete(input);
        g_state.last_surface_flinger_status =
                binder_status < 0 ? binder_status : -EIO;
        return g_state.last_surface_flinger_status;
    }

    AParcel* output = nullptr;
    g_state.last_stage = kStageTransact;
    binder_status = AIBinder_transact(
            binder, kSetSurfaceFlingerColorMatrixCommand, &input, &output, 0);
    if (output != nullptr) {
        AParcel_delete(output);
    }
    if (binder_status == STATUS_DEAD_OBJECT) {
        release_surface_flinger_locked();
    }

    const int status = binder_status == STATUS_OK
                               ? 0
                               : (binder_status < 0 ? binder_status : -EIO);
    g_state.last_surface_flinger_status = status;
    if (status == 0) {
        ++g_state.surface_flinger_color_matrix_applies;
        g_state.last_stage = kStageComplete;
    }
    return status;
}

void set_desired_pcc_locked(const PccDiagonal& requested_diagonal) {
    const PccDiagonal diagonal = normalize_pcc_diagonal(requested_diagonal);
    const bool enable = !is_identity_pcc(diagonal);
    g_state.pcc_configured = enable;
    g_state.pcc_enabled = enable;
    g_state.pcc_apply_pending = true;
    g_state.desired_pcc = diagonal;
    g_state.pcc_pending_retry_polls = 0;
}

int write_global_color_matrix_locked(const PccDiagonal& requested_diagonal) {
    int status = clear_legacy_user_color_balance_locked();
    if (status != 0) {
        return status;
    }

    const PccDiagonal diagonal = normalize_pcc_diagonal(requested_diagonal);
    const bool enable = !is_identity_pcc(diagonal);
    status = transact_surface_flinger_color_matrix_locked(diagonal);
    if (status != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "SurfaceFlinger 色彩矩阵设置失败：enabled=%d "
                            "matrix=(%.4f,%.4f,%.4f) status=%d",
                            enable ? 1 : 0, diagonal.red, diagonal.green,
                            diagonal.blue, status);
        return status;
    }

    g_state.actual_pcc_valid = true;
    g_state.actual_pcc_enabled = enable;
    g_state.actual_pcc = diagonal;
    __android_log_print(ANDROID_LOG_INFO, kLogTag,
                        "SurfaceFlinger 色彩矩阵已应用：enabled=%d "
                        "matrix=(%.4f,%.4f,%.4f) applies=%u",
                        enable ? 1 : 0, diagonal.red, diagonal.green, diagonal.blue,
                        g_state.surface_flinger_color_matrix_applies);
    return 0;
}

int apply_desired_pcc_locked() {
    const int status = write_global_color_matrix_locked(g_state.desired_pcc);
    g_state.pcc_apply_pending = status != 0;
    return status;
}

void sleep_pending_retry_interval() {
    timespec remaining = {0, kPendingRetryIntervalNanoseconds};
    while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {
    }
}

void* pending_retry_main(void*) {
    for (;;) {
        sleep_pending_retry_interval();

        pthread_mutex_lock(&g_state.mutex);
        if (g_state.retry_thread_stop) {
            pthread_mutex_unlock(&g_state.mutex);
            break;
        }
        if (!g_state.pcc_apply_pending) {
            pthread_mutex_unlock(&g_state.mutex);
            continue;
        }

        ++g_state.pcc_pending_retry_polls;
        const uint32_t retry_count = g_state.pcc_pending_retry_polls;
        const PccDiagonal expected = g_state.desired_pcc;
        const int status = apply_desired_pcc_locked();
        g_state.last_brightness_status = status;
        pthread_mutex_unlock(&g_state.mutex);

        if (status == 0) {
            __android_log_print(ANDROID_LOG_INFO, kLogTag,
                                "SurfaceFlinger 就绪后已应用待处理色彩矩阵："
                                "expected=(%.4f,%.4f,%.4f) retries=%u",
                                expected.red, expected.green, expected.blue, retry_count);
        } else if (retry_count == 1 || retry_count % 10 == 0) {
            __android_log_print(ANDROID_LOG_WARN, kLogTag,
                                "待处理 SurfaceFlinger 色彩矩阵重试失败："
                                "expected=(%.4f,%.4f,%.4f) status=%d retries=%u",
                                expected.red, expected.green, expected.blue, status,
                                retry_count);
        }
    }
    return nullptr;
}

int start_pending_retry_thread() {
    pthread_mutex_lock(&g_state.mutex);
    if (g_state.retry_thread_started) {
        pthread_mutex_unlock(&g_state.mutex);
        return 0;
    }

    g_state.retry_thread_stop = false;
    g_state.pcc_pending_retry_polls = 0;
    const int create_status = pthread_create(
            &g_state.retry_thread, nullptr, pending_retry_main, nullptr);
    const int status = create_status == 0 ? 0 : -create_status;
    g_state.retry_thread_status = status;
    g_state.retry_thread_started = create_status == 0;
    pthread_mutex_unlock(&g_state.mutex);

    if (status != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "无法启动色彩矩阵待处理重试线程：status=%d", status);
    }
    return status;
}

int stop_pending_retry_thread() {
    pthread_t retry_thread = {};
    bool should_join = false;

    pthread_mutex_lock(&g_state.mutex);
    if (g_state.retry_thread_started) {
        g_state.retry_thread_stop = true;
        retry_thread = g_state.retry_thread;
        should_join = true;
    }
    pthread_mutex_unlock(&g_state.mutex);

    const int join_status = should_join ? pthread_join(retry_thread, nullptr) : 0;
    const int status = join_status == 0 ? 0 : -join_status;

    pthread_mutex_lock(&g_state.mutex);
    g_state.retry_thread_started = false;
    g_state.retry_thread_stop = false;
    g_state.retry_thread_status = status;
    pthread_mutex_unlock(&g_state.mutex);
    return status;
}

int handle_brightness_notification(int display_id, int brightness) {
    if (display_id != kPrimaryDisplayId) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "亮度通知包含不支持的显示 ID：display=%d brightness=%d",
                            display_id, brightness);
        return -EOPNOTSUPP;
    }

    pthread_mutex_lock(&g_state.mutex);
    g_state.last_brightness = brightness;
    g_state.last_request_mode = kBrightnessNotifyMessageId;
    g_state.last_display_id = display_id;
    g_state.last_value = brightness;
    g_state.last_cookie = 0;
    ++g_state.brightness_notifications;
    g_state.last_brightness_status = 0;
    g_state.last_status = 0;
    const bool pcc_configured = g_state.pcc_configured;
    const bool pcc_enabled = g_state.pcc_enabled;
    const PccDiagonal expected = g_state.desired_pcc;
    pthread_mutex_unlock(&g_state.mutex);

    __android_log_print(ANDROID_LOG_DEBUG, kLogTag,
                        "亮度通知已记录且未重写色彩矩阵：brightness=%d "
                        "pccConfigured=%d pccEnabled=%d pcc=(%.4f,%.4f,%.4f)",
                        brightness, pcc_configured ? 1 : 0, pcc_enabled ? 1 : 0,
                        expected.red, expected.green, expected.blue);
    return 0;
}

int map_xiaomi_mode_to_render_intent(int mode) {
    switch (mode) {
        case 0:
            return 303;  // DefaultSRGB
        case 1:
            return 307;  // EnhanceSRGB
        case 2:
            return 301;  // StandardSRGB
        default:
            return -1;
    }
}

void release_qservice_locked() {
    g_state.qservice.clear();
}

android::IBinder* get_qservice_locked() {
    if (g_state.qservice) {
        g_state.last_stage = kStageServiceReady;
        return g_state.qservice.get();
    }

    g_state.last_stage = kStageGetServiceManager;
    const android::sp<android::IServiceManager> service_manager =
            android::defaultServiceManager();
    if (!service_manager) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "无法获取 Vendor ServiceManager");
        return nullptr;
    }

    g_state.last_stage = kStageCheckService;
    const android::String16 service_name(kQServiceName);
    android::sp<android::IBinder> platform_binder =
            service_manager->checkService(service_name);
    if (!platform_binder) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "Vendor ServiceManager 中不存在 display.qservice");
        return nullptr;
    }

    g_state.qservice = static_cast<android::sp<android::IBinder>&&>(platform_binder);
    g_state.last_stage = kStageServiceReady;
    return g_state.qservice.get();
}

int transact_color_mode_locked(int32_t render_intent) {
    int status = ensure_bp_binder_transact_locked();
    if (status != 0) {
        return status;
    }

    android::IBinder* binder = get_qservice_locked();
    if (binder == nullptr) {
        return -ENODEV;
    }

    android::Parcel input;
    android::Parcel output;
    g_state.last_stage = kStageMarkParcel;
    input.markForBinder(g_state.qservice);

    g_state.last_stage = kStageWriteInterfaceToken;
    const android::String16 interface_token(kQServiceDescriptor);
    status = input.writeInterfaceToken(interface_token);
    if (status != 0) {
        return status < 0 ? status : -EIO;
    }

    g_state.last_stage = kStageWriteDisplayId;
    status = input.writeInt32(kPrimaryDisplayId);
    if (status == 0) {
        g_state.last_stage = kStageWriteColorMode;
        status = input.writeInt32(kSrgbColorMode);
    }
    if (status == 0) {
        g_state.last_stage = kStageWriteRenderIntent;
        status = input.writeInt32(render_intent);
    }
    if (status != 0) {
        return status < 0 ? status : -EIO;
    }

    g_state.last_stage = kStageTransact;
    status = g_state.bp_binder_transact(
            binder, kSetColorModeWithRenderIntentCommand, input, &output, 0);
    if (status == kDeadObjectStatus) {
        release_qservice_locked();
    }
    if (status != 0) {
        return status < 0 ? status : -EIO;
    }

    g_state.last_stage = kStageComplete;
    return 0;
}

int set_feature(displayfeature_device_t*, int display_id, int mode, int value, int cookie) {
    if (display_id != kPrimaryDisplayId) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "不支持的显示 ID：display=%d mode=%d", display_id, mode);
        return -EOPNOTSUPP;
    }

    if (mode == kPaperTextureColorMode) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "纸张纹理色型没有对应的 QTI 接口：mode=%d value=%d cookie=%d",
                            mode, value, cookie);
        return -EOPNOTSUPP;
    }

    const int render_intent = map_xiaomi_mode_to_render_intent(mode);
    if (render_intent < 0 && mode != kEyeCareMode && mode != kColorTemperatureMode) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "不支持的小米色彩模式：mode=%d value=%d cookie=%d",
                            mode, value, cookie);
        return -EOPNOTSUPP;
    }

    const int normalized_eye_care_value =
            mode == kEyeCareMode ? clamp_eye_care_value(value) : value;
    const int requested_eye_care_warmth = mode == kEyeCareMode
                                                  ? map_eye_care_to_warmth(
                                                            normalized_eye_care_value)
                                                  : 0;
    const PccDiagonal requested_eye_care_pcc =
            mode == kEyeCareMode
                    ? calculate_warmth_pcc_diagonal(requested_eye_care_warmth)
                    : PccDiagonal{1.0, 1.0, 1.0};
    const PccDiagonal requested_color_temperature_pcc =
            mode == kColorTemperatureMode ? map_color_temperature_to_pcc(value)
                                          : PccDiagonal{1.0, 1.0, 1.0};

    pthread_mutex_lock(&g_state.mutex);
    g_state.last_request_mode = mode;
    g_state.last_display_id = display_id;
    g_state.last_value = value;
    g_state.last_cookie = cookie;
    int status = 0;
    bool color_mode_applied = false;
    bool pcc_reapplied = false;

    if (render_intent >= 0) {
        status = transact_color_mode_locked(render_intent);
        color_mode_applied = status == 0;
        if (color_mode_applied) {
            g_state.current_xiaomi_mode = mode;
            g_state.current_render_intent = render_intent;
            if (g_state.pcc_configured) {
                pcc_reapplied = true;
                status = apply_desired_pcc_locked();
            }
        }
    } else if (mode == kEyeCareMode) {
        g_state.eye_care_value = normalized_eye_care_value;
        g_state.eye_care_warmth = requested_eye_care_warmth;
        g_state.eye_care_pcc = requested_eye_care_pcc;
        set_desired_pcc_locked(combine_pcc_diagonals(
                g_state.color_temperature_pcc, requested_eye_care_pcc));
        status = apply_desired_pcc_locked();
    } else {
        g_state.color_temperature_value = value;
        g_state.color_temperature_pcc = requested_color_temperature_pcc;
        set_desired_pcc_locked(combine_pcc_diagonals(
                requested_color_temperature_pcc, g_state.eye_care_pcc));
        status = apply_desired_pcc_locked();
    }

    g_state.last_status = status;
    const int last_stage = g_state.last_stage;
    const int color_temperature_value = g_state.color_temperature_value;
    const int eye_care_value = g_state.eye_care_value;
    const int eye_care_warmth = g_state.eye_care_warmth;
    const PccDiagonal color_temperature_pcc = g_state.color_temperature_pcc;
    const PccDiagonal eye_care_pcc = g_state.eye_care_pcc;
    const bool pcc_enabled = g_state.pcc_enabled;
    const bool pcc_apply_pending = g_state.pcc_apply_pending;
    const PccDiagonal desired_pcc = g_state.desired_pcc;
    pthread_mutex_unlock(&g_state.mutex);

    if (render_intent >= 0 && status == 0) {
        __android_log_print(ANDROID_LOG_INFO, kLogTag,
                            "色彩模式请求已投递：xiaomi=%d colorMode=%d renderIntent=%d "
                            "pccReapplied=%d pccEnabled=%d pcc=(%.4f,%.4f,%.4f)",
                            mode, kSrgbColorMode, render_intent, pcc_reapplied ? 1 : 0,
                            pcc_enabled ? 1 : 0, desired_pcc.red, desired_pcc.green,
                            desired_pcc.blue);
    } else if (render_intent >= 0 && color_mode_applied) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "色彩模式已切换，但色彩矩阵重应用失败：xiaomi=%d "
                            "colorMode=%d renderIntent=%d status=%d stage=%d",
                            mode, kSrgbColorMode, render_intent, status, last_stage);
    } else if (render_intent >= 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "色彩模式请求投递失败：xiaomi=%d colorMode=%d renderIntent=%d "
                            "status=%d stage=%d",
                            mode, kSrgbColorMode, render_intent, status, last_stage);
    } else if (status == 0 && mode == kEyeCareMode) {
        __android_log_print(ANDROID_LOG_INFO, kLogTag,
                            "护眼强度已应用：value=%d eyeCareWarmth=%d "
                            "colorTemperatureValue=%d colorPcc=(%.4f,%.4f,%.4f) "
                            "eyeCarePcc=(%.4f,%.4f,%.4f) pccEnabled=%d "
                            "pcc=(%.4f,%.4f,%.4f)",
                            eye_care_value, eye_care_warmth, color_temperature_value,
                            color_temperature_pcc.red, color_temperature_pcc.green,
                            color_temperature_pcc.blue, eye_care_pcc.red,
                            eye_care_pcc.green, eye_care_pcc.blue,
                            pcc_enabled ? 1 : 0, desired_pcc.red, desired_pcc.green,
                            desired_pcc.blue);
    } else if (status == 0) {
        __android_log_print(ANDROID_LOG_INFO, kLogTag,
                            "色温已应用：value=%d (0x%08x) "
                            "colorPcc=(%.4f,%.4f,%.4f) eyeCareValue=%d "
                            "eyeCareWarmth=%d eyeCarePcc=(%.4f,%.4f,%.4f) "
                            "pccEnabled=%d pcc=(%.4f,%.4f,%.4f)",
                            value, static_cast<uint32_t>(value), color_temperature_pcc.red,
                            color_temperature_pcc.green, color_temperature_pcc.blue,
                            eye_care_value, eye_care_warmth, eye_care_pcc.red,
                            eye_care_pcc.green, eye_care_pcc.blue,
                            pcc_enabled ? 1 : 0, desired_pcc.red, desired_pcc.green,
                            desired_pcc.blue);
    } else {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "%s首次应用失败，目标状态已缓存等待重试：value=%d "
                            "status=%d stage=%d pending=%d",
                            mode == kEyeCareMode ? "护眼强度" : "色温", value, status,
                            last_stage, pcc_apply_pending ? 1 : 0);
    }
    return status;
}

int set_function(displayfeature_device_t*, int display_id, int mode, int value, int cookie) {
    __android_log_print(ANDROID_LOG_WARN, kLogTag,
                        "setFunction 尚未映射：display=%d mode=%d value=%d cookie=%d",
                        display_id, mode, value, cookie);
    return -EOPNOTSUPP;
}

void send_message(displayfeature_device_t*, int encoded_message, int value, const void*) {
    const uint32_t encoded = static_cast<uint32_t>(encoded_message);
    const int display_id = static_cast<int>(encoded >> kMessageDisplayIdShift);
    const int message_id = static_cast<int>(encoded & kMessageIdMask);
    if (message_id == kBrightnessNotifyMessageId) {
        (void)handle_brightness_notification(display_id, value);
        return;
    }

    pthread_mutex_lock(&g_state.mutex);
    ++g_state.ignored_messages;
    pthread_mutex_unlock(&g_state.mutex);
}

void set_listener(displayfeature_device_t*, DisplayFeatureListener listener) {
    pthread_mutex_lock(&g_state.mutex);
    g_state.listener = listener;
    pthread_mutex_unlock(&g_state.mutex);
}

void dump_state(displayfeature_device_t*, bool detail, void* output) {
    if (output == nullptr) {
        return;
    }

    char buffer[3072];
    pthread_mutex_lock(&g_state.mutex);
    snprintf(buffer, sizeof(buffer),
             "DisplayFeatureBridge: backend=vendor-platform-binder/display.qservice "
             "qserviceCached=%d colorMatrixBackend=system-libbinder-ndk/SurfaceFlinger "
             "surfaceFlingerCached=%d surfaceFlingerStatus=%d surfaceFlingerApplies=%u "
             "qtiBackend=libsdm-disp-vndapis qtiInitialized=%d "
             "legacyGlobalPccCleared=%d legacyUserColorBalanceCleared=%d "
             "pccConfigured=%d pccEnabled=%d pccApplyPending=%d "
             "pcc=(%.4f,%.4f,%.4f) actualPccValid=%d actualPccEnabled=%d "
             "actualPcc=(%.4f,%.4f,%.4f) "
             "colorTemperatureValue=%d colorTemperatureValueHex=0x%08x "
             "colorTemperaturePcc=(%.4f,%.4f,%.4f) "
             "eyeCareValue=%d eyeCareWarmth=%d eyeCarePcc=(%.4f,%.4f,%.4f) "
             "xiaomiMode=%d colorMode=%d renderIntent=%d lastRequestMode=%d "
             "lastStage=%d lastStatus=%d lastQtiStatus=%d "
             "lastBrightnessStatus=%d lastBrightness=%d lastDisplay=%d lastValue=%d "
             "lastCookie=%d brightnessNotifications=%u pendingRetryPolls=%u "
             "retryThreadStarted=%d retryThreadStatus=%d ignoredMessages=%u "
             "ignoredGamePackages=%u detail=%d\n",
             g_state.qservice ? 1 : 0, g_state.surface_flinger != nullptr ? 1 : 0,
             g_state.last_surface_flinger_status,
             g_state.surface_flinger_color_matrix_applies,
             g_state.qti_initialized ? 1 : 0,
             g_state.legacy_global_pcc_cleared ? 1 : 0,
             g_state.legacy_user_color_balance_cleared ? 1 : 0,
             g_state.pcc_configured ? 1 : 0, g_state.pcc_enabled ? 1 : 0,
             g_state.pcc_apply_pending ? 1 : 0, g_state.desired_pcc.red,
             g_state.desired_pcc.green, g_state.desired_pcc.blue,
             g_state.actual_pcc_valid ? 1 : 0,
             g_state.actual_pcc_enabled ? 1 : 0, g_state.actual_pcc.red,
             g_state.actual_pcc.green, g_state.actual_pcc.blue,
             g_state.color_temperature_value,
             static_cast<uint32_t>(g_state.color_temperature_value),
             g_state.color_temperature_pcc.red, g_state.color_temperature_pcc.green,
             g_state.color_temperature_pcc.blue, g_state.eye_care_value,
             g_state.eye_care_warmth, g_state.eye_care_pcc.red,
             g_state.eye_care_pcc.green, g_state.eye_care_pcc.blue,
             g_state.current_xiaomi_mode, kSrgbColorMode,
             g_state.current_render_intent, g_state.last_request_mode,
             g_state.last_stage, g_state.last_status, g_state.last_qti_status,
             g_state.last_brightness_status, g_state.last_brightness,
             g_state.last_display_id, g_state.last_value, g_state.last_cookie,
             g_state.brightness_notifications, g_state.pcc_pending_retry_polls,
             g_state.retry_thread_started ? 1 : 0, g_state.retry_thread_status,
             g_state.ignored_messages, g_state.ignored_game_packages, detail ? 1 : 0);
    pthread_mutex_unlock(&g_state.mutex);

    using PlatformStringAppend = void* (*)(void*, const char*);
    auto append = reinterpret_cast<PlatformStringAppend>(
            dlsym(RTLD_DEFAULT,
                  "_ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEPKc"));
    if (append != nullptr) {
        append(output, buffer);
    } else {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "无法解析平台 libc++ string::append，dump 输出被跳过");
    }
}

void set_game_pkg_name(displayfeature_device_t*, int, int, int, const void*) {
    pthread_mutex_lock(&g_state.mutex);
    ++g_state.ignored_game_packages;
    pthread_mutex_unlock(&g_state.mutex);
}

void get_capabilities(displayfeature_device_t*, uint32_t* capabilities, int* count) {
    if (capabilities != nullptr) {
        *capabilities = 0;
    }
    if (count != nullptr) {
        *count = 0;
    }
}

void* get_function(displayfeature_device_t*, int function_id) {
    switch (function_id) {
        case 1:
            return reinterpret_cast<void*>(static_cast<SetFeatureFn>(set_feature));
        case 2:
            return reinterpret_cast<void*>(static_cast<SetFunctionFn>(set_function));
        case 3:
            return reinterpret_cast<void*>(static_cast<SendMessageFn>(send_message));
        case 4:
            return reinterpret_cast<void*>(static_cast<SetListenerFn>(set_listener));
        case 5:
            return reinterpret_cast<void*>(static_cast<DumpFn>(dump_state));
        case 6:
            return reinterpret_cast<void*>(static_cast<SetGamePkgNameFn>(set_game_pkg_name));
        default:
            __android_log_print(ANDROID_LOG_WARN, kLogTag,
                                "请求了未知 DisplayFeature 函数：id=%d", function_id);
            return nullptr;
    }
}

int close_device(hw_device_t*) {
    const int retry_status = stop_pending_retry_thread();

    pthread_mutex_lock(&g_state.mutex);
    int reset_status = 0;
    if (g_state.pcc_enabled) {
        reset_status = write_global_color_matrix_locked({1.0, 1.0, 1.0});
    }
    g_state.last_stage = kStageQtiDeinit;
    const int deinit_status = deinit_qti_locked();
    const int status = reset_status != 0
                               ? reset_status
                               : (deinit_status != 0 ? deinit_status : retry_status);

    g_state.pcc_configured = false;
    g_state.pcc_enabled = false;
    g_state.pcc_apply_pending = false;
    g_state.color_temperature_value = 2;
    g_state.eye_care_value = 0;
    g_state.eye_care_warmth = 0;
    g_state.color_temperature_pcc = {1.0, 1.0, 1.0};
    g_state.eye_care_pcc = {1.0, 1.0, 1.0};
    g_state.desired_pcc = {1.0, 1.0, 1.0};
    g_state.actual_pcc_valid = false;
    g_state.actual_pcc_enabled = false;
    g_state.actual_pcc = {1.0, 1.0, 1.0};
    g_state.current_xiaomi_mode = -1;
    g_state.current_render_intent = -1;
    g_state.last_request_mode = -1;
    g_state.last_display_id = -1;
    g_state.last_value = -1;
    g_state.last_cookie = -1;
    g_state.last_status = status;
    g_state.last_qti_status = deinit_status;
    g_state.last_brightness = -1;
    g_state.last_brightness_status = -ENODEV;
    g_state.brightness_notifications = 0;
    g_state.pcc_pending_retry_polls = 0;
    g_state.legacy_global_pcc_cleared = false;
    g_state.legacy_user_color_balance_cleared = false;
    release_surface_flinger_locked();
    release_qservice_locked();
    pthread_mutex_unlock(&g_state.mutex);

    if (reset_status != 0 || deinit_status != 0 || retry_status != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "关闭设备时复位或释放显示后端失败：resetStatus=%d "
                            "deinitStatus=%d retryStatus=%d",
                            reset_status, deinit_status, retry_status);
    }
    return status;
}

displayfeature_device_t g_device = {
        {
                kHardwareDeviceTag,
                0x0100,
                nullptr,
                {0},
                close_device,
        },
        get_capabilities,
        get_function,
};

int open_device(const hw_module_t* module, const char* id, hw_device_t** device) {
    if (device == nullptr) {
        return -EINVAL;
    }
    *device = nullptr;
    if (id == nullptr || strcmp(id, kDeviceName) != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag, "不支持的设备名：%s",
                            id == nullptr ? "<null>" : id);
        return -EINVAL;
    }

    g_device.common.module = const_cast<hw_module_t*>(module);
    *device = &g_device.common;
    (void)start_pending_retry_thread();
    return 0;
}

hw_module_methods_t g_module_methods = {
        open_device,
};

}  // namespace

extern "C" {

__attribute__((visibility("default"), used)) hw_module_t HMI = {
        kHardwareModuleTag,
        0x0001,
        0,
        kModuleId,
        kDeviceName,
        "DNA HyperOS DisplayFeature bridge",
        &g_module_methods,
        nullptr,
        {0},
};

}
