ifneq ($(KERNELRELEASE),)

# The kernel invokes Kbuild from this branch.  Keep the source list in Kbuild
# so the external Makefile remains usable with each DDK target.

else

DDK_TARGET ?=
KDIR ?= /opt/ddk/kdir/$(DDK_TARGET)
ARCH ?= arm64
LLVM ?= 1
LLVM_IAS ?= 1

ifeq ($(strip $(DDK_TARGET)),)
$(error DDK_TARGET is required; select a DDK target through build.sh)
endif
ifeq ($(wildcard $(KDIR)/Makefile),)
$(error KDIR does not point to a configured kernel build tree: $(KDIR))
endif

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=$(ARCH) LLVM=$(LLVM) LLVM_IAS=$(LLVM_IAS) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=$(ARCH) LLVM=$(LLVM) LLVM_IAS=$(LLVM_IAS) clean

endif
