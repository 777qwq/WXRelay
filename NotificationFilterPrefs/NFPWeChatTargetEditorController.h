#import <UIKit/UIKit.h>

@interface NFPWeChatTargetEditorController : UITableViewController
- (instancetype)initWithTarget:(NSDictionary * _Nullable)target
                    saveHandler:(void (^)(NSDictionary *target))saveHandler;
@end
