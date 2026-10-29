#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const WXNotificationHistoryRefreshRequestNotification;
extern NSString * const WXNotificationHistoryRefreshCompletedNotification;
extern NSString * const WXNotificationHistoryRequestIdentifierKey;
extern NSString * const WXNotificationHistoryBundleIdentifierKey;
extern NSString * const WXNotificationHistoryLimitKey;
extern NSString * const WXNotificationHistoryErrorKey;
extern NSString * const WXNotificationHistorySourceKey;
extern NSString * const WXNotificationHistoryUpdatedAtKey;

extern NSString * const WXNotificationHistorySourceLive;
extern NSString * const WXNotificationHistorySourceMirror;

// 全局扫描请求专用标识：写入 request 的 bundleIdentifier 时表示「请求全部应用」。
// 与单应用请求（非空 bundleIdentifier）互斥；空字符串仍视为非法请求。
extern NSString * const WXNotificationHistoryAllAppsIdentifier;

FOUNDATION_EXPORT NSString *WXNotificationHistorySnapshotFilePath(void);
FOUNDATION_EXPORT NSString *WXNotificationHistoryRefreshRequestFilePath(void);
FOUNDATION_EXPORT NSString *WXNotificationHistoryRefreshStatusFilePath(void);

NS_ASSUME_NONNULL_END
