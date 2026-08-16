#pragma once

#include <stddef.h>
#include <stdint.h>

struct hw_module_t;
struct hw_device_t;

struct hw_module_methods_t {
    int (*open)(const hw_module_t* module, const char* id, hw_device_t** device);
};

struct hw_module_t {
    uint32_t tag;
    uint16_t module_api_version;
    uint16_t hal_api_version;
    const char* id;
    const char* name;
    const char* author;
    hw_module_methods_t* methods;
    void* dso;
    uint64_t reserved[25];
};

struct hw_device_t {
    uint32_t tag;
    uint32_t version;
    hw_module_t* module;
    uint64_t reserved[12];
    int (*close)(hw_device_t* device);
};

constexpr uint32_t kHardwareModuleTag = 0x48574d54U;  // HWMT
constexpr uint32_t kHardwareDeviceTag = 0x48574454U;  // HWDT

static_assert(sizeof(hw_module_t) == 248, "hw_module_t ABI 不匹配");
static_assert(sizeof(hw_device_t) == 120, "hw_device_t ABI 不匹配");

