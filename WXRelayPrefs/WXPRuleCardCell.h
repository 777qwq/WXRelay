#import <UIKit/UIKit.h>
#import "WXPRuleEditorKind.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WXPRuleValidationState) {
    WXPRuleValidationStateNone = 0,
    WXPRuleValidationStateValid,
    WXPRuleValidationStateInvalid
};

@interface WXPRuleCardCell : UITableViewCell

- (void)configureWithRuleEntry:(NSDictionary *)ruleEntry
                    editorKind:(WXPRuleEditorKind)editorKind
               validationState:(WXPRuleValidationState)validationState
                   editingMode:(BOOL)editingMode
                      selected:(BOOL)selected
                 toggleHandler:(void (^)(BOOL enabled))toggleHandler
              selectionHandler:(void (^)(void))selectionHandler;

@end

NS_ASSUME_NONNULL_END
