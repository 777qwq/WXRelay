#import "WXPDiagController.h"
#import "WXPLocalization.h"
#import "../Shared/WXPreferences.h"
#import <UIKit/UIKit.h>

static WXPDiagController *_sDiagSelf = nil;

static void WXPDiagDoneCallback(CFNotificationCenterRef __unused c, void __unused *observer, CFStringRef __unused name, const void __unused *object, CFDictionaryRef __unused userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_sDiagSelf reloadResult];
    });
}

@implementation WXPDiagController {
    UITextView *_textView;
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if (self = [super initWithStyle:style]) {}
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = WXPLocalizedString(@"DIAG_TITLE");
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UIBarButtonItem *run = [[UIBarButtonItem alloc] initWithTitle:WXPLocalizedString(@"DIAG_RUN") style:UIBarButtonItemStylePlain target:self action:@selector(runDiag)];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:WXPLocalizedString(@"DIAG_COPY") style:UIBarButtonItemStylePlain target:self action:@selector(copyResult)];
    self.navigationItem.rightBarButtonItems = @[ copy, run ];

    _textView = [[UITextView alloc] init];
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_textView];
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _sDiagSelf = self;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, WXPDiagDoneCallback, CFSTR("cn.qwq.wxrelay.diag/done"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    [self reloadResult];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
    if (_sDiagSelf == self) _sDiagSelf = nil;
}

- (void)reloadResult {
    NSString *text = WXDiagnosticsLoadResult();
    if (text.length == 0) {
        // v1.1.4：CFPreferences 通道在 roothide 跨进程不可靠——回退从系统剪贴板读（诊断完成时微信侧已写入）
        NSString *pb = [UIPasteboard generalPasteboard].string;
        text = (pb.length > 0 && [pb hasPrefix:@"===== WxRelay 诊断"]) ? pb : @"";
    }
    _textView.text = (text.length > 0) ? text : WXPLocalizedString(@"DIAG_EMPTY");
}

- (void)runDiag {
    BOOL enabled = WXDiagnosticsEnabledNow();
    if (!enabled) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:WXPLocalizedString(@"DIAG_NEED_ENABLE") preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:WXPLocalizedString(@"DIAG_OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    _textView.text = WXPLocalizedString(@"DIAG_RUNNING");
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("cn.qwq.wxrelay.diag/run"), NULL, NULL, YES);
}

- (void)copyResult {
    [UIPasteboard generalPasteboard].string = _textView.text ?: @"";
}

@end
