MODULE_CACHE_DIR = $(THEOS_OBJ_DIR)/ModuleCache.noindex

include $(THEOS_MAKE_PATH)/common.mk

BUNDLE_NAME = WXRelayPrefs

WXRelayPrefs_FILES = \
	WXPLocalization.m \
	WXPRootListController.m \
	WXPAppInfoProvider.m \
	WXPRuleCardCell.m \
	WXPRuleTextEditorController.m \
	WXPRulesListEditorController.m \
	WXPWeChatTargetEditorController.m \
	WXPNotificationRuleScannerController.m \
	WXPNotificationRuleTokenBuilder.m \
	WXPNotificationRuleTokenPickerController.m \
	WXPNotificationHistoryClient.m \
	WXPAppRulesExportPickerController.m \
	WXPLogsListController.m \
	WXPLogDetailController.m \
	../Shared/WXPreferences.m \
	../Shared/WXLogStore.m \
	../Shared/WXNotificationHistoryBridge.m

WXRelayPrefs_FRAMEWORKS = UIKit Foundation MobileCoreServices
WXRelayPrefs_INSTALL_PATH = /Library/PreferenceBundles
WXRelayPrefs_CFLAGS = -fobjc-arc -fmodules-cache-path=$(MODULE_CACHE_DIR) -Wno-error=deprecated-declarations
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
WXRelayPrefs_LIBRARIES = roothide
endif
WXRelayPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
