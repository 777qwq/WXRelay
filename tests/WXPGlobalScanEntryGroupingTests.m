#import <Foundation/Foundation.h>
#import "../WXRelayPrefs/WXPNotificationHistoryClient.h"
#import "../Shared/WXPreferences.h"
#import "../Shared/WXNotificationHistoryBridge.h"

//
// 全局扫描分组回归测试：覆盖全部应用镜像读取（空快照、跨 bundle 保留、损坏文件）。
// 直接编译真实 Shared/Prefs 源码，不重复定义生产常量，避免符号冲突。
//
@interface WXPNotificationHistoryClient (Testing)
+ (NSArray<NSDictionary *> *)fetchAllAppsEntriesWithError:(NSError **)error source:(NSString **)source;
@end

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXPGlobalScanTestFailure" reason:message userInfo:nil];
    }
}

int main(void) {
    @autoreleasepool {
        NSString *snapshotDirectory = NSTemporaryDirectory();
        setenv("NF_NOTIFICATION_HISTORY_DIRECTORY_OVERRIDE", snapshotDirectory.UTF8String, 1);

        // 空快照：返回空数组，不崩溃。
        NSError *error = nil;
        NSString *source = nil;
        NSArray<NSDictionary *> *empty = [WXPNotificationHistoryClient fetchAllAppsEntriesWithError:&error source:&source];
        WXAssert(empty.count == 0, @"empty snapshot should return no entries");
        WXAssert(error == nil, @"empty snapshot should not report an error");

        // 全部应用条目：不按 bundleIdentifier 过滤，保留所有有效条目。
        NSArray<NSDictionary *> *snapshot = @[
            @{
                WXLogBundleIdentifierKey: @"com.app.a",
                WXLogTitleKey: @"验证码",
                WXLogBodyKey: @"你的验证码是 1234",
                WXLogTimestampKey: @1000.0
            },
            @{
                WXLogBundleIdentifierKey: @"com.app.b",
                WXLogTitleKey: @"推广",
                WXLogBodyKey: @"限时优惠",
                WXLogTimestampKey: @2000.0
            },
            @{
                // 无 bundleIdentifier 的条目应被跳过。
                WXLogTitleKey: @"无来源",
                WXLogBodyKey: @"内容"
            }
        ];
        [snapshot writeToFile:[snapshotDirectory stringByAppendingPathComponent:@"cn.qwq.wxrelay.history.plist"] atomically:YES];

        source = nil;
        error = nil;
        NSArray<NSDictionary *> *all = [WXPNotificationHistoryClient fetchAllAppsEntriesWithError:&error source:&source];
        WXAssert(all.count == 2, @"all-apps fetch should keep entries from every bundle and drop bundleless entries");
        WXAssert([source isEqualToString:WXNotificationHistorySourceMirror], @"all-apps fetch should report the mirror source");
        WXAssert(error == nil, @"all-apps fetch should not report an error on a valid snapshot");

        // 非数组快照（损坏文件）：返回空，不崩溃。
        [@{ @"unexpected": @"shape" } writeToFile:[snapshotDirectory stringByAppendingPathComponent:@"cn.qwq.wxrelay.history.plist"] atomically:YES];
        error = nil;
        source = nil;
        NSArray<NSDictionary *> *corrupt = [WXPNotificationHistoryClient fetchAllAppsEntriesWithError:&error source:&source];
        WXAssert(corrupt.count == 0, @"corrupt snapshot should yield no entries without crashing");
        WXAssert(source == nil, @"corrupt snapshot should not report a source");
    }
    return 0;
}
