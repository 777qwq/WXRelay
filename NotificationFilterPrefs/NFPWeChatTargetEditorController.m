#import <UIKit/UIKit.h>
#import "NFPWeChatTargetEditorController.h"
#import "NFPLocalization.h"
#import "NFPRulesListEditorController.h"
#import "../Shared/NFPreferences.h"

typedef NS_ENUM(NSInteger, WPRow) { WPRowID = 0, WPRowContains, WPRowExclude, WPRowApps };

@interface NFPWeChatTargetEditorController ()
@property (nonatomic, copy) NSDictionary *target;
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, assign) BOOL enabledTarget;
@property (nonatomic, copy) NSArray *containsRules; // [{text, scope?, reply?}] v2.4.3：每条规则可带回复
@property (nonatomic, copy) NSArray *excludeRules;
@property (nonatomic, copy) NSString *appsFilter;   // v2.4.3 来源 App 白名单（扁平串，留空=全部）
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
        _appsFilter = [_target[@"apps"] isKindOfClass:[NSString class]] ? _target[@"apps"] : @"";
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
        cell.accessoryType = UITableViewCellAccessoryNone;
        UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 320, 36)];
        field.placeholder = NFPLocalizedString(@"TARGET_APPS_PLACEHOLDER");
        field.text = self.appsFilter;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [field addTarget:self action:@selector(appsChanged:) forControlEvents:UIControlEventEditingChanged];
        self.appsField = field;
        [cell.contentView addSubview:field];
        field.frame = CGRectMake(16, 4, 300, 36);
    }
    return cell;
}

- (void)idChanged:(UITextField *)f { self.targetId = f.text ?: @""; }

- (void)appsChanged:(UITextField *)f { self.appsFilter = f.text ?: @""; }

- (void)enabledChanged:(UISwitch *)sw { self.enabledTarget = sw.on; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == WPRowID) { [self.idField becomeFirstResponder]; return; }
    if (indexPath.section == WPRowApps) { [self.appsField becomeFirstResponder]; return; }
    __weak typeof(self) weakSelf = self;
    // v2.4.3：包含区=规则列表，每行「关键词=回复」，回复可空=纯转发
    if (indexPath.section == WPRowContains) {
        NSMutableString *flat = [NSMutableString string];
        for (NSDictionary *r in self.containsRules) {
            NSString *kw = [r isKindOfClass:[NSDictionary class]] ? ([r[@"text"] isKindOfClass:[NSString class]] ? r[@"text"] : @"") : (NSString *)r;
            NSString *rp = [r isKindOfClass:[NSDictionary class]] ? ([r[@"reply"] isKindOfClass:[NSString class]] ? r[@"reply"] : @"") : @"";
            if (kw.length) [flat appendFormat:@"%@=%@\n", kw, rp];
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NFPLocalizedString(@"TARGET_ROW_EDIT_RULES") message:NFPLocalizedString(@"TARGET_RULES_HINT") preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.text = flat;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:NFPLocalizedString(@"COMMON_OK") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSMutableArray *arr = [NSMutableArray array];
            for (NSString *line in [alert.textFields.firstObject.text componentsSeparatedByString:@"\n"]) {
                NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (l.length == 0) continue;
                NSRange eq = [l rangeOfString:@"="];
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                if (eq.location == NSNotFound) {
                    entry[@"text"] = l; // 纯转发规则
                } else {
                    entry[@"text"] = [[l substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    entry[@"reply"] = [[l substringFromIndex:NSMaxRange(eq)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if ([entry[@"text"] length] == 0) continue;
                }
                [arr addObject:entry];
            }
            weakSelf.containsRules = arr;
            [weakSelf.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:NFPLocalizedString(@"COMMON_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
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
    self.saveHandler(@{ @"id": tid, @"enabled": (self.target[@"enabled"] == nil ? @YES : self.target[@"enabled"]), @"contains": self.containsRules ?: @[], @"exclude": self.excludeRules ?: @[], @"apps": self.appsFilter ?: @"" });
    [self.navigationController popViewControllerAnimated:YES];
}

@end
