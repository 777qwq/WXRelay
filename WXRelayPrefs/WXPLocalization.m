#import "WXPLocalization.h"
#import "../Shared/WXPreferences.h"

NSBundle *WXPPrefsBundle(void) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = [NSBundle bundleWithPath:@"/Library/PreferenceBundles/WXRelayPrefs.bundle"];
        if (!bundle) {
            bundle = [NSBundle bundleForClass:NSClassFromString(@"WXPRootListController") ?: [NSObject class]];
        }
        if (!bundle) {
            bundle = NSBundle.mainBundle;
        }
    });
    return bundle;
}

NSString *WXPLocalizedString(NSString *key) {
    return [WXPPrefsBundle() localizedStringForKey:key value:key table:@"Localizable"];
}

NSString *WXPLocalizedRuleEditorTitle(WXPRuleEditorKind editorKind) {
    switch (editorKind) {
        case WXPRuleEditorKindExclude:
            return WXPLocalizedString(@"RULE_EXCLUDE_TITLE");
        case WXPRuleEditorKindRegex:
            return WXPLocalizedString(@"RULE_REGEX_TITLE");
        default:
            return WXPLocalizedString(@"RULE_CONTAINS_TITLE");
    }
}

static BOOL WXPModeIsWhitelist(NSString *mode) {
    return [[WXPreferences normalizedRulesMode:mode] isEqualToString:WXRulesModeWhitelist];
}

NSString *WXPLocalizedRuleEditorTitleForMode(WXPRuleEditorKind editorKind, NSString *mode) {
    BOOL whitelist = WXPModeIsWhitelist(mode);
    switch (editorKind) {
        case WXPRuleEditorKindExclude:
            return WXPLocalizedString(whitelist ? @"RULE_FORCE_BLOCK_TITLE" : @"RULE_ALLOW_EXCEPTION_TITLE");
        case WXPRuleEditorKindRegex:
            return WXPLocalizedString(whitelist ? @"RULE_REGEX_ALLOW_TITLE" : @"RULE_REGEX_BLOCK_TITLE");
        default:
            return WXPLocalizedString(whitelist ? @"RULE_ALLOW_KEYWORDS_TITLE" : @"RULE_BLOCK_KEYWORDS_TITLE");
    }
}

NSString *WXPLocalizedRulesListFooterForMode(WXPRuleEditorKind editorKind, NSString *mode) {
    BOOL whitelist = WXPModeIsWhitelist(mode);
    switch (editorKind) {
        case WXPRuleEditorKindExclude:
            return WXPLocalizedString(whitelist ? @"RULES_LIST_FORCE_BLOCK_FOOTER" : @"RULES_LIST_ALLOW_EXCEPTION_FOOTER");
        case WXPRuleEditorKindRegex:
            return WXPLocalizedString(whitelist ? @"RULES_LIST_REGEX_ALLOW_FOOTER" : @"RULES_LIST_REGEX_BLOCK_FOOTER");
        default:
            return WXPLocalizedString(whitelist ? @"RULES_LIST_ALLOW_KEYWORDS_FOOTER" : @"RULES_LIST_BLOCK_KEYWORDS_FOOTER");
    }
}

NSString *WXPLocalizedRulesListPlaceholderForMode(WXPRuleEditorKind editorKind, NSString *mode) {
    BOOL whitelist = WXPModeIsWhitelist(mode);
    switch (editorKind) {
        case WXPRuleEditorKindExclude:
            return WXPLocalizedString(whitelist ? @"RULES_LIST_FORCE_BLOCK_PLACEHOLDER" : @"RULES_LIST_ALLOW_EXCEPTION_PLACEHOLDER");
        case WXPRuleEditorKindRegex:
            return WXPLocalizedString(whitelist ? @"RULES_LIST_REGEX_ALLOW_PLACEHOLDER" : @"RULES_LIST_REGEX_BLOCK_PLACEHOLDER");
        default:
            return WXPLocalizedString(whitelist ? @"RULES_LIST_ALLOW_KEYWORDS_PLACEHOLDER" : @"RULES_LIST_BLOCK_KEYWORDS_PLACEHOLDER");
    }
}

NSString *WXPLocalizedScopeName(NSString *scope) {
    if ([scope isEqualToString:WXRuleScopeTitle]) {
        return WXPLocalizedString(@"SCOPE_TITLE");
    }
    if ([scope isEqualToString:WXRuleScopeSubtitle]) {
        return WXPLocalizedString(@"SCOPE_SUBTITLE");
    }
    if ([scope isEqualToString:WXRuleScopeAll]) {
        return WXPLocalizedString(@"SCOPE_ALL");
    }
    return WXPLocalizedString(@"SCOPE_MESSAGE");
}

NSString *WXPLocalizedMatchModeName(NSString *mode) {
    if ([mode isEqualToString:WXMatchModeExclude]) {
        return WXPLocalizedString(@"RULE_EXCLUDE_TITLE");
    }
    if ([mode isEqualToString:WXMatchModeRegex]) {
        return WXPLocalizedString(@"RULE_REGEX_TITLE");
    }
    if ([mode isEqualToString:WXMatchModeWhitelistDefault]) {
        return WXPLocalizedString(@"RULE_WHITELIST_DEFAULT_TITLE");
    }
    if ([mode isEqualToString:WXMatchModeContains]) {
        return WXPLocalizedString(@"RULE_CONTAINS_TITLE");
    }
    return mode.length > 0 ? mode : WXPLocalizedString(@"COMMON_UNKNOWN");
}

NSString *WXPLocalizedDeleteStatusName(NSString *status) {
    if ([status isEqualToString:@"success"]) {
        return WXPLocalizedString(@"DELETE_STATUS_SUCCESS");
    }
    if ([status isEqualToString:@"failed"]) {
        return WXPLocalizedString(@"DELETE_STATUS_FAILED");
    }
    if ([status isEqualToString:@"skipped"]) {
        return WXPLocalizedString(@"DELETE_STATUS_SKIPPED");
    }
    return status.length > 0 ? status : WXPLocalizedString(@"COMMON_UNKNOWN");
}

static NSString *WXPLocalizedDeleteMethodName(NSString *method) {
    if ([method isEqualToString:@"clearBulletinIDs"]) {
        return WXPLocalizedString(@"DELETE_METHOD_CLEAR_BULLETIN_IDS");
    }
    if ([method isEqualToString:@"withdrawPublisher"]) {
        return WXPLocalizedString(@"DELETE_METHOD_WITHDRAW_PUBLISHER");
    }
    if ([method isEqualToString:@"withdrawRecord"]) {
        return WXPLocalizedString(@"DELETE_METHOD_WITHDRAW_RECORD");
    }
    if ([method isEqualToString:@"removeBulletin"]) {
        return WXPLocalizedString(@"DELETE_METHOD_REMOVE_BULLETIN");
    }
    if ([method isEqualToString:@"removeBulletinReschedule"]) {
        return WXPLocalizedString(@"DELETE_METHOD_REMOVE_BULLETIN_RESCHEDULE");
    }
    if ([method isEqualToString:@"none"]) {
        return WXPLocalizedString(@"DELETE_METHOD_NONE");
    }
    if ([method isEqualToString:@"invalid-input"]) {
        return WXPLocalizedString(@"DELETE_METHOD_INVALID_INPUT");
    }
    return method.length > 0 ? method : WXPLocalizedString(@"COMMON_UNKNOWN");
}

NSString *WXPLocalizedDeleteMethodSummary(NSString *methods) {
    if (methods.length == 0) {
        return WXPLocalizedString(@"COMMON_UNKNOWN");
    }

    NSArray<NSString *> *components = [methods componentsSeparatedByString:@","];
    NSMutableArray<NSString *> *localizedComponents = [NSMutableArray arrayWithCapacity:components.count];
    for (NSString *component in components) {
        NSString *trimmed = [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }
        [localizedComponents addObject:WXPLocalizedDeleteMethodName(trimmed)];
    }

    if (localizedComponents.count == 0) {
        return WXPLocalizedString(@"COMMON_UNKNOWN");
    }
    return [localizedComponents componentsJoinedByString:@", "];
}
