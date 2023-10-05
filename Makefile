# Build everything out of tree
O ?= build
override O := $(abspath $(O))

# Interim deployment binaries
I ?= $(O)/intermediate
override I := $(abspath $(I))

# Final deployment binaries
D ?= deploy
override D := $(abspath $(D))

ROOT_DIR= $(shell pwd)
CONFIG_DIR=$(ROOT_DIR)/configs
TFA_DIR ?= $(ROOT_DIR)/arm-trusted-firmware
OPTEE_DIR ?= $(ROOT_DIR)/optee_os
UBOOT_DIR ?= $(ROOT_DIR)/u-boot
FW_DIR=$(ROOT_DIR)/ti-linux-firmware

unexport CROSS_COMPILE
unexport CROSS_COMPILE64
unexport ARCH

# Handle verbose
ifeq ("$(origin V)", "command line")
  VERBOSE = $(V)
endif
VERBOSE ?= 0
Q := $(if $(VERBOSE:1=),@)

# 64bit Defaults
CROSS_COMPILE_64 ?= aarch64-none-linux-gnu-

# 32bit Defaults
CROSS_COMPILE_32 ?= arm-none-linux-gnueabihf-

-include $(O)/.config

ifeq ($(SECURITY_TYPE),gp)
	SECTYPE_EXT = _unsigned
endif

# Packaging variables
PKGNAME = k3-firmware
VERSION = 0
SUBLEVEL = 1
GIT_VERSION = $(shell git describe --always --long --dirty || echo "unknown")
RELEASE_TAG:=$(VERSION).$(SUBLEVEL).$(GIT_VERSION)


.PHONY: all
ifndef SOC_NAME
all: help
	$(Q)echo "Please Select a defconfig"
else
all: u_boot
	$(Q)echo "BUILD COMPLETE: SoC=$(SOC_NAME) Board=$(BOARD_NAME) SECURITY=$(SECURITY_TYPE)"
endif

%defconfig: $(CONFIG_DIR)/%defconfig $(O)
	$(Q)cp $< $(O)/.config

.PHONY: tfa
tfa: $(O) $(I)
	$(Q)$(MAKE) -C $(TFA_DIR) BUILD_BASE=$(O)/arm-trusted-firmware CROSS_COMPILE=$(CROSS_COMPILE_64) ARCH=aarch64 PLAT=k3 TARGET_BOARD=$(TFA_BOARD) $(TFA_EXTRA_ARGS) SPD=opteed DEBUG=1 all
	$(Q)cp -v $(O)/arm-trusted-firmware/k3/$(TFA_BOARD)/debug/bl31.bin $(I)

.PHONY: optee
optee: $(O) $(I)
	$(Q)$(MAKE) -C $(OPTEE_DIR) O=$(O)/optee CROSS_COMPILE=$(CROSS_COMPILE_32) CROSS_COMPILE64=$(CROSS_COMPILE_64) PLATFORM=$(OPTEE_PLATFORM) $(OPTEE_EXTRA_ARGS) CFG_TEE_CORE_LOG_LEVEL=2 CFG_TEE_CORE_DEBUG=y CFG_ARM64_core=y all
	$(Q)cp -v $(O)/optee/core/tee-pager_v2.bin $(I)

.PHONY: u_boot_r5
u_boot_r5: $(O) $(D)
	$(Q)$(MAKE) -C $(UBOOT_DIR) CROSS_COMPILE=$(CROSS_COMPILE_32) O=$(O)/u-boot/r5 $(UBOOT_ARMV7_DEFCONFIG)
	$(Q)$(MAKE) -C $(UBOOT_DIR) CROSS_COMPILE=$(CROSS_COMPILE_32) O=$(O)/u-boot/r5 BINMAN_INDIRS=$(FW_DIR)
	$(Q)cp -v $(O)/u-boot/r5/tiboot3-$(SOC_NAME)-$(SECURITY_TYPE)-evm.bin $(D)/tiboot3.bin
	$(Q)if [ -f $(O)/u-boot/r5/sysfw-$(SOC_NAME)-$(SECURITY_TYPE)-evm.itb ]; then \
		cp -v $(O)/u-boot/r5/sysfw-$(SOC_NAME)-$(SECURITY_TYPE)-evm.itb $(D)/sysfw.itb; \
	fi

.PHONY: u_boot_armv8
u_boot_armv8: $(O) $(D) optee tfa
	$(Q)$(MAKE) -C $(UBOOT_DIR) CROSS_COMPILE=$(CROSS_COMPILE_64) O=$(O)/u-boot/armv8 $(UBOOT_ARMV8_DEFCONFIG)
	$(Q)$(MAKE) -C $(UBOOT_DIR) CROSS_COMPILE=$(CROSS_COMPILE_64) O=$(O)/u-boot/armv8 BINMAN_INDIRS=$(FW_DIR) \
					BL31=$(I)/bl31.bin \
				  TEE=$(I)/tee-pager_v2.bin
	$(Q)cp -v $(O)/u-boot/armv8/tispl.bin$(SECTYPE_EXT) $(D)/tispl.bin
	$(Q)cp -v $(O)/u-boot/armv8/u-boot.img$(SECTYPE_EXT) $(D)/u-boot.img

.PHONY: u_boot
u_boot: u_boot_r5 u_boot_armv8
	$(Q)echo "U-boot Build complete"

$(O):
	$(Q)mkdir -p $(O)

$(D):
	$(Q)mkdir -p $(D)

$(I): $(O)
	$(Q)mkdir -p $(I)

.PHONY: mrproper
mrproper:
	$(Q)rm -rvf $(O) $(I) $(D)

.PHONY:	source-tarball
source-tarball:
	mkdir -p rpm/SOURCES/
	git archive --prefix=k3-upstream-boot-build -o rpm/SOURCES/k3-upstream-boot-build-$(RELEASE_TAG).tar.gz HEAD
	cd arm-trusted-firmware && \
		git archive --prefix=arm-trusted-firmware -o ../rpm/SOURCES/arm-trusted-firmware-$(RELEASE_TAG).tar.gz HEAD
	cd optee_os && \
		git archive --prefix=optee_os -o ../rpm/SOURCES/optee_os-$(RELEASE_TAG).tar.gz HEAD
	cd u-boot && \
		git archive --prefix=u-boot -o ../rpm/SOURCES/u-boot-$(RELEASE_TAG).tar.gz HEAD
	tar -czf rpm/SOURCES/ti-firmware-$(RELEASE_TAG).tar.gz ti-linux-firmware/ti-dm \
		ti-linux-firmware/ti-sysfw

.PHONY:	gen-spec
gen-spec:
	mkdir -p rpm/SRPMS/
	sed "\
		s/%%RELEASE_TAG%%/$(RELEASE_TAG)/; \
		s/%%SPECTARFILE_RELEASE%%/$SPECTARFILE_RELEASE/" rpm/$(PKGNAME).spec.template > rpm/SRPMS/$(PKGNAME).spec

.PHONY: dist-srpm
dist-srpm: source-tarball gen-spec
	rpmbuild -bs --define "_sourcedir $(PWD)/rpm/SOURCES" --define "_srcrpmdir $(PWD)rpm/SRPMS" rpm/SRPMS/$(PKGNAME).spec

.PHONY: dist-rpm
dist-rpm: source-tarball gen-spec
	rpmbuild -bb --define "_sourcedir $(PWD)/rpm/SOURCES" --define "_srcrpmdir $(PWD)rpm/SRPMS" rpm/SRPMS/$(PKGNAME).spec

.PHONY: dist-clean
dist-clean:
	rm -rf rpm/SOURCES rpm/SRPMS

.PHONY: git
git:
	$(Q)git submodule status|grep '^-' && git submodule init && \
		git submodule update || echo 'Git submodules: nothin to update'

.PHONY: gitsync
gitsync:
	$(Q)git submodule init && git submodule sync && \
		git submodule update --remote && \
		echo 'Git submodules: nothin to sync'

.PHONY: gitclean
gitclean:
	$(Q)echo 'WARNING WARNING WARNING'
	$(Q)echo 'git clean -fdx;git reset --hard everything (including all submodules)!'
	$(Q)echo 'ALL LOCAL CHANGES, uncommited changes, untracked files ARE NUKED/WIPED OUT!!!!!!!!'
	$(Q)read -p 'Enter "y" to continue - any other character to abort: ' confirm;\
	if [ "$$confirm" != y ]; then echo "Aborting"; exit 1; fi;\
	echo "Cleaning!"
	$(Q)$(shell git submodule foreach git clean -fdx >/dev/null)
	$(Q)$(shell git submodule foreach git reset --hard >/dev/null)
	$(Q)git clean -fdx
	$(Q)git reset --hard

.PHONY: gitdeinit
gitdeinit:
	$(Q)echo 'WARNING WARNING WARNING'
	$(Q)echo 'git submodule deinit --all -f  -> This will WIPE OUT every git submodule details!!!'
	$(Q)echo 'git clean -fdx;git reset --hard everything (including all submodules)!'
	$(Q)echo 'ALL LOCAL CHANGES, uncommited changes, untracked files ARE NUKED/WIPED OUT!!!!!!!!'
	$(Q)read -p 'Enter "y" to continue - any other character to abort: ' confirm;\
	if [ "$$confirm" != y ]; then echo "Aborting"; exit 1; fi;\
	echo "Cleaning!"
	$(Q)$(shell git submodule foreach git clean -fdx >/dev/null)
	$(Q)$(shell git submodule foreach git reset --hard >/dev/null)
	$(Q)git clean -fdx
	$(Q)git reset --hard
	$(Q)git submodule deinit --all -f

.PHONY: gitdesc
gitdesc: git
	$(Q)$(shell git submodule foreach \
		'echo "    "`git rev-parse --abbrev-ref HEAD`" @"\
			`git describe --always --dirty` ":"\
			`git ls-remote --get-url`'\
		1>&2)
	$(Q)$(shell echo "I am at: "`git rev-parse --abbrev-ref HEAD` \
			"@" `git describe --always --dirty` ":"\
			`git ls-remote --get-url` 1>&2)

.PHONY: help
help:
	$(Q)echo
	$(Q)echo "help:"
	$(Q)echo
	$(Q)echo "Please read README.md for complete details"
	$(Q)echo
	$(Q)echo "Basic steps:"
	$(Q)echo "make soc_board_gp_all_defconfig"
	$(Q)echo "make"
	$(Q)echo
	$(Q)echo "Available defconfigs"
	$(Q)cd $(CONFIG_DIR);ls *defconfig|sort|nl
	$(Q)echo
