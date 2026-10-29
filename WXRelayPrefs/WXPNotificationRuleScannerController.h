#import <UIKit/UIKit.h>
#import "WXPRuleEditorKind.h"
#import "WXPNotificationRuleTokenPickerController.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^WXPNotificationRuleScannerCommitHandler)(WXPRuleEditorKind targetKind, NSArray<NSDictionary *> *entries, NSError **error);

@interface WXPNotificationRuleScannerController : UITableViewController

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                             displayName:(NSString *)displayName
                         initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString * _Nullable)ruleMode
                    returnViewController:(UIViewController * _Nullable)returnViewController
                           commitHandler:(WXPNotificationRuleScannerCommitHandler)commitHandler;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                             displayName:(NSString *)displayName
                         initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString * _Nullable)ruleMode
                    returnViewController:(UIViewController * _Nullable)returnViewController
                              returnMode:(WXPNotificationRuleTokenReturnMode)returnMode
                           commitHandler:(WXPNotificationRuleScannerCommitHandler)commitHandler;

@end

NS_ASSUME_NONNULL_END
