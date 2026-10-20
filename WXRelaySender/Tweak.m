/**
 * WXRelayNFSender — 微信端发送器（并入 WXRelayNF v1.7.0）
 *
 * 职责（单一）：
 *   1. 监听 darwin com.mos.wxrelay.task + 启动补发
 *   2. 消费 wxrelay_tasks/*.json（targets+text）→ 懒猫链路发送
 *   3. keepAlive 默认开（wxrelay.cfg keepAlive=0 可关）
 * 匹配逻辑全部在 SB 端（WXRelayNF 主体），本进程不做任何规则判断。
 * 日志：微信沙盒 tmp/wxrelay.log
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

static void wrLog(NSString *msg) {
    @try {
        static NSDateFormatter *f = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) { }
}

static BOOL WRSendMessage(NSString *targetId, NSString *text) {
    @try {
        id delegate = [UIApplication sharedApplication].delegate;
        if (!delegate) { wrLog(@"send: app delegate nil"); return NO; }
        SEL h = NSSelectorFromString(@"application:handleOpenURL:bundleID:annotation:");
        if (![delegate respondsToSelector:h]) { wrLog(@"send: handleOpenURL not responding"); return NO; }
        NSString *escaped = [text stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:
            [NSString stringWithFormat:@"weixin://aiwmao/user=%@&msg=%@", targetId, escaped]];
        if (!url) { wrLog(@"send: bad url"); return NO; }
        ((BOOL(*)(id,SEL,id,id,id,id))objc_msgSend)(delegate, h, nil, url, nil, nil);
        wrLog([NSString stringWithFormat:@"send ok -> %@ (len=%lu)", targetId, (unsigned long)text.length]);
        return YES;
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"send EXC: %@ %@", e.name, e.reason]);
        return NO;
    }
}

static void WRFlushTasks(void) {
    @try {
        NSString *taskDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_tasks"];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:taskDir error:nil];
        if (!files.count) return;
        wrLog([NSString stringWithFormat:@"flush %lu task(s)", (unsigned long)files.count]);
        for (NSString *fn in files) {
            if (![fn hasSuffix:@".json"]) continue;
            NSString *p = [taskDir stringByAppendingPathComponent:fn];
            NSDictionary *task = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:p]
                options:NSJSONReadingAllowFragments error:nil];
            if ([task isKindOfClass:[NSDictionary class]]) {
                NSString *text = task[@"text"];
                NSArray *targets = task[@"targets"];
                if ([text isKindOfClass:[NSString class]] && [targets isKindOfClass:[NSArray class]]) {
                    for (NSString *target in targets)
                        if ([target isKindOfClass:[NSString class]]) WRSendMessage(target, text);
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
        wrLog(@"flush done");
    } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"flush EXC %@", e.name]); }
}

static void WRTaskNotifyCallback(CFNotificationCenterRef __unused c, void __unused *o,
                                 CFStringRef __unused n, const void __unused *obj, CFDictionaryRef __unused ui) {
    @autoreleasepool { WRFlushTasks(); }
}

static void WRSetupKeepAlive(void) {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [session setActive:YES error:nil];
        NSString *path = [NSString stringWithFormat:@"%@/1sec.caf", [[NSBundle bundleWithIdentifier:@"com.apple.UIKit"] resourcePath]];
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
        if (!player) { wrLog(@"keepalive: player nil"); return; }
        [player setNumberOfLoops:-1];
        [player setVolume:1.0f];
        [player play];
        objc_setAssociatedObject([UIApplication sharedApplication], @selector(keyWindow), player, OBJC_ASSOCIATION_RETAIN);
        wrLog(@"keepalive: silent audio looping");
    } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"keepalive EXC: %@", e.name]); }
}

static NSString *WRConfig(NSString *key) {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay.cfg"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        [@"# WXRelay 发送端配置（keepAlive=0 可关后台保活）\nkeepAlive=1\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSString *content = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (l.length == 0 || [l hasPrefix:@"#"]) continue;
        NSRange eq = [l rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        if ([[[l substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:key])
            return [[l substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

__attribute__((constructor)) static void wxrelayNFSenderCtor(void) {
    @autoreleasepool {
        wrLog(@"WXRelayNFSender ctor");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRFlushTasks(); // 启动补发积压
            NSString *ka = WRConfig(@"keepAlive");
            if (![ka isEqualToString:@"0"]) WRSetupKeepAlive();
            else wrLog(@"keepAlive off (cfg)");
        });
    }
}
