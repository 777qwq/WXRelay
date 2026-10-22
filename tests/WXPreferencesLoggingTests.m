#import <Foundation/Foundation.h>
#import "../Shared/WXPreferences.h"

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXPreferencesLoggingTestFailure" reason:message userInfo:nil];
    }
}

static NSDictionary *WXPrefs(BOOL enabled, NSArray *disabledBundleIdentifiers) {
    return @{
        WXLoggingEnabledKey: @(enabled),
        WXLoggingDisabledBundleIdentifiersKey: disabledBundleIdentifiers ?: @[]
    };
}

int main(void) {
    @autoreleasepool {
        // 归一化:LoggingEnabled 缺省 -> YES
        WXAssert([WXPreferences loggingEnabledForPreferences:@{}] == YES,
                 @"missing LoggingEnabled should default to YES");

        // 归一化:LoggingEnabled 非 BOOL -> YES
        NSDictionary *nonBoolPrefs = @{ WXLoggingEnabledKey: @"nonsense" };
        NSDictionary *normalizedNonBool = [WXPreferences normalizedPreferencesFromDictionary:nonBoolPrefs];
        WXAssert([normalizedNonBool[WXLoggingEnabledKey] boolValue] == YES,
                 @"non-bool LoggingEnabled should normalize to YES");

        // 归一化:禁用列表清洗
        NSDictionary *dirtyList = [WXPreferences normalizedPreferencesFromDictionary:@{
            WXLoggingDisabledBundleIdentifiersKey: @[ @"com.a", @"com.a", @"", @42, @"com.b" ]
        }];
        NSArray *normalizedList = dirtyList[WXLoggingDisabledBundleIdentifiersKey];
        WXAssert(normalizedList.count == 2, @"disabled list should dedupe, drop empty and non-string");
        WXAssert([normalizedList containsObject:@"com.a"] && [normalizedList containsObject:@"com.b"],
                 @"disabled list should keep valid strings");

        // 组合判定矩阵
        WXAssert([WXPreferences loggingEnabledForPreferences:WXPrefs(YES, nil)] == YES,
                 @"global on, no disabled -> log");
        WXAssert([WXPreferences loggingEnabledForPreferences:WXPrefs(NO, nil)] == NO,
                 @"global off -> no log");
        WXAssert([WXPreferences isLoggingDisabledForBundleIdentifier:@"com.a" preferences:WXPrefs(YES, @[ @"com.a" ])] == YES,
                 @"bundle id in disabled list -> disabled");
        WXAssert([WXPreferences isLoggingDisabledForBundleIdentifier:@"com.b" preferences:WXPrefs(YES, @[ @"com.a" ])] == NO,
                 @"bundle id not in disabled list -> not disabled");
        WXAssert([WXPreferences loggingEnabledForBundleIdentifier:@"com.a" preferences:WXPrefs(YES, @[ @"com.a" ])] == NO,
                 @"global on but app disabled -> no log");
        WXAssert([WXPreferences loggingEnabledForBundleIdentifier:@"com.b" preferences:WXPrefs(YES, @[ @"com.a" ])] == YES,
                 @"global on and app enabled -> log");
        WXAssert([WXPreferences loggingEnabledForBundleIdentifier:@"com.a" preferences:WXPrefs(NO, @[ @"com.a" ])] == NO,
                 @"global off wins even if app not disabled");
    }
    return 0;
}
