#import "NFPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import "../Shared/NFPreferences.h"
#import "../Shared/NFLogStore.h"
#import "NFPLocalization.h"
#import "NFPRulesListEditorController.h"
#import "NFPWeChatTargetEditorController.h"
#import "NFPLogsListController.h"

@interface NFPRootListController () <UITextViewDelegate>
@end

@implementation NFPRootListController

static NSString * const NFPRulesGroupSpecifierID = @"ROOT_RULES_GROUP";
static NSString * const NFPFilteredLogsSpecifierID = @"ROOT_FILTERED_LOGS";
static NSString * const NFPWeChatTargetsSpecifierID = @"ROOT_WECHAT_TARGETS";
static NSString * const NFPProjectPageURLString = @"https://github.com/777qwq/WXRelay";

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NFPLocalizedString(@"ROOT_TITLE");

}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 移出转场帧，避免回退动画被同步刷新打断
    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; });
}

- (void)dealloc {
}


- (NSArray<NSDictionary *> *)targetListFromPrefs {
    NSDictionary *prefs = [NFPreferences loadPreferences];
    NSArray *list = prefs[NFWeChatTargetsListKey];
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

- (void)openTargetEditorWithIndex:(NSInteger)index {
    NSArray *list = [self targetListFromPrefs];
    NSDictionary *target = (index >= 0 && index < (NSInteger)list.count) ? list[index] : nil;
    __weak typeof(self) weakSelf = self;
    NFPWeChatTargetEditorController *editor = [[NFPWeChatTargetEditorController alloc] initWithTarget:target saveHandler:^(NSDictionary *saved) {
        NSMutableArray *updated = [NSMutableArray arrayWithArray:[weakSelf targetListFromPrefs]];
        if (index >= 0 && index < (NSInteger)updated.count) updated[index] = saved;
        else [updated addObject:saved];
        NSMutableDictionary *preferences = [NFPreferences loadMutablePreferences];
        preferences[NFWeChatTargetsListKey] = updated;
        NSError *error = nil;
        if (![NFPreferences savePreferences:preferences error:&error]) { return; }
        [NFPreferences postPreferencesChangedNotification];
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadSpecifiers]; });
    }];
    [self.navigationController pushViewController:editor animated:YES];
}

- (void)openTargetEditor:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:PSIDKey];
    NSInteger index = [identifier componentsSeparatedByString:@"-"].lastObject.integerValue;
    [self openTargetEditorWithIndex:index];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    NSString *ident = sp ? ([sp propertyForKey:PSIDKey] ?: @"") : @"";
    return [ident hasPrefix:@"target-"];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    NSString *ident = sp ? ([sp propertyForKey:PSIDKey] ?: @"") : @"";
    if (![ident hasPrefix:@"target-"]) return;
    NSInteger index = [ident componentsSeparatedByString:@"-"].lastObject.integerValue;
    NSMutableArray *list = [NSMutableArray arrayWithArray:[self targetListFromPrefs]];
    if (index < 0 || index >= (NSInteger)list.count) return;
    [list removeObjectAtIndex:index];
    NSMutableDictionary *preferences = [NFPreferences loadMutablePreferences];
    preferences[NFWeChatTargetsListKey] = list;
    NSError *error = nil;
    if (![NFPreferences savePreferences:preferences error:&error]) { return; }
    [NFPreferences postPreferencesChangedNotification];
    [self reloadSpecifiers];
}

- (void)targetSwitchChanged:(UISwitch *)sw {
    NSInteger index = (NSInteger)sw.tag;
    NSArray *list = [self targetListFromPrefs];
    if (index < 0 || index >= (NSInteger)list.count) return;
    NSMutableDictionary *t = [NSMutableDictionary dictionaryWithDictionary:list[index]];
    t[@"enabled"] = @(sw.on);
    NSMutableArray *updated = [NSMutableArray arrayWithArray:list];
    updated[index] = t;
    NSMutableDictionary *preferences = [NFPreferences loadMutablePreferences];
    preferences[NFWeChatTargetsListKey] = updated;
    NSError *error = nil;
    if (![NFPreferences savePreferences:preferences error:&error]) { return; }
    [NFPreferences postPreferencesChangedNotification];
}

- (NSString *)targetRowSummary:(NSDictionary *)t {
    // 信息从编辑器上浮一层：关键词数 · 排除数 · 白名单 App 数
    NSArray *contains = [t[@"contains"] isKindOfClass:[NSArray class]] ? t[@"contains"] : @[];
    NSArray *exclude = [t[@"exclude"] isKindOfClass:[NSArray class]] ? t[@"exclude"] : @[];
    NSArray *apps = [t[@"apps"] isKindOfClass:[NSArray class]] ? t[@"apps"] : @[];
    BOOL enabled = t[@"enabled"] == nil ? YES : [t[@"enabled"] boolValue];
    NSMutableString *out = [NSMutableString string];
    if (!enabled) [out appendString:@"已停用 · "];
    [out appendFormat:@"%lu 关键词", (unsigned long)contains.count];
    if (exclude.count) [out appendFormat:@" · 排除 %lu", (unsigned long)exclude.count];
    [out appendFormat:@" · 白名单 %lu App", (unsigned long)apps.count];
    return out;
}

- (NSString *)wechatTargetsSummary {
    NSDictionary *prefs = [NFPreferences loadPreferences];
    NSArray *list = prefs[NFWeChatTargetsListKey];
    return [NSString stringWithFormat:@"%lu 个目标", (unsigned long)([list isKindOfClass:[NSArray class]] ? list.count : 0)];
}

- (NSString *)filteredLogsSummary {
    return [NSString stringWithFormat:NFPLocalizedString(@"ROOT_SUMMARY_LOG_COUNT_FORMAT"),
                                      (unsigned long)[NFLogStore loadEntries].count];
}

- (NSArray *)specifiers {
    if (_specifiers) {
        return _specifiers;
    }

    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *toggleGroup = [PSSpecifier emptyGroupSpecifier];
    [toggleGroup setProperty:NFPLocalizedString(@"ROOT_TOGGLE_FOOTER") forKey:PSFooterTextGroupKey];
    [specifiers addObject:toggleGroup];

    PSSpecifier *enabledSpecifier = [PSSpecifier preferenceSpecifierNamed:NFPLocalizedString(@"ROOT_ENABLE_FILTER")
                                                                   target:self
                                                                      set:@selector(setPreferenceValue:specifier:)
                                                                      get:@selector(readPreferenceValue:)
                                                                   detail:nil
                                                                     cell:PSSwitchCell
                                                                     edit:nil];
    [enabledSpecifier setProperty:NFEnabledKey forKey:PSKeyNameKey];
    [enabledSpecifier setProperty:@YES forKey:PSDefaultValueKey];
    [specifiers addObject:enabledSpecifier];

    PSSpecifier *targetsGroup = [PSSpecifier emptyGroupSpecifier];
    [targetsGroup setProperty:NFPLocalizedString(@"ROOT_TARGETS_FOOTER") forKey:PSFooterTextGroupKey];
    [specifiers addObject:targetsGroup];

    PSSpecifier *targetsTitle = [PSSpecifier preferenceSpecifierNamed:NFPLocalizedString(@"ROOT_TARGETS_TITLE")
                                                                target:self
                                                                   set:nil
                                                                   get:nil
                                                                detail:nil
                                                                  cell:PSLinkCell
                                                                  edit:nil];
    targetsTitle->action = @selector(addTargetTapped:);
    [targetsTitle setProperty:@"addTargetTapped:" forKey:PSActionKey];
    [targetsTitle setProperty:@"targets-title" forKey:PSIDKey];
    [specifiers addObject:targetsTitle];

    NSDictionary *prefs = [NFPreferences loadPreferences];
    NSArray *targetList = prefs[NFWeChatTargetsListKey];
    if ([targetList isKindOfClass:[NSArray class]]) {
        [targetList enumerateObjectsUsingBlock:^(NSDictionary *t, NSUInteger idx, BOOL *stop) {
            NSString *tid = [t[@"id"] isKindOfClass:[NSString class]] ? t[@"id"] : @"";
            NSString *identifier = [NSString stringWithFormat:@"target-%lu", (unsigned long)idx];
            PSSpecifier *row = [self linkSpecifierWithName:(tid.length ? tid : @"(未命名)")
                                                     action:@selector(openTargetEditor:)
                                                 identifier:identifier];
            [specifiers addObject:row];
        }];
    }

    PSSpecifier *logGroup = [PSSpecifier emptyGroupSpecifier];
    [logGroup setProperty:NFPLocalizedString(@"ROOT_LOGGING_FOOTER") forKey:PSFooterTextGroupKey];
    [specifiers addObject:logGroup];

    PSSpecifier *logEnabledSpecifier = [PSSpecifier preferenceSpecifierNamed:NFPLocalizedString(@"ROOT_LOGGING")
                                                                      target:self
                                                                         set:@selector(setPreferenceValue:specifier:)
                                                                         get:@selector(readPreferenceValue:)
                                                                      detail:nil
                                                                        cell:PSSwitchCell
                                                                        edit:nil];
    [logEnabledSpecifier setProperty:NFLoggingEnabledKey forKey:PSKeyNameKey];
    [logEnabledSpecifier setProperty:@YES forKey:PSDefaultValueKey];
    [specifiers addObject:logEnabledSpecifier];

    [specifiers addObject:[self linkSpecifierWithName:NFPLocalizedString(@"ROOT_FORWARDED_LOGS")
                                               action:@selector(openLogs:)
                                           identifier:NFPFilteredLogsSpecifierID]];

    _specifiers = [specifiers copy];
    return _specifiers;
}


- (PSSpecifier *)linkSpecifierWithName:(NSString *)name
                                action:(SEL)action
                            identifier:(NSString *)identifier {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:nil
                                                               get:@selector(readLinkSummary:)
                                                            detail:nil
                                                              cell:PSLinkCell
                                                              edit:nil];
    specifier->action = action;
    [specifier setProperty:NSStringFromSelector(action) forKey:PSActionKey];
    [specifier setProperty:identifier forKey:PSIDKey];
    return specifier;
}

// PSSpecifier has no `value` property; PSTableCell resolves the right-hand text
// through performGetter, so a link row must supply a get selector. Returning nil
// leaves the row without a summary (import/export).
- (id)readLinkSummary:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:PSIDKey];
    if ([identifier isEqualToString:NFPWeChatTargetsSpecifierID]) {
        return [self wechatTargetsSummary];
    }
    if ([identifier hasPrefix:@"target-"]) {
        NSInteger index = [[identifier substringFromIndex:@"target-".length] integerValue];
        NSArray *list = [self targetListFromPrefs];
        if (index < (NSInteger)list.count) return [self targetRowSummary:list[index]];
    }
    if ([identifier isEqualToString:NFPFilteredLogsSpecifierID]) {
        return [self filteredLogsSummary];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    NSString *ident = sp ? ([sp propertyForKey:PSIDKey] ?: @"") : @"";
    if ([ident isEqualToString:@"targets-title"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self openTargetEditorWithIndex:-1];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    // Belt and braces: some PSTableCell styles ignore the getter, so write the
    // summary straight onto the cell's value label when one exists.
    NSString *summary = [self readLinkSummary:[self specifierAtIndexPath:indexPath]];
    PSSpecifier *rowSpecifier = [self specifierAtIndexPath:indexPath];
    NSString *cellIdentifier = rowSpecifier ? ([rowSpecifier propertyForKey:PSIDKey] ?: @"") : @"";
    if ([cellIdentifier isEqualToString:@"targets-title"]) {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.text = nil;
        return cell;
    }
    if (summary.length > 0 && cell.detailTextLabel != nil) {
        cell.detailTextLabel.text = summary;
    }
    // 目标行：右侧挂独立开关
    if ([cellIdentifier hasPrefix:@"target-"]) {
        NSInteger index = [cellIdentifier componentsSeparatedByString:@"-"].lastObject.integerValue;
        NSArray *list = [self targetListFromPrefs];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.accessibilityIdentifier = @"wxrelay-target-switch";
        sw.tag = index;
        if (index < (NSInteger)list.count) {
            NSDictionary *t = list[index];
            sw.on = t[@"enabled"] == nil ? YES : [t[@"enabled"] boolValue];
        }
        [sw addTarget:self action:@selector(targetSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.75;
    } else if ([cell.accessoryView isKindOfClass:[UISwitch class]]
               && [cell.accessoryView.accessibilityIdentifier isEqualToString:@"wxrelay-target-switch"]) {
        cell.accessoryView = nil; // 只清我们自己挂的开关，别动 PSSwitchCell 的系统开关
    }
    return cell;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *preferences = [NFPreferences loadPreferences];
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    id value = preferences[key];
    if (value) {
        return value;
    }
    return [specifier propertyForKey:PSDefaultValueKey];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *preferences = [NFPreferences loadMutablePreferences];
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    if (key.length == 0) {
        return;
    }

    preferences[key] = value ?: [specifier propertyForKey:PSDefaultValueKey] ?: @NO;

    NSError *error = nil;
    if (![NFPreferences savePreferences:preferences error:&error]) {
        [self presentError:error];
        return;
    }

    [NFPreferences postPreferencesChangedNotification];
}

- (void)openLogs:(PSSpecifier *)specifier {
    NFPLogsListController *controller = [[NFPLogsListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:controller animated:YES];
}

- (BOOL)openProjectPageURL {
    NSURL *projectURL = [NSURL URLWithString:NFPProjectPageURLString];
    if (projectURL == nil) {
        return NO;
    }

    UIApplication *application = [UIApplication sharedApplication];
    if (@available(iOS 10.0, *)) {
        [application openURL:projectURL options:@{} completionHandler:nil];
        return YES;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [application openURL:projectURL];
#pragma clang diagnostic pop
    return YES;
}

- (BOOL)isRulesFooterSection:(NSInteger)section {
    NSInteger group = NSNotFound;
    NSInteger row = NSNotFound;
    if (![self getGroup:&group row:&row ofSpecifierID:NFPRulesGroupSpecifierID]) {
        return NO;
    }
    return group == section;
}

- (NSAttributedString *)rulesFooterAttributedText {
    NSString *footerText = NFPLocalizedString(@"ROOT_RULES_FOOTER") ?: @"";
    NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:footerText
                                                                                        attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0],
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
    }];

    NSString *linkText = NFPLocalizedString(@"ROOT_PROJECT_LINK_TEXT");
    NSRange linkRange = [footerText rangeOfString:linkText];
    if (linkRange.location != NSNotFound) {
        [attributedText addAttribute:NSLinkAttributeName value:NFPProjectPageURLString range:linkRange];
    }

    return attributedText;
}

- (UITextView *)rulesFooterTextViewWithWidth:(CGFloat)width {
    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 1.0)];
    textView.backgroundColor = [UIColor clearColor];
    textView.delegate = self;
    textView.editable = NO;
    textView.scrollEnabled = NO;
    textView.selectable = YES;
    textView.attributedText = [self rulesFooterAttributedText];
    textView.linkTextAttributes = @{
        NSForegroundColorAttributeName: self.footerHyperlinkColor ?: [UIColor linkColor],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
    };
    textView.textContainerInset = UIEdgeInsetsZero;
    textView.textContainer.lineFragmentPadding = 0.0;
    return textView;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (![self isRulesFooterSection:section]) {
        return nil;
    }

    UIView *containerView = [[UIView alloc] initWithFrame:CGRectZero];
    containerView.backgroundColor = [UIColor clearColor];

    UITextView *textView = [self rulesFooterTextViewWithWidth:CGRectGetWidth(tableView.bounds) - 32.0];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:textView];

    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:4.0],
        [textView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:20.0],
        [textView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-20.0],
        [textView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0]
    ]];

    return containerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (![self isRulesFooterSection:section]) {
        return UITableViewAutomaticDimension;
    }

    CGFloat availableWidth = MAX(CGRectGetWidth(tableView.bounds) - 40.0, 0.0);
    UITextView *textView = [self rulesFooterTextViewWithWidth:availableWidth];
    CGSize fittingSize = [textView sizeThatFits:CGSizeMake(availableWidth, CGFLOAT_MAX)];
    return ceil(fittingSize.height) + 12.0;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForFooterInSection:(NSInteger)section {
    if (![self isRulesFooterSection:section]) {
        return UITableViewAutomaticDimension;
    }
    return 60.0;
}

- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL inRange:(NSRange)characterRange interaction:(UITextItemInteraction)interaction API_AVAILABLE(ios(10.0)) {
    [self openProjectPageURL];
    return NO;
}

- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL inRange:(NSRange)characterRange {
    [self openProjectPageURL];
    return NO;
}

- (void)presentError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NFPLocalizedString(@"COMMON_SAVE_FAILED")
                                                                   message:error.localizedDescription ?: NFPLocalizedString(@"ROOT_SAVE_FAILED_MESSAGE")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NFPLocalizedString(@"COMMON_OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
