TARGET = iphone:clang:5.0:4.2
ARCHS = armv6 armv7

PACKAGE_FORMAT = ipa

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
    AudioToolbox \
    QuartzCore

DipolShare_RESOURCE_DIRS = Resources/Images Resources/Sounds
DipolShare_RESOURCE_FILES = Configuration/Info.plist
DipolShare_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/Configuration/theos.entitlements

include $(THEOS_MAKE_PATH)/application.mk

DipolShare_LDFLAGS += \
    $(THEOS_PROJECT_DIR)/Vendor/OpenSSL/libssl-3.5.8-ios4.a \
    $(THEOS_PROJECT_DIR)/Vendor/OpenSSL/libcrypto-3.5.8-ios4.a

# iOS 4.2
CLASSIC_LINKER ?= $(shell xcrun --find ld-classic 2>/dev/null)
ifneq ($(CLASSIC_LINKER),)
DipolShare_LDFLAGS += -fuse-ld=$(CLASSIC_LINKER)
endif

DipolShare_CFLAGS += \
    -fblocks \
    -I$(THEOS_PROJECT_DIR)/Vendor/OpenSSL/include \
    -I$(THEOS_PROJECT_DIR)/Sources/Shared

SOURCE_DIRS := $(shell find $(THEOS_PROJECT_DIR)/Sources -type d)

DipolShare_CFLAGS += \
	$(addprefix -I,$(SOURCE_DIRS)) \
	-I$(THEOS_PROJECT_DIR)/Vendor/OpenSSL/include \
	-I$(THEOS_PROJECT_DIR)/Vendor/JSONKit
