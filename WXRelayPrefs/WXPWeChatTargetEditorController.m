#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "WXPWeChatTargetEditorController.h"
#import "WXPLocalization.h"
#import "WXPRulesListEditorController.h"
#import "../Shared/WXPreferences.h"
#import "WXPAppRulesExportPickerController.h"
#import "WXPAppInfoProvider.h"

typedef NS_ENUM(NSInteger, WPRow) { WPRowID = 0, WPRowContains, WPRowExclude, WPRowApps, WPRowAppsBar };

@interface WXPWeChatTargetEditorController ()
@property (nonatomic, copy) NSDictionary *target;
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, assign) BOOL enabledTarget;
@property (nonatomic, copy) NSArray *containsRules; // [{text, scope?, reply?}] v2.4.3：每条规则可带回复
@property (nonatomic, copy) NSArray *excludeRules;
@property (nonatomic, copy) NSArray *appsList;      // v2.4.6 来源 App 白名单（bundleID 数组，空=全部）
@property (nonatomic, copy) void (^saveHandler)(NSDictionary *target);
@property (nonatomic, strong) UITextField *idField;
@property (nonatomic, strong) UITextField *appsField;
@end

// v2.5.6 pop 探针：记录谁在切后台时弹导航（堆栈暴露来源插件）
@implementation WXPWeChatTargetEditorController

- (instancetype)initWithTarget:(NSDictionary *)target saveHandler:(void (^)(NSDictionary *))saveHandler {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _target = target ?: @{};
        _targetId = [_target[@"id"] isKindOfClass:[NSString class]] ? _target[@"id"] : @"";
        _containsRules = [_target[@"contains"] isKindOfClass:[NSArray class]] ? _target[@"contains"] : @[];
        _excludeRules = [_target[@"exclude"] isKindOfClass:[NSArray class]] ? _target[@"exclude"] : @[];
        _appsList = [_target[@"apps"] isKindOfClass:[NSArray class]] ? _target[@"apps"] : @[]; // v2.4.6 旧扁平串不迁移
        _saveHandler = saveHandler;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.targetId.length ? WXPLocalizedString(@"TARGET_EDIT_TITLE") : WXPLocalizedString(@"TARGET_ADD_TITLE");
    // v2.9.0 App 名缓存预热：首进不显示包标识
    if (![[WXPAppInfoProvider sharedProvider] hasCachedApplications]) {
        __weak typeof(self) weakSelf = self;
        [[WXPAppInfoProvider sharedProvider] refreshApplicationsWithCompletion:^(NSArray *applications) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.tableView reloadData];
            });
        }];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WXPLocalizedString(@"COMMON_SAVE") style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped:)];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"wrow-id"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"wrow-link"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"wrow-text"];
    if (@available(iOS 15.0, *)) { self.tableView.sectionHeaderTopPadding = 0; }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (section == WPRowApps && self.appsList.count) ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == WPRowID) return WXPLocalizedString(@"TARGET_SECTION_ID");
    if (section == WPRowContains) return WXPLocalizedString(@"TARGET_SECTION_CONTAINS");
    if (section == WPRowExclude) return WXPLocalizedString(@"TARGET_SECTION_EXCLUDE");
    return @"";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == WPRowID) return WXPLocalizedString(@"TARGET_ID_FOOTER");
    if (section == WPRowContains) return WXPLocalizedString(@"TARGET_CONTAINS_FOOTER");
    if (section == WPRowExclude) {
        return [NSString stringWithFormat:@"%@\n\n%@", WXPLocalizedString(@"TARGET_EXCLUDE_FOOTER"), WXPLocalizedString(@"TARGET_JUDGE_FOOTER")];
    }
    if (section == WPRowApps) return WXPLocalizedString(@"TARGET_APPS_FOOTER");
    return WXPLocalizedString(@"TARGET_JUDGE_FOOTER");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // v2.4.2：每种行独立复用 ID，防复用污染
    NSString *reuse = @"wrow-link";
    if (indexPath.section == WPRowID) reuse = @"wrow-id";
    else if (indexPath.section == WPRowContains) reuse = @"wrow-contains";
    else if (indexPath.section == WPRowExclude) reuse = @"wrow-exclude";
    else if (indexPath.section == WPRowApps) reuse = @"wrow-text";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    cell.textLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = nil;
    for (UIView *sub in [cell.contentView subviews]) [sub removeFromSuperview];
    if (indexPath.section == WPRowID) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 320, 36)];
        field.placeholder = WXPLocalizedString(@"TARGET_ID_PLACEHOLDER");
        field.text = self.targetId;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [field addTarget:self action:@selector(idChanged:) forControlEvents:UIControlEventEditingChanged];
        self.idField = field;
        [cell.contentView addSubview:field];
        field.frame = CGRectMake(16, 4, 300, 36);
    } else if (indexPath.section == WPRowContains) {
        cell.textLabel.text = WXPLocalizedString(@"TARGET_ROW_EDIT_RULES");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.containsRules.count];
    } else if (indexPath.section == WPRowExclude) {
        cell.textLabel.text = WXPLocalizedString(@"TARGET_ROW_EDIT_EXCLUDE");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.excludeRules.count];
    } else if (indexPath.section == WPRowApps && indexPath.row == 0) {
        // v2.5.4 标题行：点击进 App 选择页
        cell.textLabel.text = WXPLocalizedString(@"TARGET_SECTION_APPS");
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == WPRowApps && indexPath.row == 1) {
        // v2.5.6 条形框：空内容隐藏整行；App 名默认色
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        for (UIView *sub in [cell.contentView subviews]) [sub removeFromSuperview];
        NSString *bar = [self displayNamesForAppsList].count > 4 ? [[[self displayNamesForAppsList] subarrayWithRange:NSMakeRange(0,4)] componentsJoinedByString:@"、"] : [[self displayNamesForAppsList] componentsJoinedByString:@"、"];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 30)];
        l.text = bar;
        l.font = [UIFont systemFontOfSize:14.0];
        l.textColor = [UIColor labelColor];
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell.contentView addSubview:l];
        l.frame = CGRectMake(16, 8, 300, 30);
    }
    return cell;
}

- (NSArray *)displayNamesForAppsList {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *bid in self.appsList) {
        NSString *n = [[WXPAppInfoProvider sharedProvider] displayNameForBundleIdentifier:bid];
        [out addObject:n.length ? n : bid];
    }
    return out;
}

- (void)idChanged:(UITextField *)f { self.targetId = f.text ?: @""; }

- (void)enabledChanged:(UISwitch *)sw { self.enabledTarget = sw.on; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == WPRowID) { [self.idField becomeFirstResponder]; return; }
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == WPRowApps && indexPath.row == 1) return; // 条形框行不可点
    if (indexPath.section == WPRowApps && indexPath.row == 0) {
        WXPAppRulesExportPickerController *picker = [[WXPAppRulesExportPickerController alloc] initWithTitle:WXPLocalizedString(@"APP_PICKER_TITLE") selectedBundleIdentifiers:self.appsList selectionHandler:^(NSArray<NSString *> *selected) {
            weakSelf.appsList = selected;
            [weakSelf.tableView reloadData];
        }];
        [self.navigationController pushViewController:picker animated:YES];
        return;
    }
        // v2.4.4：包含区 push 规则列表页（含可选回复），不再弹窗
    if (indexPath.section == WPRowContains) {
        WXPRulesListEditorController *editor = [[WXPRulesListEditorController alloc] initWithTitle:WXPLocalizedString(@"TARGET_ROW_EDIT_CONTAINS")
                                                                                     editorKind:WXPRuleEditorKindContains
                                                                                          rules:self.containsRules
                                                                                    saveHandler:^(NSArray *saved) {
            weakSelf.containsRules = saved;
            [weakSelf.tableView reloadData];
        }];
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    NSString *title = WXPLocalizedString(@"TARGET_ROW_EDIT_EXCLUDE");
    WXPRulesListEditorController *editor = [[WXPRulesListEditorController alloc] initWithTitle:title
                                                                                         editorKind:WXPRuleEditorKindExclude
                                                                                              rules:self.excludeRules
                                                                                        saveHandler:^(NSArray *saved) {
        weakSelf.excludeRules = saved;
        [weakSelf.tableView reloadData];
    }];
    [self.navigationController pushViewController:editor animated:YES];
}

- (void)saveTapped:(id)sender {
    NSString *tid = [self.targetId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (tid.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:WXPLocalizedString(@"TARGET_ID_REQUIRED_TITLE") message:WXPLocalizedString(@"TARGET_ID_REQUIRED_MSG") preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"COMMON_OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    self.saveHandler(@{ @"id": tid, @"enabled": (self.target[@"enabled"] == nil ? @YES : self.target[@"enabled"]), @"contains": self.containsRules ?: @[], @"exclude": self.excludeRules ?: @[], @"apps": self.appsList ?: @[] });
    [self.navigationController popViewControllerAnimated:YES];
}

@end
