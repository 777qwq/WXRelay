/**
 * WXRelayNFSender — 微信端发送器（并入 WXRelayNF v1.7.0）
 *
 * 职责（单一）：
 *   1. 监听 darwin com.mos.wxrelay.task + 启动补发
 *   2. 消费 wxrelay_tasks JSON（targets+text）→ 进程内私 API 直发（v2.3.0 去懒猫）
 *   3. 锁屏存活交给 AppData 真后台（v2.5.1 移除内置保活）
 * 匹配逻辑全部在 SB 端（WXRelayNF 主体），本进程不做任何规则判断。
 * 日志：微信沙盒 tmp/wxrelay.log
 */
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

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
        // 8.0.50 实证：getContactByDisplayName 不存在，直接走列表精准扫描
        // v2.4.0 备注优先：第一轮备注精准（备注盖昵称，与微信显示语义一致）；零命中才扫昵称；撞名弃用
        if (![mgr respondsToSelector:@selector(getContactList:contactType:)]) return nil;
        id list = ((id(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u);
        if (![list isKindOfClass:[NSArray class]]) return nil;
        __block id hit = nil; __block unsigned int hits = 0;
        // 第一轮：备注
        for (id c in list) {
            if (![c respondsToSelector:@selector(m_nsRemark)]) continue;
            id rem = ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsRemark));
            if ([rem isKindOfClass:[NSString class]] && [(NSString *)rem isEqualToString:targetId]) { hit = c; hits++; if (hits > 1) break; }
        }
        if (hits > 1) { wrLog([NSString stringWithFormat:@"resolve '%@' ambiguous remark (%u), skip", targetId, hits]); return nil; }
        // 第二轮：备注零命中才扫昵称
        if (hits == 0) {
            for (id c in list) {
                if (![c respondsToSelector:@selector(m_nsNickName)]) continue;
                id nick = ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsNickName));
                if ([nick isKindOfClass:[NSString class]] && [(NSString *)nick isEqualToString:targetId]) { hit = c; hits++; if (hits > 1) break; }
            }
            if (hits > 1) { wrLog([NSString stringWithFormat:@"resolve '%@' ambiguous nick (%u), skip", targetId, hits]); return nil; }
        }
        if (hits == 1 && hit && [hit respondsToSelector:@selector(m_nsUsrName)]) {
            id wxid = ((id(*)(id,SEL))objc_msgSend)(hit, @selector(m_nsUsrName));
            if ([wxid isKindOfClass:[NSString class]] && [(NSString *)wxid length] > 0) {
                wrLog([NSString stringWithFormat:@"resolve '%@' -> %@", targetId, wxid]);
                return wxid;
            }
        }
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
                // v2.4.0 items 格式：[{id, text}]（SB 端按目标动作生成）；兼容旧 targets+text
                id items = task[@"items"];
                if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
                    for (NSDictionary *it in items)
                        if ([it isKindOfClass:[NSDictionary class]]
                            && [it[@"id"] isKindOfClass:[NSString class]]
                            && [it[@"text"] isKindOfClass:[NSString class]])
                            WRSendMessage(it[@"id"], it[@"text"]);
                } else {
                    NSString *text = task[@"text"];
                    NSArray *targets = task[@"targets"];
                    if ([text isKindOfClass:[NSString class]] && [targets isKindOfClass:[NSArray class]]) {
                        for (NSString *target in targets)
                            if ([target isKindOfClass:[NSString class]]) WRSendMessage(target, text);
                    }
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


// ===== v2.3.5 探针（一次性，验证解析链后删除）=====
__attribute__((constructor)) static void wxrelayNFSenderCtor(void) {
    @autoreleasepool {
        wrLog(@"WXRelayNFSender ctor");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRFlushTasks(); // 启动补发积压
            // v2.5.1：保活/轮询已移除，锁屏存活交给 AppData 真后台（用户拍板）
        });
    }
}

