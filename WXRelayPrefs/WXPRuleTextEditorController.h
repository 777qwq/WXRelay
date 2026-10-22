#import <UIKit/UIKit.h>
#import "WXPRuleEditorKind.h"

NS_ASSUME_NONNULL_BEGIN

@interface WXPRuleTextEditorController : UIViewController

// v2.7.7：单回复框（留空=纯转发；填了=纯回复），saveHandler 第三参为回复文本
- (instancetype)initWithTitle:(NSString *)title
                  placeholder:(NSString * _Nullable)placeholder
                  initialRule:(NSString * _Nullable)initialRule
                 initialScope:(NSString * _Nullable)initialScope
                   editorKind:(WXPRuleEditorKind)editorKind
                  saveHandler:(void (^)(NSString *rule, NSString *scope))saveHandler;

- (instancetype)initWithTitle:(NSString *)title
                  placeholder:(NSString * _Nullable)placeholder
                  initialRule:(NSString * _Nullable)initialRule
                 initialScope:(NSString * _Nullable)initialScope
            initialReplyOnly:(NSString * _Nullable)initialReplyOnly
                   editorKind:(WXPRuleEditorKind)editorKind
                  saveHandler:(void (^)(NSString *rule, NSString *scope, NSString *replyOnly))saveHandler;

@end

NS_ASSUME_NONNULL_END
