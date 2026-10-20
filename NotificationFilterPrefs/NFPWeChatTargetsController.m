#import <UIKit/UIKit.h>
#import "NFPWeChatTargetsController.h"
#import "NFPWeChatTargetEditorController.h"
#import "NFPLocalization.h"
#import "../Shared/NFPreferences.h"

@interface NFPWeChatTargetsController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *targets;
@end

@implementation NFPWeChatTargetsController

- (void)reloadTargets {
    NSDictionary *prefs = [NFPreferences loadPreferences];
    NSArray *list = prefs[NFWeChatTargetsListKey];
    self.targets = [list isKindOfClass:[NSArray class]] ? list : @[];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadTargets];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NFPLocalizedString(@"TARGETS_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addTarget:)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NFPLocalizedString(@"COMMON_DONE") style:UIBarButtonItemStyleDone target:self action:@selector(doneTapped:)];
    if (@available(iOS 15.0, *)) { self.tableView.sectionHeaderTopPadding = 0; }
}

- (void)doneTapped:(id)sender { [self.navigationController popViewControllerAnimated:YES]; }

- (void)persistTargets:(NSArray<NSDictionary *> *)list {
    NSMutableDictionary *preferences = [NFPreferences loadMutablePreferences];
    preferences[NFWeChatTargetsListKey] = list;
    NSError *error = nil;
    if (![NFPreferences savePreferences:preferences error:&error]) { return; }
    [NFPreferences postPreferencesChangedNotification];
}

- (void)addTarget:(id)sender {
    [self openEditor:nil];
}

- (void)openEditor:(NSDictionary * _Nullable)target {
    __weak typeof(self) weakSelf = self;
    NFPWeChatTargetEditorController *editor = [[NFPWeChatTargetEditorController alloc] initWithTarget:target saveHandler:^(NSDictionary *saved) {
        NSMutableArray *list = [NSMutableArray arrayWithArray:weakSelf.targets ?: @[]];
        NSString *tid = saved[@"id"];
        NSUInteger idx = [list indexOfObjectPassingTest:^BOOL(NSDictionary *t, NSUInteger i, BOOL *stop) {
            return [t[@"id"] isEqualToString:tid];
        }];
        if (idx == NSNotFound) [list addObject:saved]; else list[idx] = saved;
        [weakSelf persistTargets:list];
        [weakSelf reloadTargets];
        [weakSelf.tableView reloadData];
    }];
    [self.navigationController pushViewController:editor animated:YES];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.targets.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"target" forIndexPath:indexPath];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"target"];
    NSDictionary *t = self.targets[indexPath.row];
    cell.textLabel.text = t[@"id"];
    NSUInteger contains = [t[@"contains"] isKindOfClass:[NSArray class]] ? [t[@"contains"] count] : 0;
    NSUInteger exclude = [t[@"exclude"] isKindOfClass:[NSArray class]] ? [t[@"exclude"] count] : 0;
    BOOL enabled = t[@"enabled"] == nil ? YES : [t[@"enabled"] boolValue];
    cell.detailTextLabel.text = enabled
        ? [NSString stringWithFormat:NFPLocalizedString(@"TARGETS_ROW_SUMMARY"), contains, exclude]
        : NFPLocalizedString(@"TARGETS_ROW_DISABLED");
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openEditor:self.targets[indexPath.row]];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return NFPLocalizedString(@"TARGETS_FOOTER");
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSMutableArray *list = [NSMutableArray arrayWithArray:self.targets];
        [list removeObjectAtIndex:indexPath.row];
        [self persistTargets:list];
        [self reloadTargets];
        [self.tableView reloadData];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

@end
