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

static NSArray<NSDictionary *> *NFWeChatTargetList(void) {
    NSDictionary *prefs = NFCopyPreferencesSnapshot();
    NSArray *list = prefs[NFWeChatTargetsListKey];
    if ([list isKindOfClass:[NSArray class]]) return list;
    // 旧版迁移：逗号分隔字符串 → 每个一个全量目标
    NSString *raw = prefs[NFWeChatTargetsKey];
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return @[];
    NSMutableArray<NSDictionary *> *migrated = [NSMutableArray array];
    for (NSString *piece in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，;； "]]) {
        NSString *t = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) [migrated addObject:@{ @"id": t, @"contains": @[], @"exclude": @[] }];
    }
    return migrated;
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

static NSString *NFTextForScope(NSString *scope, NFNotificationRecord *record) {
    if ([scope isEqualToString:NFRuleScopeTitle]) return record.title ?: @"";
    if ([scope isEqualToString:NFRuleScopeSubtitle]) return record.subtitle ?: @"";
    if ([scope isEqualToString:NFRuleScopeMessage]) return record.messageText ?: @"";
    return record.joinedText ?: @"";
}

static NSArray *NFEnabledEntries(NSArray *entries) {
    if (![entries isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *enabledVal = entry[@"Enabled"] ?: entry[@"enabled"];
        if (enabledVal != nil && ![enabledVal boolValue]) continue; // 未启用规则不计入
        [out addObject:entry];
    }
    return out;
}

static BOOL NFEntryListMatches(NSArray *entries, NSString *scope, NFNotificationRecord *record) {
    for (NSDictionary *entry in NFEnabledEntries(entries)) {
        NSString *ruleText = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : @"") : (NSString *)entry;
        NSString *entryScope = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"scope"] isKindOfClass:[NSString class]] ? entry[@"scope"] : @"") : @"";
        NSString *haystack = NFTextForScope(entryScope.length ? entryScope : scope, record);
        if (ruleText.length > 0 && [haystack rangeOfString:ruleText].location != NSNotFound) return YES;
    }
    return NO;
}

// 转发去重：带 ID 的通知永久去重；无 ID 的按内容 30 秒窗口去重
static NSMutableSet<NSString *> *NFForwardedIDs = nil;
static NSMutableDictionary<NSString *, NSDate *> *NFForwardedTextMap = nil;
static dispatch_queue_t NFForwardedQueue = nil;

static void NFInitForwardedStore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NFForwardedIDs = [NSMutableSet set];
        NFForwardedTextMap = [NSMutableDictionary dictionary];
        NFForwardedQueue = dispatch_queue_create("com.mos.wxrelay.dedupe", DISPATCH_QUEUE_SERIAL);
    });
}

static BOOL NFMarkForwardedIfNew(NFNotificationRecord *record) {
    NFInitForwardedStore();
    __block BOOL isNew = NO;
    dispatch_sync(NFForwardedQueue, ^{
        NSDate *now = [NSDate date];
        NSString *nid = record.bulletinID ?: record.recordID;
        if (nid.length > 0) {
            // 带 ID：永久去重
            if ([NFForwardedIDs containsObject:nid]) { isNew = NO; return; }
            [NFForwardedIDs addObject:nid];
        }
        // 内容 30 秒窗口：对所有通知生效（重发会换 ID，仅 ID 去重不够）
        NSString *text = record.joinedText ?: @"";
        if (text.length == 0) { isNew = YES; return; }
        NSDate *seen = NFForwardedTextMap[text];
        if (seen && now.timeIntervalSince1970 - seen.timeIntervalSince1970 < 30) { isNew = NO; return; }
        NFForwardedTextMap[text] = now;
        // 清理过期
        NSMutableArray *stale = [NSMutableArray array];
        [NFForwardedTextMap enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSDate *t, BOOL *stop) {
            if (now.timeIntervalSince1970 - t.timeIntervalSince1970 >= 30) [stale addObject:k];
        }];
        [NFForwardedTextMap removeObjectsForKeys:stale];
        isNew = YES;
    });
    return isNew;
}

static void NFAppendBlockedLog(NFNotificationRecord *record, NFMatchResult *result);

static void NFReloadPreferences(void);

// v2.4.6 目标级来源 App 白名单：bundleID 数组等值匹配（picker 勾选），空数组=不限
static BOOL NFTargetAllowsApp(NSDictionary *target, NFNotificationRecord *record) {
    NSArray *apps = [target[@"apps"] isKindOfClass:[NSArray class]] ? target[@"apps"] : @[];
    if (apps.count == 0) return YES;
    NSString *bid = (record.bundleIdentifier ?: @"").lowercaseString;
    if (bid.length == 0) return NO;
    for (NSString *a in apps) {
        if ([a isKindOfClass:[NSString class]] && [a.lowercaseString isEqualToString:bid]) return YES;
    }
    return NO;
}

// v2.8.0 模块B：微信端消息源旗标（15 分钟内=微信进程活着，通知源让位，防双发）
static BOOL NFWeChatMsgSourceAlive(void) {
    NSString *container = NFWeChatContainerPath();
    if (!container) return NO;
    NSString *path = [container stringByAppendingPathComponent:@"tmp/wxrelay_msgsource.flag"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) return NO;
    NSDate *mtime = attrs[NSFileModificationDate];
    return mtime && [[NSDate date] timeIntervalSinceDate:mtime] < 900.0;
}

// v2.8.0 模块B：微信端消息 spool → record → 现有匹配管线
static void NFForwardMatchedRecordToWeChat(NFNotificationRecord *record);

static void NFSBLog(NSString *msg) {
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSString *path = @"/var/mobile/Library/wxrelay_sb.log";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:path]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) { }
}

static void NFPumpWeChatMsgSpool(void) {
    @try {
        NSString *container = NFWeChatContainerPath();
        if (!container) return;
        NSString *dir = [container stringByAppendingPathComponent:@"tmp/wxrelay_msgs"];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        NFSBLog([NSString stringWithFormat:@"pump: dir=%@ files=%lu", dir, (unsigned long)files.count]);
        if (files.count == 0) return;
        for (NSString *fn in files) {
            if (![fn hasSuffix:@".json"]) continue;
            NSString *p = [dir stringByAppendingPathComponent:fn];
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:p]
                options:NSJSONReadingAllowFragments error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = [d[@"bid"] isKindOfClass:[NSString class]] ? d[@"bid"] : @"";
            NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : @"";
            if (bid.length == 0 || title.length == 0) continue;
            NFNotificationRecord *record = [[NFNotificationRecord alloc] init];
            record.bundleIdentifier = bid;
            record.sectionID = bid;
            record.title = title;
            record.subtitle = [d[@"subtitle"] isKindOfClass:[NSString class]] ? d[@"subtitle"] : @"";
            record.body = [d[@"body"] isKindOfClass:[NSString class]] ? d[@"body"] : @"";
            record.message = record.body;
            record.bulletinID = [d[@"msgid"] isKindOfClass:[NSString class]] ? d[@"msgid"] : nil;
            NFSBLog([NSString stringWithFormat:@"pump record: title=%@ body=%@ bid=%@ id=%@", record.title, record.body, record.bundleIdentifier, record.bulletinID]);
            NFForwardMatchedRecordToWeChat(record);
            NFSBLog(@"pump: forwarded call done");
        }
    } @catch (NSException *e) { }
}

static void NFWeChatMsgSpoolCallback(CFNotificationCenterRef __unused c, void __unused *o,
                                     CFStringRef __unused n, const void __unused *obj, CFDictionaryRef __unused ui) {
    @autoreleasepool { NFPumpWeChatMsgSpool(); }
}

static void NFForwardMatchedRecordToWeChat(NFNotificationRecord *record) {
    // v2.4.9：转发前强制读最新 prefs（锁屏 darwin 排队可能跳过更新）
    NFReloadPreferences();
    // v2.8.2 模块B：微信通知让位，但 wxmsg_ 前缀的 B 记录免检（否则自堵）
    if ([record.bundleIdentifier isEqualToString:@"com.tencent.xin"] && NFWeChatMsgSourceAlive()
        && ![record.bulletinID hasPrefix:@"wxmsg_"]) { NFSBLog(@"gate: suppressed (flag fresh)"); return; }
    if ([record.bundleIdentifier isEqualToString:@"com.tencent.xin"]) NFSBLog(@"gate: passed (wxmsg or flag stale)");
    if (!NFMarkForwardedIfNew(record)) return;
    NSArray<NSDictionary *> *targets = NFWeChatTargetList();
    if (targets.count == 0) return;
    NSString *text = record.joinedText.length > 0 ? record.joinedText : record.messageText;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array]; // [{id, text}]
    for (NSDictionary *target in targets) {
        if (![target isKindOfClass:[NSDictionary class]]) continue;
        NSString *tid = [target[@"id"] isKindOfClass:[NSString class]] ? target[@"id"] : @"";
        BOOL enabled = target[@"enabled"] == nil ? YES : [target[@"enabled"] boolValue];
        if (!(tid.length && enabled)) continue;
        // v2.4.3 目标级来源 App 白名单
        if (!NFTargetAllowsApp(target, record)) continue;
        NSArray *exclude = NFEnabledEntries(target[@"exclude"]);
        if (exclude.count > 0 && NFEntryListMatches(exclude, NFRuleScopeMessage, record)) continue; // 排除一票否决
        NSArray *contains = NFEnabledEntries(target[@"contains"]);
        if (contains.count == 0) {
            // 留空=全量转发（纯转发，无回复）
            if (text.length) [items addObject:@{ @"id": tid, @"text": text }];
            continue;
        }
        // 逐规则判定：命中的规则若有 reply → 转发原文一次 + 各发一条回复（占位符展开）
        __block BOOL anyHit = NO; __block BOOL forwarded = NO;
        for (NSDictionary *entry in contains) {
            NSString *ruleText = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : @"") : (NSString *)entry;
            if (ruleText.length == 0) continue;
            NSString *entryScope = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"scope"] isKindOfClass:[NSString class]] ? entry[@"scope"] : @"") : @"";
            NSString *haystack = NFTextForScope(entryScope.length ? entryScope : NFRuleScopeMessage, record);
            if ([haystack rangeOfString:ruleText].location == NSNotFound) continue;
            anyHit = YES;
            // v2.7.7 语义：回复框留空=纯转发；填了=纯回复（不转发），文本原样发送
            NSString *replyOnly = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"replyOnly"] isKindOfClass:[NSString class]] ? entry[@"replyOnly"] : @"") : @"";
            BOOL isReplyOnly = [[replyOnly stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
            if (!isReplyOnly && !forwarded && text.length) { [items addObject:@{ @"id": tid, @"text": text }]; forwarded = YES; continue; }
            if (isReplyOnly && replyOnly.length > 0) [items addObject:@{ @"id": tid, @"text": replyOnly }];
        }
        if (!anyHit) continue;
    }
    if (items.count == 0) return;
    @autoreleasepool {
        NFMatchResult *logResult = [[NFMatchResult alloc] init];
        logResult.shouldBlock = YES;
        logResult.matchedMode = @"forward";
        NFAppendBlockedLog(record, logResult);
    }
    NSString *container = NFWeChatContainerPath();
    if (!container) return;
    @try {
        NSString *taskDir = [container stringByAppendingPathComponent:@"tmp/wxrelay_tasks"];
        [[NSFileManager defaultManager] createDirectoryAtPath:taskDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *fn = [NSString stringWithFormat:@"task_%@.json", [[NSUUID UUID] UUIDString]];
        NSDictionary *task = @{ @"items": items,
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
    NFForwardMatchedRecordToWeChat(record);
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
    NFForwardMatchedRecordToWeChat(record);
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
    NFForwardMatchedRecordToWeChat(record);
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
        NFPreferencesQueue = dispatch_queue_create("com.777qwq.wxrelay.preferences", DISPATCH_QUEUE_SERIAL);
        NFBlockedActionQueue = dispatch_queue_create("com.777qwq.wxrelay.blocked-actions", DISPATCH_QUEUE_SERIAL);
        NFBlockedActionTimestamps = [NSMutableDictionary dictionary];
        NFBlockedIdentityQueue = dispatch_queue_create("com.777qwq.wxrelay.blocked-identities", DISPATCH_QUEUE_SERIAL);
        NFBlockedIdentityCache = [NSMutableDictionary dictionary];
        NFNotificationHistoryQueue = dispatch_queue_create("com.777qwq.wxrelay.history", DISPATCH_QUEUE_SERIAL);
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
        // v2.8.0 模块B：微信消息 spool 到货
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        NFWeChatMsgSpoolCallback,
                                        (CFStringRef)@"com.777qwq.wxrelay.msg",
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
