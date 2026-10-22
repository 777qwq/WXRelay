#import <Foundation/Foundation.h>
#import "../Shared/WXPreferences.h"

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXPreferencesHomeSummaryTestFailure" reason:message userInfo:nil];
    }
}

int main(void) {
    @autoreleasepool {
        WXAssert([WXPreferences globalRuleEntryCountFromPreferences:@{}] == 0,
                 @"empty preferences should have zero global rules");
        WXAssert([WXPreferences enabledAppRulesCountFromPreferences:@{}] == 0,
                 @"empty preferences should have zero enabled apps");

        NSDictionary *disabledEntry = [WXPreferences ruleEntryWithText:@"ad"
                                                               enabled:NO
                                                            identifier:@"disabled-1"
                                                                 scope:WXRuleScopeAll];
        NSDictionary *globalPrefs = @{
            WXGlobalRulesEnabledKey: @YES,
            WXGlobalContainsKey: @[ @"promo" ],
            WXGlobalExcludeKey: @[ disabledEntry ],
            WXGlobalRegexKey: @[ @"code\\d+" ]
        };
        WXAssert([WXPreferences globalRuleEntryCountFromPreferences:globalPrefs] == 3,
                 @"global count should sum contains/exclude/regex including disabled entries");

        NSDictionary *closedGlobal = @{
            WXGlobalRulesEnabledKey: @NO,
            WXGlobalContainsKey: @[ @"promo", @"sale" ]
        };
        WXAssert([WXPreferences globalRuleEntryCountFromPreferences:closedGlobal] == 2,
                 @"global count is independent of the enabled switch");

        NSDictionary *appPrefs = @{
            WXAppRulesKey: @{
                @"com.a": @{
                    WXRulesEnabledKey: @YES
                },
                @"com.b": @{
                    WXRulesEnabledKey: @NO,
                    WXRulesContainsKey: @[ @"otp" ]
                },
                @"com.c": @{
                    WXRulesEnabledKey: @YES,
                    WXRulesContainsKey: @[ @"ad" ]
                }
            }
        };
        WXAssert([WXPreferences enabledAppRulesCountFromPreferences:appPrefs] == 2,
                 @"enabled app count should include apps whose switch is on, even without rules");
    }
    return 0;
}
