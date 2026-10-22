#import "WXPLogsListController.h"
#import "WXPLocalization.h"
#import "../Shared/WXLogStore.h"
#import "../Shared/WXPreferences.h"
#import "WXPAppInfoProvider.h"
#import "WXPLogDetailController.h"

@interface WXPLogsListController ()

@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredEntries;
@property (nonatomic, copy) NSArray<NSDictionary *> *appGroups;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredAppGroups;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy, nullable) NSString *bundleIdentifierFilter;
@property (nonatomic, copy, nullable) NSString *displayNameFilter;
@property (nonatomic, assign) BOOL showsAppEntries;

@end

@implementation WXPLogsListController


- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] initWithFrame:CGRectZero];
}
static NSString * const WXPLogsGroupBundleIdentifierKey = @"bundleIdentifier";
static NSString * const WXPLogsGroupDisplayNameKey = @"displayName";
static NSString * const WXPLogsGroupLatestEntryKey = @"latestEntry";
static NSString * const WXPLogsGroupLatestTimestampKey = @"latestTimestamp";
static NSString * const WXPLogsGroupEntriesKey = @"entries";

static NSString *WXPLogPreviewText(NSDictionary *entry) {
    NSString *joinedText = entry[WXLogJoinedTextKey];
    if (![joinedText isKindOfClass:[NSString class]] || joinedText.length == 0) {
        NSString *matchedPattern = entry[WXLogMatchedPatternKey];
        if ([matchedPattern isKindOfClass:[NSString class]] && matchedPattern.length > 0) {
            return matchedPattern;
        }
        return WXPLocalizedString(@"LOGS_EMPTY_PREVIEW");
    }

    NSMutableString *preview = [[joinedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];
    [preview replaceOccurrencesOfString:@"\n"
                             withString:@"  "
                                options:0
                                  range:NSMakeRange(0, preview.length)];
    if (preview.length > 90) {
        return [[preview substringToIndex:90] stringByAppendingString:@"…"];
    }
    return preview;
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier displayName:(NSString *)displayName {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _bundleIdentifierFilter = [bundleIdentifier copy];
        _displayNameFilter = [displayName copy];
        _showsAppEntries = YES;
    }
    return self;
}

- (BOOL)isShowingAppEntries {
    return self.showsAppEntries;
}

- (BOOL)isShowingGlobalSearchResults {
    if ([self isShowingAppEntries]) {
        return NO;
    }
    NSString *searchText = [self.searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return searchText.length > 0;
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

- (NSTimeInterval)timestampForEntry:(NSDictionary *)entry {
    if ([entry[WXLogTimestampKey] respondsToSelector:@selector(doubleValue)]) {
        return [entry[WXLogTimestampKey] doubleValue];
    }
    return 0;
}

- (NSString *)displayNameForBundleIdentifier:(NSString *)bundleIdentifier {
    return [[WXPAppInfoProvider sharedProvider] displayNameForBundleIdentifier:bundleIdentifier];
}

- (NSArray<NSDictionary *> *)sortedEntriesDescending:(NSArray<NSDictionary *> *)entries {
    return [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        NSTimeInterval lhsTimestamp = [self timestampForEntry:lhs];
        NSTimeInterval rhsTimestamp = [self timestampForEntry:rhs];
        if (lhsTimestamp > rhsTimestamp) {
            return NSOrderedAscending;
        }
        if (lhsTimestamp < rhsTimestamp) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
}

- (NSArray<NSDictionary *> *)appGroupsFromEntries:(NSArray<NSDictionary *> *)entries {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groupsByBundleIdentifier = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *orderedBundleIdentifiers = [NSMutableArray array];

    for (NSDictionary *entry in [self sortedEntriesDescending:entries]) {
        NSString *bundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ?
            entry[WXLogBundleIdentifierKey] :
            @"";
        NSMutableDictionary *group = groupsByBundleIdentifier[bundleIdentifier];
        if (!group) {
            group = [@{
                WXPLogsGroupBundleIdentifierKey: bundleIdentifier,
                WXPLogsGroupDisplayNameKey: [self displayNameForBundleIdentifier:bundleIdentifier] ?: bundleIdentifier,
                WXPLogsGroupLatestEntryKey: entry,
                WXPLogsGroupLatestTimestampKey: @([self timestampForEntry:entry]),
                WXPLogsGroupEntriesKey: [NSMutableArray array]
            } mutableCopy];
            groupsByBundleIdentifier[bundleIdentifier] = group;
            [orderedBundleIdentifiers addObject:bundleIdentifier];
        }
        [group[WXPLogsGroupEntriesKey] addObject:entry];
    }

    NSMutableArray<NSDictionary *> *groups = [NSMutableArray arrayWithCapacity:orderedBundleIdentifiers.count];
    for (NSString *bundleIdentifier in orderedBundleIdentifiers) {
        NSMutableDictionary *group = [groupsByBundleIdentifier[bundleIdentifier] mutableCopy];
        group[WXPLogsGroupEntriesKey] = [[self sortedEntriesDescending:group[WXPLogsGroupEntriesKey]] copy];
        [groups addObject:[group copy]];
    }
    return groups;
}

- (BOOL)entry:(NSDictionary *)entry matchesSearchText:(NSString *)normalizedSearchText {
    NSString *bundleIdentifier = [entry[WXLogBundleIdentifierKey] lowercaseString] ?: @"";
    NSString *displayName = [[self displayNameForBundleIdentifier:entry[WXLogBundleIdentifierKey]] lowercaseString] ?: @"";
    if ([bundleIdentifier containsString:normalizedSearchText] || [displayName containsString:normalizedSearchText]) {
        return YES;
    }

    NSArray<NSString *> *searchableValues = @[
        [entry[WXLogMatchedPatternKey] lowercaseString] ?: @"",
        [entry[WXLogJoinedTextKey] lowercaseString] ?: @"",
        [entry[WXLogTitleKey] lowercaseString] ?: @"",
        [entry[WXLogSubtitleKey] lowercaseString] ?: @"",
        [entry[WXLogHeaderKey] lowercaseString] ?: @"",
        [entry[WXLogBodyKey] lowercaseString] ?: @"",
        [entry[WXLogMessageKey] lowercaseString] ?: @""
    ];

    for (NSString *value in searchableValues) {
        if ([value containsString:normalizedSearchText]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)detailTextForSearchResultEntry:(NSDictionary *)entry {
    NSString *matchedPattern = [entry[WXLogMatchedPatternKey] isKindOfClass:[NSString class]] ? entry[WXLogMatchedPatternKey] : nil;
    NSString *previewText = WXPLogPreviewText(entry);
    if (matchedPattern.length == 0) {
        return previewText;
    }

    return [NSString stringWithFormat:WXPLocalizedString(@"LOGS_SEARCH_RESULT_DETAIL_FORMAT"),
                                      matchedPattern,
                                      previewText];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self isShowingAppEntries] ? (self.displayNameFilter ?: WXPLocalizedString(@"LOGS_TITLE")) : WXPLocalizedString(@"LOGS_TITLE");
    UIBarButtonItem *clearButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                                                 target:self
                                                                                 action:@selector(clearTapped)];
    if ([self isShowingAppEntries]) {
        self.navigationItem.rightBarButtonItem = clearButton;
    } else {
        UIBarButtonItem *limitButton = [[UIBarButtonItem alloc] initWithTitle:WXPLocalizedString(@"LOGS_LIMIT_BUTTON")
                                                                        style:UIBarButtonItemStylePlain
                                                                       target:self
                                                                       action:@selector(limitTapped)];
        self.navigationItem.rightBarButtonItems = @[clearButton, limitButton];
    }

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchResultsUpdater = self;
    searchController.searchBar.placeholder = WXPLocalizedString(@"LOGS_SEARCH_PLACEHOLDER");
    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.searchController = searchController;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadEntries];
}

- (void)reloadEntries {
    NSArray<NSDictionary *> *loadedEntries = [self sortedEntriesDescending:[WXLogStore loadEntries]];
    if ([self isShowingAppEntries]) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
            NSString *bundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[WXLogBundleIdentifierKey] : @"";
            return [bundleIdentifier isEqualToString:self.bundleIdentifierFilter ?: @""];
        }];
        self.entries = [loadedEntries filteredArrayUsingPredicate:predicate];
        self.appGroups = @[];
    } else {
        self.entries = loadedEntries;
        self.appGroups = [self appGroupsFromEntries:loadedEntries];
    }
    [self applySearchText:self.searchController.searchBar.text];
    self.tableView.backgroundView = [self currentRowCount] == 0 ? [self emptyStateView] : nil;
    [self.tableView reloadData];
}

- (UIView *)emptyStateView {
    UILabel *label = [[UILabel alloc] initWithFrame:self.tableView.bounds];
    label.text = WXPLocalizedString(@"LOGS_EMPTY");
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    return label;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentRowCount];
}

- (NSInteger)currentRowCount {
    if ([self isShowingAppEntries] || [self isShowingGlobalSearchResults]) {
        return self.filteredEntries.count;
    }
    return self.filteredAppGroups.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"log"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"log"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.numberOfLines = 2;
    }

    if ([self isShowingAppEntries] || [self isShowingGlobalSearchResults]) {
        NSDictionary *entry = self.filteredEntries[indexPath.row];
        NSString *bundleIdentifier = entry[WXLogBundleIdentifierKey];
        NSString *displayName = [self displayNameForBundleIdentifier:bundleIdentifier];
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[self timestampForEntry:entry]];

        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@",
                               displayName,
                               [[self dateFormatter] stringFromDate:date]];
        cell.detailTextLabel.text = [self isShowingGlobalSearchResults] ? [self detailTextForSearchResultEntry:entry] : WXPLogPreviewText(entry);
        cell.imageView.image = [[WXPAppInfoProvider sharedProvider] iconForBundleIdentifier:bundleIdentifier];
    } else {
        NSDictionary *group = self.filteredAppGroups[indexPath.row];
        NSDictionary *latestEntry = group[WXPLogsGroupLatestEntryKey];
        NSString *bundleIdentifier = group[WXPLogsGroupBundleIdentifierKey];
        NSString *displayName = group[WXPLogsGroupDisplayNameKey];
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[group[WXPLogsGroupLatestTimestampKey] doubleValue]];
        NSUInteger count = [group[WXPLogsGroupEntriesKey] count];

        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@",
                               displayName,
                               [[self dateFormatter] stringFromDate:date]];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  (%lu)",
                                     WXPLogPreviewText(latestEntry),
                                     (unsigned long)count];
        cell.imageView.image = [[WXPAppInfoProvider sharedProvider] iconForBundleIdentifier:bundleIdentifier];
    }
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if ([self isShowingAppEntries] || [self isShowingGlobalSearchResults]) {
        NSDictionary *entry = self.filteredEntries[indexPath.row];
        NSString *bundleIdentifier = entry[WXLogBundleIdentifierKey];
        NSString *displayName = [self displayNameForBundleIdentifier:bundleIdentifier];
        WXPLogDetailController *controller = [[WXPLogDetailController alloc] initWithEntry:entry displayName:displayName];
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }

    NSDictionary *group = self.filteredAppGroups[indexPath.row];
    WXPLogsListController *controller = [[WXPLogsListController alloc] initWithBundleIdentifier:group[WXPLogsGroupBundleIdentifierKey]
                                                                                     displayName:group[WXPLogsGroupDisplayNameKey]];
    [self.navigationController pushViewController:controller animated:YES];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self isShowingAppEntries] || [self isShowingGlobalSearchResults]) {
        return nil;
    }
    return [NSString stringWithFormat:WXPLocalizedString(@"LOGS_FOOTER_FORMAT"),
                                      (long)[self currentLogEntryLimit]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return ![self isShowingAppEntries] && ![self isShowingGlobalSearchResults];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self tableView:tableView canEditRowAtIndexPath:indexPath]) {
        return nil;
    }

    NSDictionary *group = self.filteredAppGroups[indexPath.row];
    NSString *bundleIdentifier = group[WXPLogsGroupBundleIdentifierKey];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:WXPLocalizedString(@"COMMON_DELETE")
                                                                             handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [WXLogStore clearEntriesForBundleIdentifier:bundleIdentifier ?: @""];
        [weakSelf reloadEntries];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self tableView:tableView canEditRowAtIndexPath:indexPath]) {
        return nil;
    }

    NSDictionary *group = self.filteredAppGroups[indexPath.row];
    NSString *bundleIdentifier = group[WXPLogsGroupBundleIdentifierKey] ?: @"";
    NSDictionary *preferences = [WXPreferences loadPreferences];
    BOOL disabled = [WXPreferences isLoggingDisabledForBundleIdentifier:bundleIdentifier preferences:preferences];
    NSString *title = disabled ? WXPLocalizedString(@"LOGS_RESUME_APP_LOG") : WXPLocalizedString(@"LOGS_STOP_APP_LOG");
    __weak typeof(self) weakSelf = self;
    UIContextualAction *loggingAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                                title:title
                                                                              handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [WXPreferences setLoggingDisabled:!disabled forBundleIdentifier:bundleIdentifier];
        [weakSelf reloadEntries];
        completionHandler(YES);
    }];
    loggingAction.backgroundColor = disabled ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[loggingAction]];
}

- (void)clearTapped {
    if (self.entries.count == 0) {
        return;
    }

    NSString *message = [self isShowingAppEntries] ? WXPLocalizedString(@"LOGS_CLEAR_APP_MESSAGE") : WXPLocalizedString(@"LOGS_CLEAR_MESSAGE");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:WXPLocalizedString(@"LOGS_CLEAR_TITLE")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"COMMON_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"COMMON_CLEAR")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        if ([self isShowingAppEntries]) {
            [WXLogStore clearEntriesForBundleIdentifier:self.bundleIdentifierFilter ?: @""];
        } else {
            [WXLogStore clearEntries];
        }
        [self reloadEntries];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)currentLogEntryLimit {
    NSDictionary *preferences = [WXPreferences loadPreferences];
    return [WXPreferences normalizedLogEntryLimit:preferences[WXLogEntryLimitKey]];
}

- (void)limitTapped {
    NSInteger currentLimit = [self currentLogEntryLimit];
    NSString *message = [NSString stringWithFormat:WXPLocalizedString(@"LOGS_LIMIT_MESSAGE_FORMAT"),
                         (long)[WXPreferences defaultLogEntryLimit]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:WXPLocalizedString(@"LOGS_LIMIT_TITLE")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.placeholder = [NSString stringWithFormat:@"%ld", (long)[WXPreferences defaultLogEntryLimit]];
        textField.text = [NSString stringWithFormat:@"%ld", (long)currentLimit];
        if (@available(iOS 10.0, *)) {
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }
    }];
    [alert addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"COMMON_CANCEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"COMMON_SAVE")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *rawValue = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (rawValue.length > 0) {
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            if ([rawValue rangeOfCharacterFromSet:nonDigits].location != NSNotFound || rawValue.integerValue <= 0) {
                [self presentLogLimitSaveError];
                return;
            }
        }

        NSInteger limit = rawValue.length > 0 ?
            [WXPreferences normalizedLogEntryLimit:@(rawValue.integerValue)] :
            [WXPreferences defaultLogEntryLimit];
        if (limit <= 0) {
            [self presentLogLimitSaveError];
            return;
        }
        [self saveLogEntryLimit:limit];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveLogEntryLimit:(NSInteger)limit {
    NSMutableDictionary *preferences = [WXPreferences loadMutablePreferences];
    preferences[WXLogEntryLimitKey] = @(limit);

    NSError *error = nil;
    if (![WXPreferences savePreferences:preferences error:&error]) {
        [self presentError:error fallbackMessageKey:@"LOGS_LIMIT_SAVE_FAILED"];
        return;
    }

    [WXPreferences postPreferencesChangedNotification];
    [WXLogStore trimEntriesToCurrentLimit];
    [self reloadEntries];
}

- (void)presentLogLimitSaveError {
    [self presentError:nil fallbackMessageKey:@"LOGS_LIMIT_INVALID_MESSAGE"];
}

- (void)presentError:(NSError *)error fallbackMessageKey:(NSString *)fallbackMessageKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:WXPLocalizedString(@"COMMON_SAVE_FAILED")
                                                                   message:error.localizedDescription ?: WXPLocalizedString(fallbackMessageKey)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"COMMON_OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applySearchText:searchController.searchBar.text];
    self.tableView.backgroundView = [self currentRowCount] == 0 ? [self emptyStateView] : nil;
    [self.tableView reloadData];
}

- (void)applySearchText:(NSString *)searchText {
    NSString *normalizedSearchText = [[searchText ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (normalizedSearchText.length == 0) {
        if ([self isShowingAppEntries]) {
            self.filteredEntries = self.entries ?: @[];
        } else {
            self.filteredEntries = @[];
            self.filteredAppGroups = self.appGroups ?: @[];
        }
        return;
    }

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
        return [self entry:entry matchesSearchText:normalizedSearchText];
    }];
    self.filteredEntries = [self.entries filteredArrayUsingPredicate:predicate];
    self.filteredAppGroups = @[];
}

@end
