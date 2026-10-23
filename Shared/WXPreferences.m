#import "WXPreferences.h"
#import <CoreFoundation/CoreFoundation.h>

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

NSString * const WXPreferencesIdentifier = @"com.777qwq.wxrelay";
NSString * const WXPreferencesChangedDarwinNotification = @"com.777qwq.wxrelay/preferences-changed";

NSString * const WXEnabledKey = @"Enabled";
NSString * const WXGlobalRulesEnabledKey = @"GlobalRulesEnabled";
NSString * const WXGlobalContainsKey = @"GlobalContains";
NSString * const WXGlobalExcludeKey = @"GlobalExclude";
NSString * const WXGlobalRegexKey = @"GlobalRegex";
NSString * const WXAppRulesKey = @"AppRules";
NSString * const WXDeleteFilteredNotificationsKey = @"DeleteFilteredNotifications";
NSString * const WXLoggingEnabledKey = @"LoggingEnabled";
NSString * const WXLoggingDisabledBundleIdentifiersKey = @"LoggingDisabledBundleIdentifiers";
NSString * const WXLogEntryLimitKey = @"LogEntryLimit";
NSString * const WXPrefOnlyConfiguredAppsKey = @"PrefOnlyConfiguredApps";
NSString * const WXPrefShowSystemAppsKey = @"PrefShowSystemApps";
NSString * const WXPrefShowTrollAppsKey = @"PrefShowTrollApps";
NSString * const WXWeChatForwardKey = @"WeChatForward";
NSString * const WXWeChatTargetsKey = @"WeChatTargets";
NSString * const WXWeChatTargetsListKey = @"WeChatTargetsList";
NSString * const WXKeepAliveEnabledKey = @"KeepAliveEnabled";

NSString * const WXRulesEnabledKey = @"enabled";
NSString * const WXRulesContainsKey = @"contains";
NSString * const WXRulesExcludeKey = @"exclude";
NSString * const WXRulesRegexKey = @"regex";
NSString * const WXRulesModeKey = @"mode";
NSString * const WXRulesModeBlacklist = @"blacklist";
NSString * const WXRulesModeWhitelist = @"whitelist";
NSString * const WXRuleEntryIdentifierKey = @"id";
NSString * const WXRuleEntryTextKey = @"text";
NSString * const WXRuleEntryEnabledKey = @"enabled";
NSString * const WXRuleEntryScopeKey = @"scope";
NSString * const WXRuleScopeMessage = @"message";
NSString * const WXRuleScopeTitle = @"title";
NSString * const WXRuleScopeSubtitle = @"subtitle";
NSString * const WXRuleScopeAll = @"all";

NSString * const WXLogIdentifierKey = @"id";
NSString * const WXLogTimestampKey = @"timestamp";
NSString * const WXLogBundleIdentifierKey = @"bundleID";
NSString * const WXLogTitleKey = @"title";
NSString * const WXLogSubtitleKey = @"subtitle";
NSString * const WXLogBodyKey = @"body";
NSString * const WXLogHeaderKey = @"header";
NSString * const WXLogMessageKey = @"message";
NSString * const WXLogJoinedTextKey = @"joinedText";
NSString * const WXLogSectionIDKey = @"sectionID";
NSString * const WXLogBulletinIDKey = @"bulletinID";
NSString * const WXLogRecordIDKey = @"recordID";
NSString * const WXLogPublisherBulletinIDKey = @"publisherBulletinID";
NSString * const WXLogMatchedScopeKey = @"matchedScope";
NSString * const WXLogMatchedModeKey = @"matchedMode";
NSString * const WXLogMatchedPatternKey = @"matchedPattern";
NSString * const WXLogDeleteRequestedKey = @"deleteRequested";
NSString * const WXLogDeleteStatusKey = @"deleteStatus";
NSString * const WXLogDeleteMethodKey = @"deleteMethod";

NSString * const WXMatchScopeGlobal = @"global";
NSString * const WXMatchModeExclude = @"exclude";
NSString * const WXMatchModeContains = @"contains";
NSString * const WXMatchModeRegex = @"regex";
NSString * const WXMatchModeWhitelistDefault = @"whitelist-default";

static NSString *WXPreferencesFilename(void) {
    return [WXPreferencesIdentifier stringByAppendingString:@".plist"];
}

static NSString *WXPreferencesLegacyDirectoryPath(void) {
    return @"/var/mobile/Library/Preferences";
}

static NSString *WXPreferencesLegacyFilePath(void) {
    return [WXPreferencesLegacyDirectoryPath() stringByAppendingPathComponent:WXPreferencesFilename()];
}

static NSString *WXPreferencesPrimaryFilePath(void) {
    return jbroot(WXPreferencesLegacyFilePath());
}

static NSString *WXPreferencesLegacyRootlessFilePath(void) {
    return [@"/var/jb/Library/Preferences" stringByAppendingPathComponent:WXPreferencesFilename()];
}

static NSArray<NSString *> *WXPreferencesCandidatePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *candidates = @[
        WXPreferencesPrimaryFilePath(),
        WXPreferencesLegacyFilePath(),
        WXPreferencesLegacyRootlessFilePath()
    ];

    for (NSString *path in candidates) {
        if (path.length == 0 || [paths containsObject:path]) {
            continue;
        }
        [paths addObject:path];
    }

    return paths;
}

static NSDictionary *WXPreferencesDictionaryAtPath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }

    NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:path];
    return [dictionary isKindOfClass:[NSDictionary class]] ? dictionary : nil;
}

static NSString *WXPreparePrimaryPreferencesFilePath(void) {
    NSString *primaryPath = WXPreferencesPrimaryFilePath();
    if (primaryPath.length == 0) {
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:primaryPath]) {
        return primaryPath;
    }

    for (NSString *candidatePath in WXPreferencesCandidatePaths()) {
        if ([candidatePath isEqualToString:primaryPath] ||
            ![fileManager fileExistsAtPath:candidatePath]) {
            continue;
        }

        NSString *parentPath = [primaryPath stringByDeletingLastPathComponent];
        [fileManager createDirectoryAtPath:parentPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];

        NSError *moveError = nil;
        if (![fileManager moveItemAtPath:candidatePath toPath:primaryPath error:&moveError]) {
            [fileManager copyItemAtPath:candidatePath toPath:primaryPath error:nil];
        }
        break;
    }

    return primaryPath;
}

@interface WXPreferences ()

+ (NSDictionary *)normalizedRulesDictionaryFromEnabled:(BOOL)enabled
                                                  mode:(NSString *)mode
                                              contains:(NSArray * _Nullable)contains
                                               exclude:(NSArray * _Nullable)exclude
                                                 regex:(NSArray * _Nullable)regex;

@end

@implementation WXPreferences

+ (NSArray<NSString *> *)_allPreferenceKeys {
    return @[
        WXEnabledKey,
        WXGlobalRulesEnabledKey,
        WXGlobalContainsKey,
        WXGlobalExcludeKey,
        WXGlobalRegexKey,
        WXAppRulesKey,
        WXDeleteFilteredNotificationsKey,
        WXLoggingEnabledKey,
        WXLoggingDisabledBundleIdentifiersKey,
        WXLogEntryLimitKey,
        WXPrefOnlyConfiguredAppsKey,
        WXPrefShowSystemAppsKey,
        WXPrefShowTrollAppsKey,
        WXKeepAliveEnabledKey
    ];
}

+ (NSDictionary *)defaultPreferences {
    return @{
        WXEnabledKey: @YES,
        WXGlobalRulesEnabledKey: @NO,
        WXGlobalContainsKey: @[],
        WXWeChatForwardKey: @NO,
        WXKeepAliveEnabledKey: @NO,
        WXWeChatTargetsKey: @"",
        WXGlobalExcludeKey: @[],
        WXGlobalRegexKey: @[],
        WXAppRulesKey: @{},
        WXDeleteFilteredNotificationsKey: @NO,
        WXLoggingEnabledKey: @YES,
        WXLoggingDisabledBundleIdentifiersKey: @[],
        WXLogEntryLimitKey: @([self defaultLogEntryLimit]),
        WXPrefOnlyConfiguredAppsKey: @NO,
        WXPrefShowSystemAppsKey: @YES,
        WXPrefShowTrollAppsKey: @YES
    };
}

+ (NSDictionary *)loadPreferences {
    NSString *primaryPath = WXPreparePrimaryPreferencesFilePath();
    NSDictionary *rawPreferences = WXPreferencesDictionaryAtPath(primaryPath);

    if (!rawPreferences) {
        for (NSString *candidatePath in WXPreferencesCandidatePaths()) {
            rawPreferences = WXPreferencesDictionaryAtPath(candidatePath);
            if (rawPreferences) {
                break;
            }
        }
    }

    return [self normalizedPreferencesFromDictionary:rawPreferences ?: @{}];
}

+ (NSMutableDictionary *)loadMutablePreferences {
    return [[self loadPreferences] mutableCopy];
}

+ (BOOL)savePreferences:(NSDictionary *)preferences error:(NSError **)error {
    NSDictionary *normalizedPreferences = [self normalizedPreferencesFromDictionary:preferences];
    NSString *preferencesPath = WXPreparePrimaryPreferencesFilePath();
    if (preferencesPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:WXPreferencesIdentifier
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to resolve preferences path."}];
        }
        return NO;
    }

    NSString *parentPath = [preferencesPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:parentPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    BOOL written = [normalizedPreferences writeToFile:preferencesPath atomically:YES];
    if (!written && error) {
        *error = [NSError errorWithDomain:WXPreferencesIdentifier
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write preferences."}];
    }

    return written;
}

+ (void)postPreferencesChangedNotification {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)WXPreferencesChangedDarwinNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

+ (BOOL)loggingEnabledForPreferences:(NSDictionary *)preferences {
    NSDictionary *normalizedPreferences = [self normalizedPreferencesFromDictionary:preferences];
    return [normalizedPreferences[WXLoggingEnabledKey] boolValue];
}

+ (BOOL)isLoggingDisabledForBundleIdentifier:(NSString *)bundleIdentifier
                                preferences:(NSDictionary *)preferences {
    if (bundleIdentifier.length == 0) {
        return NO;
    }

    NSDictionary *normalizedPreferences = [self normalizedPreferencesFromDictionary:preferences];
    NSArray *disabledList = normalizedPreferences[WXLoggingDisabledBundleIdentifiersKey];
    return [disabledList isKindOfClass:[NSArray class]] && [disabledList containsObject:bundleIdentifier];
}

+ (BOOL)loggingEnabledForBundleIdentifier:(NSString *)bundleIdentifier
                             preferences:(NSDictionary *)preferences {
    return [self loggingEnabledForPreferences:preferences] &&
           ![self isLoggingDisabledForBundleIdentifier:bundleIdentifier preferences:preferences];
}

+ (void)setLoggingDisabled:(BOOL)disabled
        forBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        return;
    }

    NSMutableDictionary *preferences = [self loadMutablePreferences];
    NSMutableArray<NSString *> *disabledList = [preferences[WXLoggingDisabledBundleIdentifiersKey] mutableCopy];
    if (![disabledList isKindOfClass:[NSMutableArray class]]) {
        disabledList = [NSMutableArray array];
    }

    if (disabled) {
        if (![disabledList containsObject:bundleIdentifier]) {
            [disabledList addObject:bundleIdentifier];
        }
    } else {
        [disabledList removeObject:bundleIdentifier];
    }

    preferences[WXLoggingDisabledBundleIdentifiersKey] = disabledList;

    NSError *error = nil;
    if (![self savePreferences:preferences error:&error]) {
        return;
    }

    [self postPreferencesChangedNotification];
}

+ (NSInteger)defaultLogEntryLimit {
    return 500;
}

+ (NSInteger)normalizedLogEntryLimit:(id)value {
    NSInteger defaultLimit = [self defaultLogEntryLimit];
    if (![value respondsToSelector:@selector(integerValue)]) {
        return defaultLimit;
    }

    NSInteger limit = [value integerValue];
    if (limit <= 0) {
        return defaultLimit;
    }

    return limit;
}

+ (NSDictionary *)globalRulesFromPreferences:(NSDictionary *)preferences {
    NSDictionary *normalizedPreferences = [self normalizedPreferencesFromDictionary:preferences];
    return [self normalizedRulesDictionaryFromEnabled:YES
                                             contains:normalizedPreferences[WXGlobalContainsKey]
                                              exclude:normalizedPreferences[WXGlobalExcludeKey]
                                                regex:normalizedPreferences[WXGlobalRegexKey]];
}

+ (NSDictionary *)rulesForBundleIdentifier:(NSString *)bundleIdentifier
                           fromPreferences:(NSDictionary *)preferences {
    if (bundleIdentifier.length == 0) {
        return nil;
    }

    NSDictionary *normalizedPreferences = [self normalizedPreferencesFromDictionary:preferences];
    NSDictionary *appRules = normalizedPreferences[WXAppRulesKey];
    return [self normalizedRulesDictionaryFromRawDictionary:appRules[bundleIdentifier]];
}

+ (NSDictionary *)normalizedRulesDictionaryFromRawDictionary:(NSDictionary *)rawRules {
    if (![rawRules isKindOfClass:[NSDictionary class]]) {
        return [self normalizedRulesDictionaryFromEnabled:NO
                                                     mode:WXRulesModeBlacklist
                                                 contains:nil
                                                  exclude:nil
                                                    regex:nil];
    }

    BOOL enabled = [rawRules[WXRulesEnabledKey] respondsToSelector:@selector(boolValue)] ? [rawRules[WXRulesEnabledKey] boolValue] : NO;
    return [self normalizedRulesDictionaryFromEnabled:enabled
                                                 mode:[self normalizedRulesMode:rawRules[WXRulesModeKey]]
                                             contains:rawRules[WXRulesContainsKey]
                                              exclude:rawRules[WXRulesExcludeKey]
                                                regex:rawRules[WXRulesRegexKey]];
}

+ (NSString *)normalizedRulesMode:(id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return WXRulesModeBlacklist;
    }

    if ([value isEqualToString:WXRulesModeWhitelist]) {
        return WXRulesModeWhitelist;
    }

    return WXRulesModeBlacklist;
}

+ (NSDictionary *)normalizedRulesDictionaryFromEnabled:(BOOL)enabled
                                              contains:(NSArray *)contains
                                               exclude:(NSArray *)exclude
                                                 regex:(NSArray *)regex {
    return [self normalizedRulesDictionaryFromEnabled:enabled
                                                 mode:WXRulesModeBlacklist
                                             contains:contains
                                              exclude:exclude
                                                regex:regex];
}

+ (NSDictionary *)normalizedRulesDictionaryFromEnabled:(BOOL)enabled
                                                  mode:(NSString *)mode
                                              contains:(NSArray *)contains
                                               exclude:(NSArray *)exclude
                                                 regex:(NSArray *)regex {
    return @{
        WXRulesEnabledKey: @(enabled),
        WXRulesModeKey: [self normalizedRulesMode:mode],
        WXRulesContainsKey: [self normalizedRuleEntriesFromArray:contains defaultScope:WXRuleScopeMessage],
        WXRulesExcludeKey: [self normalizedRuleEntriesFromArray:exclude defaultScope:WXRuleScopeAll],
        WXRulesRegexKey: [self normalizedRuleEntriesFromArray:regex defaultScope:WXRuleScopeAll]
    };
}

+ (BOOL)rulesDictionaryHasConfiguredValues:(NSDictionary *)rules {
    if (![rules isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    if ([rules[WXRulesEnabledKey] boolValue]) {
        return YES;
    }

    return [rules[WXRulesContainsKey] count] > 0 ||
           [rules[WXRulesExcludeKey] count] > 0 ||
           [rules[WXRulesRegexKey] count] > 0;
}

// 只翻 enabled 开关，规则条目原样保留；用于扫描保存后补一次「启用该应用规则」。
+ (BOOL)setRulesEnabled:(BOOL)enabled
     forBundleIdentifier:(NSString *)bundleIdentifier
                 error:(NSError * _Nullable * _Nullable)error {
    if (bundleIdentifier.length == 0) {
        return NO;
    }

    NSMutableDictionary *preferences = [self loadMutablePreferences];
    NSMutableDictionary *appRules = [preferences[WXAppRulesKey] mutableCopy];
    if (![appRules isKindOfClass:[NSMutableDictionary class]]) {
        appRules = [NSMutableDictionary dictionary];
    }

    NSMutableDictionary *mutableRules = [[self normalizedRulesDictionaryFromRawDictionary:appRules[bundleIdentifier]] mutableCopy];
    mutableRules[WXRulesEnabledKey] = @(enabled);
    appRules[bundleIdentifier] = mutableRules;
    preferences[WXAppRulesKey] = appRules;

    if (![self savePreferences:preferences error:error]) {
        return NO;
    }

    [self postPreferencesChangedNotification];
    return YES;
}

+ (NSUInteger)globalRuleEntryCountFromPreferences:(NSDictionary *)preferences {
    NSDictionary *rules = [self globalRulesFromPreferences:preferences];
    return [rules[WXRulesContainsKey] count] +
           [rules[WXRulesExcludeKey] count] +
           [rules[WXRulesRegexKey] count];
}

+ (NSUInteger)enabledAppRulesCountFromPreferences:(NSDictionary *)preferences {
    NSDictionary *normalizedPreferences = [self normalizedPreferencesFromDictionary:preferences];
    NSDictionary *appRules = normalizedPreferences[WXAppRulesKey];
    if (![appRules isKindOfClass:[NSDictionary class]]) {
        return 0;
    }

    __block NSUInteger count = 0;
    [appRules enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![obj isKindOfClass:[NSDictionary class]]) {
            return;
        }
        if ([obj[WXRulesEnabledKey] boolValue]) {
            count += 1;
        }
    }];
    return count;
}

+ (NSArray<NSDictionary *> *)normalizedRuleEntriesFromArray:(NSArray *)rawRules {
    return [self normalizedRuleEntriesFromArray:rawRules defaultScope:WXRuleScopeAll];
}

+ (NSArray<NSDictionary *> *)normalizedRuleEntriesFromArray:(NSArray *)rawRules
                                              defaultScope:(NSString *)defaultScope {
    if (![rawRules isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (id rawRule in rawRules) {
        NSString *identifier = nil;
        NSString *text = nil;
        BOOL enabled = YES;
        NSString *scope = defaultScope;
        id replyOnlyValue = nil;

        if ([rawRule isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dictionary = rawRule;
            id textValue = dictionary[WXRuleEntryTextKey] ?: dictionary[@"value"];
            if ([dictionary[WXRuleEntryEnabledKey] respondsToSelector:@selector(boolValue)]) {
                enabled = [dictionary[WXRuleEntryEnabledKey] boolValue];
            }
            if ([dictionary[WXRuleEntryScopeKey] isKindOfClass:[NSString class]] &&
                [dictionary[WXRuleEntryScopeKey] length] > 0) {
                scope = dictionary[WXRuleEntryScopeKey];
            }
            replyOnlyValue = dictionary[@"replyOnly"]; // v2.7.7 旧 reply 键随 normalize 洗掉
            if ([dictionary[WXRuleEntryIdentifierKey] isKindOfClass:[NSString class]] &&
                [dictionary[WXRuleEntryIdentifierKey] length] > 0) {
                identifier = dictionary[WXRuleEntryIdentifierKey];
            }
            text = [self _normalizedRuleText:textValue];
        } else {
            text = [self _normalizedRuleText:rawRule];
        }

        if (text.length == 0) {
            continue;
        }

        NSMutableDictionary *entry = [[self ruleEntryWithText:text
                                                    enabled:enabled
                                                  identifier:identifier
                                                       scope:[self _normalizedRuleScope:scope defaultScope:defaultScope]] mutableCopy];
        // v2.7.7：只透传回复框（留空=纯转发）
        if (replyOnlyValue != nil && [replyOnlyValue isKindOfClass:[NSString class]] && [(NSString *)replyOnlyValue length] > 0) {
            entry[@"replyOnly"] = replyOnlyValue;
        }
        [entries addObject:entry];
    }

    return entries;
}

+ (NSArray<NSString *> *)activeRuleTextsFromRuleEntries:(NSArray *)rawRules {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *entry in [self normalizedRuleEntriesFromArray:rawRules]) {
        if (![self ruleEntryEnabled:entry]) {
            continue;
        }

        NSString *text = [self ruleTextFromEntry:entry];
        if (text.length > 0) {
            [texts addObject:text];
        }
    }

    return texts;
}

+ (NSArray<NSDictionary *> *)activeRuleEntriesFromArray:(NSArray *)rawRules
                                          defaultScope:(NSString *)defaultScope {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSDictionary *entry in [self normalizedRuleEntriesFromArray:rawRules defaultScope:defaultScope]) {
        if ([self ruleEntryEnabled:entry]) {
            [entries addObject:entry];
        }
    }
    return entries;
}

+ (NSString *)ruleTextFromEntry:(NSDictionary *)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    return [self _normalizedRuleText:entry[WXRuleEntryTextKey]];
}

+ (BOOL)ruleEntryEnabled:(NSDictionary *)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    if ([entry[WXRuleEntryEnabledKey] respondsToSelector:@selector(boolValue)]) {
        return [entry[WXRuleEntryEnabledKey] boolValue];
    }

    return YES;
}

+ (NSString *)ruleScopeFromEntry:(NSDictionary *)entry
                    defaultScope:(NSString *)defaultScope {
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return [self _normalizedRuleScope:nil defaultScope:defaultScope];
    }

    return [self _normalizedRuleScope:entry[WXRuleEntryScopeKey] defaultScope:defaultScope];
}

+ (NSDictionary *)ruleEntryWithText:(NSString *)text
                            enabled:(BOOL)enabled
                          identifier:(NSString *)identifier
                               scope:(NSString *)scope {
    NSString *normalizedText = [self _normalizedRuleText:text];
    NSString *resolvedIdentifier = identifier.length > 0 ? identifier : [NSUUID UUID].UUIDString;
    return @{
        WXRuleEntryIdentifierKey: resolvedIdentifier,
        WXRuleEntryTextKey: normalizedText ?: @"",
        WXRuleEntryEnabledKey: @(enabled),
        WXRuleEntryScopeKey: [self _normalizedRuleScope:scope defaultScope:WXRuleScopeAll]
    };
}

+ (NSArray<NSString *> *)normalizedRuleLinesFromArray:(NSArray *)rawRules {
    if (![rawRules isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<NSString *> *normalizedRules = [NSMutableArray array];
    NSMutableSet<NSString *> *seenRules = [NSMutableSet set];

    for (id rawValue in rawRules) {
        id value = rawValue;
        if (![value respondsToSelector:@selector(description)]) {
            continue;
        }

        if ([value isKindOfClass:[NSDictionary class]]) {
            value = [self ruleTextFromEntry:value];
        }

        NSString *rule = [[value description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (rule.length == 0 || [seenRules containsObject:rule]) {
            continue;
        }

        [seenRules addObject:rule];
        [normalizedRules addObject:rule];
    }

    return normalizedRules;
}

+ (NSArray<NSString *> *)normalizedRuleLinesFromMultilineString:(NSString *)multilineString {
    if (![multilineString isKindOfClass:[NSString class]] || multilineString.length == 0) {
        return @[];
    }

    NSArray<NSString *> *components = [multilineString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    return [self normalizedRuleLinesFromArray:components];
}

+ (NSString *)multilineStringFromRuleLines:(NSArray<NSString *> *)rules {
    return [[self normalizedRuleLinesFromArray:rules] componentsJoinedByString:@"\n"];
}

+ (NSString *)logsFilePath {
    return jbroot(@"/var/mobile/Library/Preferences/com.777qwq.wxrelay.logs.plist");
}

+ (NSDictionary *)normalizedPreferencesFromDictionary:(NSDictionary *)rawPreferences {
    NSDictionary *defaultPreferences = [self defaultPreferences];
    NSMutableDictionary *normalizedPreferences = [defaultPreferences mutableCopy];

    if ([rawPreferences[WXEnabledKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXEnabledKey] = @([rawPreferences[WXEnabledKey] boolValue]);
    }

    if ([rawPreferences[WXGlobalRulesEnabledKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXGlobalRulesEnabledKey] = @([rawPreferences[WXGlobalRulesEnabledKey] boolValue]);
    }
    if ([rawPreferences[WXDeleteFilteredNotificationsKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXDeleteFilteredNotificationsKey] = @([rawPreferences[WXDeleteFilteredNotificationsKey] boolValue]);
    }
    if ([rawPreferences[WXLoggingEnabledKey] isKindOfClass:[NSNumber class]]) {
        normalizedPreferences[WXLoggingEnabledKey] = @([rawPreferences[WXLoggingEnabledKey] boolValue]);
    }

    if ([rawPreferences[WXWeChatForwardKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXWeChatForwardKey] = @([rawPreferences[WXWeChatForwardKey] boolValue]);
    }
    if ([rawPreferences[WXKeepAliveEnabledKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXKeepAliveEnabledKey] = @([rawPreferences[WXKeepAliveEnabledKey] boolValue]);
    }
    if ([rawPreferences[WXWeChatTargetsKey] isKindOfClass:[NSString class]]) {
        normalizedPreferences[WXWeChatTargetsKey] = rawPreferences[WXWeChatTargetsKey];
    }
    if ([rawPreferences[WXWeChatTargetsListKey] isKindOfClass:[NSArray class]]) {
        normalizedPreferences[WXWeChatTargetsListKey] = rawPreferences[WXWeChatTargetsListKey];
    }

    NSMutableArray<NSString *> *normalizedDisabledList = [NSMutableArray array];
    NSMutableSet<NSString *> *seenDisabledList = [NSMutableSet set];
    NSArray *rawDisabledList = rawPreferences[WXLoggingDisabledBundleIdentifiersKey];
    if ([rawDisabledList isKindOfClass:[NSArray class]]) {
        for (id rawValue in rawDisabledList) {
            if (![rawValue isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *bundleIdentifier = [rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (bundleIdentifier.length == 0 || [seenDisabledList containsObject:bundleIdentifier]) {
                continue;
            }
            [seenDisabledList addObject:bundleIdentifier];
            [normalizedDisabledList addObject:bundleIdentifier];
        }
    }
    normalizedPreferences[WXLoggingDisabledBundleIdentifiersKey] = normalizedDisabledList;
    normalizedPreferences[WXLogEntryLimitKey] = @([self normalizedLogEntryLimit:rawPreferences[WXLogEntryLimitKey]]);
    if ([rawPreferences[WXPrefOnlyConfiguredAppsKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXPrefOnlyConfiguredAppsKey] = @([rawPreferences[WXPrefOnlyConfiguredAppsKey] boolValue]);
    }
    if ([rawPreferences[WXPrefShowSystemAppsKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXPrefShowSystemAppsKey] = @([rawPreferences[WXPrefShowSystemAppsKey] boolValue]);
    }
    if ([rawPreferences[WXPrefShowTrollAppsKey] respondsToSelector:@selector(boolValue)]) {
        normalizedPreferences[WXPrefShowTrollAppsKey] = @([rawPreferences[WXPrefShowTrollAppsKey] boolValue]);
    }

    normalizedPreferences[WXGlobalContainsKey] = [self normalizedRuleEntriesFromArray:rawPreferences[WXGlobalContainsKey] defaultScope:WXRuleScopeMessage];
    normalizedPreferences[WXGlobalExcludeKey] = [self normalizedRuleEntriesFromArray:rawPreferences[WXGlobalExcludeKey] defaultScope:WXRuleScopeAll];
    normalizedPreferences[WXGlobalRegexKey] = [self normalizedRuleEntriesFromArray:rawPreferences[WXGlobalRegexKey] defaultScope:WXRuleScopeAll];

    NSMutableDictionary *normalizedAppRules = [NSMutableDictionary dictionary];
    NSDictionary *rawAppRules = rawPreferences[WXAppRulesKey];
    if ([rawAppRules isKindOfClass:[NSDictionary class]]) {
        [rawAppRules enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if (![key isKindOfClass:[NSString class]] || [((NSString *)key) length] == 0) {
                return;
            }

            normalizedAppRules[key] = [self normalizedRulesDictionaryFromRawDictionary:obj];
        }];
    }

    normalizedPreferences[WXAppRulesKey] = normalizedAppRules;

    return normalizedPreferences;
}

+ (NSString *)_normalizedRuleText:(id)value {
    if (![value respondsToSelector:@selector(description)]) {
        return nil;
    }

    return [[[value description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
}

+ (NSString *)_normalizedRuleScope:(NSString *)scope defaultScope:(NSString *)defaultScope {
    NSString *resolvedScope = [scope isKindOfClass:[NSString class]] ? scope : defaultScope;
    NSSet<NSString *> *allowedScopes = [NSSet setWithObjects:
        WXRuleScopeMessage,
        WXRuleScopeTitle,
        WXRuleScopeSubtitle,
        WXRuleScopeAll,
        nil];
    if (![allowedScopes containsObject:resolvedScope]) {
        return defaultScope ?: WXRuleScopeAll;
    }
    return resolvedScope;
}

@end
