#import <UIKit/UIKit.h>
#import "WXPRuleEditorKind.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^WXPScannedRuleMergeHandler)(WXPRuleEditorKind targetKind, NSArray<NSDictionary *> *entries, NSError **error);
typedef NSArray<NSDictionary *> * _Nonnull (^WXPRulesReloadHandler)(WXPRuleEditorKind editorKind);

@interface WXPRulesListEditorController : UITableViewController

- (instancetype)initWithTitle:(NSString *)title
                   editorKind:(WXPRuleEditorKind)editorKind
                        rules:(NSArray *)rules
                  saveHandler:(void (^)(NSArray *rules))saveHandler;

- (instancetype)initWithTitle:(NSString *)title
                   editorKind:(WXPRuleEditorKind)editorKind
                        rules:(NSArray *)rules
             bundleIdentifier:(NSString * _Nullable)bundleIdentifier
                  displayName:(NSString * _Nullable)displayName
                      ruleMode:(NSString * _Nullable)ruleMode
                  saveHandler:(void (^)(NSArray *rules))saveHandler
       scannedRuleMergeHandler:(WXPScannedRuleMergeHandler _Nullable)scannedRuleMergeHandler
             rulesReloadHandler:(WXPRulesReloadHandler _Nullable)rulesReloadHandler;

@end

NS_ASSUME_NONNULL_END
