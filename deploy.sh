#!/bin/bash
# 装到实机（免费 Apple ID 签名，7 天到期）
# 不依赖 xcode-select —— 用 DEVELOPER_DIR 指定工具链，不需要 sudo 切换。
set -uo pipefail
cd "$(dirname "$0")"

# 优先用 Xcode 27（macOS 27 上唯一能开 GUI 的），没有就退回 26.6
if [ -d /Applications/Xcode-beta.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
else
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
echo "工具链: $(xcodebuild -version 2>/dev/null | head -1)  ($DEVELOPER_DIR)"

fail() { echo ""; echo "✗ $1"; echo ""; [ -n "${2:-}" ] && echo "  怎么解: $2"; exit 1; }

# --check：只报告签名还剩多久，不安装
if [ "${1:-}" = "--check" ]; then
  P=$(ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision 2>/dev/null | head -1)
  [ -n "$P" ] || { echo "还没有 provisioning profile —— 先跑一次 ./deploy.sh"; exit 1; }
  security cms -D -i "$P" > /tmp/.nccubus_prof.plist 2>/dev/null
  EXP=$(plutil -extract ExpirationDate raw -o - /tmp/.nccubus_prof.plist 2>/dev/null)
  rm -f /tmp/.nccubus_prof.plist
  EXP_S=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$EXP" +%s 2>/dev/null)
  NOW_S=$(date +%s)
  LEFT=$(( (EXP_S - NOW_S) / 86400 ))
  HRS=$(( (EXP_S - NOW_S) % 86400 / 3600 ))
  LOCAL=$(date -j -f "%s" "$EXP_S" "+%Y-%m-%d %H:%M (%a)" 2>/dev/null)
  echo "签名到期: $LOCAL"
  if [ "$EXP_S" -le "$NOW_S" ]; then
    echo "状态: ✗ 已过期，App 打不开了。跑 ./deploy.sh 续命。"
  elif [ "$LEFT" -le 1 ]; then
    echo "状态: ⚠ 只剩 ${LEFT} 天 ${HRS} 小时，建议现在就续。"
  else
    echo "状态: ✓ 还有 ${LEFT} 天 ${HRS} 小时"
  fi
  exit 0
fi

echo ""
echo "── 预检 1/3：授权条款 ──────────────"
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  xcodebuild -version >/dev/null 2>&1 || \
    fail "Xcode 授权条款还没同意" "sudo xcodebuild -license accept  然后重跑本脚本"
fi
echo "✓ 通过"

echo ""
echo "── 预检 2/3：签名身份 ──────────────"
# 免费帐号的凭证是「第一次签东西」时才产生的，不是登入就有。
# 所以这里只警告，不挡 —— 让下面的 -allowProvisioningUpdates 去跟 Apple 要凭证。
IDENT=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1)
if [ -n "$IDENT" ]; then
  CERTNAME=$(echo "$IDENT" | sed -n 's/.*"\(.*\)"/\1/p')
  # ⚠️ CN 括号里那串（例如 NS528436PR）是「凭证 ID」，不是 Team ID。
  # 真正的 Team ID 在凭证 subject 的 OU 栏位。用错会得到
  # "No Account for Team ..." + "No profiles were found"。
  TEAM=$(security find-certificate -c "$CERTNAME" -p 2>/dev/null \
         | openssl x509 -noout -subject 2>/dev/null \
         | tr '/' '\n' | sed -n 's/^OU=//p' | head -1)
  echo "✓ $CERTNAME"
  if [ -n "$TEAM" ]; then
    echo "  Team ID: $TEAM  (取自凭证 OU)"
  else
    echo "⚠ 无法从凭证取得 Team ID，交给 Xcode 自动决定"
  fi
else
  # 还没有凭证，试着从 Xcode 已登入的帐号取得 Team ID
  TEAM=$(/usr/libexec/PlistBuddy -c "Print :IDEProvisioningTeams" \
         ~/Library/Preferences/com.apple.dt.Xcode.plist 2>/dev/null \
         | grep -oE '\bteamID = [A-Z0-9]{10}' | awk '{print $3}' | head -1)
  if [ -z "$TEAM" ]; then
    fail "Xcode 里没有登入任何 Apple ID" \
      "开 Xcode → Settings(⌘,) → Apple Accounts → Sign In → 完成密码与双因素验证"
  fi
  echo "⚠ 还没有开发凭证，稍后由 Xcode 自动申请"
  echo "  Team ID: $TEAM"
fi

echo ""
echo "── 预检 3/3：装置 ──────────────────"
DEVJSON=$(mktemp)
xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1
N=$(jq '[.result.devices[]?] | length' "$DEVJSON" 2>/dev/null || echo 0)
[ "$N" -gt 0 ] || fail "没有连线的装置" "用传输线接上 iPhone，解锁，点「信任这台电脑」"
UDID=$(jq -r '[.result.devices[]?][0].hardwareProperties.udid' "$DEVJSON")
NAME=$(jq -r '[.result.devices[]?][0].deviceProperties.name' "$DEVJSON")
OSV=$(jq -r '[.result.devices[]?][0].deviceProperties.osVersionNumber' "$DEVJSON")
echo "✓ $NAME  (iOS $OSV)  UDID: $UDID"
DEVMODE=$(jq -r '[.result.devices[]?][0].deviceProperties.developerModeStatus // "unknown"' "$DEVJSON")
if [ "$DEVMODE" = "disabled" ]; then
  fail "iPhone 的开发者模式没开" \
    "iPhone → 设定 → 隐私权与安全性 → 开发者模式 → 打开 → 重开机"
fi

echo ""
echo "── 编译并签名 ──────────────────────"
BUILDLOG=$(mktemp)
xcodebuild -project NCCUBus.xcodeproj -scheme NCCUBus \
  -configuration Debug -sdk iphoneos -destination "id=$UDID" \
  -derivedDataPath build-device \
  ${TEAM:+DEVELOPMENT_TEAM="$TEAM"} CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build > "$BUILDLOG" 2>&1
grep -E "error:|BUILD" "$BUILDLOG" || true

APP="build-device/Build/Products/Debug-iphoneos/NCCUBus.app"
# ⚠️ 不能只检查 .app 存不存在 —— 上一次成功编译的产物会留在原地，
# 于是编译失败时会把旧版装上去，而且完全不报错。必须验 BUILD SUCCEEDED。
if ! grep -q "BUILD SUCCEEDED" "$BUILDLOG"; then
  echo ""
  fail "编译失败，已中止安装（避免装成旧版）" \
       "完整 log: $BUILDLOG"
fi
[ -d "$APP" ] || fail "编译成功但找不到 .app" "把上面的讯息贴给我"

echo ""
echo "── 安装 ────────────────────────────"
xcrun devicectl device install app --device "$UDID" "$APP" || fail "安装失败" "确认 iPhone 已解锁"

cat <<'MSG'

✓ 装好了。

第一次开会跳「不受信任的开发者」：
  iPhone 设定 → 一般 → VPN与装置管理 → 点你的 Apple ID → 信任

⚠ 免费签名 7 天到期，App 会打不开。重跑本脚本即可续命：
  ~/Developer/NCCUBus/deploy.sh

随时查还剩几天：
  ~/Developer/NCCUBus/deploy.sh --check
MSG
