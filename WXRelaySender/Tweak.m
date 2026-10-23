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
#import <pthread.h>

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
static volatile BOOL WRInSend = NO;

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
    if (WRInSend) return NO; // 防重入
    WRInSend = YES;
    @try {
        // v2.3.2 安全线：解析失败绝不裸发（防错发）；标准 id 格式直通不走解析
        BOOL isPlainID = [targetId isEqualToString:@"filehelper"] || [targetId hasSuffix:@"@chatroom"]
            || [targetId hasPrefix:@"wxid_"] || [targetId hasPrefix:@"gh_"];
        NSString *resolved = isPlainID ? targetId : WRResolveTargetID(targetId);
        if (!resolved) { wrLog([NSString stringWithFormat:@"resolve failed, skip '%@'", targetId]); { WRInSend = NO; return NO; } }
        targetId = resolved;
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        Class CMessageMgr = objc_getClass("CMessageMgr");
        Class CMessageWrap = objc_getClass("CMessageWrap");
        Class SettingUtil = objc_getClass("SettingUtil");
        if (!MMServiceCenter || !CMessageMgr || !CMessageWrap || !SettingUtil) {
            wrLog(@"send: private class missing");
            { WRInSend = NO; return NO; }
        }
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id fromUsr = ((id(*)(id,SEL,long long))objc_msgSend)(SettingUtil, @selector(getLocalUsrName:), 0);
        if (!center || !fromUsr) { wrLog(@"send: center/self missing"); { WRInSend = NO; return NO; } }
        if (![center respondsToSelector:@selector(getService:)]) { wrLog(@"send: no getService"); { WRInSend = NO; return NO; } }
        id mgr = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CMessageMgr);
        if (!mgr) { wrLog(@"send: no CMessageMgr"); { WRInSend = NO; return NO; } }
        if (![(id)CMessageWrap respondsToSelector:@selector(alloc)]) { wrLog(@"send: no wrap alloc"); { WRInSend = NO; return NO; } }
        id wrap = ((id(*)(id,SEL))objc_msgSend)((id)CMessageWrap, @selector(alloc));
        wrap = ((id(*)(id,SEL,long long))objc_msgSend)(wrap, @selector(initWithMsgType:), (long long)1);
        if (!wrap) { wrLog(@"send: wrap init failed"); { WRInSend = NO; return NO; } }
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
        WRInSend = NO;
        return YES;
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"send EXC: %@ %@", e.name, e.reason]);
        { WRInSend = NO; return NO; }
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
// v0.3 banner: post local notification when in background (UILocalNotification)
static void WRPostBanner(NSString *title, NSString *body) {
    @try {
        if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) return;
        UILocalNotification *ln = [[UILocalNotification alloc] init];
        ln.fireDate = [NSDate date];
        ln.timeZone = [NSTimeZone defaultTimeZone];
        if (title.length) ln.alertTitle = title;
        if (body.length) ln.alertBody = body;
        ln.hasAction = YES;
        [[UIApplication sharedApplication] scheduleLocalNotification:ln];
        [ln release];
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"banner EXC %@", e.name]);
    }
}

static NSString *WRStr(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

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
            NSString *u = WRStr([c valueForKey:@"m_nsUsrName"]);
            if (![u isEqualToString:wxid]) continue;
            if ([c respondsToSelector:@selector(m_nsRemark)]) remark = WRStr([c valueForKey:@"m_nsRemark"]);
            if ([c respondsToSelector:@selector(m_nsNickName)]) nick = WRStr([c valueForKey:@"m_nsNickName"]);
            break;
        }
        NSString *name = remark.length ? remark : (nick.length ? nick : nil);
        return name ?: wxid;
    } @catch (NSException *e) { return wxid; }
}

static NSString *WRSelfWxid = nil;

static void WRResolveSelfWxid(void) {
    @try {
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return;
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id mgr = center ? ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr) : nil;
        if (!mgr || ![mgr respondsToSelector:@selector(getSelfContact)]) return;
        id me = ((id(*)(id,SEL))objc_msgSend)(mgr, @selector(getSelfContact));
        if ([me respondsToSelector:@selector(m_nsUsrName)])
            WRSelfWxid = [[me valueForKey:@"m_nsUsrName"] retain]; // MRC: static strong must retain
        wrLog([NSString stringWithFormat:@"B: self wxid=%@", WRSelfWxid]);
    } @catch (NSException *e) { }
}

static void WRWriteMsgSourceFlag(void) {
    @try {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_msgsource.flag"];
        [[NSString stringWithFormat:@"%f", [[NSDate date] timeIntervalSince1970]] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static NSMutableSet<NSString *> *WRLastSentTexts = nil;
static pthread_mutex_t WRLastSentMutex = PTHREAD_MUTEX_INITIALIZER;

// v2.8.6 ctor 急切初始化：静态强引用建一次永不重赋（防 over-release 僵尸）
static void WRInitLastSentStore(void) {
    pthread_mutex_lock(&WRLastSentMutex);
    if (!WRLastSentTexts) WRLastSentTexts = [[NSMutableSet alloc] init];
    pthread_mutex_unlock(&WRLastSentMutex);
}

static void WRNoteSentText(NSString *text) {
    if (!WRLastSentTexts) WRInitLastSentStore();
    pthread_mutex_lock(&WRLastSentMutex);
    [WRLastSentTexts addObject:text ?: @""];
    if (WRLastSentTexts.count > 64) {
        NSString *oldest = [WRLastSentTexts anyObject];
        if (oldest) [WRLastSentTexts removeObject:oldest];
    }
    pthread_mutex_unlock(&WRLastSentMutex);
}

static BOOL WRTextWasRecentlySent(NSString *text) {
    if (!text.length) return NO;
    if (!WRLastSentTexts) WRInitLastSentStore();
    pthread_mutex_lock(&WRLastSentMutex);
    BOOL hit = [WRLastSentTexts containsObject:text];
    pthread_mutex_unlock(&WRLastSentMutex);
    return hit;
}

// v2.8.5 发送中旗标：B hook 见旗标直接跳过（重入/回声釜底抽薪）

// v0.7 保活精准化：微信自报家门（自己场景的 persistenceIdentifier，与 SB 反挂起对象同源）
static NSString *WRWeChatScenePID(void) {
    @try {
        NSSet *scenes = [[UIApplication sharedApplication] connectedScenes];
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                NSString *pid = scene.session.persistenceIdentifier;
                if (pid.length) return pid;
            }
        }
    } @catch (NSException *e) { }
    return nil;
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
static NSString *WRHookedSelectorName = nil;

static void WRAsyncOnAddMsgHook(id self, SEL _cmd, id arg1, id wrap) {
    if (WRAsyncOnAddMsgOrig) ((void(*)(id,SEL,id,id))WRAsyncOnAddMsgOrig)(self, _cmd, arg1, wrap);
    @try {
        // 候选参数序归一：单参候选时 wrap 落在 arg1
        if ([WRHookedSelectorName isEqualToString:@"OnNewMessage:"]) wrap = arg1;
        if (WRInSend) return; // 发送中：跳过本次回声/重入
        if (![wrap isKindOfClass:[objc_getClass("CMessageWrap") class]]) return;
        WRWriteMsgSourceFlag();
        // 只收文本（v1）；系统消息/媒体后续需要再说
        unsigned int msgType = 0;
        if ([wrap respondsToSelector:@selector(m_uiMessageType)]) msgType = ((unsigned int(*)(id,SEL))objc_msgSend)(wrap, @selector(m_uiMessageType));
        if (msgType != 1) return;
        NSString *content = [wrap respondsToSelector:@selector(m_nsContent)] ? WRStr([wrap valueForKey:@"m_nsContent"]) : nil;
        if (content.length == 0) return;
        // 自发消息防线：官方 isSender 位 + 已发文本 60 秒回显双保险，杜绝回环
        BOOL isSender = NO;
        if ([wrap respondsToSelector:@selector(m_bIsSender)]) isSender = ((BOOL(*)(id,SEL))objc_msgSend)(wrap, @selector(m_bIsSender));
        if (isSender || WRTextWasRecentlySent(content)) return;
        NSString *fromUsr = [wrap respondsToSelector:@selector(m_nsFromUsr)] ? WRStr([wrap valueForKey:@"m_nsFromUsr"]) : nil;
        NSString *actualUsr = [wrap respondsToSelector:@selector(m_nsActualUsr)] ? WRStr([wrap valueForKey:@"m_nsActualUsr"]) : nil;
        if (fromUsr.length == 0) return;
        // v2.8.7 自身消息防线：来源 wxid 是自己（单聊直发 / 群聊 actualUsr）一律跳过
        if (WRSelfWxid.length && ([fromUsr isEqualToString:WRSelfWxid]
            || (actualUsr.length && [actualUsr isEqualToString:WRSelfWxid]))) return;
        BOOL isGroup = [fromUsr hasSuffix:@"@chatroom"];
        NSString *chatName = WRContactDisplayName(fromUsr);
        NSString *speaker = isGroup ? WRContactDisplayName(actualUsr ?: @"") : nil;
        NSString *title = chatName ?: fromUsr;
        NSString *subtitle = isGroup ? (speaker ?: @"") : @"";
        // v0.3 banner: background incoming message
        {
            NSString *bt = title;
            if (isGroup && subtitle.length) bt = [NSString stringWithFormat:@"%@ - %@", bt, subtitle];
            WRPostBanner(bt, content);
        }
        NSString *msgID = [wrap respondsToSelector:@selector(m_nsMsgId)] ? WRStr([wrap valueForKey:@"m_nsMsgId"]) : nil;
        if (msgID.length == 0) msgID = [NSString stringWithFormat:@"%u-%lu", (unsigned int)msgType, (unsigned long)[content hash]];
        WRSpoolMsgRecord(@{
            @"bid": @"com.tencent.xin",
            @"scenepid": WRWeChatScenePID(),
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

static BOOL WRHookMsgSourceSelector(Class CMessageMgr, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!sel || ![CMessageMgr instancesRespondToSelector:sel]) return NO;
    Method m = class_getInstanceMethod(CMessageMgr, sel);
    if (!m) return NO;
    if (WRAsyncOnAddMsgOrig) return YES; // 已挂在别的候选上
    WRAsyncOnAddMsgOrig = method_getImplementation(m);
    method_setImplementation(m, (IMP)WRAsyncOnAddMsgHook);
    WRHookedSelectorName = [name retain]; // MRC 同上
    wrLog([NSString stringWithFormat:@"B: hooked %@", name]);
    return YES;
}

static void WRInstallMsgSourceHook(void) {
    Class CMessageMgr = objc_getClass("CMessageMgr");
    if (!CMessageMgr) { wrLog(@"B: no CMessageMgr"); return; }
    // 多候选：8.x 各版本改名全试，命中即挂
    NSArray *candidates = @[@"AsyncOnAddMsg:Wrap:", @"AsyncOnAddMsg:MsgWrap:",
                            @"OnNewMessage:", @"AsyncOnAddMsgList:ListWrap:"];
    for (NSString *name in candidates) {
        if (WRHookMsgSourceSelector(CMessageMgr, name)) return;
    }
    // 全落空：吐出方法表里疑似收消息的入口，下轮锁定真名
    wrLog(@"B: none of candidates exist; class methods:");
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(CMessageMgr) ? CMessageMgr : CMessageMgr, &count);
    unsigned int shown = 0;
    for (unsigned int i = 0; i < count && shown < 12; i++) {
        NSString *n = NSStringFromSelector(method_getName(methods[i]));
        if ([n.lowercaseString containsString:@"addmsg"] || [n.lowercaseString containsString:@"newmessage"]) {
            wrLog([NSString stringWithFormat:@"B cand: %@", n]);
            shown++;
        }
    }
    free(methods);
    if (shown == 0) wrLog(@"B cand: (none matched addmsg/newmessage)");
}

// ===== v2.3.5 探针（一次性，验证解析链后删除）=====
__attribute__((constructor)) static void wxrelaySenderCtor(void) {
    @autoreleasepool {
        wrLog(@"WXRelaySender ctor");
        WRInitLastSentStore();
        WRInstallMsgSourceHook();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRResolveSelfWxid(); // 等微信联系人服务就绪
        });
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

