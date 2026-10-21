#import <UIKit/UIKit.h>
#import "NFPWeChatTargetEditorController.h"
#import "NFPLocalization.h"
#import "NFPRulesListEditorController.h"
#import "../Shared/NFPreferences.h"

typedef NS_ENUM(NSInteger, WPRow) { WPRowID = 0, WPRowContains, WPRowExclude, WPRowAction };
typedef NS_ENUM(NSInteger, WPSubRow) { WPSubAction = 0, WPSubReplyRules, WPSubReplyText };

@interface NFPWeChatTargetEditorController ()
@property (nonatomic, copy) NSDictionary *target;
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, assign) BOOL enabledTarget;
@property (nonatomic, copy) NSArray *containsRules;
@property (nonatomic, copy) NSArray *excludeRules;
@property (nonatomic, copy) void (^saveHandler)(NSDictionary *target);
@property (nonatomic, strong) UITextField *idField;
@property (nonatomic, copy) NSString *action;
@property (nonatomic, copy) NSArray *replyRules;
@property (nonatomic, copy) NSString *replyText;
@property (nonatomic, strong) UITextField *replyField;
@end

@implementation NFPWeChatTargetEditorController

- (instancetype)initWithTarget:(NSDictionary *)target saveHandler:(void (^)(NSDictionary *))saveHandler {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _target = target ?: @{};
        _targetId = [_target[@"id"] isKindOfClass:[NSString class]] ? _target[@"id"] : @"";
        _containsRules = [_target[@"contains"] isKindOfClass:[NSArray class]] ? _target[@"contains"] : @[];
        _excludeRules = [_target[@"exclude"] isKindOfClass:[NSArray class]] ? _target[@"exclude"] : @[];
        _action = [_target[@"action"] isKindOfClass:[NSString class]] ? _target[@"action"] : @"relay";
        _replyText = [_target[@"reply"] isKindOfClass:[NSString class]] ? _target[@"reply"] : @"";
        _replyRules = [_target[@"replyRules"] isKindOfClass:[NSArray class]] ? _target[@"replyRules"] : @[];
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
    if (@available(iOS 15.0, *)) { self.tableView.sectionHeaderTopPadding = 0; }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (section == WPRowAction) ? 3 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == WPRowID) return NFPLocalizedString(@"TARGET_SECTION_ID");
    if (section == WPRowContains) return NFPLocalizedString(@"TARGET_SECTION_CONTAINS");
    if (section == WPRowExclude) return NFPLocalizedString(@"TARGET_SECTION_EXCLUDE");
    return NFPLocalizedString(@"TARGET_SECTION_ACTION");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == WPRowID) return NFPLocalizedString(@"TARGET_ID_FOOTER");
    if (section == WPRowContains) return NFPLocalizedString(@"TARGET_CONTAINS_FOOTER");
    if (section == WPRowExclude) {
        return [NSString stringWithFormat:@"%@\n\n%@", NFPLocalizedString(@"TARGET_EXCLUDE_FOOTER"), NFPLocalizedString(@"TARGET_JUDGE_FOOTER")];
    }
    if (section == WPRowAction) return NFPLocalizedString(@"TARGET_ACTION_FOOTER");
    return NFPLocalizedString(@"TARGET_JUDGE_FOOTER");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = (indexPath.section == WPRowID || (indexPath.section == WPRowAction && indexPath.row == WPSubReplyText)) ? @"wrow-id" : @"wrow-link";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse forIndexPath:indexPath];
    cell.textLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = nil;
    if (indexPath.section == WPRowID) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        for (UIView *sub in [cell.contentView subviews]) [sub removeFromSuperview];
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
        cell.textLabel.text = NFPLocalizedString(@"TARGET_ROW_EDIT_CONTAINS");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.containsRules.count];
    } else if (indexPath.section == WPRowExclude) {
        cell.textLabel.text = NFPLocalizedString(@"TARGET_ROW_EDIT_EXCLUDE");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.excludeRules.count];
    } else if (indexPath.section == WPRowAction && indexPath.row == WPSubAction) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        for (UIView *sub in [cell.contentView subviews]) [sub removeFromSuperview];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[NFPLocalizedString(@"TARGET_ACTION_RELAY"), NFPLocalizedString(@"TARGET_ACTION_REPLY"), NFPLocalizedString(@"TARGET_ACTION_BOTH")]];
        seg.selectedSegmentIndex = [self.action isEqualToString:@"reply"] ? 1 : ([self.action isEqualToString:@"both"] ? 2 : 0);
        seg.tag = WPRowAction;
        [seg addTarget:self action:@selector(actionChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:seg];
        seg.frame = CGRectMake(16, 8, 300, 30);
    } else if (indexPath.section == WPRowAction && indexPath.row == WPSubReplyRules) {
        cell.textLabel.text = NFPLocalizedString(@"TARGET_ROW_EDIT_REPLY_RULES");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)self.replyRules.count];
    } else if (indexPath.section == WPRowAction && indexPath.row == WPSubReplyText) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        for (UIView *sub in [cell.contentView subviews]) [sub removeFromSuperview];
        UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 320, 36)];
        field.placeholder = NFPLocalizedString(@"TARGET_REPLY_PLACEHOLDER");
        field.text = self.replyText;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        [field addTarget:self action:@selector(replyChanged:) forControlEvents:UIControlEventEditingChanged];
        self.replyField = field;
        [cell.contentView addSubview:field];
        field.frame = CGRectMake(16, 4, 300, 36);
        BOOL hideReply = [self.action isEqualToString:@"relay"];
        cell.hidden = hideReply;
    }
    return cell;
}

- (void)idChanged:(UITextField *)f { self.targetId = f.text ?: @""; }

- (void)actionChanged:(UISegmentedControl *)seg {
    self.action = @[@"relay", @"reply", @"both"][seg.selectedSegmentIndex];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:WPRowAction] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)replyChanged:(UITextField *)f { self.replyText = f.text ?: @""; }

- (void)enabledChanged:(UISwitch *)sw { self.enabledTarget = sw.on; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == WPRowID) { [self.idField becomeFirstResponder]; return; }
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == WPRowAction && indexPath.row == WPSubReplyRules) {
        NSMutableString *flat = [NSMutableString string];
        for (NSDictionary *r in self.replyRules) {
            NSString *kw = [r[@"kw"] isKindOfClass:[NSString class]] ? r[@"kw"] : @"";
            NSString *tx = [r[@"text"] isKindOfClass:[NSString class]] ? r[@"text"] : @"";
            if (kw.length) [flat appendFormat:@"%@=%@\n", kw, tx];
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NFPLocalizedString(@"TARGET_ROW_EDIT_REPLY_RULES") message:NFPLocalizedString(@"TARGET_REPLY_RULES_HINT") preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.text = flat;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:NFPLocalizedString(@"COMMON_OK") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSMutableArray *arr = [NSMutableArray array];
            for (NSString *line in [alert.textFields.firstObject.text componentsSeparatedByString:@"\n"]) {
                NSRange eq = [line rangeOfString:@"="];
                if (eq.location == NSNotFound) continue;
                NSString *kw = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *tx = [[line substringFromIndex:NSMaxRange(eq)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (kw.length && tx.length) [arr addObject:@{ @"kw": kw, @"text": tx }];
            }
            self.replyRules = arr;
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:WPSubReplyRules inSection:WPRowAction]] withRowAnimation:UITableViewRowAnimationNone];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:NFPLocalizedString(@"COMMON_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
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
    self.saveHandler(@{ @"id": tid, @"enabled": (self.target[@"enabled"] == nil ? @YES : self.target[@"enabled"]), @"contains": self.containsRules ?: @[], @"exclude": self.excludeRules ?: @[], @"action": self.action ?: @"relay", @"reply": self.replyText ?: @"", @"replyRules": self.replyRules ?: @[] });
    [self.navigationController popViewControllerAnimated:YES];
}

@end
