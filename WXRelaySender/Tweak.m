/**
 * WXRelayNFSender — 微信端发送器（并入 WXRelayNF v1.7.0）
 *
 * 职责（单一）：
 *   1. 监听 darwin com.mos.wxrelay.task + 启动补发
 *   2. 消费 wxrelay_tasks JSON（targets+text）→ 懒猫链路发送
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
        // 内存生成 1 秒静音 WAV（8000Hz/16bit/mono），不依赖任何文件
        int sampleRate = 8000; int numSamples = sampleRate; int dataLen = numSamples * 2;
        int totalLen = 44 + dataLen;
        NSMutableData *wav = [NSMutableData dataWithCapacity:totalLen];
        uint8_t hdr[44] = {'R','I','F','F',0,0,0,0,'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,1,0,0,0,0,0,0,0,0,0,2,0,16,0,'d','a','t','a',0,0,0,0};
        int riffLen = totalLen - 8;
        int byteRate = sampleRate * 2;
        hdr[4]=riffLen&0xff; hdr[5]=(riffLen>>8)&0xff; hdr[6]=(riffLen>>16)&0xff; hdr[7]=(riffLen>>24)&0xff;
        hdr[24]=sampleRate&0xff; hdr[25]=(sampleRate>>8)&0xff; hdr[26]=(sampleRate>>16)&0xff; hdr[27]=(sampleRate>>24)&0xff;
        hdr[28]=byteRate&0xff; hdr[29]=(byteRate>>8)&0xff; hdr[30]=(byteRate>>16)&0xff; hdr[31]=(byteRate>>24)&0xff;
        hdr[36]=dataLen&0xff; hdr[37]=(dataLen>>8)&0xff; hdr[38]=(dataLen>>16)&0xff; hdr[39]=(dataLen>>24)&0xff;
        [wav appendBytes:hdr length:44];
        char zeros[256] = {0};
        for (int i = 0; i < dataLen; i += 256) [wav appendBytes:zeros length:MIN(256, dataLen - i)];
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:wav error:nil];
        if (!player) { wrLog(@"keepalive: player nil (wav)"); return; }
        [player setNumberOfLoops:-1];
        [player setVolume:0.01f];
        [player play];
        objc_setAssociatedObject([UIApplication sharedApplication], @selector(keyWindow), player, OBJC_ASSOCIATION_RETAIN);
        wrLog(@"keepalive: silent wav looping");
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"keepalive EXC: %@", e.name]);
    }
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
