#import "WXPLogDetailController.h"
#import "WXPLocalization.h"
#import "../Shared/WXPreferences.h"

@interface WXPLogDetailController ()

@property (nonatomic, copy) NSDictionary *entry;
@property (nonatomic, copy) NSString *displayName;

@end

@implementation WXPLogDetailController

- (instancetype)initWithEntry:(NSDictionary *)entry displayName:(NSString *)displayName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _entry = [entry copy];
        _displayName = [displayName copy];
        self.title = WXPLocalizedString(@"LOG_DETAIL_TITLE");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightRegular];
    textView.textContainerInset = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    textView.text = [self formattedText];
    [self.view addSubview:textView];
}

- (NSString *)formattedText {
    NSString *unknown = WXPLocalizedString(@"COMMON_UNKNOWN");
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[self.entry[WXLogTimestampKey] doubleValue]];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;

    NSString *bundleIdentifier = [self.entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? self.entry[WXLogBundleIdentifierKey] : nil;
    NSString *matchedScope = [self.entry[WXLogMatchedScopeKey] isKindOfClass:[NSString class]] ? self.entry[WXLogMatchedScopeKey] : nil;
    NSString *matchedMode = [self.entry[WXLogMatchedModeKey] isKindOfClass:[NSString class]] ? self.entry[WXLogMatchedModeKey] : nil;
    NSString *matchedPattern = [self.entry[WXLogMatchedPatternKey] isKindOfClass:[NSString class]] ? self.entry[WXLogMatchedPatternKey] : nil;
    NSString *deleteStatus = [self.entry[WXLogDeleteStatusKey] isKindOfClass:[NSString class]] ? self.entry[WXLogDeleteStatusKey] : nil;
    NSString *deleteMethod = [self.entry[WXLogDeleteMethodKey] isKindOfClass:[NSString class]] ? self.entry[WXLogDeleteMethodKey] : nil;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_APP_FORMAT"), self.displayName ?: unknown]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_BUNDLE_ID_FORMAT"), bundleIdentifier ?: unknown]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_TIME_FORMAT"), [formatter stringFromDate:date]]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_SCOPE_FORMAT"), matchedScope.length > 0 ? WXPLocalizedScopeName(matchedScope) : unknown]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_MODE_FORMAT"), matchedMode.length > 0 ? WXPLocalizedMatchModeName(matchedMode) : unknown]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_PATTERN_FORMAT"), matchedPattern ?: unknown]];
    if ([self.entry[WXLogDeleteRequestedKey] boolValue]) {
        [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_DELETE_STATUS_FORMAT"), deleteStatus.length > 0 ? WXPLocalizedDeleteStatusName(deleteStatus) : unknown]];
        [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_DELETE_METHOD_FORMAT"), deleteMethod.length > 0 ? WXPLocalizedDeleteMethodSummary(deleteMethod) : unknown]];
    }
    if ([self.entry[WXLogSectionIDKey] length] > 0) {
        [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_SECTION_ID_FORMAT"), self.entry[WXLogSectionIDKey]]];
    }
    if ([self.entry[WXLogBulletinIDKey] length] > 0) {
        [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_BULLETIN_ID_FORMAT"), self.entry[WXLogBulletinIDKey]]];
    }
    if ([self.entry[WXLogRecordIDKey] length] > 0) {
        [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_RECORD_ID_FORMAT"), self.entry[WXLogRecordIDKey]]];
    }
    if ([self.entry[WXLogPublisherBulletinIDKey] length] > 0) {
        [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_PUBLISHER_BULLETIN_ID_FORMAT"), self.entry[WXLogPublisherBulletinIDKey]]];
    }
    [lines addObject:@""];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_TITLE_FORMAT"), self.entry[WXLogTitleKey] ?: @""]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_SUBTITLE_FORMAT"), self.entry[WXLogSubtitleKey] ?: @""]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_HEADER_FORMAT"), self.entry[WXLogHeaderKey] ?: @""]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_BODY_FORMAT"), self.entry[WXLogBodyKey] ?: @""]];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_MESSAGE_FORMAT"), self.entry[WXLogMessageKey] ?: @""]];
    [lines addObject:@""];
    [lines addObject:WXPLocalizedString(@"LOG_DETAIL_JOINED_TEXT_TITLE")];
    [lines addObject:self.entry[WXLogJoinedTextKey] ?: @""];

    return [lines componentsJoinedByString:@"\n"];
}

@end
