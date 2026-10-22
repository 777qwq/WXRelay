#import "WXNotificationHistoryBridge.h"

#ifdef __has_include
  #if __has_include(<rootless.h>)
    #import <rootless.h>
  #elif __has_include(<roothide.h>)
    #include <roothide.h>
  #endif
#endif
#ifndef jbroot
  #ifdef ROOT_PATH_NS
    #define jbroot(path) ROOT_PATH_NS(path)
  #else
    #define jbroot(path) path
  #endif
#endif

NSString * const WXNotificationHistoryRefreshRequestNotification = @"com.777qwq.wxrelay.history/refresh-request";
NSString * const WXNotificationHistoryRefreshCompletedNotification = @"com.777qwq.wxrelay.history/refresh-completed";
NSString * const WXNotificationHistoryRequestIdentifierKey = @"requestID";
NSString * const WXNotificationHistoryBundleIdentifierKey = @"bundleIdentifier";
NSString * const WXNotificationHistoryLimitKey = @"limit";
NSString * const WXNotificationHistoryErrorKey = @"error";
NSString * const WXNotificationHistorySourceKey = @"source";
NSString * const WXNotificationHistoryUpdatedAtKey = @"updatedAt";

NSString * const WXNotificationHistorySourceLive = @"live";
NSString * const WXNotificationHistorySourceMirror = @"mirror";
NSString * const WXNotificationHistoryAllAppsIdentifier = @"all-apps";

static NSString *WXLegacyPreferencesFilePath(NSString *filename) {
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:filename];
}

// 与 WXPreferences / WXLogStore 保持同一模式：直接返回 jbroot() 解析后的路径，
// 历史文件写入隐藏的 .jbroot（roothide）/ jb 根（rootless）/ 原样（rootful）。
// 不做跨容器迁移，也不删除可见路径的旧文件——1.3.7 的迁移/删除正是
// roothide iOS 15 上触发 SpringBoard 安全模式的根因；旧版本留在可见路径的
// 历史文件保留在磁盘上不再读取，需要时可手动恢复。
static NSString *WXPreferencesScopedFilePath(NSString *filename) {
    // 测试钩子：允许主机端单测覆盖快照/请求/状态文件位置，生产环境不设置该变量。
    char *override = getenv("NF_NOTIFICATION_HISTORY_DIRECTORY_OVERRIDE");
    if (override != NULL && strlen(override) > 0) {
        NSString *overrideDirectory = [NSString stringWithUTF8String:override];
        return [overrideDirectory stringByAppendingPathComponent:filename];
    }
    return jbroot(WXLegacyPreferencesFilePath(filename));
}

NSString *WXNotificationHistorySnapshotFilePath(void) {
    return WXPreferencesScopedFilePath(@"com.777qwq.wxrelay.history.plist");
}

NSString *WXNotificationHistoryRefreshRequestFilePath(void) {
    return WXPreferencesScopedFilePath(@"com.777qwq.wxrelay.history-request.plist");
}

NSString *WXNotificationHistoryRefreshStatusFilePath(void) {
    return WXPreferencesScopedFilePath(@"com.777qwq.wxrelay.history-status.plist");
}
