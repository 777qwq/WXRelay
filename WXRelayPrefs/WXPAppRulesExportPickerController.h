#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WXPAppRulesExportPickerController : UITableViewController <UISearchResultsUpdating>

- (instancetype)initWithSelectedBundleIdentifiers:(NSArray<NSString *> *)selectedBundleIdentifiers
                                     selectionHandler:(void (^)(NSArray<NSString *> *selectedBundleIdentifiers))selectionHandler;

// v2.4.8：自定义标题 + 显示全部已装应用（来源 App 白名单用）
- (instancetype)initWithTitle:(NSString * _Nullable)titleOverride
             selectedBundleIdentifiers:(NSArray<NSString *> *)selectedBundleIdentifiers
                  selectionHandler:(void (^)(NSArray<NSString *> *selectedBundleIdentifiers))selectionHandler;

@end

NS_ASSUME_NONNULL_END
