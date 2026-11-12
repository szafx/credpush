TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CredHUD
CredHUD_FILES = Tweak.xm
CredHUD_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

# 注意：容器看门狗用的是 layout/usr/local/bin/creddaemon.sh（bash 一次性扫描），
# 不是编译版。编译版（creddaemon.c）会被 roothide 注入 Choicy/Crane/AutoPatches，
# 初始化阶段卡死（实测 main 都不进），所以停用；源码留着备用。
