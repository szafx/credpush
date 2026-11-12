TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CredHUD
CredHUD_FILES = Tweak.xm
CredHUD_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
