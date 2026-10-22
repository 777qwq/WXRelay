#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const WXPNotificationRuleTokenSectionScopeKey;
extern NSString * const WXPNotificationRuleTokenSectionTokensKey;

@interface WXPNotificationRuleTokenBuilder : NSObject

+ (NSArray<NSDictionary *> *)tokenSectionsFromNotificationEntry:(NSDictionary *)entry;
+ (NSArray<NSString *> *)tokensFromText:(id)rawText;
+ (NSString *)selectionKeyForScope:(NSString * _Nullable)scope
                        tokenIndex:(NSUInteger)tokenIndex
                             token:(NSString * _Nullable)token;
+ (NSArray<NSDictionary *> *)ruleEntriesFromTokenSections:(NSArray<NSDictionary *> *)tokenSections
                                         selectedTokenKeys:(NSSet<NSString *> *)selectedTokenKeys
                                             defaultScope:(NSString *)defaultScope;

@end

NS_ASSUME_NONNULL_END
