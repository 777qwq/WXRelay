#import <UIKit/UIKit.h>
#import "WXPRuleEditorKind.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^WXPNotificationRuleTokenCommitHandler)(WXPRuleEditorKind targetKind, NSArray<NSDictionary *> *entries, NSError **error);

typedef NS_ENUM(NSInteger, WXPNotificationRuleTokenReturnMode) {
    WXPNotificationRuleTokenReturnModeRulesList = 0,
    WXPNotificationRuleTokenReturnModeTargetViewController
};

@interface WXPNotificationRuleTokenPickerController : UIViewController

- (instancetype)initWithNotificationEntry:(NSDictionary *)entry
                          appDisplayName:(NSString *)appDisplayName
                          initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString * _Nullable)ruleMode
                     returnViewController:(UIViewController * _Nullable)returnViewController
                            commitHandler:(WXPNotificationRuleTokenCommitHandler)commitHandler;

- (instancetype)initWithNotificationEntry:(NSDictionary *)entry
                          appDisplayName:(NSString *)appDisplayName
                          initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString * _Nullable)ruleMode
                     returnViewController:(UIViewController * _Nullable)returnViewController
                               returnMode:(WXPNotificationRuleTokenReturnMode)returnMode
                            commitHandler:(WXPNotificationRuleTokenCommitHandler)commitHandler;

@end

NS_ASSUME_NONNULL_END
