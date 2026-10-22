#import <Foundation/Foundation.h>
#import "../WXRelayPrefs/WXPImportExportPayload.h"
#import "../Shared/WXPreferences.h"

static void WXAssert(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"WXImportExportPayloadTestFailure" reason:message userInfo:nil];
    }
}

static NSMutableDictionary *basePreferencesWithApp(NSString *bundleID, NSArray *contains) {
    NSDictionary *rules = [WXPreferences normalizedRulesDictionaryFromEnabled:YES
                                                                    contains:contains
                                                                     exclude:@[]
                                                                       regex:@[]];
    return [@{
        WXEnabledKey: @YES,
        WXGlobalRulesEnabledKey: @YES,
        WXGlobalContainsKey: @[],
        WXGlobalExcludeKey: @[],
        WXGlobalRegexKey: @[],
        WXAppRulesKey: @{ bundleID: rules },
        WXLoggingEnabledKey: @YES,
        WXLoggingDisabledBundleIdentifiersKey: @[],
        WXLogEntryLimitKey: @500,
        WXPrefOnlyConfiguredAppsKey: @NO,
        WXPrefShowSystemAppsKey: @YES,
        WXPrefShowTrollAppsKey: @YES,
        WXDeleteFilteredNotificationsKey: @NO
    } mutableCopy];
}

static NSDictionary *entry(NSString *text, NSString *scope) {
    return [WXPreferences ruleEntryWithText:text enabled:YES identifier:nil scope:scope];
}

static NSDictionary *rulesDict(NSString *mode, NSArray *contains) {
    NSDictionary *raw = @{
        WXRulesEnabledKey: @YES,
        WXRulesModeKey: mode,
        WXRulesContainsKey: contains,
        WXRulesExcludeKey: @[],
        WXRulesRegexKey: @[]
    };
    return [WXPreferences normalizedRulesDictionaryFromRawDictionary:raw];
}

int main(void) {
    @autoreleasepool {
        // A2 / A36: 导出 app-rules 载荷结构正确
        NSDictionary *rules = rulesDict(WXRulesModeBlacklist, @[ entry(@"Payment", WXRuleScopeMessage) ]);
        NSDictionary *appRulesPayload = [WXPImportExportPayload appRulesPayloadForBundleIdentifier:@"com.example.app" rules:rules];
        WXAssert([appRulesPayload[WXPPayloadTypeKey] isEqualToString:WXPPayloadTypeAppRules], @"app-rules payload type");
        WXAssert([appRulesPayload[WXPPayloadBundleIDKey] isEqualToString:@"com.example.app"], @"app-rules bundleID");
        WXAssert([appRulesPayload[WXPPayloadRulesKey] isKindOfClass:[NSDictionary class]], @"app-rules rules dict");

        // A2 / A3: app-rules-bundle 载荷结构正确，单应用也归入 bundle
        NSDictionary *bundlePayload = [WXPImportExportPayload appRulesBundlePayloadForApps:@{
            @"com.example.appA": rules
        }];
        WXAssert([bundlePayload[WXPPayloadTypeKey] isEqualToString:WXPPayloadTypeAppRulesBundle], @"bundle payload type");
        WXAssert([bundlePayload[WXPPayloadAppsKey] isKindOfClass:[NSDictionary class]], @"bundle apps dict");
        WXAssert([bundlePayload[WXPPayloadAppsKey][@"com.example.appA"] isKindOfClass:[NSDictionary class]], @"bundle keeps appA");

        // A13: full-config 外壳
        NSDictionary *fullPayload = [WXPImportExportPayload fullConfigPayloadFromPreferences:@{ WXEnabledKey: @YES, WXAppRulesKey: @{} }];
        WXAssert([fullPayload[WXPPayloadTypeKey] isEqualToString:WXPPayloadTypeFullConfig], @"full-config payload type");
        WXAssert([fullPayload[WXPPayloadPreferencesKey] isKindOfClass:[NSDictionary class]], @"full-config preferences dict");

        // A25 / A26 / A35: 单应用合并整体替换该应用，其他应用与全局规则不变
        NSMutableDictionary *prefs = basePreferencesWithApp(@"com.existing", @[ entry(@"Old", WXRuleScopeMessage) ]);
        prefs[WXLoggingDisabledBundleIdentifiersKey] = @[ @"com.existing" ];
        NSDictionary *singlePayload = [WXPImportExportPayload appRulesPayloadForBundleIdentifier:@"com.imported"
                                                                                          rules:rulesDict(WXRulesModeWhitelist, @[ entry(@"New", WXRuleScopeAll) ])];
        WXPImportExportPayloadResult *r1 = [WXPImportExportPayload applyPayload:singlePayload toMutablePreferences:prefs];
        WXAssert(r1.kind == WXPPayloadKindAppRules, @"single kind");
        WXAssert(r1.appCount == 1, @"single appCount 1");
        WXAssert([prefs[WXAppRulesKey][@"com.imported"][WXRulesModeKey] isEqualToString:WXRulesModeWhitelist], @"imported app replaced with whitelist mode");
        WXAssert([prefs[WXAppRulesKey][@"com.existing"][WXRulesContainsKey] count] == 1, @"existing app untouched");
        WXAssert([prefs[WXGlobalRulesEnabledKey] boolValue] == YES, @"global rules untouched");
        WXAssert([prefs[WXLoggingDisabledBundleIdentifiersKey] containsObject:@"com.existing"], @"logging disabled list untouched");
        WXAssert([prefs[WXLogEntryLimitKey] integerValue] == 500, @"log entry limit untouched");

        // 整体替换：同 bundleID 旧规则被新规则替换
        NSMutableDictionary *prefs2 = basePreferencesWithApp(@"com.app", @[ entry(@"OldA", WXRuleScopeMessage), entry(@"OldB", WXRuleScopeMessage) ]);
        NSDictionary *replacePayload = [WXPImportExportPayload appRulesPayloadForBundleIdentifier:@"com.app"
                                                                                           rules:rulesDict(WXRulesModeBlacklist, @[ entry(@"NewOnly", WXRuleScopeAll) ])];
        WXPImportExportPayloadResult *r2 = [WXPImportExportPayload applyPayload:replacePayload toMutablePreferences:prefs2];
        NSArray *containsAfter = prefs2[WXAppRulesKey][@"com.app"][WXRulesContainsKey];
        WXAssert(containsAfter.count == 1, @"same bundleID replaced (count 1)");
        WXAssert([[WXPreferences ruleTextFromEntry:containsAfter[0]] isEqualToString:@"NewOnly"], @"same bundleID replaced (NewOnly)");

        // A19 / A26 / A28 / A31: 多应用合并，空 bundleID 跳过，计数只算有效应用
        NSMutableDictionary *prefs3 = basePreferencesWithApp(@"com.keep", @[ entry(@"Keep", WXRuleScopeMessage) ]);
        NSDictionary *multiPayload = [WXPImportExportPayload appRulesBundlePayloadForApps:@{
            @"com.app1": rulesDict(WXRulesModeBlacklist, @[ entry(@"A1", WXRuleScopeMessage) ]),
            @"com.app2": rulesDict(WXRulesModeBlacklist, @[ entry(@"A2", WXRuleScopeMessage) ]),
            @"": rulesDict(WXRulesModeBlacklist, @[ entry(@"Skipped", WXRuleScopeMessage) ])
        }];
        WXPImportExportPayloadResult *r3 = [WXPImportExportPayload applyPayload:multiPayload toMutablePreferences:prefs3];
        WXAssert(r3.kind == WXPPayloadKindAppRulesBundle, @"bundle kind");
        WXAssert(r3.appCount == 2, @"bundle appCount 2 (empty bundleID skipped)");
        WXAssert([prefs3[WXAppRulesKey][@"com.app1"][WXRulesContainsKey] count] == 1, @"app1 imported");
        WXAssert([prefs3[WXAppRulesKey][@"com.app2"][WXRulesContainsKey] count] == 1, @"app2 imported");
        WXAssert([prefs3[WXAppRulesKey][@"com.keep"][WXRulesContainsKey] count] == 1, @"com.keep untouched");
        WXAssert([prefs3[WXAppRulesKey] objectForKey:@""] == nil, @"empty bundleID not added");

        // A20 / A29: full-config 覆盖整份
        NSMutableDictionary *prefs4 = basePreferencesWithApp(@"com.old", @[ entry(@"Old", WXRuleScopeMessage) ]);
        NSDictionary *fullConfigPayload = [WXPImportExportPayload fullConfigPayloadFromPreferences:@{
            WXEnabledKey: @NO,
            WXAppRulesKey: @{ @"com.new": rulesDict(WXRulesModeBlacklist, @[ entry(@"Fresh", WXRuleScopeMessage) ]) },
            WXGlobalContainsKey: @[ entry(@"Global", WXRuleScopeMessage) ]
        }];
        WXPImportExportPayloadResult *r4 = [WXPImportExportPayload applyPayload:fullConfigPayload toMutablePreferences:prefs4];
        WXAssert(r4.kind == WXPPayloadKindFullConfig, @"full-config kind");
        WXAssert([prefs4[WXEnabledKey] boolValue] == NO, @"full-config overwrote Enabled");
        WXAssert([prefs4[WXAppRulesKey][@"com.new"][WXRulesContainsKey] count] == 1, @"full-config imported com.new");
        WXAssert([prefs4[WXAppRulesKey] objectForKey:@"com.old"] == nil, @"full-config dropped com.old");
        WXAssert([prefs4[WXGlobalContainsKey] count] == 1, @"full-config imported global contains");

        // A21 / A37: 无 type 的旧版 flat 识别为完整配置，覆盖整份
        NSMutableDictionary *prefs5 = basePreferencesWithApp(@"com.old", @[ entry(@"Old", WXRuleScopeMessage) ]);
        NSDictionary *legacyFlat = @{
            WXEnabledKey: @YES,
            WXGlobalRulesEnabledKey: @NO,
            WXGlobalContainsKey: @[],
            WXGlobalExcludeKey: @[],
            WXGlobalRegexKey: @[],
            WXAppRulesKey: @{ @"com.legacy": @{ WXRulesEnabledKey: @YES, WXRulesModeKey: WXRulesModeWhitelist, WXRulesContainsKey: @[ entry(@"Legacy", WXRuleScopeMessage) ], WXRulesExcludeKey: @[], WXRulesRegexKey: @[] } }
        };
        WXAssert([WXPImportExportPayload kindOfPayload:legacyFlat] == WXPPayloadKindFullConfig, @"legacy flat recognized as full-config");
        WXPImportExportPayloadResult *r5 = [WXPImportExportPayload applyPayload:legacyFlat toMutablePreferences:prefs5];
        WXAssert(r5.kind == WXPPayloadKindFullConfig, @"legacy flat kind full-config");
        WXAssert([prefs5[WXAppRulesKey][@"com.legacy"][WXRulesModeKey] isEqualToString:WXRulesModeWhitelist], @"legacy flat imported com.legacy");
        WXAssert([prefs5[WXAppRulesKey] objectForKey:@"com.old"] == nil, @"legacy flat dropped com.old");

        // A16: 非 JSON / 非 dict 报错
        NSError *err = nil;
        NSDictionary *badPayload = [WXPImportExportPayload payloadFromJSONString:@"not json" error:&err];
        WXAssert(badPayload == nil, @"non-JSON returns nil");
        WXAssert(err != nil, @"non-JSON sets error");

        err = nil;
        NSDictionary *arrayPayload = [WXPImportExportPayload payloadFromJSONString:@"[1,2,3]" error:&err];
        WXAssert(arrayPayload == nil, @"non-object root returns nil");

        // A22: 未知 type 报错，不修改配置
        NSMutableDictionary *prefs6 = basePreferencesWithApp(@"com.keep", @[ entry(@"Keep", WXRuleScopeMessage) ]);
        NSDictionary *unknownPayload = @{ WXPPayloadTypeKey: @"something-unknown", @"data": @{} };
        WXPImportExportPayloadResult *r6 = [WXPImportExportPayload applyPayload:unknownPayload toMutablePreferences:prefs6];
        WXAssert(r6.kind == WXPPayloadKindUnknown, @"unknown kind");
        WXAssert(r6.error != nil, @"unknown sets error");
        WXAssert([prefs6[WXAppRulesKey][@"com.keep"][WXRulesContainsKey] count] == 1, @"unknown did not modify preferences");

        // A28: 单应用载荷 bundleID 为空报错
        NSMutableDictionary *prefs7 = basePreferencesWithApp(@"com.keep", @[ entry(@"Keep", WXRuleScopeMessage) ]);
        NSDictionary *emptyBundlePayload = [WXPImportExportPayload appRulesPayloadForBundleIdentifier:@""
                                                                                               rules:[WXPreferences normalizedRulesDictionaryFromRawDictionary:nil]];
        WXPImportExportPayloadResult *r7 = [WXPImportExportPayload applyPayload:emptyBundlePayload toMutablePreferences:prefs7];
        WXAssert(r7.error != nil, @"empty bundleID sets error");
        WXAssert([prefs7[WXAppRulesKey][@"com.keep"][WXRulesContainsKey] count] == 1, @"empty bundleID did not modify preferences");

        // A36: 导出载荷规则条目结构与偏好一致（id/text/enabled/scope）
        NSDictionary *ruleEntry = appRulesPayload[WXPPayloadRulesKey][WXRulesContainsKey][0];
        WXAssert([ruleEntry[WXRuleEntryTextKey] isEqualToString:@"Payment"], @"exported entry text");
        WXAssert([ruleEntry[WXRuleEntryEnabledKey] boolValue] == YES, @"exported entry enabled");
        WXAssert([ruleEntry[WXRuleEntryScopeKey] isEqualToString:WXRuleScopeMessage], @"exported entry scope");
        WXAssert([ruleEntry[WXRuleEntryIdentifierKey] isKindOfClass:[NSString class]], @"exported entry id");

        NSLog(@"All WXPImportExportPayload tests passed.");
    }
    return 0;
}
