#import <UIKit/UIKit.h>
#import "NFPMultilineRulesEditorController.h"

NS_ASSUME_NONNULL_BEGIN

@interface NFPRuleTextEditorController : UIViewController

- (instancetype)initWithTitle:(NSString *)title
                  placeholder:(NSString *)placeholder
                  initialRule:(NSString * _Nullable)initialRule
                 initialScope:(NSString *)initialScope
                   editorKind:(NFPRuleEditorKind)editorKind
                  saveHandler:(void (^)(NSString *rule, NSString *scope))saveHandler;

// v2.4.4：包含规则编辑带可选回复文本（saveHandler 第三参为回复，可空）
- (instancetype)initWithTitle:(NSString *)title
                  placeholder:(NSString *)placeholder
                  initialRule:(NSString * _Nullable)initialRule
                 initialScope:(NSString *)initialScope
                initialReply:(NSString * _Nullable)initialReply
                   editorKind:(NFPRuleEditorKind)editorKind
                  saveHandler:(void (^)(NSString *rule, NSString *scope, NSString *reply))saveHandler;

@end

NS_ASSUME_NONNULL_END
