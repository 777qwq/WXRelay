#import "WXPNotificationRuleTokenPickerController.h"
#import "../Shared/WXPreferences.h"
#import "WXPLocalization.h"
#import "WXPNotificationRuleTokenBuilder.h"

static const CGFloat WXPTokenHorizontalSpacing = 4.0;
static const CGFloat WXPTokenVerticalSpacing = 5.0;
static const CGFloat WXPTokenMinimumWidth = 24.0;
static const CGFloat WXPTokenMinimumHeight = 26.0;
static const CGFloat WXPTokenMaximumWidth = 168.0;
static const CGFloat WXPTokenDragHitOutset = 5.0;
static const CGFloat WXPTokenDragSampleDistance = 4.0;
static const CGFloat WXPTokenMinimumTouchSize = 30.0;

@interface WXPTokenButton : UIButton

@property (nonatomic, assign) UIEdgeInsets visualContentInsets;

@end

@implementation WXPTokenButton

- (CGSize)sizeThatFits:(CGSize)size {
    UIEdgeInsets insets = self.visualContentInsets;
    CGFloat titleMaxWidth = MAX(0.0, size.width - insets.left - insets.right);
    CGSize titleSize = [self.titleLabel sizeThatFits:CGSizeMake(titleMaxWidth, CGFLOAT_MAX)];
    return CGSizeMake(ceil(titleSize.width + insets.left + insets.right),
                      ceil(titleSize.height + insets.top + insets.bottom));
}

- (CGRect)titleRectForContentRect:(CGRect)contentRect {
    return UIEdgeInsetsInsetRect(contentRect, self.visualContentInsets);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat horizontalInset = MIN(0.0, (CGRectGetWidth(self.bounds) - WXPTokenMinimumTouchSize) / 2.0);
    CGFloat verticalInset = MIN(0.0, (CGRectGetHeight(self.bounds) - WXPTokenMinimumTouchSize) / 2.0);
    CGRect hitFrame = CGRectInset(self.bounds, horizontalInset, verticalInset);
    return CGRectContainsPoint(hitFrame, point);
}

@end

@interface WXPTokenFlowView : UIView

@property (nonatomic, assign) UIEdgeInsets contentInsets;
@property (nonatomic, assign) CGFloat horizontalSpacing;
@property (nonatomic, assign) CGFloat verticalSpacing;
@property (nonatomic, assign) CGFloat minimumTokenWidth;
@property (nonatomic, assign) CGFloat minimumTokenHeight;
@property (nonatomic, assign) CGFloat maximumTokenWidth;

- (void)addTokenView:(UIView *)tokenView;

@end

@implementation WXPTokenFlowView {
    NSMutableArray<UIView *> *_tokenViews;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _tokenViews = [NSMutableArray array];
        _contentInsets = UIEdgeInsetsZero;
        _horizontalSpacing = WXPTokenHorizontalSpacing;
        _verticalSpacing = WXPTokenVerticalSpacing;
        _minimumTokenWidth = WXPTokenMinimumWidth;
        _minimumTokenHeight = WXPTokenMinimumHeight;
        _maximumTokenWidth = WXPTokenMaximumWidth;
    }
    return self;
}

- (void)addTokenView:(UIView *)tokenView {
    if (!tokenView) {
        return;
    }

    [_tokenViews addObject:tokenView];
    [self addSubview:tokenView];
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
}

- (void)setBounds:(CGRect)bounds {
    CGFloat oldWidth = CGRectGetWidth(self.bounds);
    [super setBounds:bounds];
    if (fabs(oldWidth - CGRectGetWidth(bounds)) > 0.5) {
        [self invalidateIntrinsicContentSize];
    }
}

- (CGSize)intrinsicContentSize {
    CGFloat width = CGRectGetWidth(self.bounds);
    if (width <= 0.0) {
        width = UIScreen.mainScreen.bounds.size.width - 56.0;
    }
    return CGSizeMake(UIViewNoIntrinsicMetric, [self heightForWidth:width]);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, [self heightForWidth:size.width]);
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize
         withHorizontalFittingPriority:(UILayoutPriority)horizontalFittingPriority
               verticalFittingPriority:(UILayoutPriority)verticalFittingPriority {
    CGFloat width = targetSize.width > 0.0 ? targetSize.width : CGRectGetWidth(self.bounds);
    if (width <= 0.0) {
        width = UIScreen.mainScreen.bounds.size.width - 56.0;
    }
    return CGSizeMake(width, [self heightForWidth:width]);
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize {
    return [self systemLayoutSizeFittingSize:targetSize
               withHorizontalFittingPriority:UILayoutPriorityFittingSizeLevel
                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutTokenViewsForWidth:CGRectGetWidth(self.bounds) applyFrames:YES];
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutTokenViewsForWidth:width applyFrames:NO];
}

- (CGFloat)layoutTokenViewsForWidth:(CGFloat)width applyFrames:(BOOL)applyFrames {
    CGFloat availableWidth = MAX(0.0, width - self.contentInsets.left - self.contentInsets.right);
    if (availableWidth <= 0.0 || _tokenViews.count == 0) {
        return self.contentInsets.top + self.contentInsets.bottom;
    }

    CGFloat x = 0.0;
    CGFloat y = self.contentInsets.top;
    CGFloat rowHeight = 0.0;

    for (UIView *tokenView in _tokenViews) {
        CGSize tokenSize = [self sizeForTokenView:tokenView availableWidth:availableWidth];
        if (x > 0.0 && x + tokenSize.width > availableWidth) {
            y += rowHeight + self.verticalSpacing;
            x = 0.0;
            rowHeight = 0.0;
        }

        if (applyFrames) {
            tokenView.frame = CGRectMake(self.contentInsets.left + x, y, tokenSize.width, tokenSize.height);
        }

        x += tokenSize.width + self.horizontalSpacing;
        rowHeight = MAX(rowHeight, tokenSize.height);
    }

    return y + rowHeight + self.contentInsets.bottom;
}

- (CGSize)sizeForTokenView:(UIView *)tokenView availableWidth:(CGFloat)availableWidth {
    CGFloat cappedMaximumWidth = MIN(MAX(self.minimumTokenWidth, self.maximumTokenWidth), availableWidth);
    CGSize fittingSize = [tokenView sizeThatFits:CGSizeMake(cappedMaximumWidth, CGFLOAT_MAX)];
    CGFloat width = MIN(MAX(ceil(fittingSize.width), self.minimumTokenWidth), cappedMaximumWidth);
    CGFloat height = MAX(ceil(fittingSize.height), self.minimumTokenHeight);
    return CGSizeMake(width, height);
}

@end

@interface WXPNotificationRuleTokenPickerController () <UIGestureRecognizerDelegate>

@property (nonatomic, copy) NSDictionary *entry;
@property (nonatomic, copy) NSString *appDisplayName;
@property (nonatomic, copy) NSString *ruleMode;
@property (nonatomic, assign) WXPRuleEditorKind initialRuleKind;
@property (nonatomic, assign) WXPRuleEditorKind selectedRuleKind;
@property (nonatomic, weak, nullable) UIViewController *returnViewController;
@property (nonatomic, assign) WXPNotificationRuleTokenReturnMode returnMode;
@property (nonatomic, copy) WXPNotificationRuleTokenCommitHandler commitHandler;
@property (nonatomic, copy) NSArray<NSDictionary *> *tokenSections;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedTokenKeys;
@property (nonatomic, strong) UIStackView *tokenStackView;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIButton *> *sectionSelectButtons;
@property (nonatomic, strong) UILongPressGestureRecognizer *tokenDragGestureRecognizer;
@property (nonatomic, strong) NSMutableSet<NSString *> *dragToggledTokenKeys;
@property (nonatomic, strong) UISelectionFeedbackGenerator *tokenSelectionFeedbackGenerator;
@property (nonatomic, assign) CGPoint lastTokenDragPoint;
@property (nonatomic, assign) BOOL hasLastTokenDragPoint;
@property (nonatomic, assign) BOOL tokenDragActive;

@end

@implementation WXPNotificationRuleTokenPickerController

- (instancetype)initWithNotificationEntry:(NSDictionary *)entry
                          appDisplayName:(NSString *)appDisplayName
                          initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString *)ruleMode
                     returnViewController:(UIViewController *)returnViewController
                            commitHandler:(WXPNotificationRuleTokenCommitHandler)commitHandler {
    return [self initWithNotificationEntry:entry
                            appDisplayName:appDisplayName
                            initialRuleKind:initialRuleKind
                                  ruleMode:ruleMode
                       returnViewController:returnViewController
                                 returnMode:WXPNotificationRuleTokenReturnModeRulesList
                              commitHandler:commitHandler];
}

- (instancetype)initWithNotificationEntry:(NSDictionary *)entry
                          appDisplayName:(NSString *)appDisplayName
                          initialRuleKind:(WXPRuleEditorKind)initialRuleKind
                                 ruleMode:(NSString *)ruleMode
                     returnViewController:(UIViewController *)returnViewController
                               returnMode:(WXPNotificationRuleTokenReturnMode)returnMode
                            commitHandler:(WXPNotificationRuleTokenCommitHandler)commitHandler {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _entry = [entry copy] ?: @{};
        _appDisplayName = [appDisplayName copy] ?: @"";
        _ruleMode = [[WXPreferences normalizedRulesMode:ruleMode] copy];
        _initialRuleKind = initialRuleKind == WXPRuleEditorKindExclude ? WXPRuleEditorKindExclude : WXPRuleEditorKindContains;
        _selectedRuleKind = initialRuleKind == WXPRuleEditorKindExclude ? WXPRuleEditorKindExclude : WXPRuleEditorKindContains;
        _returnViewController = returnViewController;
        _returnMode = returnMode;
        _commitHandler = [commitHandler copy];
        _selectedTokenKeys = [NSMutableSet set];
        _dragToggledTokenKeys = [NSMutableSet set];
        _sectionSelectButtons = [NSMutableDictionary dictionary];
        _tokenSections = [WXPNotificationRuleTokenBuilder tokenSectionsFromNotificationEntry:_entry];
        self.title = WXPLocalizedString(@"RULE_SCAN_PICKER_TITLE");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WXPLocalizedString(@"COMMON_SAVE")
                                                                               style:UIBarButtonItemStyleDone
                                                                              target:self
                                                                              action:@selector(saveTapped)];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scrollView];

    UIStackView *contentStack = [[UIStackView alloc] init];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.spacing = 16.0;
    [scrollView addSubview:contentStack];

    UILabel *summaryLabel = [[UILabel alloc] init];
    summaryLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    summaryLabel.textColor = [UIColor secondaryLabelColor];
    summaryLabel.text = WXPLocalizedString(@"RULE_SCAN_NOTIFICATION_LABEL");
    [contentStack addArrangedSubview:summaryLabel];

    UITextView *summaryTextView = [[UITextView alloc] init];
    summaryTextView.translatesAutoresizingMaskIntoConstraints = NO;
    summaryTextView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    summaryTextView.textContainerInset = UIEdgeInsetsMake(12.0, 12.0, 12.0, 12.0);
    summaryTextView.layer.cornerRadius = 14.0;
    summaryTextView.editable = NO;
    summaryTextView.scrollEnabled = NO;
    summaryTextView.font = [UIFont systemFontOfSize:15.0];
    summaryTextView.text = [self notificationSummaryText];
    [contentStack addArrangedSubview:summaryTextView];

    UILabel *ruleTypeLabel = [[UILabel alloc] init];
    ruleTypeLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    ruleTypeLabel.textColor = [UIColor secondaryLabelColor];
    ruleTypeLabel.text = WXPLocalizedString(@"RULE_SCAN_RULE_TYPE_LABEL");
    [contentStack addArrangedSubview:ruleTypeLabel];

    UISegmentedControl *ruleKindControl = [[UISegmentedControl alloc] initWithItems:@[
        WXPLocalizedRuleEditorTitleForMode(WXPRuleEditorKindContains, self.ruleMode),
        WXPLocalizedRuleEditorTitleForMode(WXPRuleEditorKindExclude, self.ruleMode)
    ]];
    ruleKindControl.selectedSegmentIndex = self.selectedRuleKind == WXPRuleEditorKindExclude ? 1 : 0;
    [ruleKindControl addTarget:self action:@selector(ruleKindChanged:) forControlEvents:UIControlEventValueChanged];
    [contentStack addArrangedSubview:ruleKindControl];

    UILabel *tokenLabel = [[UILabel alloc] init];
    tokenLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    tokenLabel.textColor = [UIColor secondaryLabelColor];
    tokenLabel.text = WXPLocalizedString(@"RULE_SCAN_TOKENS_LABEL");
    [contentStack addArrangedSubview:tokenLabel];

    UIView *tokenContainer = [[UIView alloc] init];
    tokenContainer.translatesAutoresizingMaskIntoConstraints = NO;
    tokenContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tokenContainer.layer.cornerRadius = 14.0;
    [contentStack addArrangedSubview:tokenContainer];

    UIStackView *tokenStackView = [[UIStackView alloc] init];
    tokenStackView.translatesAutoresizingMaskIntoConstraints = NO;
    tokenStackView.axis = UILayoutConstraintAxisVertical;
    tokenStackView.spacing = 8.0;
    [tokenContainer addSubview:tokenStackView];
    self.tokenStackView = tokenStackView;

    UILongPressGestureRecognizer *tokenDragGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                                             action:@selector(tokenDragGestureRecognized:)];
    tokenDragGestureRecognizer.minimumPressDuration = 0.0;
    tokenDragGestureRecognizer.allowableMovement = CGFLOAT_MAX;
    tokenDragGestureRecognizer.cancelsTouchesInView = YES;
    tokenDragGestureRecognizer.delegate = self;
    [tokenContainer addGestureRecognizer:tokenDragGestureRecognizer];
    self.tokenDragGestureRecognizer = tokenDragGestureRecognizer;

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [contentStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16.0],
        [contentStack.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:16.0],
        [contentStack.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-16.0],
        [contentStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24.0],

        [summaryTextView.heightAnchor constraintGreaterThanOrEqualToConstant:120.0],
        [tokenStackView.topAnchor constraintEqualToAnchor:tokenContainer.topAnchor constant:10.0],
        [tokenStackView.leadingAnchor constraintEqualToAnchor:tokenContainer.leadingAnchor constant:10.0],
        [tokenStackView.trailingAnchor constraintEqualToAnchor:tokenContainer.trailingAnchor constant:-10.0],
        [tokenStackView.bottomAnchor constraintEqualToAnchor:tokenContainer.bottomAnchor constant:-10.0]
    ]];

    [self rebuildTokenButtons];
}

- (NSString *)notificationSummaryText {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:WXPLocalizedString(@"LOG_DETAIL_APP_FORMAT"), self.appDisplayName.length > 0 ? self.appDisplayName : WXPLocalizedString(@"APP_UNKNOWN")]];

    void (^appendField)(NSString *, NSString *) = ^(NSString *labelFormat, NSString *value) {
        NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [lines addObject:[NSString stringWithFormat:labelFormat, trimmed]];
        }
    };

    appendField(WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_TITLE_FORMAT"), [self.entry[WXLogTitleKey] isKindOfClass:[NSString class]] ? self.entry[WXLogTitleKey] : @"");
    appendField(WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_SUBTITLE_FORMAT"), [self.entry[WXLogSubtitleKey] isKindOfClass:[NSString class]] ? self.entry[WXLogSubtitleKey] : @"");
    appendField(WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_HEADER_FORMAT"), [self.entry[WXLogHeaderKey] isKindOfClass:[NSString class]] ? self.entry[WXLogHeaderKey] : @"");
    appendField(WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_BODY_FORMAT"), [self.entry[WXLogBodyKey] isKindOfClass:[NSString class]] ? self.entry[WXLogBodyKey] : @"");
    appendField(WXPLocalizedString(@"LOG_DETAIL_NOTIFICATION_MESSAGE_FORMAT"), [self.entry[WXLogMessageKey] isKindOfClass:[NSString class]] ? self.entry[WXLogMessageKey] : @"");
    return [lines componentsJoinedByString:@"\n"];
}

- (void)rebuildTokenButtons {
    for (UIView *subview in self.tokenStackView.arrangedSubviews) {
        [self.tokenStackView removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }
    [self.sectionSelectButtons removeAllObjects];

    if (self.tokenSections.count == 0) {
        UILabel *emptyLabel = [[UILabel alloc] init];
        emptyLabel.text = WXPLocalizedString(@"RULE_SCAN_NO_TOKENS");
        emptyLabel.textColor = [UIColor secondaryLabelColor];
        emptyLabel.numberOfLines = 0;
        [self.tokenStackView addArrangedSubview:emptyLabel];
        return;
    }

    for (NSDictionary *section in self.tokenSections) {
        NSString *scope = section[WXPNotificationRuleTokenSectionScopeKey];
        NSArray<NSString *> *tokens = [section[WXPNotificationRuleTokenSectionTokensKey] isKindOfClass:[NSArray class]] ? section[WXPNotificationRuleTokenSectionTokensKey] : @[];
        if (tokens.count == 0) {
            continue;
        }

        UIStackView *sectionHeader = [[UIStackView alloc] init];
        sectionHeader.axis = UILayoutConstraintAxisHorizontal;
        sectionHeader.alignment = UIStackViewAlignmentCenter;
        sectionHeader.spacing = 8.0;

        UILabel *sectionLabel = [[UILabel alloc] init];
        sectionLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        sectionLabel.textColor = [UIColor secondaryLabelColor];
        sectionLabel.text = WXPLocalizedScopeName(scope);
        [sectionHeader addArrangedSubview:sectionLabel];

        UIView *spacer = [[UIView alloc] init];
        [sectionHeader addArrangedSubview:spacer];

        UIButton *selectButton = [UIButton buttonWithType:UIButtonTypeSystem];
        selectButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        selectButton.accessibilityIdentifier = scope ?: @"";
        [selectButton addTarget:self action:@selector(sectionSelectButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [sectionHeader addArrangedSubview:selectButton];

        self.sectionSelectButtons[scope ?: @""] = selectButton;
        [self.tokenStackView addArrangedSubview:sectionHeader];

        WXPTokenFlowView *flowView = [[WXPTokenFlowView alloc] initWithFrame:CGRectZero];
        flowView.translatesAutoresizingMaskIntoConstraints = NO;
        flowView.horizontalSpacing = WXPTokenHorizontalSpacing;
        flowView.verticalSpacing = WXPTokenVerticalSpacing;
        flowView.minimumTokenWidth = WXPTokenMinimumWidth;
        flowView.minimumTokenHeight = WXPTokenMinimumHeight;
        flowView.maximumTokenWidth = WXPTokenMaximumWidth;
        [self.tokenStackView addArrangedSubview:flowView];

        for (NSUInteger tokenIndex = 0; tokenIndex < tokens.count; tokenIndex++) {
            NSString *token = tokens[tokenIndex];
            NSString *selectionKey = [WXPNotificationRuleTokenBuilder selectionKeyForScope:scope tokenIndex:tokenIndex token:token];
            WXPTokenButton *button = [WXPTokenButton buttonWithType:UIButtonTypeSystem];
            button.accessibilityIdentifier = selectionKey;
            button.visualContentInsets = UIEdgeInsetsMake(3.0, 6.0, 3.0, 6.0);
            button.layer.cornerRadius = 7.0;
            button.layer.borderWidth = 1.0;
            button.titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
            button.titleLabel.numberOfLines = 1;
            button.titleLabel.adjustsFontSizeToFitWidth = YES;
            button.titleLabel.minimumScaleFactor = 0.78;
            button.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
            [button setTitle:token forState:UIControlStateNormal];
            [button addTarget:self action:@selector(tokenTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self updateAppearanceForTokenButton:button selected:[self.selectedTokenKeys containsObject:selectionKey]];
            [flowView addTokenView:button];
        }
    }

    [self updateSectionSelectButtons];
}

- (NSArray<NSString *> *)selectionKeysForSectionScope:(NSString *)scope {
    NSString *targetScope = scope ?: @"";
    NSMutableArray<NSString *> *selectionKeys = [NSMutableArray array];
    for (NSDictionary *section in self.tokenSections) {
        NSString *sectionScope = [section[WXPNotificationRuleTokenSectionScopeKey] isKindOfClass:[NSString class]] ? section[WXPNotificationRuleTokenSectionScopeKey] : @"";
        if (![sectionScope isEqualToString:targetScope]) {
            continue;
        }

        NSArray<NSString *> *tokens = [section[WXPNotificationRuleTokenSectionTokensKey] isKindOfClass:[NSArray class]] ? section[WXPNotificationRuleTokenSectionTokensKey] : @[];
        for (NSUInteger tokenIndex = 0; tokenIndex < tokens.count; tokenIndex++) {
            [selectionKeys addObject:[WXPNotificationRuleTokenBuilder selectionKeyForScope:sectionScope tokenIndex:tokenIndex token:tokens[tokenIndex]]];
        }
    }
    return selectionKeys;
}

- (BOOL)sectionScopeIsFullySelected:(NSString *)scope {
    NSArray<NSString *> *selectionKeys = [self selectionKeysForSectionScope:scope];
    if (selectionKeys.count == 0) {
        return NO;
    }

    for (NSString *selectionKey in selectionKeys) {
        if (![self.selectedTokenKeys containsObject:selectionKey]) {
            return NO;
        }
    }
    return YES;
}

- (void)sectionSelectButtonTapped:(UIButton *)sender {
    NSString *scope = sender.accessibilityIdentifier ?: @"";
    NSArray<NSString *> *selectionKeys = [self selectionKeysForSectionScope:scope];
    if (selectionKeys.count == 0) {
        return;
    }

    NSSet<NSString *> *selectionSet = [NSSet setWithArray:selectionKeys];
    if ([self sectionScopeIsFullySelected:scope]) {
        [self.selectedTokenKeys minusSet:selectionSet];
    } else {
        [self.selectedTokenKeys unionSet:selectionSet];
    }

    [self emitTokenSelectionFeedback];
    [self updateAllTokenButtonAppearances];
    [self updateSectionSelectButtons];
}

- (void)updateAllTokenButtonAppearances {
    [self enumerateTokenButtonsUsingBlock:^(WXPTokenButton *button, BOOL *stop) {
        [self updateAppearanceForTokenButton:button selected:[self.selectedTokenKeys containsObject:button.accessibilityIdentifier]];
    }];
}

- (void)updateSectionSelectButtons {
    [self.sectionSelectButtons enumerateKeysAndObjectsUsingBlock:^(NSString *scope, UIButton *button, BOOL *stop) {
        BOOL selected = [self sectionScopeIsFullySelected:scope];
        [button setTitle:WXPLocalizedString(selected ? @"COMMON_DESELECT_ALL" : @"COMMON_SELECT_ALL") forState:UIControlStateNormal];
    }];
}

- (void)tokenTapped:(UIButton *)sender {
    [self toggleTokenButton:sender trackingCurrentDrag:NO];
}

- (void)toggleTokenButton:(UIButton *)button trackingCurrentDrag:(BOOL)trackingCurrentDrag {
    NSString *selectionKey = button.accessibilityIdentifier;
    if (selectionKey.length == 0) {
        return;
    }

    if (trackingCurrentDrag) {
        if ([self.dragToggledTokenKeys containsObject:selectionKey]) {
            return;
        }
        [self.dragToggledTokenKeys addObject:selectionKey];
    }

    BOOL selected = ![self.selectedTokenKeys containsObject:selectionKey];
    if (selected) {
        [self.selectedTokenKeys addObject:selectionKey];
    } else {
        [self.selectedTokenKeys removeObject:selectionKey];
    }

    [self emitTokenSelectionFeedback];
    [self updateAppearanceForTokenButton:button selected:selected];
    [self updateSectionSelectButtons];
}

- (void)emitTokenSelectionFeedback {
    if (!self.tokenSelectionFeedbackGenerator) {
        self.tokenSelectionFeedbackGenerator = [[UISelectionFeedbackGenerator alloc] init];
    }
    [self.tokenSelectionFeedbackGenerator selectionChanged];
    [self.tokenSelectionFeedbackGenerator prepare];
}

- (void)tokenDragGestureRecognized:(UILongPressGestureRecognizer *)gestureRecognizer {
    CGPoint point = [gestureRecognizer locationInView:self.tokenStackView];

    switch (gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan:
            self.tokenDragActive = YES;
            self.hasLastTokenDragPoint = NO;
            [self.dragToggledTokenKeys removeAllObjects];
            self.tokenSelectionFeedbackGenerator = [[UISelectionFeedbackGenerator alloc] init];
            [self.tokenSelectionFeedbackGenerator prepare];
            [self toggleTokensAlongDragPathToPoint:point];
            break;

        case UIGestureRecognizerStateChanged:
            [self toggleTokensAlongDragPathToPoint:point];
            break;

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (self.tokenDragActive) {
                [self toggleTokensAlongDragPathToPoint:point];
            }
            self.tokenDragActive = NO;
            self.hasLastTokenDragPoint = NO;
            [self.dragToggledTokenKeys removeAllObjects];
            self.tokenSelectionFeedbackGenerator = nil;
            break;

        default:
            break;
    }
}

- (void)toggleTokensAlongDragPathToPoint:(CGPoint)point {
    if (!self.tokenDragActive) {
        return;
    }

    if (!self.hasLastTokenDragPoint) {
        [self toggleTokenAtDragPoint:point];
        self.lastTokenDragPoint = point;
        self.hasLastTokenDragPoint = YES;
        return;
    }

    CGFloat dx = point.x - self.lastTokenDragPoint.x;
    CGFloat dy = point.y - self.lastTokenDragPoint.y;
    CGFloat distance = hypot(dx, dy);
    NSUInteger stepCount = MAX((NSUInteger)1, (NSUInteger)ceil(distance / WXPTokenDragSampleDistance));
    for (NSUInteger stepIndex = 1; stepIndex <= stepCount; stepIndex++) {
        CGFloat progress = (CGFloat)stepIndex / (CGFloat)stepCount;
        CGPoint sampledPoint = CGPointMake(self.lastTokenDragPoint.x + dx * progress,
                                           self.lastTokenDragPoint.y + dy * progress);
        [self toggleTokenAtDragPoint:sampledPoint];
    }

    self.lastTokenDragPoint = point;
}

- (void)toggleTokenAtDragPoint:(CGPoint)point {
    WXPTokenButton *button = [self tokenButtonAtPoint:point includeExpandedHitArea:YES];
    if (button) {
        [self toggleTokenButton:button trackingCurrentDrag:YES];
    }
}

- (WXPTokenButton *)tokenButtonAtPoint:(CGPoint)point includeExpandedHitArea:(BOOL)includeExpandedHitArea {
    __block WXPTokenButton *visibleMatch = nil;
    __block WXPTokenButton *expandedMatch = nil;
    __block CGFloat expandedMatchDistance = CGFLOAT_MAX;

    [self enumerateTokenButtonsUsingBlock:^(WXPTokenButton *button, BOOL *stop) {
        CGRect visibleFrame = [self.tokenStackView convertRect:button.bounds fromView:button];
        if (CGRectContainsPoint(visibleFrame, point)) {
            visibleMatch = button;
            *stop = YES;
            return;
        }

        if (!includeExpandedHitArea) {
            return;
        }

        CGRect expandedFrame = CGRectInset(visibleFrame, -WXPTokenDragHitOutset, -WXPTokenDragHitOutset);
        if (!CGRectContainsPoint(expandedFrame, point)) {
            return;
        }

        CGFloat centerX = CGRectGetMidX(visibleFrame);
        CGFloat centerY = CGRectGetMidY(visibleFrame);
        CGFloat distance = hypot(point.x - centerX, point.y - centerY);
        if (!expandedMatch || distance < expandedMatchDistance) {
            expandedMatch = button;
            expandedMatchDistance = distance;
        }
    }];

    return visibleMatch ?: expandedMatch;
}

- (void)enumerateTokenButtonsUsingBlock:(void (^)(WXPTokenButton *button, BOOL *stop))block {
    if (!block) {
        return;
    }

    BOOL stop = NO;
    for (UIView *arrangedSubview in self.tokenStackView.arrangedSubviews) {
        if (![arrangedSubview isKindOfClass:[WXPTokenFlowView class]]) {
            continue;
        }

        for (UIView *subview in arrangedSubview.subviews) {
            if (![subview isKindOfClass:[WXPTokenButton class]]) {
                continue;
            }

            block((WXPTokenButton *)subview, &stop);
            if (stop) {
                return;
            }
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.tokenDragGestureRecognizer) {
        return YES;
    }

    CGPoint point = [touch locationInView:self.tokenStackView];
    return [self tokenButtonAtPoint:point includeExpandedHitArea:YES] != nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.tokenDragGestureRecognizer) {
        return YES;
    }

    CGPoint point = [gestureRecognizer locationInView:self.tokenStackView];
    return [self tokenButtonAtPoint:point includeExpandedHitArea:YES] != nil;
}

- (void)updateAppearanceForTokenButton:(UIButton *)button selected:(BOOL)selected {
    button.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor tertiarySystemFillColor];
    button.layer.borderColor = (selected ? [UIColor systemBlueColor] : [UIColor separatorColor]).CGColor;
    [button setTitleColor:(selected ? [UIColor whiteColor] : [UIColor labelColor]) forState:UIControlStateNormal];
    UIAccessibilityTraits traits = UIAccessibilityTraitButton;
    if (selected) {
        traits |= UIAccessibilityTraitSelected;
    }
    button.accessibilityTraits = traits;
}

- (void)ruleKindChanged:(UISegmentedControl *)sender {
    self.selectedRuleKind = sender.selectedSegmentIndex == 1 ? WXPRuleEditorKindExclude : WXPRuleEditorKindContains;
}

- (void)saveTapped {
    if (self.selectedTokenKeys.count == 0) {
        [self presentAlertWithTitle:WXPLocalizedString(@"RULE_SCAN_EMPTY_SELECTION_TITLE")
                            message:WXPLocalizedString(@"RULE_SCAN_EMPTY_SELECTION_MESSAGE")];
        return;
    }

    NSArray<NSDictionary *> *entries = [WXPNotificationRuleTokenBuilder ruleEntriesFromTokenSections:self.tokenSections
                                                                                   selectedTokenKeys:self.selectedTokenKeys
                                                                                       defaultScope:WXRuleScopeMessage];

    NSError *error = nil;
    if (!self.commitHandler || !self.commitHandler(self.selectedRuleKind, entries, &error)) {
        [self presentAlertWithTitle:WXPLocalizedString(@"COMMON_SAVE_FAILED")
                            message:error.localizedDescription ?: WXPLocalizedString(@"PER_APP_RULES_SAVE_FAILED_MESSAGE")];
        return;
    }

    NSArray<UIViewController *> *controllers = self.navigationController.viewControllers ?: @[];
    if (self.returnViewController) {
        if (self.returnMode == WXPNotificationRuleTokenReturnModeTargetViewController) {
            [self.navigationController popToViewController:self.returnViewController animated:YES];
            return;
        }

        if (self.selectedRuleKind == self.initialRuleKind) {
            [self.navigationController popToViewController:self.returnViewController animated:YES];
            return;
        }

        NSUInteger returnIndex = [controllers indexOfObject:self.returnViewController];
        if (returnIndex != NSNotFound && returnIndex > 0) {
            [self.navigationController popToViewController:controllers[returnIndex - 1] animated:YES];
            return;
        }

        [self.navigationController popToViewController:self.returnViewController animated:YES];
        return;
    }

    [self.navigationController popViewControllerAnimated:YES];
}

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"COMMON_OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
