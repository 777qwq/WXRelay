#import <Foundation/Foundation.h>
#import "../Shared/WXLogStore.h"

@interface WXPreferences : NSObject
+ (NSDictionary *)loadPreferences;
+ (NSInteger)normalizedLogEntryLimit:(id)value;
+ (NSString *)logsFilePath;
@end

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
    return path.length > 0 ? path : [NSTemporaryDirectory() stringByAppendingPathComponent:@"nf-logstore-coalescing-test.plist"];
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

// 带当前时间戳的条目。clear-state 机制会把「同 bundle 且 timestamp <= clearedAt」的条目视为已清理，
// 因此验证 clear 之后新通知能否落盘时，必须用当前/未来时间戳，避免被 clear-state 过滤（与
// WXLogStoreClearTests.m 一致）。
static NSDictionary *WXMakeFreshEntry(NSString *identifierSuffix) {
    NSMutableDictionary *entry = [WXMakeEntry(identifierSuffix) mutableCopy];
    entry[WXLogTimestampKey] = @([[NSDate date] timeIntervalSince1970] + 1.0);
    return [entry copy];
}

static void WXFlushLogQueue(void) {
    dispatch_sync([WXLogStore _logQueue], ^{
    });
}

static void WXCleanupLogFiles(NSString *logPath) {
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[logPath stringByAppendingString:@".cleared.plist"] error:nil];
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

        int failures = 0;

        // Case A: append does not flush immediately; disk should not yet contain the entry.
        WXCleanupLogFiles(logPath);
        [WXLogStore appendBlockedEntry:WXMakeEntry(@"a")];
        WXFlushLogQueue(); // drain the append async block, but no forced flush.
        {
            NSArray *diskEntries = [NSArray arrayWithContentsOfFile:logPath];
            NSUInteger diskCount = [diskEntries isKindOfClass:[NSArray class]] ? diskEntries.count : 0;
            if (diskCount != 0) {
                fprintf(stderr, "FAIL Case A: disk should be empty before flush, got %lu\n", (unsigned long)diskCount);
                failures++;
            } else {
                printf("PASS Case A: disk empty before forced flush\n");
            }
        }

        // Case B: after forced flush, loadEntries sees the entry (deduped).
        [WXLogStore _flushLockedForTesting];
        {
            NSArray<NSDictionary *> *entries = [WXLogStore loadEntries];
            NSUInteger matchCount = 0;
            for (NSDictionary *entry in entries) {
                if ([[entry objectForKey:WXLogRecordIDKey] isEqualToString:@"record-a"]) {
                    matchCount++;
                }
            }
            if (entries.count != 1 || matchCount != 1) {
                fprintf(stderr, "FAIL Case B: expected 1 entry after flush, got entries=%lu matchCount=%lu\n",
                        (unsigned long)entries.count, (unsigned long)matchCount);
                failures++;
            } else {
                printf("PASS Case B: disk has 1 deduped entry after flush\n");
            }
        }

        // Case C: append (no flush) -> clearEntries -> append new -> flush -> old entry must not revive.
        // 用未来时间戳的新条目，避免被 clear-state 过滤（与 WXLogStoreClearTests.m 一致）。
        [WXLogStore appendBlockedEntry:WXMakeFreshEntry(@"old")];
        WXFlushLogQueue(); // drain append; old not yet flushed to disk.
        [WXLogStore clearEntries];
        [WXLogStore appendBlockedEntry:WXMakeFreshEntry(@"new")];
        WXFlushLogQueue();
        [WXLogStore _flushLockedForTesting];
        {
            NSArray<NSDictionary *> *entries = [WXLogStore loadEntries];
            BOOL hasOld = NO, hasNew = NO;
            for (NSDictionary *entry in entries) {
                NSString *recordID = [entry objectForKey:WXLogRecordIDKey];
                if ([recordID isEqualToString:@"record-old"]) hasOld = YES;
                if ([recordID isEqualToString:@"record-new"]) hasNew = YES;
            }
            if (hasOld || !hasNew) {
                fprintf(stderr, "FAIL Case C: old revived=%d new present=%d\n", hasOld, hasNew);
                failures++;
            } else {
                printf("PASS Case C: old entry cleared, new entry present, no revival\n");
            }
        }

        WXCleanupLogFiles(logPath);
        [[NSFileManager defaultManager] removeItemAtPath:testDirectory error:nil];

        if (failures > 0) {
            fprintf(stderr, "RESULT: %d FAILURE(S)\n", failures);
            return 1;
        }
        printf("RESULT: ALL PASS\n");
        return 0;
    }
}
