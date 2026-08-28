#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <link.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits.h>

namespace {

constexpr char kLogTag[] = "OP13HyperOSFix";
constexpr char kTargetLibrary[] = "libbluetooth_jni.so";
constexpr char kCoreLibrary[] = "liblhdcv5.so";
constexpr char kWrapperLibrary[] = "liblhdcv5BT_enc.so";

constexpr uint32_t kIntervalNormalMs = 20;
constexpr uint32_t kIntervalLowLatencyMs = 10;
constexpr uint32_t kBtDefaultBufferSize = 4096 + 16;
constexpr uint16_t kAvdtMediaOffset = 23;
constexpr uint16_t kPayloadHeaderLength = 2;
constexpr uint16_t kLhdcOffset = kAvdtMediaOffset + kPayloadHeaderLength;
constexpr uint32_t kMaxSamplesPerFrame = 960;
constexpr uint32_t kChannelCount = 2;
constexpr uint32_t kMaxBatchFrames = 8;
constexpr size_t kMaxPcmBatchBytes =
        kMaxSamplesPerFrame * kChannelCount * 4U * kMaxBatchFrames;
constexpr size_t kCodecObjectScanSize = 512;
constexpr size_t kCodecInfoSize = 14;
constexpr uint32_t kQualityAuto = 9;

constexpr uint32_t kInterval20Instruction = 0x52800280;
constexpr uint32_t kInterval10Instruction = 0x52800140;
constexpr size_t kIntervalInstructionOffset = 28;
constexpr size_t kStubClusterSize = 72;

constexpr std::array<uint8_t, 48> kStubSignature = {
        0x5f, 0x24, 0x03, 0xd5, 0xc0, 0x03, 0x5f, 0xd6,
        0x5f, 0x24, 0x03, 0xd5, 0xc0, 0x03, 0x5f, 0xd6,
        0x5f, 0x24, 0x03, 0xd5, 0xc0, 0x03, 0x5f, 0xd6,
        0x5f, 0x24, 0x03, 0xd5, 0x80, 0x02, 0x80, 0x52,
        0xc0, 0x03, 0x5f, 0xd6, 0x5f, 0x24, 0x03, 0xd5,
        0xe0, 0x03, 0x1f, 0x2a, 0xc0, 0x03, 0x5f, 0xd6,
};

struct BtHdr {
    uint16_t event;
    uint16_t len;
    uint16_t offset;
    uint16_t layerSpecific;
};

struct EncoderPeerParams {
    bool isPeerEdr;
    bool peerSupports3Mbps;
    uint16_t peerMtu;
};

using ReadCallback = uint32_t (*)(uint8_t*, uint32_t);
using EnqueueCallback = bool (*)(BtHdr*, size_t, uint32_t);
using EncoderInit = void (*)(const EncoderPeerParams*, void*, ReadCallback, EnqueueCallback);
using EncoderCleanup = void (*)();
using FeedingReset = void (*)();
using FeedingFlush = void (*)();
using GetInterval = uint64_t (*)();
using GetEffectiveFrameSize = int (*)();
using SendFrames = void (*)(uint64_t);
using SetQueueLength = void (*)(size_t);

using GetHandle = int32_t (*)(uint32_t, void**);
using FreeHandle = int32_t (*)(void*);
using GetBitrate = int32_t (*)(void*, uint32_t*);
using SetBitrate = int32_t (*)(void*, uint32_t);
using AdjustBitrate = int32_t (*)(void*, uint32_t);
using InitEncoder = int32_t (*)(void*, uint32_t, uint32_t, uint32_t, uint32_t,
                                uint32_t, uint32_t);
using GetBlockSize = int32_t (*)(void*, uint32_t*);
using Encode = int32_t (*)(void*, void*, uint32_t, uint8_t*, uint32_t, uint32_t*,
                           uint32_t*);

struct BackendApi {
    void* coreLibrary = nullptr;
    void* wrapperLibrary = nullptr;
    GetHandle getHandle = nullptr;
    FreeHandle freeHandle = nullptr;
    GetBitrate getBitrate = nullptr;
    SetBitrate setBitrate = nullptr;
    SetBitrate setMaxBitrate = nullptr;
    SetBitrate setMinBitrate = nullptr;
    AdjustBitrate adjustBitrate = nullptr;
    InitEncoder initEncoder = nullptr;
    GetBlockSize getBlockSize = nullptr;
    Encode encode = nullptr;
    bool loaded = false;
};

struct CodecParameters {
    uint32_t sampleRate = 0;
    uint32_t bitsPerSample = 0;
    uint32_t version = 0;
    uint32_t quality = kQualityAuto;
    uint32_t maxBitrate = 0;
    uint32_t minBitrate = 0;
    uint32_t intervalMs = kIntervalNormalMs;
    bool lossless = false;
    size_t otaOffset = 0;
};

struct EncoderState {
    ReadCallback readCallback = nullptr;
    EnqueueCallback enqueueCallback = nullptr;
    void* handle = nullptr;
    uint32_t mtu = 0;
    uint32_t sampleRate = 0;
    uint32_t bitsPerSample = 0;
    uint32_t quality = kQualityAuto;
    uint32_t intervalMs = kIntervalNormalMs;
    uint64_t feedingCounter = 0;
    uint64_t bytesPerTick = 0;
    uint64_t lastFrameUs = 0;
    uint32_t timestamp = 0;
    uint32_t sequence = 0;
    std::array<uint8_t, kMaxPcmBatchBytes> pcmBuffer{};
};

struct TargetImage {
    uintptr_t base = 0;
    const ElfW(Phdr)* headers = nullptr;
    ElfW(Half) headerCount = 0;
};

BackendApi gBackend;
EncoderState gEncoder;
pthread_mutex_t gBackendMutex = PTHREAD_MUTEX_INITIALIZER;
std::atomic<bool> gEncoderReady{false};
std::atomic<uint32_t> gEncodeErrorCount{0};
using LogMessageWriter = void (*)(struct __android_log_message*);
LogMessageWriter gOriginalLogMessageWriter = nullptr;
using LegacyLogWriter = int (*)(int, const char*, const char*);
LegacyLogWriter gOriginalLegacyLogWriter = nullptr;
using BufferedLogWriter = int (*)(int, int, const char*, const char*);
BufferedLogWriter gOriginalBufferedLogWriter = nullptr;

void bridgeEncoderInit(const EncoderPeerParams*, void*, ReadCallback, EnqueueCallback);
void bridgeEncoderCleanup();
void bridgeFeedingReset();
void bridgeFeedingFlush();
uint64_t bridgeGetInterval();
int bridgeGetEffectiveFrameSize();
void bridgeSendFrames(uint64_t);
void bridgeSetQueueLength(size_t);

const char* baseName(const char* path) {
    if (path == nullptr) {
        return nullptr;
    }
    const char* slash = std::strrchr(path, '/');
    return slash == nullptr ? path : slash + 1;
}

int findTargetImage(struct dl_phdr_info* info, size_t, void* data) {
    const char* name = baseName(info->dlpi_name);
    if (name == nullptr || std::strcmp(name, kTargetLibrary) != 0) {
        return 0;
    }
    auto* image = static_cast<TargetImage*>(data);
    image->base = static_cast<uintptr_t>(info->dlpi_addr);
    image->headers = info->dlpi_phdr;
    image->headerCount = info->dlpi_phnum;
    return 1;
}

bool addressIsExecutable(const TargetImage& image, uintptr_t address) {
    for (ElfW(Half) index = 0; index < image.headerCount; ++index) {
        const ElfW(Phdr)& header = image.headers[index];
        if (header.p_type != PT_LOAD || (header.p_flags & PF_X) == 0) {
            continue;
        }
        uintptr_t start = image.base + header.p_vaddr;
        uintptr_t end = start + header.p_memsz;
        if (address >= start && address < end) {
            return true;
        }
    }
    return false;
}

bool matchesStubCluster(const uint8_t* candidate) {
    if (std::memcmp(candidate, kStubSignature.data(), kIntervalInstructionOffset) != 0) {
        return false;
    }
    uint32_t intervalInstruction = 0;
    std::memcpy(&intervalInstruction, candidate + kIntervalInstructionOffset,
                sizeof(intervalInstruction));
    if (intervalInstruction != kInterval20Instruction &&
        intervalInstruction != kInterval10Instruction) {
        return false;
    }
    if (std::memcmp(candidate + kIntervalInstructionOffset + sizeof(intervalInstruction),
                    kStubSignature.data() + kIntervalInstructionOffset +
                            sizeof(intervalInstruction),
                    kStubSignature.size() - kIntervalInstructionOffset -
                            sizeof(intervalInstruction)) != 0) {
        return false;
    }

    uint32_t trailer[6]{};
    std::memcpy(trailer, candidate + kStubSignature.size(), sizeof(trailer));
    return trailer[0] == 0xd503245f && trailer[1] == 0xd65f03c0 &&
           trailer[2] == 0xd503245f &&
           (trailer[3] & 0x9f00001f) == 0x90000008 &&
           (trailer[4] & 0xffc003ff) == 0xb9000100 && trailer[5] == 0xd65f03c0;
}

uint8_t* findUniqueStubCluster(const TargetImage& image) {
    uint8_t* match = nullptr;
    size_t count = 0;
    for (ElfW(Half) index = 0; index < image.headerCount; ++index) {
        const ElfW(Phdr)& header = image.headers[index];
        if (header.p_type != PT_LOAD || (header.p_flags & PF_X) == 0 ||
            header.p_memsz < kStubClusterSize) {
            continue;
        }
        auto* start = reinterpret_cast<uint8_t*>(image.base + header.p_vaddr);
        size_t limit = static_cast<size_t>(header.p_memsz) - kStubClusterSize;
        for (size_t offset = 0; offset <= limit; offset += sizeof(uint32_t)) {
            if (matchesStubCluster(start + offset)) {
                match = start + offset;
                ++count;
            }
        }
    }
    if (count != 1) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "LHDC bridge rejected stub clusters=%zu", count);
        return nullptr;
    }
    return match;
}

uintptr_t readPointer(const uint8_t* address) {
    uintptr_t value = 0;
    std::memcpy(&value, address, sizeof(value));
    return value;
}

uintptr_t* findUniqueInterfaceTable(const TargetImage& image, const uint8_t* cluster) {
    const std::array<uintptr_t, 7> expected = {
            reinterpret_cast<uintptr_t>(cluster),
            reinterpret_cast<uintptr_t>(cluster + 8),
            reinterpret_cast<uintptr_t>(cluster + 16),
            reinterpret_cast<uintptr_t>(cluster + 24),
            reinterpret_cast<uintptr_t>(cluster + 36),
            reinterpret_cast<uintptr_t>(cluster + 48),
            reinterpret_cast<uintptr_t>(cluster + 56),
    };

    uintptr_t* match = nullptr;
    size_t count = 0;
    constexpr size_t tableBytes = sizeof(uintptr_t) * 8;
    for (ElfW(Half) index = 0; index < image.headerCount; ++index) {
        const ElfW(Phdr)& header = image.headers[index];
        if (header.p_type != PT_LOAD || (header.p_flags & PF_R) == 0 ||
            (header.p_flags & PF_X) != 0 || header.p_memsz < tableBytes) {
            continue;
        }
        auto* start = reinterpret_cast<uint8_t*>(image.base + header.p_vaddr);
        size_t limit = static_cast<size_t>(header.p_memsz) - tableBytes;
        for (size_t offset = 0; offset <= limit; offset += alignof(uintptr_t)) {
            const uint8_t* candidate = start + offset;
            bool matches = true;
            for (size_t slot = 0; slot < expected.size(); ++slot) {
                if (readPointer(candidate + (slot + 1) * sizeof(uintptr_t)) != expected[slot]) {
                    matches = false;
                    break;
                }
            }
            if (!matches || !addressIsExecutable(image, readPointer(candidate))) {
                continue;
            }
            match = reinterpret_cast<uintptr_t*>(start + offset);
            ++count;
        }
    }
    if (count != 1) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "LHDC bridge rejected interface tables=%zu", count);
        return nullptr;
    }
    return match;
}

int memoryProtectionFor(const void* address) {
    FILE* maps = std::fopen("/proc/self/maps", "re");
    if (maps == nullptr) {
        return PROT_READ;
    }
    uintptr_t target = reinterpret_cast<uintptr_t>(address);
    char line[512];
    int result = PROT_READ;
    while (std::fgets(line, sizeof(line), maps) != nullptr) {
        unsigned long long start = 0;
        unsigned long long end = 0;
        char permissions[5]{};
        if (std::sscanf(line, "%llx-%llx %4s", &start, &end, permissions) != 3 ||
            target < start || target >= end) {
            continue;
        }
        result = 0;
        if (permissions[0] == 'r') result |= PROT_READ;
        if (permissions[1] == 'w') result |= PROT_WRITE;
        if (permissions[2] == 'x') result |= PROT_EXEC;
        break;
    }
    std::fclose(maps);
    return result;
}

bool textContains(const char* text, const char* fragment) {
    return text != nullptr && std::strstr(text, fragment) != nullptr;
}

bool shouldSuppressHotPathLog(const struct __android_log_message* logMessage) {
    if (!gEncoderReady.load(std::memory_order_relaxed) || logMessage == nullptr ||
        logMessage->message == nullptr) {
        return false;
    }
    const char* file = logMessage->file;
    const char* message = logMessage->message;
    bool fromHalVersion = textContains(file, "hal_version_manager.cc") ||
            textContains(message, "hal_version_manager.cc");
    if (fromHalVersion &&
        textContains(message, "GetHalTransport: HAL Transport: AIDL")) {
        return true;
    }

    bool fromA2dpEncoding = textContains(file, "a2dp_encoding.cc") ||
            textContains(message, "a2dp_encoding.cc");
    if (fromA2dpEncoding &&
        (std::strcmp(message, "is_hal_enabled") == 0 ||
         std::strcmp(message, "read") == 0 ||
         textContains(message, "] is_hal_enabled") ||
         textContains(message, "] read"))) {
        return true;
    }

    bool fromA2dpSource = textContains(file, "btif_a2dp_source.cc") ||
            textContains(message, "btif_a2dp_source.cc");
    return fromA2dpSource &&
            textContains(message, "btif_a2dp_source_enqueue_callback");
}

void filteredLogMessageWriter(struct __android_log_message* logMessage) {
    if (!shouldSuppressHotPathLog(logMessage) && gOriginalLogMessageWriter != nullptr) {
        gOriginalLogMessageWriter(logMessage);
    }
}

int filteredLegacyLogWriter(int priority, const char* tag, const char* message) {
    bool hotPath = gEncoderReady.load(std::memory_order_relaxed) &&
            textContains(message, "a2dp_encoding.cc") &&
            (textContains(message, "] is_hal_enabled") ||
             textContains(message, "] read"));
    if (hotPath) {
        return 1;
    }
    return gOriginalLegacyLogWriter == nullptr
            ? -1 : gOriginalLegacyLogWriter(priority, tag, message);
}

int filteredBufferedLogWriter(int bufferId, int priority, const char* tag,
                              const char* message) {
    bool hotPath = gEncoderReady.load(std::memory_order_relaxed) &&
            textContains(message, "a2dp_encoding.cc") &&
            (textContains(message, "] is_hal_enabled") ||
             textContains(message, "] read"));
    if (hotPath) {
        return 1;
    }
    return gOriginalBufferedLogWriter == nullptr
            ? -1 : gOriginalBufferedLogWriter(bufferId, priority, tag, message);
}

int filteredLogPrint(int priority, const char* tag, const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    bool candidate = gEncoderReady.load(std::memory_order_relaxed) &&
            format != nullptr;
    if (candidate) {
        char message[512];
        va_list copy;
        va_copy(copy, arguments);
        std::vsnprintf(message, sizeof(message), format, copy);
        va_end(copy);
        if (textContains(message, "a2dp_encoding.cc") &&
            (textContains(message, "] is_hal_enabled") ||
             textContains(message, "] read"))) {
            va_end(arguments);
            return 1;
        }
    }
    int result = __android_log_vprint(priority, tag, format, arguments);
    va_end(arguments);
    return result;
}

bool replaceReadOnlyPointer(uintptr_t* slot, uintptr_t replacement,
                            uintptr_t* originalOutput) {
    uintptr_t original = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (original == replacement) {
        return true;
    }
    long pageSizeValue = sysconf(_SC_PAGESIZE);
    if (pageSizeValue <= 0) {
        return false;
    }
    size_t pageSize = static_cast<size_t>(pageSizeValue);
    uintptr_t pageStart = reinterpret_cast<uintptr_t>(slot) &
            ~(static_cast<uintptr_t>(pageSize) - 1U);
    int originalProtection = memoryProtectionFor(slot);
    if (mprotect(reinterpret_cast<void*>(pageStart), pageSize,
                 originalProtection | PROT_WRITE) != 0) {
        return false;
    }
    *originalOutput = original;
    __atomic_store_n(slot, replacement, __ATOMIC_RELEASE);
    if (mprotect(reinterpret_cast<void*>(pageStart), pageSize, originalProtection) != 0) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "LHDC hot-log filter installed; protection restore failed");
    }
    return true;
}

[[maybe_unused]] bool installHotPathLogFilter(const TargetImage& image) {
    const ElfW(Dyn)* dynamic = nullptr;
    size_t dynamicCount = 0;
    for (ElfW(Half) index = 0; index < image.headerCount; ++index) {
        const ElfW(Phdr)& header = image.headers[index];
        if (header.p_type != PT_DYNAMIC) {
            continue;
        }
        dynamic = reinterpret_cast<const ElfW(Dyn)*>(image.base + header.p_vaddr);
        dynamicCount = static_cast<size_t>(header.p_memsz) / sizeof(ElfW(Dyn));
        break;
    }
    if (dynamic == nullptr) {
        return false;
    }

    const ElfW(Sym)* symbols = nullptr;
    const char* strings = nullptr;
    const ElfW(Rela)* relocations = nullptr;
    size_t relocationBytes = 0;
    ElfW(Sword) relocationType = DT_NULL;
    for (size_t index = 0; index < dynamicCount && dynamic[index].d_tag != DT_NULL;
         ++index) {
        switch (dynamic[index].d_tag) {
            case DT_SYMTAB:
                symbols = reinterpret_cast<const ElfW(Sym)*>(
                        image.base + dynamic[index].d_un.d_ptr);
                break;
            case DT_STRTAB:
                strings = reinterpret_cast<const char*>(
                        image.base + dynamic[index].d_un.d_ptr);
                break;
            case DT_JMPREL:
                relocations = reinterpret_cast<const ElfW(Rela)*>(
                        image.base + dynamic[index].d_un.d_ptr);
                break;
            case DT_PLTRELSZ:
                relocationBytes = static_cast<size_t>(dynamic[index].d_un.d_val);
                break;
            case DT_PLTREL:
                relocationType = static_cast<ElfW(Sword)>(dynamic[index].d_un.d_val);
                break;
            default:
                break;
        }
    }
    if (symbols == nullptr || strings == nullptr || relocations == nullptr ||
        relocationBytes == 0 || relocationType != DT_RELA) {
        return false;
    }

    uintptr_t* messageSlot = nullptr;
    uintptr_t* legacySlot = nullptr;
    uintptr_t* printSlot = nullptr;
    uintptr_t* bufferedSlot = nullptr;
    size_t relocationCount = relocationBytes / sizeof(ElfW(Rela));
    for (size_t index = 0; index < relocationCount; ++index) {
        size_t symbolIndex = ELF64_R_SYM(relocations[index].r_info);
        const char* name = strings + symbols[symbolIndex].st_name;
        if (std::strcmp(name, "__android_log_write_log_message") == 0) {
            messageSlot = reinterpret_cast<uintptr_t*>(
                    image.base + relocations[index].r_offset);
        } else if (std::strcmp(name, "__android_log_write") == 0) {
            legacySlot = reinterpret_cast<uintptr_t*>(
                    image.base + relocations[index].r_offset);
        } else if (std::strcmp(name, "__android_log_print") == 0) {
            printSlot = reinterpret_cast<uintptr_t*>(
                    image.base + relocations[index].r_offset);
        } else if (std::strcmp(name, "__android_log_buf_write") == 0) {
            bufferedSlot = reinterpret_cast<uintptr_t*>(
                    image.base + relocations[index].r_offset);
        }
    }
    if (messageSlot == nullptr || legacySlot == nullptr || printSlot == nullptr ||
        bufferedSlot == nullptr) {
        return false;
    }

    uintptr_t originalMessage = 0;
    if (!replaceReadOnlyPointer(
                messageSlot, reinterpret_cast<uintptr_t>(&filteredLogMessageWriter),
                &originalMessage)) {
        return false;
    }
    gOriginalLogMessageWriter = reinterpret_cast<LogMessageWriter>(originalMessage);

    uintptr_t originalLegacy = 0;
    if (!replaceReadOnlyPointer(
                legacySlot, reinterpret_cast<uintptr_t>(&filteredLegacyLogWriter),
                &originalLegacy)) {
        return false;
    }
    gOriginalLegacyLogWriter = reinterpret_cast<LegacyLogWriter>(originalLegacy);

    uintptr_t ignoredOriginalPrint = 0;
    if (!replaceReadOnlyPointer(
                printSlot, reinterpret_cast<uintptr_t>(&filteredLogPrint),
                &ignoredOriginalPrint)) {
        return false;
    }

    uintptr_t originalBuffered = 0;
    if (!replaceReadOnlyPointer(
                bufferedSlot, reinterpret_cast<uintptr_t>(&filteredBufferedLogWriter),
                &originalBuffered)) {
        return false;
    }
    gOriginalBufferedLogWriter = reinterpret_cast<BufferedLogWriter>(originalBuffered);
    return true;
}

bool replaceInterfaceTable(uintptr_t* table) {
    const std::array<uintptr_t, 8> replacements = {
            reinterpret_cast<uintptr_t>(&bridgeEncoderInit),
            reinterpret_cast<uintptr_t>(&bridgeEncoderCleanup),
            reinterpret_cast<uintptr_t>(&bridgeFeedingReset),
            reinterpret_cast<uintptr_t>(&bridgeFeedingFlush),
            reinterpret_cast<uintptr_t>(&bridgeGetInterval),
            reinterpret_cast<uintptr_t>(&bridgeGetEffectiveFrameSize),
            reinterpret_cast<uintptr_t>(&bridgeSendFrames),
            reinterpret_cast<uintptr_t>(&bridgeSetQueueLength),
    };

    long pageSizeValue = sysconf(_SC_PAGESIZE);
    if (pageSizeValue <= 0) {
        return false;
    }
    size_t pageSize = static_cast<size_t>(pageSizeValue);
    uintptr_t tableStart = reinterpret_cast<uintptr_t>(table);
    uintptr_t pageStart = tableStart & ~(static_cast<uintptr_t>(pageSize) - 1U);
    uintptr_t tableEnd = tableStart + replacements.size() * sizeof(uintptr_t);
    uintptr_t pageEnd = (tableEnd + pageSize - 1U) & ~(static_cast<uintptr_t>(pageSize) - 1U);
    size_t length = pageEnd - pageStart;
    int originalProtection = memoryProtectionFor(table);
    if (mprotect(reinterpret_cast<void*>(pageStart), length,
                 originalProtection | PROT_WRITE) != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC bridge could not write interface table");
        return false;
    }
    for (size_t slot = 0; slot < replacements.size(); ++slot) {
        __atomic_store_n(table + slot, replacements[slot], __ATOMIC_RELEASE);
    }
    if (mprotect(reinterpret_cast<void*>(pageStart), length, originalProtection) != 0) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "LHDC bridge installed; table protection restore failed");
    }
    return true;
}

template <typename T>
bool loadSymbol(void* library, const char* name, T* output) {
    *output = reinterpret_cast<T>(dlsym(library, name));
    if (*output != nullptr) {
        return true;
    }
    __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                        "LHDC bridge missing backend symbol %s", name);
    return false;
}

void unloadBackend(BackendApi* backend) {
    if (backend->wrapperLibrary != nullptr) {
        dlclose(backend->wrapperLibrary);
    }
    if (backend->coreLibrary != nullptr) {
        dlclose(backend->coreLibrary);
    }
    *backend = BackendApi{};
}

bool loadBackendLocked() {
    if (gBackend.loaded) {
        return true;
    }

    Dl_info ownLibrary{};
    if (dladdr(reinterpret_cast<void*>(&bridgeEncoderInit), &ownLibrary) == 0 ||
        ownLibrary.dli_fname == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC bridge cannot locate module native directory");
        return false;
    }
    char directory[PATH_MAX];
    if (std::strlen(ownLibrary.dli_fname) >= sizeof(directory)) {
        return false;
    }
    std::strcpy(directory, ownLibrary.dli_fname);
    char* slash = std::strrchr(directory, '/');
    if (slash == nullptr) {
        return false;
    }
    *slash = '\0';

    char corePath[PATH_MAX];
    char wrapperPath[PATH_MAX];
    if (std::snprintf(corePath, sizeof(corePath), "%s/%s", directory, kCoreLibrary) >=
            static_cast<int>(sizeof(corePath)) ||
        std::snprintf(wrapperPath, sizeof(wrapperPath), "%s/%s", directory, kWrapperLibrary) >=
            static_cast<int>(sizeof(wrapperPath))) {
        return false;
    }

    BackendApi backend;
    backend.coreLibrary = dlopen(corePath, RTLD_NOW | RTLD_GLOBAL);
    if (backend.coreLibrary == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC bridge core load failed: %s", dlerror());
        return false;
    }
    backend.wrapperLibrary = dlopen(wrapperPath, RTLD_NOW | RTLD_LOCAL);
    if (backend.wrapperLibrary == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC bridge wrapper load failed: %s", dlerror());
        unloadBackend(&backend);
        return false;
    }

    bool valid =
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_get_handle", &backend.getHandle) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_free_handle", &backend.freeHandle) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_get_bitrate", &backend.getBitrate) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_set_bitrate", &backend.setBitrate) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_set_max_bitrate",
                       &backend.setMaxBitrate) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_set_min_bitrate",
                       &backend.setMinBitrate) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_adjust_bitrate",
                       &backend.adjustBitrate) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_init_encoder", &backend.initEncoder) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_get_block_Size",
                       &backend.getBlockSize) &&
            loadSymbol(backend.wrapperLibrary, "lhdcv5BT_encode", &backend.encode);
    if (!valid) {
        unloadBackend(&backend);
        return false;
    }
    backend.loaded = true;
    gBackend = backend;
    __android_log_print(ANDROID_LOG_INFO, kLogTag,
                        "LHDC V5 encoder backend loaded on demand");
    return true;
}

bool ensureBackendLoaded() {
    pthread_mutex_lock(&gBackendMutex);
    bool result = loadBackendLocked();
    pthread_mutex_unlock(&gBackendMutex);
    return result;
}

bool singleBit(uint8_t value) {
    return value != 0 && (value & static_cast<uint8_t>(value - 1U)) == 0;
}

bool parseOtaCodecInfo(const uint8_t* data, CodecParameters* parameters) {
    if (data[0] != 13 || (data[1] >> 4U) != 0 || data[2] != 0xff ||
        data[3] != 0x3a || data[4] != 0x05 || data[5] != 0 || data[6] != 0 ||
        data[7] != 0x35 || data[8] != 0x4c) {
        return false;
    }

    uint8_t sampleRate = data[9] & 0x35;
    uint8_t bits = data[10] & 0x07;
    uint8_t version = data[11] & 0x0f;
    if (!singleBit(sampleRate) || !singleBit(bits) || !singleBit(version) ||
        (data[11] & 0x10) == 0) {
        return false;
    }
    switch (sampleRate) {
        case 0x20: parameters->sampleRate = 44100; break;
        case 0x10: parameters->sampleRate = 48000; break;
        case 0x04: parameters->sampleRate = 96000; break;
        case 0x01: parameters->sampleRate = 192000; break;
        default: return false;
    }
    switch (bits) {
        case 0x04: parameters->bitsPerSample = 16; break;
        case 0x02: parameters->bitsPerSample = 24; break;
        case 0x01: parameters->bitsPerSample = 32; break;
        default: return false;
    }
    parameters->version = version;
    switch (data[10] & 0x30) {
        case 0x00: parameters->maxBitrate = 8; break;
        case 0x30: parameters->maxBitrate = 7; break;
        case 0x20: parameters->maxBitrate = 6; break;
        case 0x10: parameters->maxBitrate = 5; break;
    }
    switch (data[10] & 0xc0) {
        case 0x00: parameters->minBitrate = 0; break;
        case 0x40: parameters->minBitrate = 1; break;
        case 0x80: parameters->minBitrate = 3; break;
        case 0xc0: parameters->minBitrate = 5; break;
    }
    parameters->intervalMs = (data[12] & 0x40) != 0
            ? kIntervalLowLatencyMs : kIntervalNormalMs;
    parameters->lossless = (data[12] & 0x80) != 0;
    return true;
}

int32_t readInt32(const uint8_t* address) {
    int32_t value = 0;
    std::memcpy(&value, address, sizeof(value));
    return value;
}

int64_t readInt64(const uint8_t* address) {
    int64_t value = 0;
    std::memcpy(&value, address, sizeof(value));
    return value;
}

void findSelectedQuality(const uint8_t* object, size_t otaOffset,
                         CodecParameters* parameters) {
    constexpr size_t codecConfigSize = 56;
    constexpr size_t codecSpecific1Offset = 24;
    for (size_t offset = 0; offset + codecConfigSize <= otaOffset; offset += 4) {
        int32_t codecType = readInt32(object + offset);
        int32_t priority = readInt32(object + offset + 4);
        uint32_t sampleRate = static_cast<uint32_t>(readInt32(object + offset + 8));
        uint32_t bits = static_cast<uint32_t>(readInt32(object + offset + 12));
        uint32_t channelMode = static_cast<uint32_t>(readInt32(object + offset + 16));
        if (codecType != 19 || priority < -1 || priority > 100000 ||
            !singleBit(static_cast<uint8_t>(sampleRate)) || sampleRate > 0x20 ||
            !singleBit(static_cast<uint8_t>(bits)) || bits > 0x04 || channelMode != 2) {
            continue;
        }
        uint64_t specific = static_cast<uint64_t>(readInt64(
                object + offset + codecSpecific1Offset));
        uint32_t quality = static_cast<uint32_t>(specific & 0xffU);
        if ((specific & 0xc000U) == 0x8000U && quality <= kQualityAuto) {
            parameters->quality = quality;
            return;
        }
    }
}

bool readCodecParameters(void* codecConfig, CodecParameters* parameters) {
    const auto* object = static_cast<const uint8_t*>(codecConfig);
    bool found = false;
    for (size_t offset = 0; offset + kCodecInfoSize <= kCodecObjectScanSize; ++offset) {
        CodecParameters candidate;
        if (!parseOtaCodecInfo(object + offset, &candidate)) {
            continue;
        }
        candidate.otaOffset = offset;
        *parameters = candidate;
        found = true;
        break;
    }
    if (!found) {
        return false;
    }
    findSelectedQuality(object, parameters->otaOffset, parameters);
    return true;
}

void clearEncoderState() {
    gEncoder.readCallback = nullptr;
    gEncoder.enqueueCallback = nullptr;
    gEncoder.handle = nullptr;
    gEncoder.mtu = 0;
    gEncoder.sampleRate = 0;
    gEncoder.bitsPerSample = 0;
    gEncoder.quality = kQualityAuto;
    gEncoder.intervalMs = kIntervalNormalMs;
    gEncoder.feedingCounter = 0;
    gEncoder.bytesPerTick = 0;
    gEncoder.lastFrameUs = 0;
    gEncoder.timestamp = 0;
    gEncoder.sequence = 0;
}

void releaseEncoderHandle() {
    gEncoderReady.store(false, std::memory_order_release);
    if (gEncoder.handle != nullptr && gBackend.freeHandle != nullptr) {
        int32_t result = gBackend.freeHandle(gEncoder.handle);
        if (result != 0) {
            __android_log_print(ANDROID_LOG_WARN, kLogTag,
                                "LHDC V5 free handle failed=%d", result);
        }
    }
    clearEncoderState();
}

void resetFeedingState() {
    gEncoder.feedingCounter = 0;
    gEncoder.bytesPerTick =
            static_cast<uint64_t>(gEncoder.sampleRate) * gEncoder.bitsPerSample / 8U *
            kChannelCount * gEncoder.intervalMs / 1000U;
    gEncoder.lastFrameUs = 0;
    gEncoder.sequence = 0;
    if (gEncoder.handle != nullptr && gEncoder.quality == kQualityAuto &&
        gBackend.setBitrate != nullptr) {
        gBackend.setBitrate(gEncoder.handle, kQualityAuto);
    }
}

void bridgeEncoderInit(const EncoderPeerParams* peer, void* codecConfig,
                       ReadCallback readCallback, EnqueueCallback enqueueCallback) {
    gEncoderReady.store(false, std::memory_order_release);
    releaseEncoderHandle();
    if (peer == nullptr || codecConfig == nullptr || readCallback == nullptr ||
        enqueueCallback == nullptr || peer->peerMtu <= kPayloadHeaderLength) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC V5 encoder init rejected invalid input");
        return;
    }
    if (!ensureBackendLoaded()) {
        return;
    }

    CodecParameters parameters;
    if (!readCodecParameters(codecConfig, &parameters)) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC V5 OTA codec config not found in OS4 object");
        return;
    }

    gEncoder.readCallback = readCallback;
    gEncoder.enqueueCallback = enqueueCallback;
    gEncoder.sampleRate = parameters.sampleRate;
    gEncoder.bitsPerSample = parameters.bitsPerSample;
    gEncoder.quality = parameters.quality;
    gEncoder.intervalMs = parameters.intervalMs;
    gEncoder.mtu = std::min<uint32_t>(
            peer->peerMtu, kBtDefaultBufferSize - kLhdcOffset - sizeof(BtHdr));

    int32_t result = gBackend.getHandle(parameters.version, &gEncoder.handle);
    if (result != 0 || gEncoder.handle == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC V5 get handle failed=%d version=%u", result,
                            parameters.version);
        releaseEncoderHandle();
        return;
    }

    uint32_t maxBitrate = parameters.lossless ? 8 : parameters.maxBitrate;
    uint32_t encoderMtu = gEncoder.mtu - kPayloadHeaderLength;
    result = gBackend.initEncoder(gEncoder.handle, gEncoder.sampleRate,
                                  gEncoder.bitsPerSample, gEncoder.quality, encoderMtu,
                                  gEncoder.intervalMs, parameters.lossless ? 1U : 0U);
    if (result == 0) result = gBackend.setMaxBitrate(gEncoder.handle, maxBitrate);
    if (result == 0) result = gBackend.setMinBitrate(gEncoder.handle, parameters.minBitrate);
    if (result == 0) result = gBackend.setBitrate(gEncoder.handle, gEncoder.quality);
    if (result != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC V5 backend initialization failed=%d", result);
        releaseEncoderHandle();
        return;
    }

    gEncoder.timestamp = 0;
    resetFeedingState();
    gEncodeErrorCount.store(0, std::memory_order_relaxed);
    gEncoderReady.store(true, std::memory_order_release);
    __android_log_print(ANDROID_LOG_INFO, kLogTag,
                        "LHDC V5 ready: %u Hz/%u bit q=%u mtu=%u tick=%u ms lossless=%u ota=0x%zx",
                        gEncoder.sampleRate, gEncoder.bitsPerSample, gEncoder.quality,
                        gEncoder.mtu, gEncoder.intervalMs, parameters.lossless ? 1U : 0U,
                        parameters.otaOffset);
}

void bridgeEncoderCleanup() {
    releaseEncoderHandle();
}

void bridgeFeedingReset() {
    if (!gEncoderReady.load(std::memory_order_acquire)) {
        return;
    }
    resetFeedingState();
}

void bridgeFeedingFlush() {
    gEncoder.feedingCounter = 0;
}

uint64_t bridgeGetInterval() {
    return gEncoder.intervalMs;
}

int bridgeGetEffectiveFrameSize() {
    return static_cast<int>(gEncoder.mtu);
}

void logEncodeErrorOnce(const char* message, int32_t result) {
    if (gEncodeErrorCount.fetch_add(1, std::memory_order_relaxed) == 0) {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag, "%s=%d", message, result);
    }
}

bool readPcmBatch(uint8_t* buffer, uint32_t expectedBytes) {
    uint32_t actual = gEncoder.readCallback(buffer, expectedBytes);
    if (actual == 0) {
        return false;
    }
    if (actual > expectedBytes) {
        actual = expectedBytes;
    }
    if (actual < expectedBytes) {
        std::memset(buffer + actual, 0, expectedBytes - actual);
    }
    return true;
}

void bridgeSendFrames(uint64_t timestampUs) {
    if (!gEncoderReady.load(std::memory_order_acquire)) {
        return;
    }

    uint32_t samplesPerFrame = 0;
    int32_t result = gBackend.getBlockSize(gEncoder.handle, &samplesPerFrame);
    if (result != 0 || samplesPerFrame == 0 || samplesPerFrame > kMaxSamplesPerFrame) {
        logEncodeErrorOnce("LHDC V5 invalid block size", result);
        return;
    }
    uint32_t pcmBytesPerFrame = samplesPerFrame * kChannelCount *
            gEncoder.bitsPerSample / 8U;
    constexpr uint32_t frameCapacity = kMaxSamplesPerFrame * kChannelCount * 4U;
    if (pcmBytesPerFrame == 0 || pcmBytesPerFrame > frameCapacity) {
        logEncodeErrorOnce("LHDC V5 PCM frame too large",
                           static_cast<int32_t>(pcmBytesPerFrame));
        return;
    }

    uint64_t elapsedUs = static_cast<uint64_t>(gEncoder.intervalMs) * 1000U;
    if (gEncoder.lastFrameUs != 0 && timestampUs > gEncoder.lastFrameUs) {
        elapsedUs = timestampUs - gEncoder.lastFrameUs;
    }
    gEncoder.lastFrameUs = timestampUs;
    gEncoder.feedingCounter += gEncoder.bytesPerTick * elapsedUs /
            (static_cast<uint64_t>(gEncoder.intervalMs) * 1000U);
    uint64_t scheduledFrames = gEncoder.feedingCounter / pcmBytesPerFrame;
    gEncoder.feedingCounter -= scheduledFrames * pcmBytesPerFrame;
    // A stale media-task timestamp must not trigger an expensive catch-up burst.
    uint32_t frameCount = static_cast<uint32_t>(
            std::min<uint64_t>(scheduledFrames, kMaxBatchFrames));
    if (frameCount == 0) {
        return;
    }

    uint32_t batchBytes = frameCount * pcmBytesPerFrame;
    if (!readPcmBatch(gEncoder.pcmBuffer.data(), batchBytes)) {
        gEncoder.feedingCounter += batchBytes;
        return;
    }

    uint32_t frameIndex = 0;
    while (frameIndex < frameCount && gEncoderReady.load(std::memory_order_acquire)) {
        auto* packet = static_cast<BtHdr*>(std::malloc(kBtDefaultBufferSize));
        if (packet == nullptr) {
            logEncodeErrorOnce("LHDC V5 packet allocation failed", -1);
            return;
        }
        packet->event = 0;
        packet->len = 0;
        packet->offset = kLhdcOffset;
        packet->layerSpecific = 0;

        uint32_t writtenFrames = 0;
        uint32_t sourceBytes = 0;
        uint32_t written = 0;
        do {
            uint8_t* input = gEncoder.pcmBuffer.data() +
                    static_cast<size_t>(frameIndex) * pcmBytesPerFrame;
            sourceBytes += pcmBytesPerFrame;
            uint32_t available = kBtDefaultBufferSize - sizeof(BtHdr) - packet->offset -
                    packet->len;
            uint8_t* output = reinterpret_cast<uint8_t*>(packet + 1) + packet->offset +
                    packet->len;
            uint32_t outputFrames = 0;
            written = 0;
            result = gBackend.encode(gEncoder.handle, input, pcmBytesPerFrame, output,
                                     available, &written, &outputFrames);
            if (result != 0 || written > available) {
                std::free(packet);
                logEncodeErrorOnce("LHDC V5 encode failed", result);
                return;
            }
            packet->len = static_cast<uint16_t>(packet->len + written);
            writtenFrames += outputFrames;
            ++frameIndex;
        } while (written == 0 && frameIndex < frameCount);

        if (packet->len == 0) {
            std::free(packet);
            continue;
        }
        packet->layerSpecific = static_cast<uint16_t>(
                ((gEncoder.sequence++ & 0xffU) << 8U) | ((writtenFrames << 2U) & 0xffU));
        std::memcpy(packet + 1, &gEncoder.timestamp, sizeof(gEncoder.timestamp));
        gEncoder.timestamp += writtenFrames * samplesPerFrame;
        if (!gEncoder.enqueueCallback(packet, 1, sourceBytes)) {
            return;
        }
    }
}

void bridgeSetQueueLength(size_t queueLength) {
    if (!gEncoderReady.load(std::memory_order_acquire) ||
        gEncoder.quality != kQualityAuto || gBackend.adjustBitrate == nullptr) {
        return;
    }
    int32_t result = gBackend.adjustBitrate(
            gEncoder.handle, static_cast<uint32_t>(std::min<size_t>(queueLength, UINT32_MAX)));
    if (result != 0) {
        logEncodeErrorOnce("LHDC V5 ABR adjustment failed", result);
    }
}

int installBridge() {
    TargetImage image;
    dl_iterate_phdr(findTargetImage, &image);
    if (image.headers == nullptr) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "LHDC bridge target JNI library not loaded");
        return -1;
    }
    uint8_t* cluster = findUniqueStubCluster(image);
    if (cluster == nullptr) {
        return -2;
    }
    uintptr_t* table = findUniqueInterfaceTable(image, cluster);
    if (table == nullptr) {
        return -3;
    }
    if (!replaceInterfaceTable(table)) {
        return -4;
    }
    if (!installHotPathLogFilter(image)) {
        __android_log_print(ANDROID_LOG_WARN, kLogTag,
                            "LHDC bridge installed without hot-log filter");
    }
    __android_log_print(ANDROID_LOG_INFO, kLogTag,
                        "LHDC V5 cold encoder interface installed");
    return 1;
}

int probeLhdcLibraries() {
    Dl_info ownLibrary{};
    if (dladdr(reinterpret_cast<void*>(&probeLhdcLibraries), &ownLibrary) == 0 ||
        ownLibrary.dli_fname == nullptr) {
        return 0;
    }
    char directory[PATH_MAX];
    if (std::strlen(ownLibrary.dli_fname) >= sizeof(directory)) {
        return 0;
    }
    std::strcpy(directory, ownLibrary.dli_fname);
    char* slash = std::strrchr(directory, '/');
    if (slash == nullptr) {
        return 0;
    }
    *slash = '\0';

    char corePath[PATH_MAX];
    char wrapperPath[PATH_MAX];
    if (std::snprintf(corePath, sizeof(corePath), "%s/%s", directory, kCoreLibrary) >=
            static_cast<int>(sizeof(corePath)) ||
        std::snprintf(wrapperPath, sizeof(wrapperPath), "%s/%s", directory,
                      kWrapperLibrary) >= static_cast<int>(sizeof(wrapperPath))) {
        return 0;
    }

    int status = 0;
    void* core = dlopen(corePath, RTLD_NOW | RTLD_GLOBAL);
    if (core == nullptr) {
        return status;
    }
    status |= 1;
    void* wrapper = dlopen(wrapperPath, RTLD_NOW | RTLD_LOCAL);
    if (wrapper != nullptr) {
        status |= 2;
        const char* required[] = {
                "lhdcv5BT_get_handle",
                "lhdcv5BT_init_encoder",
                "lhdcv5BT_encode",
        };
        bool symbolsPresent = true;
        for (const char* symbol : required) {
            if (dlsym(wrapper, symbol) == nullptr) {
                symbolsPresent = false;
                break;
            }
        }
        if (symbolsPresent) {
            status |= 4;
        }
        dlclose(wrapper);
    }
    dlclose(core);
    return status;
}

}  // namespace

extern "C" __attribute__((constructor)) void op13LhdcColdInit() {
    auto installAfterJniLoad = [](void*) -> void* {
        // Dependency constructors run before libbluetooth_jni's own constructors.
        // Wait until that load transaction has completed, then retry only during
        // this short startup window. No worker remains after installation.
        usleep(100000);
        int result = -1;
        for (int attempt = 0; attempt < 50; ++attempt) {
            result = installBridge();
            if (result > 0) {
                return nullptr;
            }
            usleep(20000);
        }
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC cold bridge init failed, status=%d", result);
        return nullptr;
    };

    pthread_t worker;
    if (pthread_create(&worker, nullptr, installAfterJniLoad, nullptr) == 0) {
        pthread_detach(worker);
    } else {
        __android_log_print(ANDROID_LOG_ERROR, kLogTag,
                            "LHDC cold bridge could not start init worker");
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_local_mio_op13hyperosfix_BluetoothHooks_nativeApplyLhdcPatch(JNIEnv*, jclass) {
    static std::atomic<int> result{0};
    int cached = result.load(std::memory_order_acquire);
    if (cached > 0) {
        return cached;
    }
    int current = installBridge();
    if (current > 0) {
        result.store(current, std::memory_order_release);
    }
    return current;
}

extern "C" JNIEXPORT jint JNICALL
Java_local_mio_op13hyperosfix_NativeDiagnostics_nativeProbeLhdc(JNIEnv*, jclass) {
    return probeLhdcLibraries();
}
