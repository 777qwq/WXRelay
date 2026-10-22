#import <Foundation/Foundation.h>
#import "../Shared/WXPreferences.h"

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXPreferencesRuleModeTestFailure" reason:message userInfo:nil];
    }
}

static void WXAssertStringEquals(NSString *actual, NSString *expected, NSString *message) {
    WXAssert([actual isEqualToString:expected], [NSString stringWithFormat:@"%@ actual=%@ expected=%@", message, actual, expected]);
}

int main(void) {
    @autoreleasepool {
        NSDictionary *missingMode = [WXPreferences normalizedRulesDictionaryFromRawDictionary:@{
            WXRulesEnabledKey: @YES,
            WXRulesContainsKey: @[ @"promo" ]
        }];
        WXAssertStringEquals(missingMode[WXRulesModeKey], WXRulesModeBlacklist, @"missing mode should default to blacklist");
        WXAssert([missingMode[WXRulesEnabledKey] boolValue], @"enabled flag should be preserved");

        NSDictionary *whitelistMode = [WXPreferences normalizedRulesDictionaryFromRawDictionary:@{
            WXRulesEnabledKey: @YES,
            WXRulesModeKey: WXRulesModeWhitelist,
            WXRulesContainsKey: @[ @"otp" ],
            WXRulesExcludeKey: @[ @"ad" ],
            WXRulesRegexKey: @[ @"code\\d+" ]
        }];
        WXAssertStringEquals(whitelistMode[WXRulesModeKey], WXRulesModeWhitelist, @"valid whitelist mode should be preserved");
        WXAssert([whitelistMode[WXRulesContainsKey] count] == 1, @"contains entries should survive normalization");
        WXAssert([whitelistMode[WXRulesExcludeKey] count] == 1, @"exclude entries should survive normalization");
        WXAssert([whitelistMode[WXRulesRegexKey] count] == 1, @"regex entries should survive normalization");

        NSDictionary *invalidMode = [WXPreferences normalizedRulesDictionaryFromRawDictionary:@{
            WXRulesModeKey: @"allowlist"
        }];
        WXAssertStringEquals(invalidMode[WXRulesModeKey], WXRulesModeBlacklist, @"invalid string mode should normalize to blacklist");

        NSDictionary *nonStringMode = [WXPreferences normalizedRulesDictionaryFromRawDictionary:@{
            WXRulesModeKey: @42
        }];
        WXAssertStringEquals(nonStringMode[WXRulesModeKey], WXRulesModeBlacklist, @"non-string mode should normalize to blacklist");

        NSDictionary *defaultDictionary = [WXPreferences normalizedRulesDictionaryFromEnabled:YES contains:nil exclude:nil regex:nil];
        WXAssertStringEquals(defaultDictionary[WXRulesModeKey], WXRulesModeBlacklist, @"legacy constructor should create blacklist dictionaries");
    }
    return 0;
}
