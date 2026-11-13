TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CredHUD
CredHUD_FILES = Tweak.xm
CredHUD_CFLAGS = -fobjc-arc

# 直推 helper：让 creddaemon 自己把会话 POST 到面板（不切 App）。
# ★ 用 ObjC/Theos TOOL —— Go 编出来的是 macOS 平台，iOS 拒绝加载（wrong platform）。
#   装到 /usr/libexec（rootless → /var/jb/usr/libexec），别放 /usr/local/bin（roothide 会注入）。
TOOL_NAME = credpush-helper
credpush-helper_FILES = helper/main.m
credpush-helper_CFLAGS = -fobjc-arc
credpush-helper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

# 注意：容器看门狗用的是 layout/usr/local/bin/creddaemon.sh（bash 一次性扫描），
# 不是编译版。编译版（creddaemon.c）会被 roothide 注入 Choicy/Crane/AutoPatches，
# 初始化阶段卡死（实测 main 都不进），所以停用；源码留着备用。
