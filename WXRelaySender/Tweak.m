/**
 * WXRelaySender — 微信端发送器（并入 WXRelay v1.7.0）
 *
 * 职责（单一）：
 *   1. 监听 darwin com.mos.wxrelay.task + 启动补发
 *   2. 消费 wxrelay_tasks JSON（targets+text）→ 进程内私 API 直发（v2.3.0 去懒猫）
 *   3. 锁屏存活交给 AppData 真后台（v2.5.1 移除内置保活）
 * 匹配逻辑全部在 SB 端（WXRelay 主体），本进程不做任何规则判断。
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

static void WRNoteSentText(NSString *text);

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
        WRNoteSentText(text);
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


// ===== v2.8.0 模块B：消息源（AsyncOnAddMsg 全覆盖）=====
// 管线：微信收消息 → 组 record JSON → 落 wxrelay_msgs + darwin 呼 SB → SB 匹配 → 现有任务通道回微信
static NSString *WRContactDisplayName(NSString *wxid) {
    if (wxid.length == 0) return wxid;
    @try {
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return wxid;
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id mgr = center ? ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr) : nil;
        if (!mgr || ![mgr respondsToSelector:@selector(getSelfContact)]) return wxid;
        // 按表精准扫：先备注后昵称（与路径A同名语义）
        if (![mgr respondsToSelector:@selector(getContactList:contactType:)]) return wxid;
        id list = ((id(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u);
        if (![list isKindOfClass:[NSArray class]]) return wxid;
        __block NSString *remark = nil, *nick = nil;
        for (id c in list) {
            if (![c respondsToSelector:@selector(m_nsUsrName)]) continue;
            NSString *u = [c valueForKey:@"m_nsUsrName"];
            if (![u isEqualToString:wxid]) continue;
            if ([c respondsToSelector:@selector(m_nsRemark)]) remark = [c valueForKey:@"m_nsRemark"];
            if ([c respondsToSelector:@selector(m_nsNickName)]) nick = [c valueForKey:@"m_nsNickName"];
            break;
        }
        NSString *name = remark.length ? remark : (nick.length ? nick : nil);
        return name ?: wxid;
    } @catch (NSException *e) { return wxid; }
}

static void WRWriteMsgSourceFlag(void) {
    @try {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_msgsource.flag"];
        [[NSString stringWithFormat:@"%f", [[NSDate date] timeIntervalSince1970]] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static NSMutableSet<NSString *> *WRLastSentTexts = nil;
static dispatch_queue_t WRLastSentQueue = nil;

static void WRNoteSentText(NSString *text) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WRLastSentTexts = [NSMutableSet set];
        WRLastSentQueue = dispatch_queue_create("com.777qwq.wxrelay.lastsent", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_barrier_async(WRLastSentQueue, ^{
        [WRLastSentTexts addObject:text ?: @""];
        if (WRLastSentTexts.count > 64) [WRLastSentTexts removeObject:[[WRLastSentTexts allObjects] firstObject]];
    });
}

static BOOL WRTextWasRecentlySent(NSString *text) {
    if (!WRLastSentTexts) return NO;
    __block BOOL hit = NO;
    dispatch_sync(WRLastSentQueue, ^{ hit = [WRLastSentTexts containsObject:text ?: @""]; });
    return hit;
}

static void WRSpoolMsgRecord(NSDictionary *record) {
    @try {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_msgs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"msg_%@.json", [[NSUUID UUID] UUIDString]]];
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        if (data) { [data writeToFile:path atomically:YES];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.777qwq.wxrelay.msg"), NULL, NULL, YES); }
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"spool EXC %@", e.name]);
    }
}

static IMP WRAsyncOnAddMsgOrig = NULL;

static void WRAsyncOnAddMsgHook(id self, SEL _cmd, id arg1, id wrap) {
    if (WRAsyncOnAddMsgOrig) ((void(*)(id,SEL,id,id))WRAsyncOnAddMsgOrig)(self, _cmd, arg1, wrap);
    @try {
        if (![wrap isKindOfClass:[objc_getClass("CMessageWrap") class]]) return;
        WRWriteMsgSourceFlag();
        // 只收文本（v1）；系统消息/媒体后续需要再说
        unsigned int msgType = 0;
        if ([wrap respondsToSelector:@selector(m_uiMessageType)]) msgType = ((unsigned int(*)(id,SEL))objc_msgSend)(wrap, @selector(m_uiMessageType));
        if (msgType != 1) return;
        NSString *content = [wrap respondsToSelector:@selector(m_nsContent)] ? [wrap valueForKey:@"m_nsContent"] : nil;
        if (content.length == 0) return;
        // 自发消息防线：官方 isSender 位 + 已发文本 60 秒回显双保险，杜绝回环
        BOOL isSender = NO;
        if ([wrap respondsToSelector:@selector(m_bIsSender)]) isSender = ((BOOL(*)(id,SEL))objc_msgSend)(wrap, @selector(m_bIsSender));
        if (isSender || WRTextWasRecentlySent(content)) return;
        NSString *fromUsr = [wrap respondsToSelector:@selector(m_nsFromUsr)] ? [wrap valueForKey:@"m_nsFromUsr"] : nil;
        NSString *actualUsr = [wrap respondsToSelector:@selector(m_nsActualUsr)] ? [wrap valueForKey:@"m_nsActualUsr"] : nil;
        if (fromUsr.length == 0) return;
        BOOL isGroup = [fromUsr hasSuffix:@"@chatroom"];
        NSString *chatName = WRContactDisplayName(fromUsr);
        NSString *speaker = isGroup ? WRContactDisplayName(actualUsr ?: @"") : nil;
        NSString *title = chatName ?: fromUsr;
        NSString *subtitle = isGroup ? (speaker ?: @"") : @"";
        NSString *msgID = [wrap respondsToSelector:@selector(m_nsMsgId)] ? [wrap valueForKey:@"m_nsMsgId"] : nil;
        if (msgID.length == 0) msgID = [NSString stringWithFormat:@"%u-%lu", (unsigned int)msgType, (unsigned long)[content hash]];
        WRSpoolMsgRecord(@{
            @"bid": @"com.tencent.xin",
            @"title": title,
            @"subtitle": subtitle,
            @"body": content,
            @"msgid": [NSString stringWithFormat:@"wxmsg_%@", msgID],
        });
        wrLog([NSString stringWithFormat:@"B hooked: %@ (%@)", title, isGroup ? @"group" : @"chat"]);
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"B EXC: %@ %@", e.name, e.reason]);
    }
}

static void WRInstallMsgSourceHook(void) {
    Class CMessageMgr = objc_getClass("CMessageMgr");
    SEL sel = @selector(AsyncOnAddMsg:Wrap:);
    if (!CMessageMgr || ![CMessageMgr instancesRespondToSelector:sel]) {
        wrLog(@"B: AsyncOnAddMsg missing, hook skipped");
        return;
    }
    // 纯 runtime swizzle（substrate 不进链），与 prefs 端同款手法
    Method m = class_getInstanceMethod(CMessageMgr, sel);
    if (!m) { wrLog(@"B: no Method, hook skipped"); return; }
    WRAsyncOnAddMsgOrig = method_getImplementation(m);
    method_setImplementation(m, (IMP)WRAsyncOnAddMsgHook);
    wrLog(@"B: AsyncOnAddMsg hook installed");
}

// ===== v2.3.5 探针（一次性，验证解析链后删除）=====
__attribute__((constructor)) static void wxrelayNFSenderCtor(void) {
    @autoreleasepool {
        wrLog(@"WXRelaySender ctor");
        WRInstallMsgSourceHook();
        WRWriteMsgSourceFlag();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRFlushTasks(); // 启动补发积压
            // v2.5.1：保活/轮询已移除，锁屏存活交给 AppData 真后台（用户拍板）
        });
    }
}

