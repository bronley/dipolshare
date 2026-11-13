TARGET = iphone:clang:5.0:4.2
ARCHS = armv6 armv7

PACKAGE_FORMAT = ipa

DEV_TESTING ?= 0
ifeq ($(filter $(DEV_TESTING),0 1),)
$(error DEV_TESTING must be 0 or 1)
endif
ifeq ($(DEV_TESTING),1)
THEOS_OBJ_DIR_NAME = obj/dev-testing$(_THEOS_OBJ_DIR_EXTENSION)
THEOS_PACKAGE_DIR = packages/dev-testing
endif

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DipolShare

DipolShare_FILES = $(shell find Sources -name '*.m' -o -name '*.mm' -o -name '*.c' -o -name '*.cpp')
DipolShare_FILES += Vendor/JSONKit/JSONKit.m

DipolShare_FRAMEWORKS = \
    UIKit \
    Foundation \
    CoreGraphics \
    Security \
    QuickLook \
    AssetsLibrary \
    AddressBook \
    MobileCoreServices \
    AudioToolbox \
    QuartzCore \
    ImageIO

DipolShare_RESOURCE_DIRS = Resources/Images Resources/Sounds
DipolShare_RESOURCE_FILES = Configuration/Info.plist
DipolShare_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/Configuration/theos.entitlements

include $(THEOS_MAKE_PATH)/application.mk

DipolShare_LDFLAGS += \
    $(THEOS_PROJECT_DIR)/Vendor/OpenSSL/libssl-3.5.8-ios4.a \
    $(THEOS_PROJECT_DIR)/Vendor/OpenSSL/libcrypto-3.5.8-ios4.a

CLASSIC_LINKER ?= $(shell xcrun --find ld-classic 2>/dev/null)
ifneq ($(CLASSIC_LINKER),)
DipolShare_LDFLAGS += -fuse-ld=$(CLASSIC_LINKER)
endif

DipolShare_CFLAGS += \
    -DDIPOLSHARE_DEV_TESTING=$(DEV_TESTING) \
    -fblocks \
    -I$(THEOS_PROJECT_DIR)/Vendor/OpenSSL/include \
    -I$(THEOS_PROJECT_DIR)/Sources/Shared

SOURCE_DIRS := $(shell find $(THEOS_PROJECT_DIR)/Sources -type d)

DipolShare_CFLAGS += \
	$(addprefix -I,$(SOURCE_DIRS)) \
	-I$(THEOS_PROJECT_DIR)/Vendor/OpenSSL/include \
	-I$(THEOS_PROJECT_DIR)/Vendor/JSONKit
