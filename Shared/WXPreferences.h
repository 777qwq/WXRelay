#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const WXPreferencesIdentifier;
extern NSString * const WXPreferencesChangedDarwinNotification;

extern NSString * const WXEnabledKey;
extern NSString * const WXGlobalRulesEnabledKey;
extern NSString * const WXGlobalContainsKey;
extern NSString * const WXGlobalExcludeKey;
extern NSString * const WXGlobalRegexKey;
extern NSString * const WXAppRulesKey;
extern NSString * const WXDeleteFilteredNotificationsKey;
extern NSString * const WXLoggingEnabledKey;
extern NSString * const WXDiagnosticsEnabledKey;
extern NSString * const WXLoggingDisabledBundleIdentifiersKey;
extern NSString * const WXLogEntryLimitKey;
extern NSString * const WXPrefOnlyConfiguredAppsKey;
extern NSString * const WXPrefShowSystemAppsKey;
extern NSString * const WXPrefShowTrollAppsKey;

// WXRelay forward keys
extern NSString * const WXWeChatForwardKey;
extern NSString * const WXWeChatTargetsKey;
extern NSString * const WXWeChatTargetsListKey;

extern NSString * const WXRulesEnabledKey;
extern NSString * const WXRulesContainsKey;
extern NSString * const WXRulesExcludeKey;
extern NSString * const WXRulesRegexKey;
extern NSString * const WXRulesModeKey;
extern NSString * const WXRulesModeBlacklist;
extern NSString * const WXRulesModeWhitelist;
extern NSString * const WXRuleEntryIdentifierKey;
extern NSString * const WXRuleEntryTextKey;
extern NSString * const WXRuleEntryEnabledKey;
extern NSString * const WXRuleEntryScopeKey;
extern NSString * const WXRuleScopeMessage;
extern NSString * const WXRuleScopeTitle;
extern NSString * const WXRuleScopeSubtitle;
extern NSString * const WXRuleScopeAll;

extern NSString * const WXLogIdentifierKey;
extern NSString * const WXLogTimestampKey;
extern NSString * const WXLogBundleIdentifierKey;
extern NSString * const WXLogTitleKey;
extern NSString * const WXLogSubtitleKey;
extern NSString * const WXLogBodyKey;
extern NSString * const WXLogHeaderKey;
extern NSString * const WXLogMessageKey;
extern NSString * const WXLogJoinedTextKey;
extern NSString * const WXLogSectionIDKey;
extern NSString * const WXLogBulletinIDKey;
extern NSString * const WXLogRecordIDKey;
extern NSString * const WXLogPublisherBulletinIDKey;
extern NSString * const WXLogMatchedScopeKey;
extern NSString * const WXLogMatchedModeKey;
extern NSString * const WXLogMatchedPatternKey;
extern NSString * const WXLogDeleteRequestedKey;
extern NSString * const WXLogDeleteStatusKey;
extern NSString * const WXLogDeleteMethodKey;

extern NSString * const WXMatchScopeGlobal;
extern NSString * const WXMatchModeExclude;
extern NSString * const WXMatchModeContains;
extern NSString * const WXMatchModeRegex;
extern NSString * const WXMatchModeWhitelistDefault;

void WXDiagnosticsSaveResult(NSString *text);
NSString *WXDiagnosticsLoadResult(void);
NSDictionary *WXPreferencesCopySnapshot(void);
BOOL WXDiagnosticsEnabledNow(void);

@interface WXPreferences : NSObject

+ (NSDictionary *)defaultPreferences;
+ (BOOL)loggingEnabledForPreferences:(NSDictionary *)preferences;
+ (BOOL)isLoggingDisabledForBundleIdentifier:(NSString *)bundleIdentifier
                                preferences:(NSDictionary *)preferences;
+ (BOOL)loggingEnabledForBundleIdentifier:(NSString *)bundleIdentifier
                             preferences:(NSDictionary *)preferences;
+ (void)setLoggingDisabled:(BOOL)disabled
        forBundleIdentifier:(NSString *)bundleIdentifier;
+ (NSDictionary *)loadPreferences;
+ (NSMutableDictionary *)loadMutablePreferences;
+ (NSDictionary *)normalizedPreferencesFromDictionary:(NSDictionary * _Nullable)rawPreferences;
+ (BOOL)savePreferences:(NSDictionary *)preferences error:(NSError * _Nullable * _Nullable)error;
+ (void)postPreferencesChangedNotification;
+ (NSInteger)defaultLogEntryLimit;
+ (NSInteger)normalizedLogEntryLimit:(id _Nullable)value;

+ (NSDictionary *)globalRulesFromPreferences:(NSDictionary *)preferences;
+ (NSDictionary * _Nullable)rulesForBundleIdentifier:(NSString *)bundleIdentifier
                                     fromPreferences:(NSDictionary *)preferences;
+ (NSDictionary *)normalizedRulesDictionaryFromRawDictionary:(NSDictionary * _Nullable)rawRules;
+ (NSString *)normalizedRulesMode:(id _Nullable)value;
+ (NSDictionary *)normalizedRulesDictionaryFromEnabled:(BOOL)enabled
                                              contains:(NSArray * _Nullable)contains
                                               exclude:(NSArray * _Nullable)exclude
                                                 regex:(NSArray * _Nullable)regex;
+ (BOOL)rulesDictionaryHasConfiguredValues:(NSDictionary * _Nullable)rules;
+ (BOOL)setRulesEnabled:(BOOL)enabled
     forBundleIdentifier:(NSString *)bundleIdentifier
                 error:(NSError * _Nullable * _Nullable)error;
+ (NSUInteger)globalRuleEntryCountFromPreferences:(NSDictionary *)preferences;
+ (NSUInteger)enabledAppRulesCountFromPreferences:(NSDictionary *)preferences;

+ (NSArray<NSDictionary *> *)normalizedRuleEntriesFromArray:(NSArray * _Nullable)rawRules;
+ (NSArray<NSDictionary *> *)normalizedRuleEntriesFromArray:(NSArray * _Nullable)rawRules
                                              defaultScope:(NSString *)defaultScope;
+ (NSArray<NSString *> *)activeRuleTextsFromRuleEntries:(NSArray * _Nullable)rawRules;
+ (NSArray<NSDictionary *> *)activeRuleEntriesFromArray:(NSArray * _Nullable)rawRules
                                          defaultScope:(NSString *)defaultScope;
+ (NSString *)ruleTextFromEntry:(NSDictionary * _Nullable)entry;
+ (BOOL)ruleEntryEnabled:(NSDictionary * _Nullable)entry;
+ (NSString *)ruleScopeFromEntry:(NSDictionary * _Nullable)entry
                    defaultScope:(NSString *)defaultScope;
+ (NSDictionary *)ruleEntryWithText:(NSString *)text
                            enabled:(BOOL)enabled
                          identifier:(NSString * _Nullable)identifier
                               scope:(NSString *)scope;

+ (NSArray<NSString *> *)normalizedRuleLinesFromArray:(NSArray * _Nullable)rawRules;
+ (NSArray<NSString *> *)normalizedRuleLinesFromMultilineString:(NSString * _Nullable)multilineString;
+ (NSString *)multilineStringFromRuleLines:(NSArray<NSString *> * _Nullable)rules;

+ (NSString *)logsFilePath;

@end

NS_ASSUME_NONNULL_END
