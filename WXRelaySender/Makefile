ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXRelaySender
WXRelaySender_FILES = Tweak.m
WXRelaySender_CFLAGS = -Wno-error=deprecated-declarations
WXRelaySender_FRAMEWORKS = UIKit Foundation AVFoundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
