#!/bin/bash
# 主机端回归测试：直接编译 tests/*.m 并运行。
# 测试文件自带所需常量与桩实现；只有 WXPGlobalScanEntryGroupingTests 编译真实源码。
# 其余测试需要链接真实 Shared/Prefs 源码以提供 extern 常量与真实类，
# 同时用 -D 强制桩实现优先（测试文件内的定义与生产常量同值）。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
SHARED="Shared/WXPreferences.m Shared/WXLogStore.m Shared/WXNotificationHistoryBridge.m"
for t in tests/*.m; do
  name="$(basename "$t" .m)"
  out="/tmp/nf-test-$name"
  case "$name" in
    WXPGlobalScanEntryGroupingTests)
      srcs="tests/$name.m WXRelayPrefs/WXPNotificationHistoryClient.m $SHARED"
      ;;
    WXRuleEngineModeTests)
      srcs="tests/$name.m Shared/WXPreferences.m WXRelayTweak/WXRuleEngine.m WXRelayTweak/WXNotificationRecord.m"
      ;;
    WXWhitelistDedupeTests)
      echo "SKIP $name (XCTest-based)"
      continue
      ;;
    WXPNotificationRuleTokenBuilderTests)
      # 测试自带常量与桩 WXPreferences，与真实源码重复定义 → 只链 TokenBuilder。
      srcs="tests/$name.m WXRelayPrefs/WXPNotificationRuleTokenBuilder.m"
      ;;
    WXPImportExportPayloadTests)
      srcs="tests/$name.m WXRelayPrefs/WXPImportExportPayload.m Shared/WXPreferences.m"
      ;;
    WXLogStore*)
      # 桩 WXPreferences 与真实 WXPreferences 冲突：只链接 WXLogStore 与其需要的常量。
      # 测试自带常量定义，链接真实 WXPreferences.m 会重复定义 → 只链 WXLogStore.m。
      srcs="tests/$name.m Shared/WXLogStore.m"
      ;;
    *)
      srcs="tests/$name.m $SHARED"
      ;;
  esac
  if xcrun clang -fobjc-arc -framework Foundation $srcs -I Shared -I WXRelayPrefs -I WXRelayTweak -o "$out" 2>/tmp/nf-test-$name.err; then
    if "$out"; then
      echo "PASS $name"
    else
      echo "FAIL(run) $name"; fail=1
    fi
  else
    echo "FAIL(build) $name"; head -6 /tmp/nf-test-$name.err; fail=1
  fi
done
exit $fail
