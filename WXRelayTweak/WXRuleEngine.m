#import "WXRuleEngine.h"
#import "WXNotificationRecord.h"
#import "../Shared/WXPreferences.h"

@implementation WXMatchResult
@end

@implementation WXRuleEngine

+ (WXMatchResult *)_allowResult {
    WXMatchResult *result = [[WXMatchResult alloc] init];
    result.shouldBlock = NO;
    return result;
}

+ (WXMatchResult *)_resultWithShouldBlock:(BOOL)shouldBlock
                                    scope:(NSString *)scope
                                     mode:(NSString *)mode
                                  pattern:(NSString *)pattern {
    WXMatchResult *result = [[WXMatchResult alloc] init];
    result.shouldBlock = shouldBlock;
    result.matchedScope = scope;
    result.matchedMode = mode;
    result.matchedPattern = pattern;
    return result;
}

+ (NSString *)_scopeNameForBundleIdentifier:(NSString *)bundleIdentifier {
    return [NSString stringWithFormat:@"app:%@", bundleIdentifier];
}

+ (NSString * _Nullable)_firstMatchingContainsRuleInRules:(NSArray<NSString *> *)rules text:(NSString *)text {
    for (NSString *rule in rules) {
        if ([text rangeOfString:rule options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return rule;
        }
    }
    return nil;
}

+ (NSString * _Nullable)_firstMatchingRegexRuleInRules:(NSArray<NSString *> *)rules text:(NSString *)text {
    for (NSString *rule in rules) {
        NSError *error = nil;
        NSRegularExpression *regularExpression = [NSRegularExpression regularExpressionWithPattern:rule
                                                                                           options:NSRegularExpressionCaseInsensitive
                                                                                             error:&error];
        if (error || !regularExpression) {
            continue;
        }

        if ([regularExpression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) {
            return rule;
        }
    }
    return nil;
}

+ (NSString *)_textForScope:(NSString *)scope record:(WXNotificationRecord *)record defaultScope:(NSString *)defaultScope {
    NSString *resolvedScope = [WXPreferences ruleScopeFromEntry:@{ WXRuleEntryScopeKey: scope ?: @"" }
                                                  defaultScope:defaultScope];
    if ([resolvedScope isEqualToString:WXRuleScopeTitle]) {
        return record.title ?: @"";
    }
    if ([resolvedScope isEqualToString:WXRuleScopeSubtitle]) {
        return record.subtitle ?: @"";
    }
    if ([resolvedScope isEqualToString:WXRuleScopeMessage]) {
        return record.messageText ?: @"";
    }
    return record.joinedText ?: @"";
}

+ (NSString * _Nullable)_firstMatchingRuleEntryInRules:(NSArray *)rawRules
                                           defaultScope:(NSString *)defaultScope
                                                  regex:(BOOL)regex
                                                 record:(WXNotificationRecord *)record {
    for (NSDictionary *ruleEntry in [WXPreferences activeRuleEntriesFromArray:rawRules defaultScope:defaultScope]) {
        NSString *ruleText = [WXPreferences ruleTextFromEntry:ruleEntry];
        NSString *matchText = [self _textForScope:[WXPreferences ruleScopeFromEntry:ruleEntry defaultScope:defaultScope]
                                           record:record
                                     defaultScope:defaultScope];
        NSArray *singleRule = ruleText.length > 0 ? @[ruleText] : @[];
        NSString *matchedRule = regex ? [self _firstMatchingRegexRuleInRules:singleRule text:matchText] : [self _firstMatchingContainsRuleInRules:singleRule text:matchText];
        if (matchedRule.length > 0) {
            return matchedRule;
        }
    }
    return nil;
}

+ (WXMatchResult * _Nullable)_evaluateBlacklistRules:(NSDictionary *)rules
                                           scopeName:(NSString *)scopeName
                                              record:(WXNotificationRecord *)record {
    NSString *matchedExclude = [self _firstMatchingRuleEntryInRules:rules[WXRulesExcludeKey]
                                                       defaultScope:WXRuleScopeAll
                                                              regex:NO
                                                             record:record];
    if (matchedExclude.length > 0) {
        return [self _resultWithShouldBlock:NO
                                      scope:scopeName
                                       mode:WXMatchModeExclude
                                    pattern:matchedExclude];
    }

    NSString *matchedContains = [self _firstMatchingRuleEntryInRules:rules[WXRulesContainsKey]
                                                        defaultScope:WXRuleScopeMessage
                                                               regex:NO
                                                              record:record];
    if (matchedContains.length > 0) {
        return [self _resultWithShouldBlock:YES
                                      scope:scopeName
                                       mode:WXMatchModeContains
                                    pattern:matchedContains];
    }

    NSString *matchedRegex = [self _firstMatchingRuleEntryInRules:rules[WXRulesRegexKey]
                                                     defaultScope:WXRuleScopeAll
                                                            regex:YES
                                                           record:record];
    if (matchedRegex.length > 0) {
        return [self _resultWithShouldBlock:YES
                                      scope:scopeName
                                       mode:WXMatchModeRegex
                                    pattern:matchedRegex];
    }

    return nil;
}

+ (WXMatchResult * _Nullable)_evaluateAppRules:(NSDictionary *)rules
                                     scopeName:(NSString *)scopeName
                                        record:(WXNotificationRecord *)record {
    NSString *mode = [WXPreferences normalizedRulesMode:rules[WXRulesModeKey]];
    BOOL whitelist = [mode isEqualToString:WXRulesModeWhitelist];

    NSString *matchedExclude = [self _firstMatchingRuleEntryInRules:rules[WXRulesExcludeKey]
                                                       defaultScope:WXRuleScopeAll
                                                              regex:NO
                                                             record:record];
    if (matchedExclude.length > 0) {
        return [self _resultWithShouldBlock:whitelist
                                      scope:scopeName
                                       mode:WXMatchModeExclude
                                    pattern:matchedExclude];
    }

    NSString *matchedContains = [self _firstMatchingRuleEntryInRules:rules[WXRulesContainsKey]
                                                        defaultScope:WXRuleScopeMessage
                                                               regex:NO
                                                              record:record];
    if (matchedContains.length > 0) {
        return [self _resultWithShouldBlock:!whitelist
                                      scope:scopeName
                                       mode:WXMatchModeContains
                                    pattern:matchedContains];
    }

    NSString *matchedRegex = [self _firstMatchingRuleEntryInRules:rules[WXRulesRegexKey]
                                                     defaultScope:WXRuleScopeAll
                                                            regex:YES
                                                           record:record];
    if (matchedRegex.length > 0) {
        return [self _resultWithShouldBlock:!whitelist
                                      scope:scopeName
                                       mode:WXMatchModeRegex
                                    pattern:matchedRegex];
    }

    if (whitelist) {
        return [self _resultWithShouldBlock:YES
                                      scope:scopeName
                                       mode:WXMatchModeWhitelistDefault
                                    pattern:nil];
    }

    return nil;
}

+ (WXMatchResult *)evaluateRecord:(WXNotificationRecord *)record
                      preferences:(NSDictionary *)preferences {
    if (![preferences[WXEnabledKey] boolValue]) {
        return [self _allowResult];
    }

    NSString *joinedText = record.joinedText ?: @"";
    NSString *messageText = record.messageText ?: @"";
    if (joinedText.length == 0 && messageText.length == 0) {
        return [self _allowResult];
    }

    NSDictionary *globalRules = [WXPreferences globalRulesFromPreferences:preferences];
    if ([globalRules[WXRulesEnabledKey] boolValue]) {
        WXMatchResult *globalResult = [self _evaluateBlacklistRules:globalRules
                                                          scopeName:WXMatchScopeGlobal
                                                             record:record];
        if (globalResult) {
            return globalResult;
        }
    }

    if (record.bundleIdentifier.length > 0) {
        NSDictionary *appRules = [WXPreferences rulesForBundleIdentifier:record.bundleIdentifier
                                                         fromPreferences:preferences];
        if ([appRules[WXRulesEnabledKey] boolValue]) {
            WXMatchResult *appResult = [self _evaluateAppRules:appRules
                                                     scopeName:[self _scopeNameForBundleIdentifier:record.bundleIdentifier]
                                                        record:record];
            if (appResult) {
                return appResult;
            }
        }
    }

    return [self _allowResult];
}

@end
