#import "WXPNotificationHistoryClient.h"
#import "../Shared/WXPreferences.h"
#import "../Shared/WXNotificationHistoryBridge.h"

@implementation WXPNotificationHistoryClient

+ (NSString *)_normalizedBundleIdentifier:(NSString *)bundleIdentifier {
    return [bundleIdentifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

+ (BOOL)_ensureDirectoryForFilePath:(NSString *)filePath error:(NSError **)error {
    NSString *directoryPath = [filePath stringByDeletingLastPathComponent];
    return [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:error];
}

+ (NSString *)requestRefreshForBundleIdentifier:(NSString *)bundleIdentifier
                                          limit:(NSUInteger)limit
                                          error:(NSError **)error {
    NSString *normalizedBundleIdentifier = [self _normalizedBundleIdentifier:bundleIdentifier];
    if (normalizedBundleIdentifier.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"cn.qwq.wxrelay.history"
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"RULE_SCAN_SOURCE_FAILED"}];
        }
        return nil;
    }

    NSString *requestIdentifier = [[NSUUID UUID] UUIDString];
    NSDictionary *request = @{
        WXNotificationHistoryRequestIdentifierKey: requestIdentifier,
        WXNotificationHistoryBundleIdentifierKey: normalizedBundleIdentifier,
        WXNotificationHistoryLimitKey: @(limit > 0 ? limit : 200),
        WXLogTimestampKey: @([[NSDate date] timeIntervalSince1970])
    };

    NSString *requestPath = WXNotificationHistoryRefreshRequestFilePath();
    if (![self _ensureDirectoryForFilePath:requestPath error:error]) {
        return nil;
    }

    if (![request writeToFile:requestPath atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"cn.qwq.wxrelay.history"
                                         code:11
                                     userInfo:@{NSLocalizedDescriptionKey: @"RULE_SCAN_SOURCE_FAILED"}];
        }
        return nil;
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)WXNotificationHistoryRefreshRequestNotification,
                                         NULL,
                                         NULL,
                                         YES);
    return requestIdentifier;
}

+ (NSDictionary *)refreshStatusForRequestIdentifier:(NSString *)requestIdentifier
                                   bundleIdentifier:(NSString *)bundleIdentifier {
    if (requestIdentifier.length == 0) {
        return nil;
    }

    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:WXNotificationHistoryRefreshStatusFilePath()];
    if (![status isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *statusRequestIdentifier = [status[WXNotificationHistoryRequestIdentifierKey] isKindOfClass:[NSString class]] ?
        status[WXNotificationHistoryRequestIdentifierKey] :
        nil;
    if (![statusRequestIdentifier isEqualToString:requestIdentifier]) {
        return nil;
    }

    NSString *normalizedBundleIdentifier = [self _normalizedBundleIdentifier:bundleIdentifier];
    NSString *statusBundleIdentifier = [status[WXNotificationHistoryBundleIdentifierKey] isKindOfClass:[NSString class]] ?
        status[WXNotificationHistoryBundleIdentifierKey] :
        nil;
    if (normalizedBundleIdentifier.length > 0 && ![statusBundleIdentifier isEqualToString:normalizedBundleIdentifier]) {
        return nil;
    }

    return status;
}

+ (NSArray<NSDictionary *> * _Nullable)_entriesFromSnapshotFileForBundleIdentifier:(NSString *)bundleIdentifier
                                                                      filePresent:(BOOL *)filePresent {
    NSArray *entries = [NSArray arrayWithContentsOfFile:WXNotificationHistorySnapshotFilePath()];
    if (![entries isKindOfClass:[NSArray class]]) {
        if (filePresent) {
            *filePresent = [[NSFileManager defaultManager] fileExistsAtPath:WXNotificationHistorySnapshotFilePath()];
        }
        return @[];
    }
    if (filePresent) {
        *filePresent = YES;
    }

    NSMutableArray<NSDictionary *> *filteredEntries = [NSMutableArray array];
    for (id entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *entryBundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[WXLogBundleIdentifierKey] : nil;
        if (![entryBundleIdentifier isEqualToString:bundleIdentifier]) {
            continue;
        }
        [filteredEntries addObject:entry];
    }
    return filteredEntries;
}

+ (NSArray<NSDictionary *> *)fetchEntriesForBundleIdentifier:(NSString *)bundleIdentifier
                                                       error:(NSError **)error
                                                      source:(NSString **)source {
    NSString *normalizedBundleIdentifier = [self _normalizedBundleIdentifier:bundleIdentifier];
    if (normalizedBundleIdentifier.length == 0) {
        if (source) {
            *source = nil;
        }
        return @[];
    }

    BOOL snapshotFilePresent = NO;
    NSArray<NSDictionary *> *snapshotEntries = [self _entriesFromSnapshotFileForBundleIdentifier:normalizedBundleIdentifier
                                                                                     filePresent:&snapshotFilePresent];
    if (snapshotFilePresent) {
        if (source) {
            *source = WXNotificationHistorySourceMirror;
        }
        return snapshotEntries;
    }

    if (source) {
        *source = nil;
    }
    return @[];
}

+ (NSArray<NSDictionary *> *)fetchAllAppsEntriesWithError:(NSError **)error
                                                   source:(NSString **)source {
    NSArray *entries = [NSArray arrayWithContentsOfFile:WXNotificationHistorySnapshotFilePath()];
    if (![entries isKindOfClass:[NSArray class]]) {
        if (source) {
            *source = nil;
        }
        return @[];
    }

    NSMutableArray<NSDictionary *> *filteredEntries = [NSMutableArray array];
    for (id entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *entryBundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[WXLogBundleIdentifierKey] : nil;
        if (entryBundleIdentifier.length == 0) {
            continue;
        }
        [filteredEntries addObject:entry];
    }

    if (source) {
        *source = WXNotificationHistorySourceMirror;
    }
    return filteredEntries;
}

@end
