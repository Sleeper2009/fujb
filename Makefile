ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

THEOS_DEVICE_IP =
INSTALL_TARGET_PROCESSES = mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LEDBreathe

LEDBreathe_FILES = Tweak.xm
LEDBreathe_CFLAGS = -fobjc-arc
LEDBreathe_FRAMEWORKS = Foundation
LEDBreathe_PRIVATE_FRAMEWORKS = AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"
	install.exec "killall -9 SpringBoard"
