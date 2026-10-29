INSTALL_TARGET_PROCESSES = MobileSafari

TARGET = iphone:clang:16.4:15.0
ARCHS= arm64 arm64e
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TabGuard
TabGuard_FILES = Tweak.xm TGPrefs.m TGPrefsShared.m TGPopupRequest.m TGPopupBanner.m TGDelegateHook.m
TabGuard_FRAMEWORKS = WebKit
TabGuard_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

# make TABGUARD_DEBUG=1 to log the tweak's decisions to Console.app
ifeq ($(TABGUARD_DEBUG),1)
TabGuard_CFLAGS += -DTG_DEBUG=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
after-install::
	install.exec "killall -9 MobileSafari"
SUBPROJECTS += TabGuardPref
include $(THEOS_MAKE_PATH)/aggregate.mk
