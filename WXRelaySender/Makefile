ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXRelayNFSender
WXRelayNFSender_FILES = Tweak.m
WXRelayNFSender_FRAMEWORKS = UIKit Foundation AVFoundation CoreFoundation UserNotifications

include $(THEOS_MAKE_PATH)/tweak.mk
