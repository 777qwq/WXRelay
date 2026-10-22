#import <Foundation/Foundation.h>
#import "../Shared/WXLogStore.h"

@interface WXPreferences : NSObject
+ (NSDictionary *)loadPreferences;
+ (NSInteger)normalizedLogEntryLimit:(id)value;
+ (NSString *)logsFilePath;
@end

NSString * const WXLogIdentifierKey = @"id";
NSString * const WXLogTimestampKey = @"timestamp";
NSString * const WXLogBundleIdentifierKey = @"bundleID";
NSString * const WXLogSectionIDKey = @"sectionID";
NSString * const WXLogBulletinIDKey = @"bulletinID";
NSString * const WXLogRecordIDKey = @"recordID";
NSString * const WXLogPublisherBulletinIDKey = @"publisherBulletinID";
NSString * const WXLogMatchedScopeKey = @"matchedScope";
NSString * const WXLogMatchedPatternKey = @"matchedPattern";
NSString * const WXLogEntryLimitKey = @"LogEntryLimit";

@implementation WXPreferences

+ (NSDictionary *)loadPreferences {
    return @{ WXLogEntryLimitKey: @500 };
}

+ (NSInteger)normalizedLogEntryLimit:(id)value {
    if (![value respondsToSelector:@selector(integerValue)] || [value integerValue] <= 0) {
        return 500;
    }
    return [value integerValue];
}

+ (NSString *)logsFilePath {
    NSString *path = NSProcessInfo.processInfo.environment[@"NF_LOG_STORE_TEST_PATH"];
    return path.length > 0 ? path : [NSTemporaryDirectory() stringByAppendingPathComponent:@"nf-logstore-test.plist"];
}

@end

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXLogStoreTestFailure" reason:message userInfo:nil];
    }
}

static NSDictionary *WXEntry(NSString *bundleIdentifier, NSTimeInterval timestamp, NSString *bulletinID) {
    return @{
        WXLogBundleIdentifierKey: bundleIdentifier,
        WXLogTimestampKey: @(timestamp),
        WXLogBulletinIDKey: bulletinID,
        WXLogMatchedScopeKey: @"app:test",
        WXLogMatchedPatternKey: @"old"
    };
}

int main(void) {
    @autoreleasepool {
        NSString *testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:testDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *logPath = [testDirectory stringByAppendingPathComponent:@"logs.plist"];
        setenv("NF_LOG_STORE_TEST_PATH", logPath.UTF8String, 1);

        NSString *bundleIdentifier = @"com.example.demo";
        NSTimeInterval oldTimestamp = [[NSDate date] timeIntervalSince1970] - 120.0;
        [WXLogStore clearEntries];
        [WXLogStore appendBlockedEntry:WXEntry(bundleIdentifier, oldTimestamp, @"old-1")];
        [WXLogStore clearEntriesForBundleIdentifier:bundleIdentifier];
        [WXLogStore appendBlockedEntry:WXEntry(bundleIdentifier, oldTimestamp, @"old-1")];
        [WXLogStore trimEntriesToCurrentLimit];

        NSArray *entriesAfterOldReplay = [WXLogStore loadEntries];
        WXAssert(entriesAfterOldReplay.count == 0, @"old replayed entry should stay cleared");

        [WXLogStore appendBlockedEntry:WXEntry(bundleIdentifier, [[NSDate date] timeIntervalSince1970] + 1.0, @"new-1")];
        [WXLogStore trimEntriesToCurrentLimit];
        NSArray *entriesAfterNewNotification = [WXLogStore loadEntries];
        WXAssert(entriesAfterNewNotification.count == 1, @"new entry after clear should be logged");

        [[NSFileManager defaultManager] removeItemAtPath:testDirectory error:nil];
    }
    return 0;
}
