#import "WXPNotificationRuleTokenBuilder.h"
#import "../Shared/WXPreferences.h"

NSString * const WXPNotificationRuleTokenSectionScopeKey = @"scope";
NSString * const WXPNotificationRuleTokenSectionTokensKey = @"tokens";

static NSString * const WXPNotificationRuleTokenSelectionSeparator = @"\n";

@implementation WXPNotificationRuleTokenBuilder

+ (NSArray<NSDictionary *> *)tokenSectionsFromNotificationEntry:(NSDictionary *)entry {
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];

    [self appendSectionWithScope:WXRuleScopeTitle
                        rawTexts:@[entry[WXLogTitleKey] ?: @""]
                      toSections:sections];
    [self appendSectionWithScope:WXRuleScopeSubtitle
                        rawTexts:@[entry[WXLogSubtitleKey] ?: @""]
                      toSections:sections];
    [self appendSectionWithScope:WXRuleScopeMessage
                        rawTexts:@[entry[WXLogHeaderKey] ?: @"", entry[WXLogBodyKey] ?: @"", entry[WXLogMessageKey] ?: @""]
                      toSections:sections];

    return sections;
}

+ (void)appendSectionWithScope:(NSString *)scope
                      rawTexts:(NSArray *)rawTexts
                    toSections:(NSMutableArray<NSDictionary *> *)sections {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];

    for (id rawText in rawTexts) {
        [tokens addObjectsFromArray:[self tokensFromText:rawText]];
    }

    if (tokens.count == 0) {
        return;
    }

    [sections addObject:@{
        WXPNotificationRuleTokenSectionScopeKey: scope,
        WXPNotificationRuleTokenSectionTokensKey: tokens
    }];
}

+ (NSArray<NSString *> *)tokensFromText:(id)rawText {
    if (![rawText isKindOfClass:[NSString class]]) {
        return @[];
    }

    NSString *text = [(NSString *)rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSMutableString *currentWord = [NSMutableString string];
    NSCharacterSet *lettersAndDigits = [NSCharacterSet alphanumericCharacterSet];
    NSCharacterSet *whitespaceAndNewlines = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSCharacterSet *punctuation = [NSCharacterSet punctuationCharacterSet];

    void (^flushCurrentWord)(void) = ^{
        if (currentWord.length > 0) {
            [tokens addObject:[currentWord copy]];
            [currentWord setString:@""];
        }
    };

    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        if (substring.length == 0) {
            return;
        }

        unichar character = [substring characterAtIndex:0];
        if ([whitespaceAndNewlines characterIsMember:character]) {
            flushCurrentWord();
            return;
        }

        if ([punctuation characterIsMember:character]) {
            flushCurrentWord();
            return;
        }

        if ([self characterIsCJK:character]) {
            flushCurrentWord();
            [tokens addObject:substring];
            return;
        }

        if ([lettersAndDigits characterIsMember:character]) {
            [currentWord appendString:substring];
            return;
        }

        flushCurrentWord();
        [tokens addObject:substring];
    }];

    flushCurrentWord();
    return tokens;
}

+ (BOOL)characterIsCJK:(unichar)character {
    return (character >= 0x3400 && character <= 0x4DBF) ||
           (character >= 0x4E00 && character <= 0x9FFF) ||
           (character >= 0xF900 && character <= 0xFAFF);
}

+ (NSString *)selectionKeyForScope:(NSString *)scope
                        tokenIndex:(NSUInteger)tokenIndex
                             token:(NSString *)token {
    return [NSString stringWithFormat:@"%@%@%lu%@%@", scope ?: @"", WXPNotificationRuleTokenSelectionSeparator, (unsigned long)tokenIndex, WXPNotificationRuleTokenSelectionSeparator, token ?: @""];
}

+ (NSArray<NSDictionary *> *)ruleEntriesFromTokenSections:(NSArray<NSDictionary *> *)tokenSections
                                         selectedTokenKeys:(NSSet<NSString *> *)selectedTokenKeys
                                             defaultScope:(NSString *)defaultScope {
    if (selectedTokenKeys.count == 0) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

    for (NSDictionary *section in tokenSections) {
        NSString *scope = [section[WXPNotificationRuleTokenSectionScopeKey] isKindOfClass:[NSString class]] ? section[WXPNotificationRuleTokenSectionScopeKey] : defaultScope;
        NSArray<NSString *> *tokens = [section[WXPNotificationRuleTokenSectionTokensKey] isKindOfClass:[NSArray class]] ? section[WXPNotificationRuleTokenSectionTokensKey] : @[];
        NSMutableArray<NSString *> *selectedTokens = [NSMutableArray array];

        for (NSUInteger tokenIndex = 0; tokenIndex < tokens.count; tokenIndex++) {
            NSString *token = tokens[tokenIndex];
            NSString *selectionKey = [self selectionKeyForScope:scope tokenIndex:tokenIndex token:token];
            if ([selectedTokenKeys containsObject:selectionKey]) {
                [selectedTokens addObject:token];
            }
        }

        NSString *ruleText = [selectedTokens componentsJoinedByString:@""];
        if (ruleText.length == 0) {
            continue;
        }

        [entries addObject:[WXPreferences ruleEntryWithText:ruleText
                                                    enabled:YES
                                                  identifier:nil
                                                       scope:scope ?: defaultScope ?: WXRuleScopeMessage]];
    }

    return entries;
}

@end
