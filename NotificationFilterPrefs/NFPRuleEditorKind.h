#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NFPRuleEditorKind) {
    NFPRuleEditorKindContains = 0,
    NFPRuleEditorKindExclude,
    NFPRuleEditorKindRegex
};

NS_ASSUME_NONNULL_END
