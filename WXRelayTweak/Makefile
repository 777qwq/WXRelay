MODULE_CACHE_DIR = $(THEOS_OBJ_DIR)/ModuleCache.noindex

include $(THEOS_MAKE_PATH)/common.mk

TWEAK_NAME = WXRelay

WXRelay_FILES = \
	Tweak.xm \
	WXNotificationRecord.m \
	WXRuleEngine.m \
	../Shared/WXPreferences.m \
	../Shared/WXLogStore.m \
	../Shared/WXNotificationHistoryBridge.m

WXRelay_CFLAGS = -fobjc-arc -fmodules-cache-path=$(MODULE_CACHE_DIR)
WXRelay_FRAMEWORKS = Foundation
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
WXRelay_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
