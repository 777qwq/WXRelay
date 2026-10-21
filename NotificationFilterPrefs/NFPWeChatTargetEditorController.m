#import <UIKit/UIKit.h>
#import "NFPWeChatTargetEditorController.h"
#import "NFPLocalization.h"
#import "NFPRulesListEditorController.h"
#import "../Shared/NFPreferences.h"
#import "NFPAppRulesExportPickerController.h"

typedef NS_ENUM(NSInteger, WPRow) { WPRowID = 0, WPRowContains, WPRowExclude, WPRowApps };

@interface NFPWeChatTargetEditorController ()
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

@implementation NFPWeChatTargetEditorController

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
    self.title = self.targetId.length ? NFPLocalizedString(@"TARGET_EDIT_TITLE") : NFPLocalizedString(@"TARGET_ADD_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NFPLocalizedString(@"COMMON_SAVE") style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped:)];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"wrow-id"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"wrow-link"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"wrow-text"];
    if (@available(iOS 15.0, *)) { self.tableView.sectionHeaderTopPadding = 0; }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == WPRowID) return NFPLocalizedString(@"TARGET_SECTION_ID");
    if (section == WPRowContains) return NFPLocalizedString(@"TARGET_SECTION_CONTAINS");
    if (section == WPRowExclude) return NFPLocalizedString(@"TARGET_SECTION_EXCLUDE");
    return NFPLocalizedString(@"TARGET_SECTION_APPS");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == WPRowID) return NFPLocalizedString(@"TARGET_ID_FOOTER");
    if (section == WPRowContains) return NFPLocalizedString(@"TARGET_CONTAINS_FOOTER");
    if (section == WPRowExclude) {
        return [NSString stringWithFormat:@"%@\n\n%@", NFPLocalizedString(@"TARGET_EXCLUDE_FOOTER"), NFPLocalizedString(@"TARGET_JUDGE_FOOTER")];
    }
    if (section == WPRowApps) return NFPLocalizedString(@"TARGET_APPS_FOOTER");
    return NFPLocalizedString(@"TARGET_JUDGE_FOOTER");
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
        field.placeholder = NFPLocalizedString(@"TARGET_ID_PLACEHOLDER");
        field.text = self.targetId;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [field addTarget:self action:@selector(idChanged:) forControlEvents:UIControlEventEditingChanged];
        self.idField = field;
        [cell.contentView addSubview:field];
        field.frame = CGRectMake(16, 4, 300, 36);
    } else if (indexPath.section == WPRowContains) {
        cell.textLabel.text = NFPLocalizedString(@"TARGET_ROW_EDIT_RULES");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.containsRules.count];
    } else if (indexPath.section == WPRowExclude) {
        cell.textLabel.text = NFPLocalizedString(@"TARGET_ROW_EDIT_EXCLUDE");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.excludeRules.count];
    } else if (indexPath.section == WPRowApps) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        unsigned long n = self.appsList.count;
        cell.detailTextLabel.text = n ? [NSString stringWithFormat:@"%lu 个 App", n] : NFPLocalizedString(@"TARGET_APPS_PLACEHOLDER");
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    return cell;
}

- (void)idChanged:(UITextField *)f { self.targetId = f.text ?: @""; }

- (void)enabledChanged:(UISwitch *)sw { self.enabledTarget = sw.on; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == WPRowID) { [self.idField becomeFirstResponder]; return; }
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == WPRowApps) {
        NFPAppRulesExportPickerController *picker = [[NFPAppRulesExportPickerController alloc] initWithSelectedBundleIdentifiers:self.appsList selectionHandler:^(NSArray<NSString *> *selected) {
            weakSelf.appsList = selected;
            [weakSelf.tableView reloadData];
        }];
        [self.navigationController pushViewController:picker animated:YES];
        return;
    }
        // v2.4.4：包含区 push 规则列表页（含可选回复），不再弹窗
    if (indexPath.section == WPRowContains) {
        NFPRulesListEditorController *editor = [[NFPRulesListEditorController alloc] initWithTitle:NFPLocalizedString(@"TARGET_ROW_EDIT_CONTAINS")
                                                                                     editorKind:NFPRuleEditorKindContains
                                                                                          rules:self.containsRules
                                                                                    saveHandler:^(NSArray *saved) {
            weakSelf.containsRules = saved;
            [weakSelf.tableView reloadData];
        }];
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    NSString *title = NFPLocalizedString(@"TARGET_ROW_EDIT_EXCLUDE");
    NFPRulesListEditorController *editor = [[NFPRulesListEditorController alloc] initWithTitle:title
                                                                                         editorKind:NFPRuleEditorKindExclude
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
        UIAlertController *a = [UIAlertController alertControllerWithTitle:NFPLocalizedString(@"TARGET_ID_REQUIRED_TITLE") message:NFPLocalizedString(@"TARGET_ID_REQUIRED_MSG") preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:NFPLocalizedString(@"COMMON_OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    self.saveHandler(@{ @"id": tid, @"enabled": (self.target[@"enabled"] == nil ? @YES : self.target[@"enabled"]), @"contains": self.containsRules ?: @[], @"exclude": self.excludeRules ?: @[], @"apps": self.appsList ?: @[] });
    [self.navigationController popViewControllerAnimated:YES];
}

@end
