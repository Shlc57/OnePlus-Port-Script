LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := op13_lhdc_cold
LOCAL_SRC_FILES := lhdc_cold.cpp
LOCAL_CPPFLAGS := -std=c++17 -fvisibility=hidden -fno-exceptions -fno-rtti -mbranch-protection=standard -Wall -Wextra -Werror
LOCAL_LDFLAGS := -Wl,-z,now -Wl,-z,relro
LOCAL_LDLIBS := -llog -ldl
include $(BUILD_SHARED_LIBRARY)
