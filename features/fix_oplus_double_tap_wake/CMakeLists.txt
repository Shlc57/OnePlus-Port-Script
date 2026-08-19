cmake_minimum_required(VERSION 3.22)
project(touchfeature_oplus_bridge LANGUAGES CXX)

add_executable(touchfeature-oplus-bridge src/touchfeature_oplus_bridge.cpp)

set(OPLUS_DOUBLE_TAP_PROJECT_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
    CACHE PATH "目标移植工程根目录")
set(OPLUS_DOUBLE_TAP_SYSTEM_LIB_DIR
    "${OPLUS_DOUBLE_TAP_PROJECT_ROOT}/system/system/lib64"
    CACHE PATH "目标 System 平台库目录")

set(touchfeature_binder_ndk_path
    "${OPLUS_DOUBLE_TAP_SYSTEM_LIB_DIR}/libbinder_ndk.so")
if(NOT EXISTS "${touchfeature_binder_ndk_path}")
    message(FATAL_ERROR "缺少目标平台库：${touchfeature_binder_ndk_path}")
endif()
add_library(touchfeature_platform_binder_ndk SHARED IMPORTED)
set_target_properties(touchfeature_platform_binder_ndk PROPERTIES
    IMPORTED_LOCATION "${touchfeature_binder_ndk_path}"
)

target_compile_features(touchfeature-oplus-bridge PRIVATE cxx_std_17)
target_include_directories(touchfeature-oplus-bridge PRIVATE include)
target_compile_options(touchfeature-oplus-bridge PRIVATE
    -Os
    -Wall
    -Wextra
    -Werror
    -fvisibility=hidden
    -fno-exceptions
    -fno-rtti
    -fno-threadsafe-statics
    -ffunction-sections
    -fdata-sections
    -mbranch-protection=standard
)
target_link_options(touchfeature-oplus-bridge PRIVATE
    -nostdlib++
    -Wl,--as-needed
    -Wl,--gc-sections
    -Wl,--no-undefined
    -Wl,--strip-all
    -Wl,-z,max-page-size=16384
    -Wl,-z,relro
    -Wl,-z,now
)
target_link_libraries(touchfeature-oplus-bridge PRIVATE
    log
    touchfeature_platform_binder_ndk
)

set_target_properties(touchfeature-oplus-bridge PROPERTIES
    OUTPUT_NAME "vendor.dna.hardware.touchfeature-oplus-bridge"
)
