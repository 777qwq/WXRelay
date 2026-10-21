#import "NFPAppRulesExportPickerController.h"
#import "../Shared/NFPreferences.h"
#import "NFPLocalization.h"
#import "NFPAppInfoProvider.h"

static NSString * const NFPExportPickerBundleIdentifierKey = @"bundleID";
static NSString * const NFPExportPickerDisplayNameKey = @"displayName";

@interface NFPAppRulesExportPickerController ()

@property (nonatomic, copy) NSArray<NSString *> *initiallySelectedBundleIdentifiers;
@property (nonatomic, copy) void (^selectionHandler)(NSArray<NSString *> *selectedBundleIdentifiers);
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedBundleIdentifiers;
@property (nonatomic, copy) NSArray<NSDictionary *> *applications;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredApplications;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIBarButtonItem *doneButton;
@property (nonatomic, copy, nullable) NSString *titleOverride;

@end

static void NAVLog2(NSString *msg) {
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSString *path = @"/var/mobile/Library/wxrelay_nav.log";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:path]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) { }
}

@implementation NFPAppRulesExportPickerController


- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] initWithFrame:CGRectZero];
}
- (instancetype)initWithTitle:(NSString *)titleOverride
             selectedBundleIdentifiers:(NSArray<NSString *> *)selectedBundleIdentifiers
                  selectionHandler:(void (^)(NSArray<NSString *> *))selectionHandler {
    self = [self initWithSelectedBundleIdentifiers:selectedBundleIdentifiers selectionHandler:selectionHandler];
    if (self) { _titleOverride = [titleOverride copy]; }
    return self;
}

- (instancetype)initWithSelectedBundleIdentifiers:(NSArray<NSString *> *)selectedBundleIdentifiers
                                 selectionHandler:(void (^)(NSArray<NSString *> *))selectionHandler {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _initiallySelectedBundleIdentifiers = [selectedBundleIdentifiers copy] ?: @[];
        _selectionHandler = [selectionHandler copy];
        _selectedBundleIdentifiers = [NSMutableSet setWithArray:_initiallySelectedBundleIdentifiers];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.titleOverride ?: NFPLocalizedString(@"APP_RULES_EXPORT_PICKER_TITLE");
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.tableView.allowsMultipleSelection = YES;
    [self.tableView setEditing:YES animated:NO];
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchResultsUpdater = self;
    searchController.searchBar.placeholder = NFPLocalizedString(@"APP_RULES_SEARCH_PLACEHOLDER");
    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.searchController = searchController;

    self.doneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                     target:self
                                                                     action:@selector(doneTapped)];
    self.navigationItem.rightBarButtonItem = self.doneButton;

    [self reloadApplications];
    // v2.4.10：照原壳无条件刷新（缓存可能为空或过期）
    [[NFPAppInfoProvider sharedProvider] refreshApplicationsWithCompletion:^(NSArray *applications) {
        [self reloadApplications];
    }];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(navAppBackground) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(navAppForeground) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)navAppBackground { NAVLog2(@"app BACKGROUND while picker"); }
- (void)navAppForeground { NAVLog2(@"app FOREGROUND"); }

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    NSUInteger depth = self.navigationController.viewControllers.count;
    NAVLog2([NSString stringWithFormat:@"picker disappear stack=%lu", (unsigned long)depth]);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadApplications];
}

- (void)reloadApplications {
    NSDictionary *preferences = [NFPreferences loadPreferences];
    NSDictionary *appRules = preferences[NFAppRulesKey];

    NSMutableSet<NSString *> *configuredBundleIdentifiers = [NSMutableSet set];
    [appRules enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) {
            return;
        }
        if ([NFPreferences rulesDictionaryHasConfiguredValues:obj]) {
            [configuredBundleIdentifiers addObject:key];
        }
    }];

    NSArray<NSDictionary *> *applications = [[NFPAppInfoProvider sharedProvider] sortedApplicationsWithConfiguredBundleIdentifiers:configuredBundleIdentifiers
                                                                                                                  onlyConfiguredApps:NO
                                                                                                                        showSystemApps:YES
                                                                                                                         showTrollApps:YES];
    self.applications = applications;
    [self applySearchText:self.searchController.searchBar.text];
    [self updateDoneButton];
    [self.tableView reloadData];
}

- (void)applySearchText:(NSString *)searchText {
    NSString *normalizedSearchText = [[searchText ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (normalizedSearchText.length == 0) {
        self.filteredApplications = self.applications ?: @[];
        return;
    }

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *application, NSDictionary *bindings) {
        NSString *displayName = [application[NFPExportPickerDisplayNameKey] lowercaseString] ?: @"";
        NSString *bundleIdentifier = [application[NFPExportPickerBundleIdentifierKey] lowercaseString] ?: @"";
        return [displayName containsString:normalizedSearchText] || [bundleIdentifier containsString:normalizedSearchText];
    }];
    self.filteredApplications = [self.applications filteredArrayUsingPredicate:predicate];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applySearchText:searchController.searchBar.text];
    [self.tableView reloadData];
}

- (void)updateDoneButton {
    NSUInteger count = self.selectedBundleIdentifiers.count;
    self.doneButton.title = count > 0 ? [NSString stringWithFormat:NFPLocalizedString(@"APP_RULES_EXPORT_DONE_COUNT_FORMAT"), (unsigned long)count]
                                     : NFPLocalizedString(@"COMMON_DONE");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApplications.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    }

    NSDictionary *application = self.filteredApplications[indexPath.row];
    NSString *bundleIdentifier = application[NFPExportPickerBundleIdentifierKey];
    cell.textLabel.text = application[NFPExportPickerDisplayNameKey];
    cell.detailTextLabel.text = bundleIdentifier;
    cell.imageView.image = [[NFPAppInfoProvider sharedProvider] iconForBundleIdentifier:bundleIdentifier];
    [cell setNeedsLayout];

    if ([self.selectedBundleIdentifiers containsObject:bundleIdentifier]) {
        [tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    }

    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    // v2.4.9：来源白名单场景用新文案
    if (self.titleOverride) return NFPLocalizedString(@"TARGET_APPS_FOOTER");
    return NFPLocalizedString(@"APP_RULES_EXPORT_PICKER_FOOTER");
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *application = self.filteredApplications[indexPath.row];
    NSString *bundleIdentifier = application[NFPExportPickerBundleIdentifierKey];
    if (bundleIdentifier.length > 0) {
        [self.selectedBundleIdentifiers addObject:bundleIdentifier];
    }
    [self updateDoneButton];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *application = self.filteredApplications[indexPath.row];
    NSString *bundleIdentifier = application[NFPExportPickerBundleIdentifierKey];
    [self.selectedBundleIdentifiers removeObject:bundleIdentifier];
    [self updateDoneButton];
}

- (void)doneTapped {
    NSArray<NSString *> *selected = [self.selectedBundleIdentifiers allObjects];
    if (self.selectionHandler) {
        self.selectionHandler(selected);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
