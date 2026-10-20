#import <UIKit/UIKit.h>
#import "NFPWeChatTargetEditorController.h"
#import "NFPLocalization.h"
#import "NFPRulesListEditorController.h"
#import "../Shared/NFPreferences.h"

typedef NS_ENUM(NSInteger, WPRow) { WPRowID = 0, WPRowContains, WPRowExclude };

@interface NFPWeChatTargetEditorController ()
@property (nonatomic, copy) NSDictionary *target;
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSArray *containsRules;
@property (nonatomic, copy) NSArray *excludeRules;
@property (nonatomic, copy) void (^saveHandler)(NSDictionary *target);
@property (nonatomic, strong) UITextField *idField;
@end

@implementation NFPWeChatTargetEditorController

- (instancetype)initWithTarget:(NSDictionary *)target saveHandler:(void (^)(NSDictionary *))saveHandler {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _target = target ?: @{};
        _targetId = [_target[@"id"] isKindOfClass:[NSString class]] ? _target[@"id"] : @"";
        _containsRules = [_target[@"contains"] isKindOfClass:[NSArray class]] ? _target[@"contains"] : @[];
        _excludeRules = [_target[@"exclude"] isKindOfClass:[NSArray class]] ? _target[@"exclude"] : @[];
        _saveHandler = saveHandler;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.targetId.length ? NFPLocalizedString(@"TARGET_EDIT_TITLE") : NFPLocalizedString(@"TARGET_ADD_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NFPLocalizedString(@"COMMON_DONE") style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped:)];
    if (@available(iOS 15.0, *)) { self.tableView.sectionHeaderTopPadding = 0; }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == WPRowID) return NFPLocalizedString(@"TARGET_SECTION_ID");
    if (section == WPRowContains) return NFPLocalizedString(@"TARGET_SECTION_CONTAINS");
    return NFPLocalizedString(@"TARGET_SECTION_EXCLUDE");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == WPRowID) return NFPLocalizedString(@"TARGET_ID_FOOTER");
    if (section == WPRowContains) return NFPLocalizedString(@"TARGET_CONTAINS_FOOTER");
    return NFPLocalizedString(@"TARGET_EXCLUDE_FOOTER");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"row"];
    cell.textLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = nil;
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
        cell.contentView.addSubview(field);
        field.frame = CGRectMake(16, 4, 300, 36);
    } else if (indexPath.section == WPRowContains) {
        cell.textLabel.text = NFPLocalizedString(@"TARGET_ROW_EDIT_CONTAINS");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.containsRules.count];
    } else {
        cell.textLabel.text = NFPLocalizedString(@"TARGET_ROW_EDIT_EXCLUDE");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.excludeRules.count];
    }
    return cell;
}

- (void)idChanged:(UITextField *)f { self.targetId = f.text ?: @""; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == WPRowID) { [self.idField becomeFirstResponder]; return; }
    __weak typeof(self) weakSelf = self;
    NFPRuleEditorKind kind = (indexPath.section == WPRowContains) ? NFPRuleEditorKindContains : NFPRuleEditorKindExclude;
    NSString *title = (indexPath.section == WPRowContains) ? NFPLocalizedString(@"TARGET_ROW_EDIT_CONTAINS") : NFPLocalizedString(@"TARGET_ROW_EDIT_EXCLUDE");
    NSArray *rules = (indexPath.section == WPRowContains) ? self.containsRules : self.excludeRules;
    NFPRulesListEditorController *editor = [[NFPRulesListEditorController alloc] initWithTitle:title
                                                                                         editorKind:kind
                                                                                              rules:rules
                                                                                        saveHandler:^(NSArray *saved) {
        if (indexPath.section == WPRowContains) weakSelf.containsRules = saved;
        else weakSelf.excludeRules = saved;
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
    self.saveHandler(@{ @"id": tid, @"contains": self.containsRules ?: @[], @"exclude": self.excludeRules ?: @[] });
    [self.navigationController popViewControllerAnimated:YES];
}

@end
