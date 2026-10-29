#import <Foundation/Foundation.h>

#import "../Shared/WXLogStore.h"

NSString * const WXLogEntryLimitKey = @"LogEntryLimit";
NSString * const WXLogIdentifierKey = @"id";
NSString * const WXLogTimestampKey = @"timestamp";
NSString * const WXLogBundleIdentifierKey = @"bundleID";
NSString * const WXLogSectionIDKey = @"sectionID";
NSString * const WXLogBulletinIDKey = @"bulletinID";
NSString * const WXLogRecordIDKey = @"recordID";
NSString * const WXLogPublisherBulletinIDKey = @"publisherBulletinID";
NSString * const WXLogMatchedScopeKey = @"matchedScope";
NSString * const WXLogMatchedPatternKey = @"matchedPattern";

@interface WXPreferences : NSObject

+ (NSDictionary *)loadPreferences;
+ (NSInteger)normalizedLogEntryLimit:(id)value;
+ (NSString *)logsFilePath;

@end

@implementation WXPreferences

+ (NSDictionary *)loadPreferences {
    return @{ WXLogEntryLimitKey: @500 };
}

+ (NSInteger)normalizedLogEntryLimit:(id)value {
    if (![value respondsToSelector:@selector(integerValue)]) {
        return 500;
    }

    NSInteger limit = [value integerValue];
    return limit > 0 ? limit : 500;
}

+ (NSString *)logsFilePath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"nf-logstore-regression.plist"];
}

@end

@interface WXLogStore (Testing)

+ (dispatch_queue_t)_logQueue;
+ (void)_flushLockedForTesting;

@end

static NSDictionary *WXMakeEntry(NSString *identifierSuffix) {
    return @{
        WXLogIdentifierKey: [NSString stringWithFormat:@"entry-%@", identifierSuffix],
        WXLogTimestampKey: @1000.0,
        WXLogBundleIdentifierKey: @"com.example.messages",
        WXLogSectionIDKey: @"com.example.messages",
        WXLogRecordIDKey: [NSString stringWithFormat:@"record-%@", identifierSuffix],
        WXLogPublisherBulletinIDKey: [NSString stringWithFormat:@"record-%@", identifierSuffix],
        WXLogMatchedScopeKey: @"app:com.example.messages",
        WXLogMatchedPatternKey: @"match-pattern"
    };
}

static void WXFlushLogQueue(void) {
    // 排空 _logQueue 上的 async 任务并强制把内存缓存落盘，
    // 否则写合并后 loadEntries 读磁盘可能拿不到最新条目。
    [WXLogStore _flushLockedForTesting];
}

static void WXCleanupLogFiles(void) {
    NSString *logPath = [WXPreferences logsFilePath];
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[logPath stringByAppendingString:@".cleared.plist"] error:nil];
}

int main(void) {
    @autoreleasepool {
        WXCleanupLogFiles();

        NSDictionary *targetEntry = WXMakeEntry(@"target");
        [WXLogStore appendBlockedEntry:targetEntry];
        WXFlushLogQueue();

        for (NSInteger index = 0; index < 20; index++) {
            NSString *suffix = [NSString stringWithFormat:@"filler-%ld", (long)index];
            [WXLogStore appendBlockedEntry:WXMakeEntry(suffix)];
        }
        WXFlushLogQueue();

        [WXLogStore appendBlockedEntry:targetEntry];
        WXFlushLogQueue();

        NSArray<NSDictionary *> *entries = [WXLogStore loadEntries];
        NSUInteger duplicateCount = 0;
        for (NSDictionary *entry in entries) {
            NSString *recordID = entry[WXLogRecordIDKey];
            if ([recordID isEqualToString:@"record-target"]) {
                duplicateCount += 1;
            }
        }

        if (entries.count != 21 || duplicateCount != 1) {
            fprintf(stderr,
                    "FAIL entries=%lu duplicateCount=%lu\n",
                    (unsigned long)entries.count,
                    (unsigned long)duplicateCount);
            WXCleanupLogFiles();
            return 1;
        }

        printf("PASS entries=%lu duplicateCount=%lu\n",
               (unsigned long)entries.count,
               (unsigned long)duplicateCount);
        WXCleanupLogFiles();
        return 0;
    }
}
