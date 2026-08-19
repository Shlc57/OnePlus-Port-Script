#pragma once

#include <android/binder_ibinder.h>
#include <android/binder_status.h>

#include <stdint.h>

// These stable libbinder_ndk entry points are exported by the target system,
// but the standalone NDK sysroot intentionally omits the service-manager and
// process headers used by platform builds.
extern "C" {

binder_status_t AServiceManager_addService(AIBinder* binder, const char* instance);
AIBinder* AServiceManager_checkService(const char* instance);
AIBinder* AServiceManager_waitForService(const char* instance);

void ABinderProcess_setThreadPoolMaxThreadCount(uint32_t num_threads);
void ABinderProcess_startThreadPool();
void ABinderProcess_joinThreadPool();

void AIBinder_markVintfStability(AIBinder* binder);

}
