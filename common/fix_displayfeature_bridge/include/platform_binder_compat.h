#pragma once

#include <stddef.h>
#include <stdint.h>

namespace android {

class RefBase {
public:
    void incStrong(const void* id) const;
    void decStrong(const void* id) const;

protected:
    RefBase();
    virtual ~RefBase();
    virtual void onFirstRef();
    virtual void onLastStrongRef(const void* id);
    virtual bool onIncStrongAttempted(uint32_t flags, const void* id);
    virtual void onLastWeakRef(const void* id);

private:
    class weakref_impl;
    weakref_impl* const mRefs;
};

template <typename T>
class sp {
public:
    constexpr sp() : ptr_(nullptr) {}

    sp(const sp& other) : ptr_(other.ptr_) {
        if (ptr_ != nullptr) {
            ptr_->incStrong(this);
        }
    }

    sp(sp&& other) noexcept : ptr_(other.ptr_) {
        other.ptr_ = nullptr;
    }

    sp& operator=(const sp& other) {
        if (ptr_ == other.ptr_) {
            return *this;
        }

        T* new_ptr = other.ptr_;
        if (new_ptr != nullptr) {
            new_ptr->incStrong(this);
        }

        T* old_ptr = ptr_;
        ptr_ = new_ptr;
        if (old_ptr != nullptr) {
            old_ptr->decStrong(this);
        }
        return *this;
    }

    sp& operator=(sp&& other) noexcept {
        if (this == &other) {
            return *this;
        }

        clear();
        ptr_ = other.ptr_;
        other.ptr_ = nullptr;
        return *this;
    }

    ~sp() {
        if (ptr_ != nullptr) {
            ptr_->decStrong(this);
        }
    }

    T* get() const {
        return ptr_;
    }

    T* operator->() const {
        return ptr_;
    }

    explicit operator bool() const {
        return ptr_ != nullptr;
    }

    void clear() {
        T* old_ptr = ptr_;
        ptr_ = nullptr;
        if (old_ptr != nullptr) {
            old_ptr->decStrong(this);
        }
    }

private:
    T* ptr_;
};

class IBinder : public virtual RefBase {};

class IInterface : public virtual RefBase {
public:
    IInterface();

protected:
    virtual ~IInterface();
    virtual IBinder* onAsBinder() = 0;
};

class String16 {
public:
    explicit String16(const char* value);
    ~String16();

private:
    const char16_t* value_;
};

class alignas(8) Parcel {
public:
    Parcel();
    ~Parcel();

    void markForBinder(const sp<IBinder>& binder);
    int32_t writeInterfaceToken(const String16& interface);
    int32_t writeInt32(int32_t value);

private:
    unsigned char opaque_[120];
};

class IServiceManager : public IInterface {
public:
    virtual const String16& getInterfaceDescriptor() const;

    IServiceManager();
    virtual ~IServiceManager();

    virtual sp<IBinder> getService(const String16& name) const = 0;
    virtual sp<IBinder> checkService(const String16& name) const = 0;
};

sp<IServiceManager> defaultServiceManager();

}  // namespace android

static_assert(sizeof(android::sp<android::IBinder>) == sizeof(void*),
              "Platform Binder sp ABI 不匹配");
static_assert(sizeof(android::RefBase) == 2 * sizeof(void*), "Platform RefBase ABI 不匹配");
static_assert(sizeof(android::String16) == sizeof(void*), "Platform String16 ABI 不匹配");
static_assert(sizeof(android::Parcel) == 120, "Platform Parcel ABI 不匹配");
static_assert(alignof(android::Parcel) == 8, "Platform Parcel 对齐不匹配");
