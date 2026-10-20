#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <BulletinBoard/BulletinBoard.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "NFNotificationRecord.h"
#import "NFRuleEngine.h"
#import "../Shared/NFPreferences.h"
#import "../Shared/NFLogStore.h"
#import "../Shared/NFNotificationHistoryBridge.h"

static NSDictionary *NFCurrentPreferences = nil;
static dispatch_queue_t NFPreferencesQueue = nil;
static void *NFBBServerQueueSpecificKey = &NFBBServerQueueSpecificKey;
static dispatch_queue_t NFBlockedActionQueue = nil;
static NSMutableDictionary<NSString *, NSNumber *> *NFBlockedActionTimestamps = nil;
static dispatch_queue_t NFBlockedIdentityQueue = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *NFBlockedIdentityCache = nil;
static dispatch_queue_t NFNotificationHistoryQueue = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *NFNotificationHistoryEntriesByKey = nil;
static NSMutableDictionary<NSString *, id> *NFNotificationHistoryDataProviders = nil;
static __unsafe_unretained id NFCurrentBBServer = nil;
typedef void (*NFWithdrawByRecordIDFunction)(id dataProvider, NSString *recordID);
typedef void (*NFWithdrawByPublisherBulletinIDFunction)(id dataProvider, NSString *publisherBulletinID);
typedef void (^NFBooleanCompletionBlock)(BOOL value);
typedef void (^NFBooleanErrorCompletionBlock)(BOOL value, NSError *error);
static void NFClearTransientBlockedCaches(void);
static void NFPerformSyncOrInlineOnBBServerQueue(dispatch_block_t block);
static void NFReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(NSString *bundleIdentifier,
                                                                         NSArray<NSDictionary *> *entries);
static void NFPersistNotificationHistoryMirrorEntriesLocked(void);

static NSDictionary *NFCopyPreferencesSnapshot(void) {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(NFPreferencesQueue, ^{
        snapshot = NFCurrentPreferences ?: [NFPreferences defaultPreferences];
    });
    return snapshot;
}

static NSArray<NSString *> *NFWeChatTargetList(void) {
    NSString *raw = NFCopyPreferencesSnapshot()[NFWeChatTargetsKey];
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return @[];
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    for (NSString *piece in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，;； "]]) {
        NSString *t = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) [targets addObject:t];
    }
    return targets;
}

static NSString *NFWeChatContainerPath(void) {
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *d in dirs) {
        NSString *meta = [appsDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", d]];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([[md objectForKey:@"MCMMetadataIdentifier"] isEqualToString:@"com.tencent.xin"]) {
            return [appsDir stringByAppendingPathComponent:d];
        }
    }
    return nil;
}

static void NFForwardMatchedRecordToWeChat(NFNotificationRecord *record) {
    NSArray<NSString *> *targets = NFWeChatTargetList();
    if (targets.count == 0) return;
    NSString *text = record.joinedText.length > 0 ? record.joinedText : record.messageText;
    if (text.length == 0) return;
    NSString *container = NFWeChatContainerPath();
    if (!container) return;
    @try {
        NSString *taskDir = [container stringByAppendingPathComponent:@"tmp/wxrelay_tasks"];
        [[NSFileManager defaultManager] createDirectoryAtPath:taskDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *fn = [NSString stringWithFormat:@"task_%@.json", [[NSUUID UUID] UUIDString]];
        NSDictionary *task = @{ @"targets": targets, @"text": text,
            @"ts": [NSString stringWithFormat:@"%f", [NSDate date].timeIntervalSince1970] };
        NSData *data = [NSJSONSerialization dataWithJSONObject:task options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[taskDir stringByAppendingPathComponent:fn] atomically:YES];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL, NULL, YES);
    } @catch (NSException *e) { }
}

static void NFUpdatePreferencesSnapshot(NSDictionary *preferences) {
    dispatch_sync(NFPreferencesQueue, ^{
        NFCurrentPreferences = [preferences copy];
    });
}

static void NFReloadPreferences(void) {
    NFUpdatePreferencesSnapshot([NFPreferences loadPreferences]);
    NFClearTransientBlockedCaches();
}

static void NFPreferencesChangedCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    NFReloadPreferences();
}

static NSMutableDictionary *NFBuildBlockedLogEntry(NFNotificationRecord *record, NFMatchResult *result) {
    if (!result.shouldBlock) {
        return nil;
    }

    NSMutableDictionary *logEntry = [[record dictionaryRepresentation] mutableCopy];
    if (result.matchedScope.length > 0) {
        logEntry[NFLogMatchedScopeKey] = result.matchedScope;
    }
    if (result.matchedMode.length > 0) {
        logEntry[NFLogMatchedModeKey] = result.matchedMode;
    }
    if (result.matchedPattern.length > 0) {
        logEntry[NFLogMatchedPatternKey] = result.matchedPattern;
    }

    return logEntry;
}

static void NFAppendBlockedLog(NFNotificationRecord *record, NFMatchResult *result) {
    if (!result.shouldBlock) {
        return;
    }

    if (!NFShouldLogBlockedRecord(record)) {
        return;
    }

    NSMutableDictionary *logEntry = NFBuildBlockedLogEntry(record, result);
    [NFLogStore appendBlockedEntry:logEntry];
}

static id NFCallObject(id obj, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!obj || !selector || ![obj respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(obj, selector);
}

static NSString *NFNormalizedStringValue(id value) {
    if (!value) {
        return nil;
    }

    NSString *stringValue = nil;
    if ([value isKindOfClass:[NSString class]]) {
        stringValue = value;
    } else if ([value respondsToSelector:@selector(stringValue)]) {
        id response = ((id (*)(id, SEL))objc_msgSend)(value, @selector(stringValue));
        if ([response isKindOfClass:[NSString class]]) {
            stringValue = response;
        }
    }

    return [stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSTimeInterval NFBlockedActionDedupeWindow(void) {
    return 2.0;
}

static NSTimeInterval NFBlockedIdentityTTL(void) {
    return 900.0;
}

static NSString *NFBlockedActionRecordKey(NFNotificationRecord *record, NFMatchResult *result) {
    if (!record || !result.shouldBlock) {
        return nil;
    }

    NSString *bulletinID = NFNormalizedStringValue(record.bulletinID);
    NSString *recordID = NFNormalizedStringValue(record.recordID);
    NSString *publisherBulletinID = NFNormalizedStringValue(record.publisherBulletinID);
    if (bulletinID.length == 0 && recordID.length == 0 && publisherBulletinID.length == 0) {
        return nil;
    }

    NSString *matchedPattern = NFNormalizedStringValue(result.matchedPattern);
    NSString *matchedMode = NFNormalizedStringValue(result.matchedMode);

    // For whitelist default block mode with no pattern, include content hash to distinguish different notifications
    if (matchedPattern.length == 0 && [matchedMode isEqualToString:NFMatchModeWhitelistDefault]) {
        NSString *contentForHash = [NSString stringWithFormat:@"%@|%@|%@",
                                    NFNormalizedStringValue(record.title) ?: @"",
                                    NFNormalizedStringValue(record.subtitle) ?: @"",
                                    NFNormalizedStringValue(record.messageText) ?: @""];
        matchedPattern = [NSString stringWithFormat:@"content:%lu", (unsigned long)[contentForHash hash]];
    }

    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@",
                                      NFNormalizedStringValue(record.bundleIdentifier) ?: @"",
                                      NFNormalizedStringValue(record.sectionID) ?: @"",
                                      bulletinID ?: @"",
                                      recordID ?: @"",
                                      publisherBulletinID ?: @"",
                                      NFNormalizedStringValue(result.matchedScope) ?: @"",
                                      matchedPattern ?: @""];
}

static NSArray<NSString *> *NFBlockedIdentityKeysForRecord(NFNotificationRecord *record) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];

    NSString *bulletinID = NFNormalizedStringValue(record.bulletinID);
    if (bulletinID.length > 0) {
        [keys addObject:[NSString stringWithFormat:@"bulletin:%@", bulletinID]];
    }

    NSString *recordID = NFNormalizedStringValue(record.recordID);
    if (recordID.length > 0) {
        [keys addObject:[NSString stringWithFormat:@"record:%@", recordID]];
    }

    NSString *publisherBulletinID = NFNormalizedStringValue(record.publisherBulletinID);
    if (publisherBulletinID.length > 0) {
        [keys addObject:[NSString stringWithFormat:@"publisher:%@", publisherBulletinID]];
    }

    return keys;
}

static void NFPurgeExpiredBlockedIdentityEntriesLocked(NSTimeInterval now) {
    NSTimeInterval ttl = NFBlockedIdentityTTL();
    NSMutableArray<NSString *> *expiredKeys = [NSMutableArray array];

    [NFBlockedIdentityCache enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
        NSNumber *timestamp = [entry[@"timestamp"] respondsToSelector:@selector(doubleValue)] ? entry[@"timestamp"] : nil;
        if (!timestamp || (now - timestamp.doubleValue) > ttl) {
            [expiredKeys addObject:key];
        }
    }];

    if (expiredKeys.count > 0) {
        [NFBlockedIdentityCache removeObjectsForKeys:expiredKeys];
    }
}

static BOOL NFIsExplicitAllowResult(NFMatchResult *result) {
    return !result.shouldBlock && [result.matchedMode isEqualToString:NFMatchModeExclude];
}

static void NFRememberBlockedIdentityForRecord(NFNotificationRecord *record, NFMatchResult *result) {
    if (!record || !result.shouldBlock) {
        return;
    }

    NSArray<NSString *> *identityKeys = NFBlockedIdentityKeysForRecord(record);
    if (identityKeys.count == 0) {
        return;
    }

    NSDictionary *entry = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"matchedScope": result.matchedScope ?: @"",
        @"matchedMode": result.matchedMode ?: @"",
        @"matchedPattern": result.matchedPattern ?: @""
    };

    dispatch_sync(NFBlockedIdentityQueue, ^{
        NFPurgeExpiredBlockedIdentityEntriesLocked([entry[@"timestamp"] doubleValue]);
        for (NSString *key in identityKeys) {
            NFBlockedIdentityCache[key] = entry;
        }
    });
}

static NSDictionary *NFCachedBlockedIdentityEntryForRecord(NFNotificationRecord *record) {
    NSArray<NSString *> *identityKeys = NFBlockedIdentityKeysForRecord(record);
    if (identityKeys.count == 0) {
        return nil;
    }

    __block NSDictionary *matchedEntry = nil;
    dispatch_sync(NFBlockedIdentityQueue, ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NFPurgeExpiredBlockedIdentityEntriesLocked(now);
        for (NSString *key in identityKeys) {
            NSDictionary *entry = NFBlockedIdentityCache[key];
            if (entry) {
                matchedEntry = entry;
                break;
            }
        }
    });

    return matchedEntry;
}

static NFMatchResult *NFCachedBlockedIdentityResultForRecord(NFNotificationRecord *record) {
    NSDictionary *entry = NFCachedBlockedIdentityEntryForRecord(record);
    if (!entry) {
        return nil;
    }

    NFMatchResult *result = [[NFMatchResult alloc] init];
    result.shouldBlock = YES;
    result.matchedScope = [entry[@"matchedScope"] isKindOfClass:[NSString class]] ? entry[@"matchedScope"] : nil;
    result.matchedMode = [entry[@"matchedMode"] isKindOfClass:[NSString class]] ? entry[@"matchedMode"] : nil;
    result.matchedPattern = [entry[@"matchedPattern"] isKindOfClass:[NSString class]] ? entry[@"matchedPattern"] : nil;
    return result;
}

static void NFClearTransientBlockedCaches(void) {
    if (NFBlockedActionQueue) {
        dispatch_sync(NFBlockedActionQueue, ^{
            [NFBlockedActionTimestamps removeAllObjects];
        });
    }

    if (NFBlockedIdentityQueue) {
        dispatch_sync(NFBlockedIdentityQueue, ^{
            [NFBlockedIdentityCache removeAllObjects];
        });
    }
}

static NSString *NFNotificationHistoryRecordKeyFromRecord(NFNotificationRecord *record) {
    if (!record) {
        return nil;
    }

    NSString *bundleIdentifier = NFNormalizedStringValue(record.bundleIdentifier);
    NSString *bulletinID = NFNormalizedStringValue(record.bulletinID);
    NSString *recordID = NFNormalizedStringValue(record.recordID);
    NSString *publisherBulletinID = NFNormalizedStringValue(record.publisherBulletinID);
    NSString *title = NFNormalizedStringValue(record.title);
    NSString *message = NFNormalizedStringValue(record.messageText.length > 0 ? record.messageText : record.joinedText);

    if (bulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|bulletin|%@", bundleIdentifier ?: @"", bulletinID];
    }
    if (recordID.length > 0) {
        return [NSString stringWithFormat:@"%@|record|%@", bundleIdentifier ?: @"", recordID];
    }
    if (publisherBulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|publisher|%@", bundleIdentifier ?: @"", publisherBulletinID];
    }
    if (bundleIdentifier.length == 0 || (title.length == 0 && message.length == 0)) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@|content|%@|%@", bundleIdentifier, title ?: @"", message ?: @""];
}

// 与 NFReplaceNotificationHistoryMirrorEntriesForBundleIdentifier 一致的字段提取，
// 供不需要重建 NFNotificationRecord 的批量合并路径使用。
static NSString *NFNotificationHistoryRecordKeyFromDictionaryEntry(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *bundleIdentifier = NFNormalizedStringValue(entry[NFLogBundleIdentifierKey]);
    NSString *bulletinID = NFNormalizedStringValue(entry[NFLogBulletinIDKey]);
    NSString *recordID = NFNormalizedStringValue(entry[NFLogRecordIDKey]);
    NSString *publisherBulletinID = NFNormalizedStringValue(entry[NFLogPublisherBulletinIDKey]);
    NSString *title = NFNormalizedStringValue(entry[NFLogTitleKey]);
    NSString *message = NFNormalizedStringValue(entry[NFLogMessageKey]) ?: NFNormalizedStringValue(entry[NFLogBodyKey]);
    NSString *joinedText = NFNormalizedStringValue(entry[NFLogJoinedTextKey]);
    if (message.length == 0) {
        message = joinedText;
    }

    if (bulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|bulletin|%@", bundleIdentifier ?: @"", bulletinID];
    }
    if (recordID.length > 0) {
        return [NSString stringWithFormat:@"%@|record|%@", bundleIdentifier ?: @"", recordID];
    }
    if (publisherBulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|publisher|%@", bundleIdentifier ?: @"", publisherBulletinID];
    }
    if (bundleIdentifier.length == 0 || (title.length == 0 && message.length == 0)) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@|content|%@|%@", bundleIdentifier, title ?: @"", message ?: @""];
}

static NSDictionary *NFNotificationHistoryDictionaryFromRecord(NFNotificationRecord *record) {
    if (!record) {
        return nil;
    }

    NSMutableDictionary *entry = [[record dictionaryRepresentation] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (record.timestamp) {
        entry[NFLogTimestampKey] = @([record.timestamp timeIntervalSince1970]);
    }
    return [entry copy];
}

static void NFStoreNotificationHistoryRecord(NFNotificationRecord *record) {
    NSString *recordKey = NFNotificationHistoryRecordKeyFromRecord(record);
    NSDictionary *entry = NFNotificationHistoryDictionaryFromRecord(record);
    if (recordKey.length == 0 || !entry) {
        return;
    }

    dispatch_sync(NFNotificationHistoryQueue, ^{
        NFNotificationHistoryEntriesByKey[recordKey] = entry;
        NFPersistNotificationHistoryMirrorEntriesLocked();
    });
}

static NSArray<NSDictionary *> *NFSortedNotificationHistoryEntriesFromDictionaryEntries(NSArray<NSDictionary *> *entries) {
    return [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        NSTimeInterval lhsTimestamp = [lhs[NFLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [lhs[NFLogTimestampKey] doubleValue] : 0;
        NSTimeInterval rhsTimestamp = [rhs[NFLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [rhs[NFLogTimestampKey] doubleValue] : 0;
        if (lhsTimestamp > rhsTimestamp) {
            return NSOrderedAscending;
        }
        if (lhsTimestamp < rhsTimestamp) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
}

static void NFPersistNotificationHistoryMirrorEntriesLocked(void) {
    NSArray<NSDictionary *> *entries = NFSortedNotificationHistoryEntriesFromDictionaryEntries([NFNotificationHistoryEntriesByKey allValues]);
    NSString *snapshotPath = NFNotificationHistorySnapshotFilePath();
    NSString *directoryPath = [snapshotPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [entries writeToFile:snapshotPath atomically:YES];
}

static void NFRememberNotificationHistoryDataProvider(id dataProvider) {
    NSString *sectionIdentifier = NFNormalizedStringValue(NFCallObject(dataProvider, @"sectionIdentifier"));
    if (sectionIdentifier.length == 0) {
        sectionIdentifier = NFNormalizedStringValue(NFCallObject(dataProvider, @"sectionID"));
    }
    if (sectionIdentifier.length == 0) {
        return;
    }

    dispatch_sync(NFNotificationHistoryQueue, ^{
        NFNotificationHistoryDataProviders[sectionIdentifier] = dataProvider;
    });
}

static void NFPrimeNotificationHistoryForDataProvider(id dataProvider) {
    NSString *bundleIdentifier = NFNormalizedStringValue(NFCallObject(dataProvider, @"sectionIdentifier"));
    if (bundleIdentifier.length == 0) {
        bundleIdentifier = NFNormalizedStringValue(NFCallObject(dataProvider, @"sectionID"));
    }
    if (bundleIdentifier.length == 0) {
        return;
    }

    @try {
        NSSet *bulletins = nil;
        if ([dataProvider respondsToSelector:@selector(bulletinsFilteredBy:count:lastCleared:)]) {
            bulletins = ((id (*)(id, SEL, NSUInteger, NSUInteger, id))objc_msgSend)(dataProvider,
                                                                                     @selector(bulletinsFilteredBy:count:lastCleared:),
                                                                                     0,
                                                                                     200,
                                                                                     nil);
        }
        if (![bulletins isKindOfClass:[NSSet class]]) {
            return;
        }

        NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:bulletins.count];
        for (id bulletin in bulletins) {
            NFNotificationRecord *record = [NFNotificationRecord recordFromBulletin:bulletin];
            if (record.bundleIdentifier.length == 0) {
                record.bundleIdentifier = bundleIdentifier;
            }
            NSDictionary *entry = NFNotificationHistoryDictionaryFromRecord(record);
            if (entry) {
                [entries addObject:entry];
            }
        }

        NFReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(bundleIdentifier,
                                                                     NFSortedNotificationHistoryEntriesFromDictionaryEntries(entries));
    } @catch (NSException *exception) {
        // Silently fail if notification history priming fails - this is non-critical functionality
    }
}

static void NFRememberNotificationHistoryDataProviderForSectionFromServer(id server, NSString *sectionIdentifier) {
    if (!server || sectionIdentifier.length == 0) {
        return;
    }

    @try {
        SEL selector = NSSelectorFromString(@"dataProviderForSectionID:");
        if (![server respondsToSelector:selector]) {
            return;
        }

        id dataProvider = ((id (*)(id, SEL, id))objc_msgSend)(server, selector, sectionIdentifier);
        if (dataProvider) {
            NFRememberNotificationHistoryDataProvider(dataProvider);
            NFPrimeNotificationHistoryForDataProvider(dataProvider);
        }
    } @catch (NSException *exception) {
        // Silently fail if notification history tracking fails - this is non-critical functionality
    }
}

static NSArray<NSDictionary *> *NFNotificationHistoryMirrorEntriesForBundleIdentifier(NSString *bundleIdentifier, NSUInteger limit) {
    __block NSArray<NSDictionary *> *entries = nil;
    dispatch_sync(NFNotificationHistoryQueue, ^{
        NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
        [NFNotificationHistoryEntriesByKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
            NSString *entryBundleIdentifier = [entry[NFLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[NFLogBundleIdentifierKey] : @"";
            if (![entryBundleIdentifier isEqualToString:bundleIdentifier]) {
                return;
            }
            [matches addObject:entry];
        }];
        NSArray<NSDictionary *> *sortedEntries = NFSortedNotificationHistoryEntriesFromDictionaryEntries(matches);
        if (limit > 0 && sortedEntries.count > limit) {
            sortedEntries = [sortedEntries subarrayWithRange:NSMakeRange(0, limit)];
        }
        entries = sortedEntries;
    });
    return entries ?: @[];
}

static void NFReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(NSString *bundleIdentifier,
                                                                         NSArray<NSDictionary *> *entries) {
    if (bundleIdentifier.length == 0) {
        return;
    }

    dispatch_sync(NFNotificationHistoryQueue, ^{
        NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
        [NFNotificationHistoryEntriesByKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
            NSString *entryBundleIdentifier = [entry[NFLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[NFLogBundleIdentifierKey] : @"";
            if ([entryBundleIdentifier isEqualToString:bundleIdentifier]) {
                [keysToRemove addObject:key];
            }
        }];
        if (keysToRemove.count > 0) {
            [NFNotificationHistoryEntriesByKey removeObjectsForKeys:keysToRemove];
        }

        for (NSDictionary *entry in entries) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NFNotificationRecord *record = [[NFNotificationRecord alloc] init];
            record.bundleIdentifier = [entry[NFLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[NFLogBundleIdentifierKey] : bundleIdentifier;
            record.sectionID = [entry[NFLogSectionIDKey] isKindOfClass:[NSString class]] ? entry[NFLogSectionIDKey] : nil;
            record.bulletinID = [entry[NFLogBulletinIDKey] isKindOfClass:[NSString class]] ? entry[NFLogBulletinIDKey] : nil;
            record.recordID = [entry[NFLogRecordIDKey] isKindOfClass:[NSString class]] ? entry[NFLogRecordIDKey] : nil;
            record.publisherBulletinID = [entry[NFLogPublisherBulletinIDKey] isKindOfClass:[NSString class]] ? entry[NFLogPublisherBulletinIDKey] : nil;
            record.title = [entry[NFLogTitleKey] isKindOfClass:[NSString class]] ? entry[NFLogTitleKey] : nil;
            record.subtitle = [entry[NFLogSubtitleKey] isKindOfClass:[NSString class]] ? entry[NFLogSubtitleKey] : nil;
            record.header = [entry[NFLogHeaderKey] isKindOfClass:[NSString class]] ? entry[NFLogHeaderKey] : nil;
            record.body = [entry[NFLogBodyKey] isKindOfClass:[NSString class]] ? entry[NFLogBodyKey] : nil;
            record.message = [entry[NFLogMessageKey] isKindOfClass:[NSString class]] ? entry[NFLogMessageKey] : nil;
            record.messageText = NFNormalizedStringValue(entry[NFLogMessageKey]) ?: NFNormalizedStringValue(entry[NFLogBodyKey]) ?: @"";
            record.joinedText = [entry[NFLogJoinedTextKey] isKindOfClass:[NSString class]] ? entry[NFLogJoinedTextKey] : @"";
            NSTimeInterval timestamp = [entry[NFLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [entry[NFLogTimestampKey] doubleValue] : [[NSDate date] timeIntervalSince1970];
            record.timestamp = [NSDate dateWithTimeIntervalSince1970:timestamp];

            NSString *recordKey = NFNotificationHistoryRecordKeyFromRecord(record);
            if (recordKey.length > 0) {
                NFNotificationHistoryEntriesByKey[recordKey] = entry;
            }
        }
        NFPersistNotificationHistoryMirrorEntriesLocked();
    });
}

static NSArray<NSDictionary *> *NFNotificationHistoryLiveEntriesForBundleIdentifier(NSString *bundleIdentifier, NSUInteger limit) {
    __block NSArray<NSDictionary *> *resultEntries = nil;

    @try {
        NFPerformSyncOrInlineOnBBServerQueue(^{
            __block id dataProvider = nil;
            dispatch_sync(NFNotificationHistoryQueue, ^{
                dataProvider = NFNotificationHistoryDataProviders[bundleIdentifier];
            });
            if (!dataProvider && NFCurrentBBServer) {
                NFRememberNotificationHistoryDataProviderForSectionFromServer(NFCurrentBBServer, bundleIdentifier);
                dispatch_sync(NFNotificationHistoryQueue, ^{
                    dataProvider = NFNotificationHistoryDataProviders[bundleIdentifier];
                });
            }
            if (!dataProvider) {
                return;
            }

            NSSet *bulletins = nil;
            if ([dataProvider respondsToSelector:@selector(bulletinsFilteredBy:count:lastCleared:)]) {
                NSUInteger count = limit > 0 ? limit : 200;
                bulletins = ((id (*)(id, SEL, NSUInteger, NSUInteger, id))objc_msgSend)(dataProvider,
                                                                                         @selector(bulletinsFilteredBy:count:lastCleared:),
                                                                                         0,
                                                                                         count,
                                                                                         nil);
            }
            if (![bulletins isKindOfClass:[NSSet class]]) {
                return;
            }

            NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:bulletins.count];
            for (id bulletin in bulletins) {
                NFNotificationRecord *record = [NFNotificationRecord recordFromBulletin:bulletin];
                if (record.bundleIdentifier.length == 0) {
                    record.bundleIdentifier = bundleIdentifier;
                }
                NSDictionary *entry = NFNotificationHistoryDictionaryFromRecord(record);
                if (entry) {
                    [entries addObject:entry];
                }
            }

            NSArray<NSDictionary *> *sortedEntries = NFSortedNotificationHistoryEntriesFromDictionaryEntries(entries);
            NFReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(bundleIdentifier, sortedEntries);
            if (limit > 0 && sortedEntries.count > limit) {
                sortedEntries = [sortedEntries subarrayWithRange:NSMakeRange(0, limit)];
            }
            resultEntries = sortedEntries;
        });
    } @catch (NSException *exception) {
        // Silently fail if notification history retrieval fails - this is non-critical functionality
        resultEntries = nil;
    }

    return resultEntries;
}

static void NFPostNotificationHistoryRefreshStatus(NSString *requestIdentifier,
                                                   NSString *bundleIdentifier,
                                                   NSString *source,
                                                   NSString *errorMessage) {
    if (requestIdentifier.length == 0 || bundleIdentifier.length == 0) {
        return;
    }

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[NFNotificationHistoryRequestIdentifierKey] = requestIdentifier;
    status[NFNotificationHistoryBundleIdentifierKey] = bundleIdentifier;
    status[NFNotificationHistorySourceKey] = source.length > 0 ? source : NFNotificationHistorySourceMirror;
    status[NFNotificationHistoryUpdatedAtKey] = @([[NSDate date] timeIntervalSince1970]);
    if (errorMessage.length > 0) {
        status[NFNotificationHistoryErrorKey] = errorMessage;
    }

    NSString *statusPath = NFNotificationHistoryRefreshStatusFilePath();
    NSString *directoryPath = [statusPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [status writeToFile:statusPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)NFNotificationHistoryRefreshCompletedNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

// 全局扫描：遍历已注册的全部 dataProvider，逐个 section 取实时条目，
// 合并后整体写回快照镜像。任一 section 失败时跳过该 section，其余继续。
static void NFProcessNotificationHistoryRefreshRequestForAllApps(NSString *requestIdentifier, NSUInteger limit) {
    __block NSArray<NSString *> *bundleIdentifiers = nil;
    dispatch_sync(NFNotificationHistoryQueue, ^{
        bundleIdentifiers = [NFNotificationHistoryDataProviders allKeys];
    });

    NSMutableArray<NSDictionary *> *allEntries = [NSMutableArray array];
    __block BOOL anyLive = NO;

    for (NSString *sectionIdentifier in bundleIdentifiers) {
        @try {
            NSArray<NSDictionary *> *sectionEntries = NFNotificationHistoryLiveEntriesForBundleIdentifier(sectionIdentifier, limit);
            if (sectionEntries.count > 0) {
                [allEntries addObjectsFromArray:sectionEntries];
                anyLive = YES;
            }
        } @catch (NSException *exception) {
            // 单个 section 失败不影响其余应用的历史刷新。
        }
    }

    NSString *source = anyLive ? NFNotificationHistorySourceLive : NFNotificationHistorySourceMirror;
    if (allEntries.count > 0) {
        dispatch_sync(NFNotificationHistoryQueue, ^{
            NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
            [NFNotificationHistoryEntriesByKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
                NSString *entryBundleIdentifier = [entry[NFLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[NFLogBundleIdentifierKey] : @"";
                if ([bundleIdentifiers containsObject:entryBundleIdentifier]) {
                    [keysToRemove addObject:key];
                }
            }];
            if (keysToRemove.count > 0) {
                [NFNotificationHistoryEntriesByKey removeObjectsForKeys:keysToRemove];
            }

            for (NSDictionary *entry in allEntries) {
                if (![entry isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSString *recordKey = NFNotificationHistoryRecordKeyFromDictionaryEntry(entry);
                if (recordKey.length > 0) {
                    NFNotificationHistoryEntriesByKey[recordKey] = entry;
                }
            }
            NFPersistNotificationHistoryMirrorEntriesLocked();
        });
    }

    NFPostNotificationHistoryRefreshStatus(requestIdentifier, NFNotificationHistoryAllAppsIdentifier, source, nil);
}

static void NFProcessNotificationHistoryRefreshRequest(void) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:NFNotificationHistoryRefreshRequestFilePath()];
    if (![request isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSString *requestIdentifier = NFNormalizedStringValue(request[NFNotificationHistoryRequestIdentifierKey]);
    NSString *bundleIdentifier = NFNormalizedStringValue(request[NFNotificationHistoryBundleIdentifierKey]);
    NSUInteger limit = [request[NFNotificationHistoryLimitKey] respondsToSelector:@selector(unsignedIntegerValue)] ?
        [request[NFNotificationHistoryLimitKey] unsignedIntegerValue] :
        200;
    if (requestIdentifier.length == 0 || bundleIdentifier.length == 0) {
        return;
    }

    if ([bundleIdentifier isEqualToString:NFNotificationHistoryAllAppsIdentifier]) {
        NFProcessNotificationHistoryRefreshRequestForAllApps(requestIdentifier, limit);
        return;
    }

    NSArray<NSDictionary *> *liveEntries = NFNotificationHistoryLiveEntriesForBundleIdentifier(bundleIdentifier, limit);
    NSString *source = liveEntries ? NFNotificationHistorySourceLive : NFNotificationHistorySourceMirror;
    if (!liveEntries) {
        (void)NFNotificationHistoryMirrorEntriesForBundleIdentifier(bundleIdentifier, limit);
    }

    NFPostNotificationHistoryRefreshStatus(requestIdentifier, bundleIdentifier, source, nil);
}

static void NFNotificationHistoryRefreshRequestCallback(CFNotificationCenterRef center,
                                                        void *observer,
                                                        CFStringRef name,
                                                        const void *object,
                                                        CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NFProcessNotificationHistoryRefreshRequest();
        }
    });
}

static NFMatchResult *NFEvaluateRecord(NFNotificationRecord *record) {
    NSDictionary *preferences = NFCopyPreferencesSnapshot();
    NFMatchResult *result = [NFRuleEngine evaluateRecord:record preferences:preferences];
    if (![preferences[NFEnabledKey] boolValue]) {
        return result;
    }

    if (result.shouldBlock) {
        NFRememberBlockedIdentityForRecord(record, result);
        return result;
    }

    if (NFIsExplicitAllowResult(result)) {
        return result;
    }

    NFMatchResult *cachedBlockedResult = NFCachedBlockedIdentityResultForRecord(record);
    if (cachedBlockedResult.shouldBlock) {
        return cachedBlockedResult;
    }

    return result;
}

static void NFBackfillRecordSectionIdentifier(NFNotificationRecord *record, id sectionIdentifier) {
    NSString *resolvedSectionIdentifier = NFNormalizedStringValue(sectionIdentifier);
    if (resolvedSectionIdentifier.length == 0) {
        return;
    }

    if (record.bundleIdentifier.length == 0) {
        record.bundleIdentifier = resolvedSectionIdentifier;
    }
    if (record.sectionID.length == 0) {
        record.sectionID = resolvedSectionIdentifier;
    }
}

static NSUInteger NFNotificationRecordSignalScore(NFNotificationRecord *record) {
    if (!record) {
        return 0;
    }

    NSUInteger score = 0;
    if (record.bundleIdentifier.length > 0) {
        score += 1;
    }
    if (record.sectionID.length > 0) {
        score += 1;
    }
    if (record.bulletinID.length > 0) {
        score += 1;
    }
    if (record.recordID.length > 0) {
        score += 1;
    }
    if (record.publisherBulletinID.length > 0) {
        score += 1;
    }
    if (record.title.length > 0) {
        score += 2;
    }
    if (record.subtitle.length > 0) {
        score += 1;
    }
    if (record.header.length > 0) {
        score += 1;
    }
    if (record.body.length > 0) {
        score += 2;
    }
    if (record.message.length > 0) {
        score += 2;
    }
    if (record.joinedText.length > 0) {
        score += 3;
    }

    return score;
}

static NFNotificationRecord *NFBestRecordFromNotificationObject(id notificationObject,
                                                                id fallbackSectionIdentifier) {
    NFNotificationRecord *requestRecord = [NFNotificationRecord recordFromNotificationRequest:notificationObject];
    NFBackfillRecordSectionIdentifier(requestRecord, fallbackSectionIdentifier);

    NFNotificationRecord *bulletinRecord = [NFNotificationRecord recordFromBulletin:notificationObject];
    NFBackfillRecordSectionIdentifier(bulletinRecord, fallbackSectionIdentifier);

    if (NFNotificationRecordSignalScore(bulletinRecord) > NFNotificationRecordSignalScore(requestRecord)) {
        return bulletinRecord;
    }

    return requestRecord;
}

static dispatch_queue_t NFBBServerQueue(void) {
    static dispatch_queue_t cachedQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __unsafe_unretained dispatch_queue_t *queuePointer = (__unsafe_unretained dispatch_queue_t *)dlsym(RTLD_DEFAULT, "__BBServerQueue");
        if (queuePointer) {
            cachedQueue = *queuePointer;
            dispatch_queue_set_specific(cachedQueue,
                                        NFBBServerQueueSpecificKey,
                                        NFBBServerQueueSpecificKey,
                                        NULL);
        }
    });
    return cachedQueue;
}

static void NFPerformSyncOrInlineOnBBServerQueue(dispatch_block_t block) {
    dispatch_queue_t queue = NFBBServerQueue();
    if (!queue) {
        block();
        return;
    }

    if (dispatch_get_specific(NFBBServerQueueSpecificKey) == NFBBServerQueueSpecificKey) {
        block();
        return;
    }

    dispatch_sync(queue, block);
}

%group NFDispatcherHooks

%hook NCNotificationDispatcher

- (void)postNotificationWithRequest:(id)request {
    // WXRelayNF：不做任何拦截，统一放行（捕获与转发在 BBServer 层）
    %orig;
}

%end

%end

%group NFBulletinHooks

%hook BBServer

- (void)_addDataProvider:(id)dataProvider sortSectionsNow:(BOOL)sortSections {
    @try {
        if (dataProvider) {
            NFRememberNotificationHistoryDataProvider(dataProvider);
            NFPrimeNotificationHistoryForDataProvider(dataProvider);
        }
    } @catch (NSException *exception) {
        // Silently fail if notification history tracking fails - this is non-critical functionality
    }
    %orig;
}

- (void)publishBulletinRequest:(id)request destinations:(unsigned long long)destinations {
    NFNotificationRecord *record = [NFNotificationRecord recordFromNotificationRequest:request];
    NFMatchResult *result = NFEvaluateRecord(record);
    if (result.shouldBlock) {
        NFForwardMatchedRecordToWeChat(record);
        NFAppendBlockedLog(record, result);
    }
    %orig;
}

- (void)_publishBulletinRequest:(id)request forSectionID:(id)sectionIdentifier forDestinations:(unsigned long long)destinations {
        %orig;
}

- (void)updateSection:(id)sectionIdentifier inFeed:(unsigned long long)feed withBulletinRequests:(id)bulletinRequests {
    %orig;
}

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    NFNotificationRecord *record = [NFNotificationRecord recordFromBulletin:bulletin];
    NFMatchResult *result = NFEvaluateRecord(record);
    if (result.shouldBlock) {
        NFForwardMatchedRecordToWeChat(record);
        NFAppendBlockedLog(record, result);
    }
    %orig;
}

- (void)_modifyBulletin:(id)bulletin {
        %orig;
}

- (void)_addBulletin:(id)bulletin {
        %orig;
}

- (void)_sendAddBulletin:(id)bulletin toFeeds:(unsigned long long)feeds {
        %orig;
}

- (void)_sendModifyBulletin:(id)bulletin toFeeds:(unsigned long long)feeds {
        %orig;
}

- (void)_sendBulletinUpdate:(id)update {
        %orig;
}

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations alwaysToLockScreen:(BOOL)alwaysToLockScreen {
    NFNotificationRecord *record = [NFNotificationRecord recordFromBulletin:bulletin];
    NFMatchResult *result = NFEvaluateRecord(record);
    if (result.shouldBlock) {
        NFForwardMatchedRecordToWeChat(record);
        NFAppendBlockedLog(record, result);
    }
    %orig;
}

%end

%end

%group NFObserverHooks

%hook BBObserver

- (void)updateBulletin:(id)updateTransaction withReply:(id)reply {
    %orig;
}

- (void)_queue_updateAddBulletin:(id)update withReply:(id)reply {
    %orig;
}

- (void)_queue_updateModifyBulletin:(id)update withReply:(id)reply {
    %orig;
}

%end

%end

%group NFObserverServerProxyHooks

%hook BBObserverServerProxy

- (void)updateBulletin:(id)updateTransaction withHandler:(id)handler {
    %orig;
}

%end

%end

%group NFObserverClientProxyHooks

%hook BBObserverClientProxy

- (void)updateBulletin:(id)updateTransaction withHandler:(id)handler {
    %orig;
}

%end

%end

%group NFDataProviderProxyHooks

%hook BBDataProviderProxy

- (void)addBulletin:(id)bulletin forDestinations:(unsigned long long)destinations {
        %orig;
}

- (void)modifyBulletin:(id)bulletin {
        %orig;
}

%end

%end

%group NFRemoteDataProviderHooks

%hook BBRemoteDataProvider

- (void)addBulletin:(id)bulletin forDestinations:(unsigned long long)destinations {
        %orig;
}

- (void)modifyBulletin:(id)bulletin {
        %orig;
}

%end

%end

%ctor {
    @autoreleasepool {
        NFPreferencesQueue = dispatch_queue_create("com.tune.notificationfilter.preferences", DISPATCH_QUEUE_SERIAL);
        NFBlockedActionQueue = dispatch_queue_create("com.tune.notificationfilter.blocked-actions", DISPATCH_QUEUE_SERIAL);
        NFBlockedActionTimestamps = [NSMutableDictionary dictionary];
        NFBlockedIdentityQueue = dispatch_queue_create("com.tune.notificationfilter.blocked-identities", DISPATCH_QUEUE_SERIAL);
        NFBlockedIdentityCache = [NSMutableDictionary dictionary];
        NFNotificationHistoryQueue = dispatch_queue_create("com.tune.notificationfilter.history", DISPATCH_QUEUE_SERIAL);
        NFNotificationHistoryEntriesByKey = [NSMutableDictionary dictionary];
        NFNotificationHistoryDataProviders = [NSMutableDictionary dictionary];
        NFReloadPreferences();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        NFPreferencesChangedCallback,
                                        (CFStringRef)NFPreferencesChangedDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        NFNotificationHistoryRefreshRequestCallback,
                                        (CFStringRef)NFNotificationHistoryRefreshRequestNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        if (objc_getClass("NCNotificationDispatcher")) {
            %init(NFDispatcherHooks);
        }

        if (objc_getClass("BBServer")) {
            %init(NFBulletinHooks);
        }
        if (objc_getClass("BBObserver")) {
            %init(NFObserverHooks);
        }
        if (objc_getClass("BBObserverServerProxy")) {
            %init(NFObserverServerProxyHooks);
        }
        if (objc_getClass("BBObserverClientProxy")) {
            %init(NFObserverClientProxyHooks);
        }
        if (objc_getClass("BBDataProviderProxy")) {
            %init(NFDataProviderProxyHooks);
        }
        if (objc_getClass("BBRemoteDataProvider")) {
            %init(NFRemoteDataProviderHooks);
        }
    }
}
