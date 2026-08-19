#include "platform_binder_compat.h"

#include <android/binder_parcel.h>
#include <android/log.h>

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace {

constexpr char kLogTag[] = "TouchFeatureOplusBridge";
constexpr char kXiaomiDescriptor[] =
        "vendor.xiaomi.hw.touchfeature.ITouchFeature";
constexpr char kXiaomiService[] =
        "vendor.xiaomi.hw.touchfeature.ITouchFeature/default";
constexpr char kXiaomiInterfaceHash[] =
        "734e11ac1aabda7e8d55c6a8d162630186d35915";
constexpr char kOplusDescriptor[] =
        "vendor.oplus.hardware.touch.IOplusTouch";
constexpr char kOplusService[] =
        "vendor.oplus.hardware.touch.IOplusTouch/default";

constexpr transaction_code_t kXiaomiSetModeValueTransaction = 9;
constexpr transaction_code_t kOplusTouchWriteNodeTransaction = 4;
constexpr transaction_code_t kGetInterfaceHashTransaction = 0x00fffffeU;
constexpr transaction_code_t kGetInterfaceVersionTransaction = 0x00ffffffU;
constexpr binder_flags_t kPrivateLocalFlag = 0x10000000U;
constexpr int32_t kXiaomiInterfaceVersion = 1;
constexpr int32_t kXiaomiPrimaryTouchId = 0;
constexpr int32_t kXiaomiDoubleTapMode = 14;
constexpr int32_t kOplusWriteSuccess = 1;

struct BridgeConfig {
    int32_t panel_id;
    int32_t gesture_cfg_node;
    int32_t gesture_enable_node;
    int32_t gesture_cfg_value;
};

struct BridgeState {
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    BridgeConfig config = {};
    AIBinder_Class* oplus_class = nullptr;
    AIBinder_Class* xiaomi_class = nullptr;
    AIBinder* oplus_service = nullptr;
    AIBinder* xiaomi_service = nullptr;
    int32_t last_requested_value = -1;
    int32_t last_backend_result = -ENODEV;
    uint32_t successful_updates = 0;
};

BridgeState g_state;

void* stateless_on_create(void*) {
    return nullptr;
}

void stateless_on_destroy(void*) {}

binder_status_t reject_all_transactions(AIBinder*, transaction_code_t,
                                         const AParcel*, AParcel*) {
    return STATUS_UNKNOWN_TRANSACTION;
}

int parse_non_negative_int32(const char* value, const char* description,
                             int32_t* output) {
    if (value == nullptr || value[0] == '\0' || output == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "%s parameter is empty", description);
        return -EINVAL;
    }

    errno = 0;
    char* end = nullptr;
    const long parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed < 0 ||
        parsed > INT32_MAX) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "%s parameter is invalid: %s", description, value);
        return -EINVAL;
    }
    *output = static_cast<int32_t>(parsed);
    return 0;
}

int ensure_oplus_class_locked() {
    if (g_state.oplus_class != nullptr) {
        return 0;
    }
    g_state.oplus_class = AIBinder_Class_define(
            kOplusDescriptor, stateless_on_create, stateless_on_destroy,
            reject_all_transactions);
    if (g_state.oplus_class == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "failed to define IOplusTouch Binder class");
        return -ENOMEM;
    }
    return 0;
}

void release_oplus_service_locked() {
    if (g_state.oplus_service != nullptr) {
        AIBinder_decStrong(g_state.oplus_service);
        g_state.oplus_service = nullptr;
    }
}

AIBinder* adopt_oplus_service_locked(AIBinder* service) {
    if (service == nullptr) {
        return nullptr;
    }
    if (!AIBinder_associateClass(service, g_state.oplus_class)) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "IOplusTouch service descriptor mismatch");
        AIBinder_decStrong(service);
        return nullptr;
    }
    release_oplus_service_locked();
    g_state.oplus_service = service;
    return g_state.oplus_service;
}

AIBinder* get_oplus_service_locked(bool wait_for_service) {
    if (g_state.oplus_service != nullptr &&
        AIBinder_isAlive(g_state.oplus_service)) {
        return g_state.oplus_service;
    }
    release_oplus_service_locked();
    if (ensure_oplus_class_locked() != 0) {
        return nullptr;
    }

    AIBinder* service = wait_for_service
                                 ? AServiceManager_waitForService(kOplusService)
                                 : AServiceManager_checkService(kOplusService);
    return adopt_oplus_service_locked(service);
}

int write_oplus_node_locked(int32_t node_id, const char* value) {
    AIBinder* backend = get_oplus_service_locked(false);
    if (backend == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "IOplusTouch backend is unavailable");
        return -ENODEV;
    }

    AParcel* input = nullptr;
    AParcel* output = nullptr;
    binder_status_t status = AIBinder_prepareTransaction(backend, &input);
    if (status == STATUS_OK) {
        status = AParcel_writeInt32(input, g_state.config.panel_id);
    }
    if (status == STATUS_OK) {
        status = AParcel_writeInt32(input, node_id);
    }
    if (status == STATUS_OK) {
        status = AParcel_writeString(input, value,
                                     static_cast<int32_t>(strlen(value)));
    }
    if (status != STATUS_OK) {
        AParcel_delete(input);
        return status;
    }

    status = AIBinder_transact(backend, kOplusTouchWriteNodeTransaction,
                               &input, &output, kPrivateLocalFlag);
    if (status == STATUS_DEAD_OBJECT) {
        release_oplus_service_locked();
    }
    if (status != STATUS_OK) {
        AParcel_delete(output);
        return status;
    }

    AStatus* service_status = nullptr;
    status = AParcel_readStatusHeader(output, &service_status);
    if (status != STATUS_OK) {
        AStatus_delete(service_status);
        AParcel_delete(output);
        return status;
    }
    if (!AStatus_isOk(service_status)) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "IOplusTouch node write returned exception: %s",
                            AStatus_getDescription(service_status));
        AStatus_delete(service_status);
        AParcel_delete(output);
        return -EIO;
    }
    AStatus_delete(service_status);

    int32_t backend_result = 0;
    status = AParcel_readInt32(output, &backend_result);
    AParcel_delete(output);
    if (status != STATUS_OK) {
        return status;
    }
    if (backend_result != kOplusWriteSuccess) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "IOplusTouch rejected node write: node=%d result=%d",
                            node_id, backend_result);
        return -EIO;
    }
    return 0;
}

int update_double_tap_locked(int32_t requested_value) {
    if (requested_value == 0) {
        return write_oplus_node_locked(g_state.config.gesture_enable_node, "0");
    }
    if (requested_value != 1) {
        return -EINVAL;
    }

    char gesture_cfg_value[16];
    const int length = snprintf(gesture_cfg_value, sizeof(gesture_cfg_value),
                                "%d", g_state.config.gesture_cfg_value);
    if (length <= 0 || static_cast<size_t>(length) >= sizeof(gesture_cfg_value)) {
        return -EINVAL;
    }
    int status = write_oplus_node_locked(g_state.config.gesture_cfg_node,
                                         gesture_cfg_value);
    if (status != 0) {
        return status;
    }
    return write_oplus_node_locked(g_state.config.gesture_enable_node, "1");
}

binder_status_t write_ok_header(AParcel* output) {
    AStatus* ok = AStatus_newOk();
    if (ok == nullptr) {
        return STATUS_NO_MEMORY;
    }
    const binder_status_t status = AParcel_writeStatusHeader(output, ok);
    AStatus_delete(ok);
    return status;
}

binder_status_t write_int_response(AParcel* output, int32_t value) {
    binder_status_t status = write_ok_header(output);
    if (status == STATUS_OK) {
        status = AParcel_writeInt32(output, value);
    }
    return status;
}

binder_status_t xiaomi_on_transact(AIBinder*, transaction_code_t code,
                                    const AParcel* input, AParcel* output) {
    if (code == kGetInterfaceVersionTransaction) {
        return write_int_response(output, kXiaomiInterfaceVersion);
    }
    if (code == kGetInterfaceHashTransaction) {
        binder_status_t status = write_ok_header(output);
        if (status == STATUS_OK) {
            status = AParcel_writeString(
                    output, kXiaomiInterfaceHash,
                    static_cast<int32_t>(strlen(kXiaomiInterfaceHash)));
        }
        return status;
    }
    if (code != kXiaomiSetModeValueTransaction) {
        return STATUS_UNKNOWN_TRANSACTION;
    }

    int32_t touch_id = -1;
    int32_t mode = -1;
    int32_t value = -1;
    binder_status_t status = AParcel_readInt32(input, &touch_id);
    if (status == STATUS_OK) {
        status = AParcel_readInt32(input, &mode);
    }
    if (status == STATUS_OK) {
        status = AParcel_readInt32(input, &value);
    }
    if (status != STATUS_OK) {
        return status;
    }

    int32_t result = -EOPNOTSUPP;
    if (touch_id == kXiaomiPrimaryTouchId && mode == kXiaomiDoubleTapMode) {
        pthread_mutex_lock(&g_state.mutex);
        result = update_double_tap_locked(value);
        g_state.last_requested_value = value;
        g_state.last_backend_result = result;
        if (result == 0) {
            ++g_state.successful_updates;
        }
        pthread_mutex_unlock(&g_state.mutex);

        __android_log_print(result == 0 ? ANDROID_LOG_INFO : ANDROID_LOG_ERROR,
                            kLogTag,
                            "double-tap request: touchId=%d mode=%d value=%d result=%d",
                            touch_id, mode, value, result);
    } else {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "unsupported request: touchId=%d mode=%d value=%d",
                            touch_id, mode, value);
    }
    return write_int_response(output, result);
}

binder_status_t xiaomi_on_dump(AIBinder*, int fd, const char**, uint32_t) {
    pthread_mutex_lock(&g_state.mutex);
    dprintf(fd,
            "TouchFeatureOplusBridge: panelId=%d gestureCfgNode=%d "
            "gestureEnableNode=%d gestureCfgValue=%d backendCached=%d "
            "lastRequestedValue=%d lastBackendResult=%d successfulUpdates=%u\n",
            g_state.config.panel_id, g_state.config.gesture_cfg_node,
            g_state.config.gesture_enable_node, g_state.config.gesture_cfg_value,
            g_state.oplus_service != nullptr ? 1 : 0,
            g_state.last_requested_value, g_state.last_backend_result,
            g_state.successful_updates);
    pthread_mutex_unlock(&g_state.mutex);
    return STATUS_OK;
}

int register_xiaomi_service() {
    g_state.xiaomi_class = AIBinder_Class_define(
            kXiaomiDescriptor, stateless_on_create, stateless_on_destroy,
            xiaomi_on_transact);
    if (g_state.xiaomi_class == nullptr) {
        return -ENOMEM;
    }
    AIBinder_Class_setOnDump(g_state.xiaomi_class, xiaomi_on_dump);

    g_state.xiaomi_service = AIBinder_new(g_state.xiaomi_class, nullptr);
    if (g_state.xiaomi_service == nullptr) {
        return -ENOMEM;
    }
    AIBinder_markVintfStability(g_state.xiaomi_service);
    const binder_status_t status =
            AServiceManager_addService(g_state.xiaomi_service, kXiaomiService);
    if (status != STATUS_OK) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "failed to register Xiaomi TouchFeature service: %d",
                            status);
        return status;
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 5) {
        __android_log_print(
                ANDROID_LOG_ERROR, kLogTag,
                "usage: %s PANEL_ID GESTURE_CFG_NODE GESTURE_ENABLE_NODE "
                "GESTURE_CFG_VALUE",
                argc > 0 && argv[0] != nullptr ? argv[0] : "touchfeature-oplus-bridge");
        return EXIT_FAILURE;
    }

    if (parse_non_negative_int32(argv[1], "panel ID",
                                 &g_state.config.panel_id) != 0 ||
        parse_non_negative_int32(argv[2], "gesture cfg node",
                                 &g_state.config.gesture_cfg_node) != 0 ||
        parse_non_negative_int32(argv[3], "gesture enable node",
                                 &g_state.config.gesture_enable_node) != 0 ||
        parse_non_negative_int32(argv[4], "gesture cfg value",
                                 &g_state.config.gesture_cfg_value) != 0) {
        return EXIT_FAILURE;
    }

    ABinderProcess_setThreadPoolMaxThreadCount(1);
    ABinderProcess_startThreadPool();

    pthread_mutex_lock(&g_state.mutex);
    const bool backend_ready = get_oplus_service_locked(true) != nullptr;
    pthread_mutex_unlock(&g_state.mutex);
    if (!backend_ready) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "failed to connect to IOplusTouch backend");
        return EXIT_FAILURE;
    }

    const int status = register_xiaomi_service();
    if (status != 0) {
        return EXIT_FAILURE;
    }
    __android_log_print(
            ANDROID_LOG_INFO, kLogTag,
            "registered %s -> %s (panel=%d cfgNode=%d enableNode=%d cfgValue=%d)",
            kXiaomiService, kOplusService, g_state.config.panel_id,
            g_state.config.gesture_cfg_node, g_state.config.gesture_enable_node,
            g_state.config.gesture_cfg_value);
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;
}
