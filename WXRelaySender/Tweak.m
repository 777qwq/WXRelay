/**
 * WXRelayNFSender — 微信端发送器（并入 WXRelayNF v1.7.0）
 *
 * 职责（单一）：
 *   1. 监听 darwin com.mos.wxrelay.task + 启动补发
 *   2. 消费 wxrelay_tasks JSON（targets+text）→ 进程内私 API 直发（v2.3.0 去懒猫）
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

// v2.3.2 路A：备注/昵称 → wxid，**仅精准匹配**（不做包含/前缀）；解析失败返回 nil，绝不裸发
static NSString *WRResolveTargetID(NSString *targetId) {
    @try {
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return nil;
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id mgr = center ? ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr) : nil;
        if (!mgr) return nil;
        // 1) 官方精准接口（显示名精确匹配）
        if ([mgr respondsToSelector:@selector(getContactByDisplayName:)]) {
            id contact = ((id(*)(id,SEL,id))objc_msgSend)(mgr, @selector(getContactByDisplayName:), targetId);
            if (contact && [contact respondsToSelector:@selector(m_nsUsrName)]) {
                id wxid = ((id(*)(id,SEL))objc_msgSend)(contact, @selector(m_nsUsrName));
                if ([wxid isKindOfClass:[NSString class]] && [(NSString *)wxid length] > 0) {
                    wrLog([NSString stringWithFormat:@"resolve '%@' -> %@", targetId, wxid]);
                    return wxid;
                }
            }
        }
        // 2) 备注名/昵称精准匹配：遍历联系人表，== 比较；唯一命中才用，多命中弃用
        if (![mgr respondsToSelector:@selector(getContactList:contactType:)]) return nil;
        id list = ((id(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u);
        if (![list isKindOfClass:[NSArray class]]) return nil;
        id hit = nil; unsigned int hits = 0;
        for (id c in list) {
            if (![c respondsToSelector:@selector(m_nsRemark)]) continue;
            id remark = ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsRemark));
            BOOL rm = [remark isKindOfClass:[NSString class]] && [(NSString *)remark isEqualToString:targetId];
            id nick = [c respondsToSelector:@selector(m_nsNickName)] ? ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsNickName)) : nil;
            BOOL nm = [nick isKindOfClass:[NSString class]] && [(NSString *)nick isEqualToString:targetId];
            if (rm || nm) {
                hit = c; hits++;
                if (hits > 1) break; // 多命中：撞名，弃用
            }
        }
        if (hits == 1 && hit && [hit respondsToSelector:@selector(m_nsUsrName)]) {
            id wxid = ((id(*)(id,SEL))objc_msgSend)(hit, @selector(m_nsUsrName));
            if ([wxid isKindOfClass:[NSString class]] && [(NSString *)wxid length] > 0) {
                wrLog([NSString stringWithFormat:@"resolve '%@' -> %@", targetId, wxid]);
                return wxid;
            }
        }
        if (hits > 1) wrLog([NSString stringWithFormat:@"resolve '%@' ambiguous (%u), skip", targetId, hits]);
        return nil;
    } @catch (NSException *e) { return nil; }
}

// v2.3.0 直发：进程内私 API，走微信原生发送管线（CMessageMgr AddMsg），不再依赖懒猫 handleOpenURL
// 参考：DKWechatHelper sendMsg（8.x 实战）+ iWeChat dump 头；真机签名待验证
static BOOL WRSendMessage(NSString *targetId, NSString *text) {
    @try {
        // v2.3.2 安全线：解析失败绝不裸发（防错发）；标准 id 格式直通不走解析
        BOOL isPlainID = [targetId isEqualToString:@"filehelper"] || [targetId hasSuffix:@"@chatroom"]
            || [targetId hasPrefix:@"wxid_"] || [targetId hasPrefix:@"gh_"];
        NSString *resolved = isPlainID ? targetId : WRResolveTargetID(targetId);
        if (!resolved) { wrLog([NSString stringWithFormat:@"resolve failed, skip '%@'", targetId]); return NO; }
        targetId = resolved;
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        Class CMessageMgr = objc_getClass("CMessageMgr");
        Class CMessageWrap = objc_getClass("CMessageWrap");
        Class SettingUtil = objc_getClass("SettingUtil");
        if (!MMServiceCenter || !CMessageMgr || !CMessageWrap || !SettingUtil) {
            wrLog(@"send: private class missing");
            return NO;
        }
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id fromUsr = ((id(*)(id,SEL,long long))objc_msgSend)(SettingUtil, @selector(getLocalUsrName:), 0);
        if (!center || !fromUsr) { wrLog(@"send: center/self missing"); return NO; }
        if (![center respondsToSelector:@selector(getService:)]) { wrLog(@"send: no getService"); return NO; }
        id mgr = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CMessageMgr);
        if (!mgr) { wrLog(@"send: no CMessageMgr"); return NO; }
        if (![(id)CMessageWrap respondsToSelector:@selector(alloc)]) { wrLog(@"send: no wrap alloc"); return NO; }
        id wrap = ((id(*)(id,SEL))objc_msgSend)((id)CMessageWrap, @selector(alloc));
        wrap = ((id(*)(id,SEL,long long))objc_msgSend)(wrap, @selector(initWithMsgType:), (long long)1);
        if (!wrap) { wrLog(@"send: wrap init failed"); return NO; }
        ((void(*)(id,SEL,id))objc_msgSend)(wrap, @selector(setM_nsFromUsr:), fromUsr);
        ((void(*)(id,SEL,id))objc_msgSend)(wrap, @selector(setM_nsContent:), text);
        ((void(*)(id,SEL,id))objc_msgSend)(wrap, @selector(setM_nsToUsr:), targetId);
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(wrap, @selector(setM_uiMesLocalID:), 11u);
        ((void(*)(id,SEL,_Bool))objc_msgSend)(wrap, @selector(setM_uiStatus:), YES);
        // 时间戳：优先 MMNewSessionMgr GenSendMsgTime，失败则用系统时间
        Class MMNewSessionMgr = objc_getClass("MMNewSessionMgr");
        unsigned int ctime = (unsigned int)[[NSDate date] timeIntervalSince1970];
        if (MMNewSessionMgr) {
            id sm = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), MMNewSessionMgr);
            if (sm && [sm respondsToSelector:@selector(GenSendMsgTime)])
                ctime = ((unsigned int(*)(id,SEL))objc_msgSend)(sm, @selector(GenSendMsgTime));
        }
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(wrap, @selector(setM_uiCreateTime:), ctime);
        ((void(*)(id,SEL,id,id))objc_msgSend)(mgr, @selector(AddMsg:MsgWrap:), targetId, wrap);
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

static BOOL WRKeepAliveEnabled(void) {
    @try {
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        [candidates addObject:@"/var/jb/var/mobile/Library/Preferences"];
        [candidates addObject:@"/var/mobile/Library/Preferences"];
        NSArray *jbRoots = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
        for (NSString *d in jbRoots) {
            if ([d hasPrefix:@".jbroot-"]) {
                [candidates addObject:[[NSString stringWithFormat:@"/var/containers/Bundle/Application/%@", d] stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]];
            }
        }
        for (NSString *dir in candidates) {
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                [dir stringByAppendingPathComponent:@"com.tune.notificationfilter.plist"]];
            if (prefs) {
                id v = prefs[@"KeepAlive"];
                wrLog([NSString stringWithFormat:@"keepAlive cfg from %@: %@", dir.lastPathComponent, v ?: @"(default)"]);
                return v ? [v boolValue] : YES;
            }
        }
    } @catch (NSException *e) { }
    return YES;
}

// ===== v2.3.3 探针（一次性，验证解析链后删除）=====
static void WRProbe(void) {
    @autoreleasepool {
        wrLog(@"=== PROBE START ===");
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        wrLog([NSString stringWithFormat:@"probe cls CContactMgr=%d MMServiceCenter=%d", CContactMgr!=nil, MMServiceCenter!=nil]);
        if (!CContactMgr || !MMServiceCenter) { wrLog(@"=== PROBE END (no cls) ==="); return; }
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id mgr = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr);
        wrLog([NSString stringWithFormat:@"probe mgr=%d getByName=%d getList2=%d", mgr!=nil,
            [mgr respondsToSelector:@selector(getContactByDisplayName:)],
            [mgr respondsToSelector:@selector(getContactList:contactType:)]]);
        if (![mgr respondsToSelector:@selector(getContactList:contactType:)]) { wrLog(@"=== PROBE END (no list) ==="); return; }
        id list = ((id(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u);
        wrLog([NSString stringWithFormat:@"probe list=%@ count=%lu", NSStringFromClass([list class]), (unsigned long)([list isKindOfClass:[NSArray class]]?[list count]:0)]);
        if (![list isKindOfClass:[NSArray class]]) { wrLog(@"=== PROBE END (bad list) ==="); return; }
        unsigned int shown = 0;
        for (id c in list) {
            if (shown >= 5) break;
            id uid  = [c respondsToSelector:@selector(m_nsUsrName)]  ? ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsUsrName))  : nil;
            id nick = [c respondsToSelector:@selector(m_nsNickName)] ? ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsNickName)) : nil;
            id rem  = [c respondsToSelector:@selector(m_nsRemark)]   ? ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsRemark))   : nil;
            wrLog([NSString stringWithFormat:@"probe c[%u] usr=%@ nick=%@ remark=%@",
                shown,
                [uid isKindOfClass:[NSString class]]?uid:@"(nil/type%)",
                [nick isKindOfClass:[NSString class]]?nick:@"(nil)",
                [rem isKindOfClass:[NSString class]]?rem:@"(nil)"]);
            shown++;
        }
        // 精准匹配实测：取最后一个配置目标（非标准 id 的那个，如“谢”）
        id prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.tune.notificationfilter.plist"];
        wrLog([NSString stringWithFormat:@"probe prefs=%d", prefs!=nil]);
        wrLog(@"=== PROBE END ===");
    }
}

static void WRProbeNotifyCallback(CFNotificationCenterRef __unused c, void __unused *o,
                                  CFStringRef __unused n, const void __unused *obj, CFDictionaryRef __unused ui) {
    @autoreleasepool { WRProbe(); }
}

__attribute__((constructor)) static void wxrelayNFSenderCtor(void) {
    @autoreleasepool {
        wrLog(@"WXRelayNFSender ctor");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRProbeNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.probe", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRProbe(); // v2.3.3 探针自动跑一次（无 SSH 触发方案）
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRFlushTasks(); // 启动补发积压
            if (WRKeepAliveEnabled()) WRSetupKeepAlive();
            else wrLog(@"keepAlive off (NF cfg)");
        });
    }
}
