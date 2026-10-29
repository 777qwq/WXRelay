#import "WXPNotificationRuleScannerController.h"
#import "../Shared/WXPreferences.h"
#import "../Shared/WXNotificationHistoryBridge.h"
#import "WXPAppInfoProvider.h"
#import "WXPNotificationHistoryClient.h"
#import "WXPLocalization.h"
#import "WXPNotificationRuleTokenPickerController.h"

@interface WXPNotificationRuleScannerController ()

@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *ruleMode;
@property (nonatomic, assign) WXPRuleEditorKind initialRuleKind;
@property (nonatomic, weak, nullable) UIViewController *returnViewController;
@property (nonatomic, assign) WXPNotificationRuleTokenReturnMode returnMode;
@property (nonatomic, copy) WXPNotificationRuleScannerCommitHandler commitHandler;
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy, nullable) NSString *historySource;
@property (nonatomic, copy, nullable) NSString *refreshRequestIdentifier;
@property (nonatomic, strong, nullable) NSTimer *refreshTimeoutTimer;
@property (nonatomic, assign) BOOL waitingForRefresh;

@end

@implementation WXPNotificationRuleScannerController


- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] initWithFrame:CGRectZero];
}
static NSTimeInterval const WXPNotificationRuleScannerRefreshTimeout = 1.5;

static void WXPNotificationHistoryRefreshCompletedCallback(CFNotificationCenterRef center,
                                                           void *observer,
                                                           CFStringRef name,
                                                           const void *object,
                                                           CFDictionaryRef userInfo) {
    WXPNotificationRuleScannerController *controller = (__bridge WXPNotificationRuleScannerController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller handleRefreshCompletedNotification];
    });
}

static NSString *WXPScannerPreviewText(NSDictionary *entry) {
    NSArray<NSString *> *candidates = @[
        [entry[WXLogMessageKey] isKindOfClass:[NSString class]] ? entry[WXLogMessageKey] : @"",
        [entry[WXLogBodyKey] isKindOfClass:[NSString class]] ? entry[WXLogBodyKey] : @"",
        [entry[WXLogTitleKey] isKindOfClass:[NSString class]] ? entry[WXLogTitleKey] : @"",
        [entry[WXLogSubtitleKey] isKindOfClass:[NSString class]] ? entry[WXLogSubtitleKey] : @"",
        [entry[WXLogHeaderKey] isKindOfClass:[NSString class]] ? entry[WXLogHeaderKey] : @"",
        [entry[WXLogJoinedTextKey] isKindOfClass:[NSString class]] ? entry[WXLogJoinedTextKey] : @""
    ];

    for (NSString *candidate in candidates) {
        NSString *trimmed = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }

        NSMutableString *preview = [[trimmed stringByReplacingOccurrencesOfString:@"\n" withString:@"  "] mutableCopy];
        if (preview.length > 100) {
            return [[preview substringToIndex:100] stringByAppendingString:@"…"];
        }
        return preview;
    }

    return @"";
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                             displayName:(NSString *)displayName
                         initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString *)ruleMode
                    returnViewController:(UIViewController *)returnViewController
                           commitHandler:(WXPNotificationRuleScannerCommitHandler)commitHandler {
    return [self initWithBundleIdentifier:bundleIdentifier
                              displayName:displayName
                          initialRuleKind:initialRuleKind
                                  ruleMode:ruleMode
                     returnViewController:returnViewController
                               returnMode:WXPNotificationRuleTokenReturnModeRulesList
                            commitHandler:commitHandler];
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                             displayName:(NSString *)displayName
                         initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString *)ruleMode
                    returnViewController:(UIViewController *)returnViewController
                              returnMode:(WXPNotificationRuleTokenReturnMode)returnMode
                           commitHandler:(WXPNotificationRuleScannerCommitHandler)commitHandler {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _bundleIdentifier = [bundleIdentifier copy] ?: @"";
        _displayName = [displayName copy] ?: _bundleIdentifier;
        _ruleMode = [[WXPreferences normalizedRulesMode:ruleMode] copy];
        _initialRuleKind = initialRuleKind;
        _returnViewController = returnViewController;
        _returnMode = returnMode;
        _commitHandler = [commitHandler copy];
        _entries = @[];
        self.title = WXPLocalizedString(@"RULE_SCAN_TITLE");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.prompt = self.displayName;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(self),
                                    WXPNotificationHistoryRefreshCompletedCallback,
                                    (CFStringRef)WXNotificationHistoryRefreshCompletedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self requestRefreshAndReloadEntries];
}

- (void)dealloc {
    [self.refreshTimeoutTimer invalidate];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)(self),
                                       (CFStringRef)WXNotificationHistoryRefreshCompletedNotification,
                                       NULL);
}

- (void)requestRefreshAndReloadEntries {
    [self.refreshTimeoutTimer invalidate];
    self.refreshTimeoutTimer = nil;
    self.waitingForRefresh = NO;
    self.refreshRequestIdentifier = nil;

    NSError *error = nil;
    NSString *requestIdentifier = [WXPNotificationHistoryClient requestRefreshForBundleIdentifier:self.bundleIdentifier
                                                                                            limit:200
                                                                                            error:&error];
    if (requestIdentifier.length == 0) {
        [self reloadEntries];
        return;
    }

    self.refreshRequestIdentifier = requestIdentifier;
    self.waitingForRefresh = YES;
    self.entries = @[];
    self.historySource = nil;
    self.tableView.backgroundView = [self loadingStateView];
    [self.tableView reloadData];
    self.refreshTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:WXPNotificationRuleScannerRefreshTimeout
                                                                target:self
                                                              selector:@selector(refreshRequestDidTimeout:)
                                                              userInfo:requestIdentifier
                                                               repeats:NO];
    [self handleRefreshCompletedNotification];
}

- (void)handleRefreshCompletedNotification {
    if (!self.waitingForRefresh || self.refreshRequestIdentifier.length == 0) {
        return;
    }

    NSDictionary *status = [WXPNotificationHistoryClient refreshStatusForRequestIdentifier:self.refreshRequestIdentifier
                                                                          bundleIdentifier:self.bundleIdentifier];
    if (!status) {
        return;
    }

    [self.refreshTimeoutTimer invalidate];
    self.refreshTimeoutTimer = nil;
    self.waitingForRefresh = NO;
    NSString *source = [status[WXNotificationHistorySourceKey] isKindOfClass:[NSString class]] ? status[WXNotificationHistorySourceKey] : nil;
    [self reloadEntriesWithPreferredSource:source];
}

- (void)refreshRequestDidTimeout:(NSTimer *)timer {
    NSString *requestIdentifier = [timer.userInfo isKindOfClass:[NSString class]] ? timer.userInfo : nil;
    if (requestIdentifier.length > 0 && ![requestIdentifier isEqualToString:self.refreshRequestIdentifier]) {
        return;
    }

    self.refreshTimeoutTimer = nil;
    self.waitingForRefresh = NO;
    [self reloadEntries];
}

- (void)reloadEntries {
    [self reloadEntriesWithPreferredSource:nil];
}

- (void)reloadEntriesWithPreferredSource:(NSString *)preferredSource {
    NSError *error = nil;
    NSString *source = nil;
    NSArray<NSDictionary *> *loadedEntries = [WXPNotificationHistoryClient fetchEntriesForBundleIdentifier:self.bundleIdentifier
                                                                                                     error:&error
                                                                                                    source:&source];
    self.historySource = preferredSource ?: source;
    if (error && loadedEntries.count == 0) {
        self.tableView.backgroundView = [self errorStateView:error.localizedDescription];
        self.entries = @[];
        [self.tableView reloadData];
        return;
    }

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
        return [self hasScannableContentForEntry:entry];
    }];

    self.entries = [[loadedEntries filteredArrayUsingPredicate:predicate] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        NSTimeInterval lhsTimestamp = [lhs[WXLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [lhs[WXLogTimestampKey] doubleValue] : 0;
        NSTimeInterval rhsTimestamp = [rhs[WXLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [rhs[WXLogTimestampKey] doubleValue] : 0;
        if (lhsTimestamp > rhsTimestamp) {
            return NSOrderedAscending;
        }
        if (lhsTimestamp < rhsTimestamp) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    self.tableView.backgroundView = self.entries.count == 0 ? [self emptyStateView] : nil;
    [self.tableView reloadData];
}

- (BOOL)hasScannableContentForEntry:(NSDictionary *)entry {
    NSArray<NSString *> *fields = @[
        [entry[WXLogTitleKey] isKindOfClass:[NSString class]] ? entry[WXLogTitleKey] : @"",
        [entry[WXLogSubtitleKey] isKindOfClass:[NSString class]] ? entry[WXLogSubtitleKey] : @"",
        [entry[WXLogHeaderKey] isKindOfClass:[NSString class]] ? entry[WXLogHeaderKey] : @"",
        [entry[WXLogBodyKey] isKindOfClass:[NSString class]] ? entry[WXLogBodyKey] : @"",
        [entry[WXLogMessageKey] isKindOfClass:[NSString class]] ? entry[WXLogMessageKey] : @""
    ];
    for (NSString *field in fields) {
        if ([[field stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0) {
            return YES;
        }
    }
    return NO;
}

- (UIView *)loadingStateView {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.frame = self.tableView.bounds;
    indicator.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [indicator startAnimating];
    return indicator;
}

- (UIView *)emptyStateView {
    UILabel *label = [[UILabel alloc] initWithFrame:self.tableView.bounds];
    label.text = WXPLocalizedString(@"RULE_SCAN_EMPTY");
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    return label;
}

- (UIView *)errorStateView:(NSString *)message {
    UILabel *label = [[UILabel alloc] initWithFrame:self.tableView.bounds];
    NSString *resolvedMessage = message;
    if ([resolvedMessage isEqualToString:@"RULE_SCAN_SOURCE_FAILED"]) {
        resolvedMessage = WXPLocalizedString(resolvedMessage);
    }
    label.text = resolvedMessage.length > 0 ? resolvedMessage : WXPLocalizedString(@"RULE_SCAN_SOURCE_FAILED");
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    return label;
}

- (NSDateFormatter *)dateFormatter {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
    });
    return formatter;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"scan"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"scan"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    NSDictionary *entry = self.entries[indexPath.row];
    NSTimeInterval timestamp = [entry[WXLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [entry[WXLogTimestampKey] doubleValue] : 0;
    NSString *preview = WXPScannerPreviewText(entry);
    cell.textLabel.text = preview;
    cell.detailTextLabel.text = [[self dateFormatter] stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
    cell.imageView.image = [[WXPAppInfoProvider sharedProvider] iconForBundleIdentifier:self.bundleIdentifier];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self.historySource isEqualToString:@"mirror"]) {
        return WXPLocalizedString(@"RULE_SCAN_FOOTER_MIRROR");
    }
    return WXPLocalizedString(@"RULE_SCAN_FOOTER");
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= self.entries.count) {
        return;
    }

    NSDictionary *entry = self.entries[indexPath.row];
    WXPNotificationRuleTokenPickerController *controller = [[WXPNotificationRuleTokenPickerController alloc] initWithNotificationEntry:entry
                                                                                                                           appDisplayName:self.displayName
                                                                                                                           initialRuleKind:self.initialRuleKind
                                                                                                                                  ruleMode:self.ruleMode
                                                                                                                      returnViewController:self.returnViewController
                                                                                                                                returnMode:self.returnMode
                                                                                                                             commitHandler:self.commitHandler];
    [self.navigationController pushViewController:controller animated:YES];
}

@end
