ARCHS= arm64 arm64e
TARGET = iphone:clang:16.4:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = TabGuard
TabGuard_FILES = TGRootListController.m
TabGuard_INSTALL_PATH = /Library/PreferenceBundles
TabGuard_FRAMEWORKS = UIKit UniformTypeIdentifiers
TabGuard_PRIVATE_FRAMEWORKS = Preferences
TabGuard_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/TabGuard.plist$(ECHO_END)
