INSTALL_TARGET_PROCESSES = MobileSafari

TARGET = iphone:clang:16.4:16.0
ARCHS= arm64 arm64e
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TabGuard
TabGuard_FILES = Tweak.xm TGPrefs.m TGPopupRequest.m TGPopupBanner.m TGDelegateHook.m
TabGuard_FRAMEWORKS = WebKit
TabGuard_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
after-install::
	install.exec "killall -9 MobileSafari"
SUBPROJECTS += TabGuardPref
include $(THEOS_MAKE_PATH)/aggregate.mk
