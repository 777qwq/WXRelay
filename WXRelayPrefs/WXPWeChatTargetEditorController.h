#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WXPWeChatTargetEditorController : UITableViewController
- (instancetype)initWithTarget:(NSDictionary * _Nullable)target
                    saveHandler:(void (^)(NSDictionary *target))saveHandler;
@end

NS_ASSUME_NONNULL_END
