#import <Foundation/Foundation.h>

@class WXNotificationRecord;

NS_ASSUME_NONNULL_BEGIN

@interface WXMatchResult : NSObject

@property (nonatomic, assign) BOOL shouldBlock;
@property (nonatomic, copy, nullable) NSString *matchedScope;
@property (nonatomic, copy, nullable) NSString *matchedMode;
@property (nonatomic, copy, nullable) NSString *matchedPattern;

@end

@interface WXRuleEngine : NSObject

+ (WXMatchResult *)evaluateRecord:(WXNotificationRecord *)record
                      preferences:(NSDictionary *)preferences;

@end

NS_ASSUME_NONNULL_END
