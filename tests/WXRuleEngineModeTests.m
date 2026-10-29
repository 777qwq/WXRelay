#import <Foundation/Foundation.h>
#import "../WXRelayTweak/WXRuleEngine.h"
#import "../WXRelayTweak/WXNotificationRecord.h"
#import "../Shared/WXPreferences.h"

static NSDictionary *WXRule(NSString *text, NSString *scope) {
    return [WXPreferences ruleEntryWithText:text enabled:YES identifier:nil scope:scope];
}

static WXNotificationRecord *WXRecord(NSString *body) {
    WXNotificationRecord *record = [[WXNotificationRecord alloc] init];
    record.bundleIdentifier = @"com.example.chat";
    record.body = body;
    record.messageText = body ?: @"";
    record.joinedText = body ?: @"";
    record.timestamp = [NSDate date];
    return record;
}

static NSDictionary *WXPreferencesWithAppRules(NSDictionary *appRules) {
    return [WXPreferences normalizedPreferencesFromDictionary:@{
        WXEnabledKey: @YES,
        WXGlobalRulesEnabledKey: @NO,
        WXAppRulesKey: @{ @"com.example.chat": appRules }
    }];
}

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXRuleEngineModeTestFailure" reason:message userInfo:nil];
    }
}

static void WXAssertMode(WXMatchResult *result, BOOL shouldBlock, NSString *mode, NSString *message) {
    WXAssert(result.shouldBlock == shouldBlock, [message stringByAppendingFormat:@" shouldBlock=%d", result.shouldBlock]);
    if (mode.length > 0) {
        WXAssert([result.matchedMode isEqualToString:mode], [message stringByAppendingFormat:@" mode=%@ expected=%@", result.matchedMode, mode]);
    }
}

int main(void) {
    @autoreleasepool {
        NSDictionary *blacklistRules = [WXPreferences normalizedRulesDictionaryFromRawDictionary:@{
            WXRulesEnabledKey: @YES,
            WXRulesModeKey: WXRulesModeBlacklist,
            WXRulesContainsKey: @[ WXRule(@"promo", WXRuleScopeMessage) ],
            WXRulesExcludeKey: @[ WXRule(@"otp", WXRuleScopeAll) ],
            WXRulesRegexKey: @[ WXRule(@"sale[0-9]+", WXRuleScopeAll) ]
        }];
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"promo today") preferences:WXPreferencesWithAppRules(blacklistRules)], YES, WXMatchModeContains, @"blacklist contains should block");
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"otp promo") preferences:WXPreferencesWithAppRules(blacklistRules)], NO, WXMatchModeExclude, @"blacklist exclude should allow before contains");
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"sale2026") preferences:WXPreferencesWithAppRules(blacklistRules)], YES, WXMatchModeRegex, @"blacklist regex should block");
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"plain message") preferences:WXPreferencesWithAppRules(blacklistRules)], NO, nil, @"blacklist no match should allow");

        NSDictionary *whitelistRules = [WXPreferences normalizedRulesDictionaryFromRawDictionary:@{
            WXRulesEnabledKey: @YES,
            WXRulesModeKey: WXRulesModeWhitelist,
            WXRulesContainsKey: @[ WXRule(@"otp", WXRuleScopeMessage) ],
            WXRulesExcludeKey: @[ WXRule(@"ad", WXRuleScopeAll) ],
            WXRulesRegexKey: @[ WXRule(@"code[0-9]+", WXRuleScopeAll) ]
        }];
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"otp 123") preferences:WXPreferencesWithAppRules(whitelistRules)], NO, WXMatchModeContains, @"whitelist contains should allow");
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"code2026") preferences:WXPreferencesWithAppRules(whitelistRules)], NO, WXMatchModeRegex, @"whitelist regex should allow");
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"ad otp") preferences:WXPreferencesWithAppRules(whitelistRules)], YES, WXMatchModeExclude, @"whitelist exclude should block before contains");
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"plain message") preferences:WXPreferencesWithAppRules(whitelistRules)], YES, WXMatchModeWhitelistDefault, @"whitelist no match should block by default");

        NSDictionary *globalFirstPreferences = [WXPreferences normalizedPreferencesFromDictionary:@{
            WXEnabledKey: @YES,
            WXGlobalRulesEnabledKey: @YES,
            WXGlobalContainsKey: @[ WXRule(@"global-block", WXRuleScopeAll) ],
            WXAppRulesKey: @{ @"com.example.chat": whitelistRules }
        }];
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"global-block otp") preferences:globalFirstPreferences], YES, WXMatchModeContains, @"global block should run before app whitelist allow");

        NSDictionary *disabledWhitelist = [WXPreferences normalizedRulesDictionaryFromRawDictionary:@{
            WXRulesEnabledKey: @NO,
            WXRulesModeKey: WXRulesModeWhitelist
        }];
        WXAssertMode([WXRuleEngine evaluateRecord:WXRecord(@"plain message") preferences:WXPreferencesWithAppRules(disabledWhitelist)], NO, nil, @"disabled app whitelist should not block");
    }
    return 0;
}
