#import "WXNotificationRecord.h"
#import "../Shared/WXPreferences.h"
#import <objc/message.h>

static id WXCallObject(id obj, SEL selector) {
    if (!obj || !selector || ![obj respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(obj, selector);
}

static NSString *WXNormalizedString(id value) {
    if (!value) {
        return nil;
    }

    NSString *stringValue = nil;
    if ([value isKindOfClass:[NSString class]]) {
        stringValue = value;
    } else if ([value respondsToSelector:@selector(stringValue)]) {
        id response = ((id (*)(id, SEL))objc_msgSend)(value, @selector(stringValue));
        if ([response isKindOfClass:[NSString class]]) {
            stringValue = response;
        }
    }

    return [stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *WXValueForSelectorName(id primaryObject, id fallbackObject, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    NSString *value = WXNormalizedString(WXCallObject(primaryObject, selector));
    if (value.length > 0) {
        return value;
    }

    return WXNormalizedString(WXCallObject(fallbackObject, selector));
}

static NSString *WXSectionIdentifier(id obj) {
    NSString *sectionIdentifier = WXValueForSelectorName(obj, nil, @"sectionIdentifier");
    if (sectionIdentifier.length > 0) {
        return sectionIdentifier;
    }

    return WXValueForSelectorName(obj, nil, @"sectionID");
}

static NSString *WXJoinedText(NSArray<NSString *> *values) {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    NSMutableSet<NSString *> *seenValues = [NSMutableSet set];

    for (NSString *value in values) {
        if (value.length == 0 || [seenValues containsObject:value]) {
            continue;
        }

        [seenValues addObject:value];
        [components addObject:value];
    }

    return [components componentsJoinedByString:@"\n"];
}

static NSDate *WXDateForSelectorName(id primaryObject, id fallbackObject, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    id value = WXCallObject(primaryObject, selector);
    if ([value isKindOfClass:[NSDate class]]) {
        return value;
    }

    value = WXCallObject(fallbackObject, selector);
    if ([value isKindOfClass:[NSDate class]]) {
        return value;
    }
    return nil;
}

@implementation WXNotificationRecord

+ (instancetype)recordFromNotificationRequest:(id)request {
    id content = WXCallObject(request, @selector(content));

    WXNotificationRecord *record = [[self alloc] init];
    record.bundleIdentifier = WXSectionIdentifier(request);
    record.sectionID = WXValueForSelectorName(request, nil, @"sectionID");
    if (record.sectionID.length == 0) {
        record.sectionID = WXValueForSelectorName(request, nil, @"section");
    }
    record.bulletinID = WXValueForSelectorName(request, nil, @"bulletinID");
    record.recordID = WXValueForSelectorName(request, nil, @"recordID");
    record.publisherBulletinID = WXValueForSelectorName(request, nil, @"publisherBulletinID");
    record.title = WXValueForSelectorName(content, request, @"title");
    record.subtitle = WXValueForSelectorName(content, request, @"subtitle");
    record.header = WXValueForSelectorName(content, request, @"header");
    record.body = WXValueForSelectorName(content, request, @"body");
    record.message = WXValueForSelectorName(content, request, @"message");
    record.messageText = WXJoinedText(@[
        record.body ?: @"",
        record.message ?: @""
    ]);
    record.joinedText = WXJoinedText(@[
        record.title ?: @"",
        record.subtitle ?: @"",
        record.header ?: @"",
        record.body ?: @"",
        record.message ?: @""
    ]);
    record.timestamp = WXDateForSelectorName(request, content, @"date") ?:
        WXDateForSelectorName(request, content, @"publicationDate") ?:
        WXDateForSelectorName(request, content, @"lastInterruptDate") ?:
        [NSDate date];
    return record;
}

+ (instancetype)recordFromBulletin:(id)bulletin {
    WXNotificationRecord *record = [[self alloc] init];
    record.bundleIdentifier = WXSectionIdentifier(bulletin);
    record.sectionID = WXValueForSelectorName(bulletin, nil, @"sectionID");
    if (record.sectionID.length == 0) {
        record.sectionID = WXValueForSelectorName(bulletin, nil, @"section");
    }
    record.bulletinID = WXValueForSelectorName(bulletin, nil, @"bulletinID");
    record.recordID = WXValueForSelectorName(bulletin, nil, @"recordID");
    record.publisherBulletinID = WXValueForSelectorName(bulletin, nil, @"publisherBulletinID");
    record.title = WXValueForSelectorName(bulletin, nil, @"title");
    record.subtitle = WXValueForSelectorName(bulletin, nil, @"subtitle");
    record.header = WXValueForSelectorName(bulletin, nil, @"header");
    record.body = WXValueForSelectorName(bulletin, nil, @"body");
    record.message = WXValueForSelectorName(bulletin, nil, @"message");
    record.messageText = WXJoinedText(@[
        record.body ?: @"",
        record.message ?: @""
    ]);
    record.joinedText = WXJoinedText(@[
        record.title ?: @"",
        record.subtitle ?: @"",
        record.header ?: @"",
        record.body ?: @"",
        record.message ?: @""
    ]);
    record.timestamp = WXDateForSelectorName(bulletin, nil, @"date") ?:
        WXDateForSelectorName(bulletin, nil, @"publicationDate") ?:
        WXDateForSelectorName(bulletin, nil, @"lastInterruptDate") ?:
        [NSDate date];
    return record;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    dictionary[WXLogTimestampKey] = @([self.timestamp timeIntervalSince1970]);
    dictionary[WXLogJoinedTextKey] = self.joinedText ?: @"";

    if (self.bundleIdentifier.length > 0) {
        dictionary[WXLogBundleIdentifierKey] = self.bundleIdentifier;
    }
    if (self.title.length > 0) {
        dictionary[WXLogTitleKey] = self.title;
    }
    if (self.subtitle.length > 0) {
        dictionary[WXLogSubtitleKey] = self.subtitle;
    }
    if (self.body.length > 0) {
        dictionary[WXLogBodyKey] = self.body;
    }
    if (self.header.length > 0) {
        dictionary[WXLogHeaderKey] = self.header;
    }
    if (self.message.length > 0) {
        dictionary[WXLogMessageKey] = self.message;
    }
    if (self.sectionID.length > 0) {
        dictionary[WXLogSectionIDKey] = self.sectionID;
    }
    if (self.bulletinID.length > 0) {
        dictionary[WXLogBulletinIDKey] = self.bulletinID;
    }
    if (self.recordID.length > 0) {
        dictionary[WXLogRecordIDKey] = self.recordID;
    }
    if (self.publisherBulletinID.length > 0) {
        dictionary[WXLogPublisherBulletinIDKey] = self.publisherBulletinID;
    }

    return dictionary;
}

@end
