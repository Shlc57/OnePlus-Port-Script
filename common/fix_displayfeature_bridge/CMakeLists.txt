cmake_minimum_required(VERSION 3.22)
project(displayfeature_bridge LANGUAGES CXX)

add_library(displayfeature.default SHARED src/displayfeature_bridge.cpp)

set(DISPLAYFEATURE_PROJECT_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
    CACHE PATH "目标移植工程根目录")
set(DISPLAYFEATURE_VENDOR_LIB_DIR
    "${DISPLAYFEATURE_PROJECT_ROOT}/vendor/lib64"
    CACHE PATH "目标 Vendor 平台库目录")
set(DISPLAYFEATURE_SYSTEM_LIB_DIR
    "${DISPLAYFEATURE_PROJECT_ROOT}/system/system/lib64"
    CACHE PATH "目标 System 平台库目录")

foreach(platform_library binder utils)
    set(platform_library_path "${DISPLAYFEATURE_VENDOR_LIB_DIR}/lib${platform_library}.so")
    if(NOT EXISTS "${platform_library_path}")
        message(FATAL_ERROR "缺少目标平台库：${platform_library_path}")
    endif()
    add_library(displayfeature_platform_${platform_library} SHARED IMPORTED)
    set_target_properties(displayfeature_platform_${platform_library} PROPERTIES
        IMPORTED_LOCATION "${platform_library_path}"
    )
endforeach()

set(displayfeature_binder_ndk_path
    "${DISPLAYFEATURE_SYSTEM_LIB_DIR}/libbinder_ndk.so")
if(NOT EXISTS "${displayfeature_binder_ndk_path}")
    message(FATAL_ERROR "缺少目标平台库：${displayfeature_binder_ndk_path}")
endif()
add_library(displayfeature_platform_binder_ndk SHARED IMPORTED)
set_target_properties(displayfeature_platform_binder_ndk PROPERTIES
    IMPORTED_LOCATION "${displayfeature_binder_ndk_path}"
)

set(displayfeature_qti_vndapis_path
    "${DISPLAYFEATURE_VENDOR_LIB_DIR}/libsdm-disp-vndapis.so")
if(NOT EXISTS "${displayfeature_qti_vndapis_path}")
    message(FATAL_ERROR "缺少目标平台库：${displayfeature_qti_vndapis_path}")
endif()
add_library(displayfeature_qti_vndapis SHARED IMPORTED)
set_target_properties(displayfeature_qti_vndapis PROPERTIES
    IMPORTED_LOCATION "${displayfeature_qti_vndapis_path}"
)

target_compile_features(displayfeature.default PRIVATE cxx_std_17)
target_include_directories(displayfeature.default PRIVATE include)
target_compile_options(displayfeature.default PRIVATE
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
target_link_options(displayfeature.default PRIVATE
    -nostdlib++
    -Wl,--as-needed
    -Wl,--gc-sections
    -Wl,--no-undefined
    -Wl,--strip-all
    -Wl,-z,max-page-size=16384
    -Wl,-z,relro
    -Wl,-z,now
    -Wl,-soname,displayfeature.default.so
)
target_link_libraries(displayfeature.default PRIVATE
    log
    dl
    displayfeature_platform_binder
    displayfeature_platform_binder_ndk
    displayfeature_platform_utils
    displayfeature_qti_vndapis
)

set_target_properties(displayfeature.default PROPERTIES
    PREFIX ""
    OUTPUT_NAME "displayfeature.default"
)
