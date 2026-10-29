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
#import <sys/sysctl.h>
#import "../Shared/WXPreferences.h"

static void wrLog(NSString *msg);
static void WRResolveSelfWxid(void);   // v1.1.11 前置声明（WRSendMessage 在定义前调用）
static void WRDiagIfEnabled(void);     // v1.1.11 前置声明（B hook 在定义前调用）
static NSString *WRSelfWxid;           // v1.1.12：纯 tentative（不带初始化），正式定义在 resolve 段
// v1.1.6 服务入口自适应：8.0.7x+ 走 +[MMServiceCenter defaultCenter]；8.0.5x~7x 走
// MMContextManager.defaultManager → 当前 MMContext（v1.1.9：ctx 自带 getService:，直接用）
static id WRServiceCenter(void) {
    Class M = objc_getClass("MMServiceCenter");
    if (M && [M respondsToSelector:@selector(defaultCenter)]) {
        return ((id(*)(id,SEL))objc_msgSend)(M, @selector(defaultCenter));
    }
    Class MMCM = objc_getClass("MMContextManager");
    if (MMCM && [MMCM respondsToSelector:@selector(defaultManager)]) {
        @try {
            id mgr = ((id(*)(id,SEL))objc_msgSend)(MMCM, @selector(defaultManager));
            NSArray *ctxs = mgr ? [mgr valueForKey:@"m_contexts"] : nil;
            id ctx = (ctxs.count > 0) ? ctxs[0] : nil;
            if (ctx) {
                // v1.1.9 修正：8.0.5x~7x 的正确入口是 **-[MMContext getService:]**（ctx 自带），
                // 不是内层 m_serviceCenter 的 getService:——1.1.6 挖错对象导致微信内部炸
                if ([ctx respondsToSelector:@selector(getService:)]) {
                    wrLog([NSString stringWithFormat:@"svc: use MMContext(%@) directly", NSStringFromClass([ctx class])]);
                    return ctx;
                }
                SEL scSel = NSSelectorFromString(@"serviceCenter");
                id sc = [ctx respondsToSelector:scSel] ? ((id(*)(id,SEL))objc_msgSend)(ctx, scSel) : [ctx valueForKey:@"m_serviceCenter"];
                wrLog([NSString stringWithFormat:@"svc: ctx no getService:, fallback sc=%@ class=%@",
                      sc ? @"非nil" : @"nil", sc ? NSStringFromClass([sc class]) : @"-"]);
                if (sc) return sc;
            }
        } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"svc EXC: %@", e.name]); }
    }
    return nil;
}

static void wrLog(NSString *msg) {
    @try {
        static NSDateFormatter *f = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay.log"];
        // v1.0.10 日志上限 30KB：超限裁头部保留尾部 15KB（对齐到行首）
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (attr && [attr fileSize] > 30 * 1024) {
            NSData *all = [NSData dataWithContentsOfFile:path];
            unsigned long long keep = 15 * 1024;
            if (all.length > keep) {
                NSRange cut = NSMakeRange(all.length - keep, keep);
                NSData *tail = [all subdataWithRange:cut];
                NSRange nl = [tail rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, tail.length > 64 ? 64 : tail.length)];
                if (nl.location != NSNotFound && nl.location + 1 < tail.length)
                    tail = [tail subdataWithRange:NSMakeRange(nl.location + 1, tail.length - nl.location - 1)];
                [tail writeToFile:path atomically:YES];
            }
        }
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
// v1.1.7 就绪门：8.0.75 启动早期（3s）外部调 getService: 会在微信内部炸 unrecognized selector
// （异常在展开期二次抛出转 terminate，@try 兜不住）——就绪前禁止一切微信私 API 调用。
// 就绪信号 = B hook 收到首条消息（消息管线能跑 = 服务可用），事件驱动零轮询
static volatile BOOL WRReady = NO;

// v2.3.2 路A：备注/昵称 → wxid，**仅精准匹配**（不做包含/前缀）；解析失败返回 nil，绝不裸发
static NSString *WRResolveTargetID(NSString *targetId) {
    @try {
        if (!WRReady) return nil; // v1.1.7 就绪门
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return nil;
        id center = WRServiceCenter(); // v1.1.6 自适应入口
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
        if (!WRReady) { wrLog(@"send: not ready, keep task"); { WRInSend = NO; return NO; } } // v1.1.7 就绪门
        // v1.1.10：诊断结束，恢复实际发送
        // v2.3.2 安全线：解析失败绝不裸发（防错发）；标准 id 格式直通不走解析
        BOOL isPlainID = [targetId isEqualToString:@"filehelper"] || [targetId hasSuffix:@"@chatroom"]
            || [targetId hasPrefix:@"wxid_"] || [targetId hasPrefix:@"gh_"];
        NSString *resolved = isPlainID ? targetId : WRResolveTargetID(targetId);
        if (!resolved) { wrLog([NSString stringWithFormat:@"resolve failed, skip '%@'", targetId]); { WRInSend = NO; return NO; } }
        targetId = resolved;
        Class CMessageMgr = objc_getClass("CMessageMgr");
        Class CMessageWrap = objc_getClass("CMessageWrap");
        if (!CMessageMgr || !CMessageWrap) {
            wrLog(@"send: private class missing");
            { WRInSend = NO; return NO; }
        }
        id center = WRServiceCenter(); // v1.1.9：MMContext 本体
        // v1.1.10：SettingUtil getLocalUsrName: 在 8.0.75 不存在（诊断实证），改用 resolve 链的自身 wxid
        NSString *fromUsr = WRSelfWxid;
        if (!fromUsr) { WRResolveSelfWxid(); fromUsr = WRSelfWxid; }
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
        if (!WRReady) { wrLog(@"flush: not ready, keep tasks"); return; } // v1.1.7 就绪门：任务文件原地保留
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
static NSString *WRStr(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSString *WRContactDisplayName(NSString *wxid) {
    if (wxid.length == 0) return wxid;
    @try {
        if (!WRReady) return wxid; // v1.1.7 就绪门
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return wxid;
        id center = WRServiceCenter(); // v1.1.6 自适应入口
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
        id center = WRServiceCenter(); // v1.1.9：优先 MMContext 本体
        // v1.1.9 门禁泛化：center 是 MMContext 本体或内层 serviceCenter，只要响应 getService: 就放行
        wrLog([NSString stringWithFormat:@"resolve: center=%@ class=%@ hasGetService=%d",
              center ? @"非nil" : @"nil",
              center ? NSStringFromClass([center class]) : @"-",
              center ? [center respondsToSelector:@selector(getService:)] : -1]);
        if (!center || ![center respondsToSelector:@selector(getService:)]) { wrLog(@"resolve: center no getService:, abort"); return; }
        id mgr = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr);
        wrLog([NSString stringWithFormat:@"resolve: mgr=%@ class=%@", mgr ? @"非nil" : @"nil", mgr ? NSStringFromClass([mgr class]) : @"-"]);
        if (!mgr || ![mgr respondsToSelector:@selector(getSelfContact)]) return;
        id me = ((id(*)(id,SEL))objc_msgSend)(mgr, @selector(getSelfContact));
        wrLog([NSString stringWithFormat:@"resolve: me=%@ class=%@", me ? @"非nil" : @"nil", me ? NSStringFromClass([me class]) : @"-"]);
        if ([me respondsToSelector:@selector(m_nsUsrName)])
            WRSelfWxid = [[me valueForKey:@"m_nsUsrName"] retain]; // MRC: static strong must retain
        wrLog([NSString stringWithFormat:@"B: self wxid=%@", WRSelfWxid]);
    } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"resolve EXC: %@ %@", e.name, e.reason]); }
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

static void WRSpoolMsgRecord(NSDictionary *record) {
    @try {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_msgs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"msg_%@.json", [[NSUUID UUID] UUIDString]]];
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        if (data) { [data writeToFile:path atomically:YES];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("cn.qwq.wxrelay.msg"), NULL, NULL, YES); }
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"spool EXC %@", e.name]);
    }
}

static IMP WRAsyncOnAddMsgOrig = NULL;
static NSString *WRHookedSelectorName = nil;

// 引用消息 appmsg XML（type 57）→ 转发文本："回复正文\n引用 xxx：原句"。非 type57 返回 nil（不转发）。
static NSString *WRXmlUnescape(NSString *s) {
    if (!s) return nil;
    s = [s stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    s = [s stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    s = [s stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    s = [s stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    s = [s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"]; // 最后还原
    return s;
}

static NSString *WRXmlTagText(NSString *xml, NSString *tag) {
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange r = [xml rangeOfString:open];
    if (r.location == NSNotFound) return nil;
    NSRange r2 = [xml rangeOfString:close options:0 range:NSMakeRange(r.location + r.length, xml.length - r.location - r.length)];
    if (r2.location == NSNotFound) return nil;
    return [xml substringWithRange:NSMakeRange(r.location + r.length, r2.location - (r.location + r.length))];
}

static NSString *WRParseReferAppMsg(NSString *xml) {
    @try {
        if ([xml rangeOfString:@"<type>57<"].location == NSNotFound) return nil;
        NSString *reply = WRXmlUnescape(WRXmlTagText(xml, @"title"));
        NSString *refer = nil;
        NSRange rb = [xml rangeOfString:@"<refermsg>"];
        NSRange re = [xml rangeOfString:@"</refermsg>"];
        if (rb.location != NSNotFound && re.location != NSNotFound && re.location > rb.location) {
            NSString *block = [xml substringWithRange:NSMakeRange(rb.location, re.location + re.length - rb.location)];
            NSString *who = WRXmlUnescape(WRXmlTagText(block, @"displayname"));
            NSString *what = WRXmlUnescape(WRXmlTagText(block, @"content"));
            if (what.length > 0 && [what hasPrefix:@"<"]) {
                // 引用的是链接/卡片等富消息：取内层标题
                NSString *inner = WRXmlUnescape(WRXmlTagText(what, @"title"));
                what = inner.length > 0 ? inner : nil;
            }
            if (what.length > 0) what = [what stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (what.length > 60) what = [[what substringToIndex:60] stringByAppendingString:@"…"];
            if (who.length > 0 && what.length > 0) refer = [NSString stringWithFormat:@"引用 %@：%@", who, what];
            else if (who.length > 0) refer = [NSString stringWithFormat:@"引用 %@", who];
        }
        if (reply.length > 0 && refer.length > 0) return [NSString stringWithFormat:@"%@\n%@", reply, refer];
        if (reply.length > 0) return reply;
        if (refer.length > 0) return refer;
        return nil;
    } @catch (NSException *e) {
        return nil;
    }
}

// v1.0.9 探针：群 CContact 方法名普查（纯反射零调用，每群一次）——为群昵称锁定 8.0.78 真实可用接口
// v1.0.11 群昵称：从群 CContact 的 m_nsChatRoomData XML 解析成员 DisplayName（纯字符串解析，零微信方法调用）
static NSString *WRGroupNickFromRoomData(id groupContact, NSString *memberUsr) {
    if (!groupContact || memberUsr.length == 0) return nil;
    @try {
        NSString *xml = WRStr([groupContact valueForKey:@"m_nsChatRoomData"]);
        if (xml.length == 0) return nil;
        NSString *open = [NSString stringWithFormat:@"<Member UserName=\"%@\">", memberUsr];
        NSRange rb = [xml rangeOfString:open];
        if (rb.location == NSNotFound) return nil;
        NSRange re = [xml rangeOfString:@"</Member>" options:0 range:NSMakeRange(rb.location + rb.length, xml.length - rb.location - rb.length)];
        if (re.location == NSNotFound) return nil;
        NSString *block = [xml substringWithRange:NSMakeRange(rb.location, re.location + re.length - rb.location)];
        NSString *dn = WRXmlUnescape(WRXmlTagText(block, @"DisplayName"));
        return dn.length > 0 ? dn : nil;
    } @catch (NSException *e) { return nil; }
}

static id WRFindContactObj(NSString *usr) {
    @try {
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter || !usr.length || !WRReady) return nil; // v1.1.7 就绪门
        id center = WRServiceCenter(); // v1.1.6 自适应入口
        id mgr = center ? ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr) : nil;
        if (!mgr || ![mgr respondsToSelector:@selector(getContactList:contactType:)]) return nil;
        id list = ((id(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u);
        if (![list isKindOfClass:[NSArray class]]) return nil;
        for (id c in list) {
            if (![c respondsToSelector:@selector(m_nsUsrName)]) continue;
            NSString *u = WRStr([c valueForKey:@"m_nsUsrName"]);
            if ([u isEqualToString:usr]) return c;
        }
    } @catch (NSException *e) { }
    return nil;
}

static void WRAsyncOnAddMsgHook(id self, SEL _cmd, id arg1, id wrap) {
    if (WRAsyncOnAddMsgOrig) {
        // v1.0.7 防炸兜底：WxRelay 延迟挂载后位于 hook 链上游，下游 tweak（如 WxNotify）
        // 在消息处理中抛的 ObjC 异常沿栈传回此调用点，吞掉以免整条链闪退；微信原方法已在下游先执行过
        @try {
            ((void(*)(id,SEL,id,id))WRAsyncOnAddMsgOrig)(self, _cmd, arg1, wrap);
        } @catch (NSException *e) {
            wrLog([NSString stringWithFormat:@"B: 下游hook异常已拦截: %@ %@", e.name, e.reason]);
        }
    }
    @try {
        // 候选参数序归一：单参候选时 wrap 落在 arg1
        if ([WRHookedSelectorName isEqualToString:@"OnNewMessage:"]) wrap = arg1;
        if (WRInSend) return; // 发送中：跳过本次回声/重入
        if (![wrap isKindOfClass:[objc_getClass("CMessageWrap") class]]) return;
        // v1.1.7 就绪门置位：首条消息到达 = 微信消息管线就绪 → 惰性解析自身 wxid + 补发积压任务
        if (!WRReady) {
            WRReady = YES;
            wrLog(@"B: first message -> ready, lazy resolve");
            WRResolveSelfWxid();
            WRFlushTasks();
            WRDiagIfEnabled(); // v1.1.11：诊断开关开着就绪后自动跑一次
        }
        WRWriteMsgSourceFlag();
        // 收文本 + 引用消息（引用=msgType 49 的 appmsg XML，type 57 + refermsg 节点，CMessageWrap isReferMsgType 同源）；系统消息/媒体仍不收
        unsigned int msgType = 0;
        if ([wrap respondsToSelector:@selector(m_uiMessageType)]) msgType = ((unsigned int(*)(id,SEL))objc_msgSend)(wrap, @selector(m_uiMessageType));
        if (msgType != 1 && msgType != 49) return;
        NSString *content = [wrap respondsToSelector:@selector(m_nsContent)] ? WRStr([wrap valueForKey:@"m_nsContent"]) : nil;
        if (content.length == 0) return;
        if (msgType == 49) {
            content = WRParseReferAppMsg(content);
            if (content.length == 0) return; // 非 type57 的 appmsg（链接/文件/小程序等）维持不转
        }
        // 自发消息防线：官方 isSender 位 + 已发文本 60 秒回显双保险，杜绝回环
        BOOL isSender = NO;
        if ([wrap respondsToSelector:@selector(m_bIsSender)]) isSender = ((BOOL(*)(id,SEL))objc_msgSend)(wrap, @selector(m_bIsSender));
        if (isSender || WRTextWasRecentlySent(content)) return;
        NSString *fromUsr = [wrap respondsToSelector:@selector(m_nsFromUsr)] ? WRStr([wrap valueForKey:@"m_nsFromUsr"]) : nil;
        // v1.0.5: m_nsActualUsr 已被 8.x 新架构除名（头文件 0 命中），发言人改取 m_nsRealChatUsr，旧架构字段保留兜底
        NSString *actualUsr = [wrap respondsToSelector:@selector(m_nsRealChatUsr)] ? WRStr([wrap valueForKey:@"m_nsRealChatUsr"]) : nil;
        if (actualUsr.length == 0 && [wrap respondsToSelector:@selector(m_nsActualUsr)]) actualUsr = WRStr([wrap valueForKey:@"m_nsActualUsr"]);
        if (fromUsr.length == 0) return;
        // v2.8.7 自身消息防线：来源 wxid 是自己（单聊直发 / 群聊 actualUsr）一律跳过
        if (WRSelfWxid.length && ([fromUsr isEqualToString:WRSelfWxid]
            || (actualUsr.length && [actualUsr isEqualToString:WRSelfWxid]))) return;
        BOOL isGroup = [fromUsr hasSuffix:@"@chatroom"];
        NSString *chatName = WRContactDisplayName(fromUsr);
        // v1.0.8 回退：getChatRoomMemberDisplayName: 在 8.0.78 上炸（1.0.5 起闪退的头号嫌疑，头文件系 8.0.54/55），
// v1.0.11 群昵称：m_nsChatRoomData XML 的 DisplayName（群昵称）优先，通讯录备注/昵称兜底；
        // 1.0.5 的 getChatRoomMemberDisplayName: 直调已废（8.0.78 内部炸），数据解析全程零微信方法调用
        NSString *speaker = nil;
        if (isGroup && actualUsr.length) {
            id gc = WRFindContactObj(fromUsr);
            speaker = WRGroupNickFromRoomData(gc, actualUsr);
            if (speaker.length == 0) speaker = WRContactDisplayName(actualUsr);
        }
        NSString *title = chatName ?: fromUsr;
        NSString *subtitle = isGroup ? (speaker ?: @"") : @"";
        NSString *msgID = [wrap respondsToSelector:@selector(m_nsMsgId)] ? WRStr([wrap valueForKey:@"m_nsMsgId"]) : nil;
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
// ============ v1.1.2 诊断模块：五路信息收集，结果写公共文件供 Prefs 读取复制 ============
static NSString *WRDiagClassMethods(Class C, NSString *needle1, NSString *needle2) {
    if (!C) return @"(类不存在)";
    unsigned int n = 0;
    Method *ms = class_copyMethodList(C, &n);
    NSMutableString *out = [NSMutableString string];
    for (unsigned int i = 0; i < n; i++) {
        NSString *sel = NSStringFromSelector(method_getName(ms[i]));
        if ((needle1 && [sel rangeOfString:needle1].location != NSNotFound)
            || (needle2 && [sel rangeOfString:needle2].location != NSNotFound)
            || (!needle1 && !needle2))
            [out appendFormat:@"%@ ", sel];
    }
    free(ms);
    return out.length ? out : @"(无匹配)";
}

// v1.2.2 分段落盘：每路探针跑完即写文件，中途炸了也留得住已完成的段落
static void WRDiagWrite(NSMutableString *r) {
    @try {
        NSString *diagPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay-diag.log"];
        [r writeToFile:diagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void WRDiagRun(void) {
    NSMutableString *r = [NSMutableString string];
    static NSDateFormatter *df = nil;
    static dispatch_once_t dfOnce;
    dispatch_once(&dfOnce, ^{ df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss"; });
    [r appendFormat:@"===== WxRelay 诊断 %@ =====\n", [df stringFromDate:[NSDate date]]];
    [r appendFormat:@"微信版本: %@\n", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"];
    char mach[128] = {0}; size_t sz = sizeof(mach);
    sysctlbyname("hw.machine", mach, &sz, NULL, 0);
    [r appendFormat:@"设备: %s\n", mach];

    @try {
        [r appendString:@"\n[1] 服务入口\n"];
        Class M = objc_getClass("MMServiceCenter");
        if (!M) { [r appendString:@"  MMServiceCenter 类不存在\n"]; }
        else {
            [r appendFormat:@"  类方法(全): %@\n", WRDiagClassMethods(object_getClass(M), nil, nil)];
            NSString *found = nil;
            for (NSString *cand in @[@"defaultCenter", @"sharedInstance", @"sharedCenter", @"instance", @"getInstance"]) {
                SEL sel = NSSelectorFromString(cand);
                BOOL ok = [M respondsToSelector:sel];
                [r appendFormat:@"  候选 +[MMServiceCenter %@]: %@\n", cand, ok ? @"存在" : @"无"];
                if (ok && !found) {
                    @try {
                        id c = ((id(*)(id,SEL))objc_msgSend)(M, sel);
                        id mgr = c ? ((id(*)(id,SEL,id))objc_msgSend)(c, @selector(getService:), objc_getClass("CMessageMgr")) : nil;
                        [r appendFormat:@"    -> center=%@ CMessageMgr=%@\n", c ? @"拿到" : @"nil", mgr ? @"拿到" : @"nil"];
                        if (c && mgr) found = cand;
                    } @catch (NSException *e) {
                        [r appendFormat:@"    -> EXC: %@\n", e.name];
                    }
                }
            }
            [r appendFormat:@"  可用入口: %@\n", found ?: @"(无——send/通讯录链路不可用)"];
            // v1.1.6 补探：MMContextManager 路径（8.0.5x~7x 的真实入口）
            // v1.2.2 修正：直接探 **MMContext 本体** 的 getService:——内层 m_serviceCenter 的 getService:
            // 是已知必炸调用（1.1.9 实证），探针自己不能再踩
            Class MMCM = objc_getClass("MMContextManager");
            [r appendFormat:@"  MMContextManager defaultManager: %@\n", (MMCM && [MMCM respondsToSelector:@selector(defaultManager)]) ? @"存在" : @"无"];
            if (MMCM && [MMCM respondsToSelector:@selector(defaultManager)]) {
                @try {
                    id dm = ((id(*)(id,SEL))objc_msgSend)(MMCM, @selector(defaultManager));
                    NSArray *ctxs = dm ? [dm valueForKey:@"m_contexts"] : nil;
                    id ctx = (ctxs.count > 0) ? ctxs[0] : nil;
                    if (ctx) {
                        id cmgr = [ctx respondsToSelector:@selector(getService:)] ? ((id(*)(id,SEL,id))objc_msgSend)(ctx, @selector(getService:), objc_getClass("CMessageMgr")) : nil;
                        [r appendFormat:@"  MMContext 路径: contexts=%lu hasGetService=%d CMessageMgr=%@\n", (unsigned long)ctxs.count, [ctx respondsToSelector:@selector(getService:)], cmgr ? @"拿到" : @"nil"];
                    } else {
                        [r appendFormat:@"  MMContext 路径: contexts=%@\n", ctxs ? @"(空)" : @"nil"];
                    }
                } @catch (NSException *e) {
                    [r appendFormat:@"  MMContext 路径 EXC: %@\n", e.name];
                }
            }
        }
    } @catch (NSException *e) { [r appendFormat:@"  EXC: %@\n", e.name]; }

    @try {
            WRDiagWrite(r); // v1.2.2 段落落盘

    [r appendString:@"\n[2] 消息捕获\n"];
        Class CMessageMgr = objc_getClass("CMessageMgr");
        [r appendFormat:@"  CMessageMgr AddMsg 系: %@\n", WRDiagClassMethods(CMessageMgr, @"AddMsg", @"NewMsg")];
        [r appendFormat:@"  hook 挂载: %@\n", WRHookedSelectorName ?: @"(未挂载)"];
    } @catch (NSException *e) { [r appendFormat:@"  EXC: %@\n", e.name]; }

    @try {
            WRDiagWrite(r); // v1.2.2 段落落盘

    [r appendString:@"\n[3] CMessageWrap 字段\n"];
        Class W = objc_getClass("CMessageWrap");
        for (NSString *f in @[@"m_uiMessageType", @"m_nsContent", @"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr", @"m_nsActualUsr", @"m_nsMsgId", @"m_bIsSender", @"m_uiCreateTime"]) {
            [r appendFormat:@"  %@: %@\n", f, [W instancesRespondToSelector:NSSelectorFromString(f)] ? @"有" : @"无"];
        }
    } @catch (NSException *e) { [r appendFormat:@"  EXC: %@\n", e.name]; }

    @try {
            WRDiagWrite(r); // v1.2.2 段落落盘

    [r appendString:@"\n[4] 通讯录与群数据\n"];
        Class CContactMgr = objc_getClass("CContactMgr");
        // v1.1.11：改走 v1.1.9 实证入口（MMContext 本体 getService:），旧候选单例普查并入 [1]
        id center = WRServiceCenter();
        if (![center respondsToSelector:@selector(getService:)]) { [r appendString:@"  服务中心不可用，跳过\n"]; }
        else {
            id mgr = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr);
            NSArray *list = [mgr respondsToSelector:@selector(getContactList:contactType:)] ? ((NSArray *(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u) : nil;
            [r appendFormat:@"  getContactList: %@ 条目=%lu\n", list ? @"可用" : @"不可用", (unsigned long)list.count];
            if (list) {
                unsigned int groups = 0, dumped = 0;
                for (id c2 in list) {
                    if (![c2 respondsToSelector:@selector(m_nsUsrName)]) continue;
                    NSString *u = WRStr([c2 valueForKey:@"m_nsUsrName"]);
                    if (![u hasSuffix:@"@chatroom"]) continue;
                    groups++;
                    if (dumped < 3) {
                        dumped++;
                        NSString *xml = WRStr([c2 valueForKey:@"m_nsChatRoomData"]) ?: @"";
                        [r appendFormat:@"  群 %@ 成员数据: len=%lu 前200: %@\n", u, (unsigned long)xml.length, [xml substringToIndex:MIN(200, xml.length)]];
                    }
                }
                [r appendFormat:@"  群总数: %u（前 3 个已采样）\n", groups];
            }
        }
    } @catch (NSException *e) { [r appendFormat:@"  EXC: %@\n", e.name]; }

    @try {
            WRDiagWrite(r); // v1.2.2 段落落盘

    [r appendString:@"\n[5] 直发链\n"];
        Class SU = objc_getClass("SettingUtil");
        [r appendFormat:@"  SettingUtil: %@\n", SU ? @"有" : @"无"];
        [r appendFormat:@"  getLocalUsrName:: %@\n", SU && [SU instancesRespondToSelector:@selector(getLocalUsrName:)] ? @"有" : @"无"];
        Class CM = objc_getClass("CMessageMgr");
        [r appendFormat:@"  AddMsg:MsgWrap:: %@\n", CM && [CM instancesRespondToSelector:@selector(AddMsg:MsgWrap:)] ? @"有" : @"无"];
        [r appendString:@"  (诊断不真发消息)\n"];
    } @catch (NSException *e) { [r appendFormat:@"  EXC: %@\n", e.name]; }

        WRDiagWrite(r);
    [r appendString:@"===== 诊断结束 =====\n"];
    // v1.1.11 诊断改版：结果写微信沙盒 tmp/wxrelay-diag.log（与 wxrelay.log 同目录），不再走剪贴板/CFPreferences
    NSString *diagPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay-diag.log"];
    [r writeToFile:diagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    wrLog(@"diag: 诊断完成，已写入 wxrelay-diag.log");
}

static void WRDiagDarwinCallback(CFNotificationCenterRef __unused c, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!WRReady) { wrLog(@"diag: not ready, skip (首次消息就绪后自动补跑)"); return; } // v1.1.11 就绪门
        WRDiagRun();
    });
}

// v1.1.11：诊断开关开启时，就绪后自动跑一次
static void WRDiagIfEnabled(void) {
    @try {
        if ([[[WXPreferences loadPreferences] objectForKey:WXDiagLogEnabledKey] boolValue]) {
            dispatch_async(dispatch_get_main_queue(), ^{ WRDiagRun(); });
        }
    } @catch (NSException *e) { }
}

__attribute__((constructor)) static void wxrelaySenderCtor(void) {
    @autoreleasepool {
        wrLog(@"WXRelaySender ctor");
        WRInitLastSentStore();
        // v1.0.7 延迟挂载：让其它消息 hook（WxNotify 等）先挂，WxRelay 排 hook 链尾（上游），
        // 配合 orig 处的 @try 兜住下游异常。窗口期(3s)内的消息漏转发，可接受
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRInstallMsgSourceHook();
            // v1.1.7：启动期 getService:(CContactMgr) 会在 8.0.75 内部炸（unrecognized selector，
            // 展开期二次抛出转 terminate，@try 兜不住）——WRResolveSelfWxid 改 B hook 首条消息时惰性调用
        });
        WRWriteMsgSourceFlag();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, WRDiagDarwinCallback, CFSTR("cn.qwq.wxrelay.diag/run"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRFlushTasks(); // 启动补发积压
            // v2.5.1：保活/轮询已移除，锁屏存活交给 AppData 真后台（用户拍板）
        });
    }
}

