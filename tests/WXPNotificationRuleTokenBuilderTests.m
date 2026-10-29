#import <Foundation/Foundation.h>
#import "../WXRelayPrefs/WXPNotificationRuleTokenBuilder.h"

NSString * const WXRuleEntryIdentifierKey = @"id";
NSString * const WXRuleEntryTextKey = @"text";
NSString * const WXRuleEntryEnabledKey = @"enabled";
NSString * const WXRuleEntryScopeKey = @"scope";
NSString * const WXRuleScopeMessage = @"message";
NSString * const WXRuleScopeTitle = @"title";
NSString * const WXRuleScopeSubtitle = @"subtitle";
NSString * const WXRuleScopeAll = @"all";
NSString * const WXLogTitleKey = @"title";
NSString * const WXLogSubtitleKey = @"subtitle";
NSString * const WXLogBodyKey = @"body";
NSString * const WXLogHeaderKey = @"header";
NSString * const WXLogMessageKey = @"message";

@interface WXPreferences : NSObject
+ (NSDictionary *)ruleEntryWithText:(NSString *)text
                            enabled:(BOOL)enabled
                          identifier:(NSString *)identifier
                               scope:(NSString *)scope;
@end

@implementation WXPreferences

+ (NSDictionary *)ruleEntryWithText:(NSString *)text
                            enabled:(BOOL)enabled
                          identifier:(NSString *)identifier
                               scope:(NSString *)scope {
    return @{
        WXRuleEntryIdentifierKey: identifier.length > 0 ? identifier : @"test-id",
        WXRuleEntryTextKey: text ?: @"",
        WXRuleEntryEnabledKey: @(enabled),
        WXRuleEntryScopeKey: scope ?: WXRuleScopeAll
    };
}

@end

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXPNotificationRuleTokenBuilderTestFailure" reason:message userInfo:nil];
    }
}

static void WXAssertArrayEquals(NSArray *actual, NSArray *expected, NSString *message) {
    WXAssert([actual isEqualToArray:expected], [NSString stringWithFormat:@"%@ actual=%@ expected=%@", message, actual, expected]);
}

int main(void) {
    @autoreleasepool {
        NSArray<NSString *> *mixedTokens = [WXPNotificationRuleTokenBuilder tokensFromText:@"限时sale 2026已到"];
        WXAssertArrayEquals(mixedTokens, (@[@"限", @"时", @"sale", @"2026", @"已", @"到"]), @"mixed Chinese and English tokens should keep every Chinese character and every English word");

        NSArray<NSString *> *duplicateTokens = [WXPNotificationRuleTokenBuilder tokensFromText:@"哈哈OK OK"];
        WXAssertArrayEquals(duplicateTokens, (@[@"哈", @"哈", @"OK", @"OK"]), @"duplicate characters and words should remain selectable");

        NSDictionary *entry = @{
            WXLogTitleKey: @"限时sale",
            WXLogBodyKey: @"马上到"
        };
        NSArray<NSDictionary *> *sections = [WXPNotificationRuleTokenBuilder tokenSectionsFromNotificationEntry:entry];
        WXAssert(sections.count == 2, @"title and message sections should both be built");

        NSString *titleScope = sections[0][WXPNotificationRuleTokenSectionScopeKey];
        NSArray<NSString *> *titleTokens = sections[0][WXPNotificationRuleTokenSectionTokensKey];
        NSString *messageScope = sections[1][WXPNotificationRuleTokenSectionScopeKey];
        NSArray<NSString *> *messageTokens = sections[1][WXPNotificationRuleTokenSectionTokensKey];
        WXAssertArrayEquals(titleTokens, (@[@"限", @"时", @"sale"]), @"title tokens should stay in source order");
        WXAssertArrayEquals(messageTokens, (@[@"马", @"上", @"到"]), @"message tokens should stay in source order");

        NSSet<NSString *> *sameScopeSelection = [NSSet setWithObjects:
            [WXPNotificationRuleTokenBuilder selectionKeyForScope:messageScope tokenIndex:0 token:messageTokens[0]],
            [WXPNotificationRuleTokenBuilder selectionKeyForScope:messageScope tokenIndex:2 token:messageTokens[2]],
            nil];
        NSArray<NSDictionary *> *sameScopeEntries = [WXPNotificationRuleTokenBuilder ruleEntriesFromTokenSections:sections
                                                                                                  selectedTokenKeys:sameScopeSelection
                                                                                                      defaultScope:WXRuleScopeMessage];
        WXAssert(sameScopeEntries.count == 1, @"one scan save should create exactly one rule for same-scope selection");
        WXAssert([sameScopeEntries[0][WXRuleEntryTextKey] isEqualToString:@"马到"], @"non-contiguous characters should be connected inside one rule");
        WXAssert([sameScopeEntries[0][WXRuleEntryScopeKey] isEqualToString:WXRuleScopeMessage], @"same-scope selection should keep that scope");

        NSSet<NSString *> *mixedScopeSelection = [NSSet setWithObjects:
            [WXPNotificationRuleTokenBuilder selectionKeyForScope:titleScope tokenIndex:0 token:titleTokens[0]],
            [WXPNotificationRuleTokenBuilder selectionKeyForScope:titleScope tokenIndex:1 token:titleTokens[1]],
            [WXPNotificationRuleTokenBuilder selectionKeyForScope:messageScope tokenIndex:2 token:messageTokens[2]],
            nil];
        NSArray<NSDictionary *> *mixedScopeEntries = [WXPNotificationRuleTokenBuilder ruleEntriesFromTokenSections:sections
                                                                                                 selectedTokenKeys:mixedScopeSelection
                                                                                                      defaultScope:WXRuleScopeMessage];
        WXAssert(mixedScopeEntries.count == 2, @"cross-scope selection should create one rule per selected section");
        WXAssert([mixedScopeEntries[0][WXRuleEntryTextKey] isEqualToString:@"限时"], @"title selected pieces should be connected inside the title rule");
        WXAssert([mixedScopeEntries[0][WXRuleEntryScopeKey] isEqualToString:WXRuleScopeTitle], @"title selection should keep title scope");
        WXAssert([mixedScopeEntries[1][WXRuleEntryTextKey] isEqualToString:@"到"], @"message selected pieces should be connected inside the message rule");
        WXAssert([mixedScopeEntries[1][WXRuleEntryScopeKey] isEqualToString:WXRuleScopeMessage], @"message selection should keep message scope");
    }
    return 0;
}
