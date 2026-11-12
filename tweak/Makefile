TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CredHUD
CredHUD_FILES = Tweak.xm
CredHUD_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

# 容器新会话看门狗：kqueue 事件驱动，平时 0% CPU
TOOL_NAME = creddaemon
creddaemon_FILES = creddaemon.c
creddaemon_INSTALL_PATH = /usr/local/bin
creddaemon_CFLAGS = -Wall -O2
# ★ 必须带 platform-application，否则内核直接 SIGKILL（实测：无 entitlements 时 exec 即死）
creddaemon_CODESIGN_FLAGS = -Screddaemon.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
