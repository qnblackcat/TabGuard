INSTALL_TARGET_PROCESSES = MobileSafari

TARGET = iphone:clang:16.4:16.0
ARCHS= arm64 arm64e
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TabGuard
TabGuard_FILES = Tweak.xm
TabGuard_FRAMEWORKS = WebKit
TabGuard_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
after-install::
	install.exec "killall -9 MobileSafari"
SUBPROJECTS += TabGuard
include $(THEOS_MAKE_PATH)/aggregate.mk
