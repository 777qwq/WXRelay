#import <Foundation/Foundation.h>
#import "WXPRuleEditorKind.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSBundle *WXPPrefsBundle(void);
FOUNDATION_EXPORT NSString *WXPLocalizedString(NSString *key);
FOUNDATION_EXPORT NSString *WXPLocalizedRuleEditorTitle(WXPRuleEditorKind editorKind);
FOUNDATION_EXPORT NSString *WXPLocalizedRuleEditorTitleForMode(WXPRuleEditorKind editorKind, NSString *mode);
FOUNDATION_EXPORT NSString *WXPLocalizedRulesListFooterForMode(WXPRuleEditorKind editorKind, NSString *mode);
FOUNDATION_EXPORT NSString *WXPLocalizedRulesListPlaceholderForMode(WXPRuleEditorKind editorKind, NSString *mode);
FOUNDATION_EXPORT NSString *WXPLocalizedScopeName(NSString *scope);
FOUNDATION_EXPORT NSString *WXPLocalizedMatchModeName(NSString *mode);
FOUNDATION_EXPORT NSString *WXPLocalizedDeleteStatusName(NSString *status);
FOUNDATION_EXPORT NSString *WXPLocalizedDeleteMethodSummary(NSString *methods);

NS_ASSUME_NONNULL_END
