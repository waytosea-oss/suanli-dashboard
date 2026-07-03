#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="算力码表"
PACKAGE_NAME="算力码表-安装包"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_DIR="$DIST_DIR/$PACKAGE_NAME"
ZIP_PATH="$DIST_DIR/$PACKAGE_NAME.zip"
DESKTOP_ZIP="$HOME/Desktop/$PACKAGE_NAME.zip"

cd "$ROOT_DIR"

OPEN_APP=0 ./script/build_and_run.sh

rm -rf "$PACKAGE_DIR" "$ZIP_PATH"
mkdir -p "$PACKAGE_DIR"
ditto "$DIST_DIR/$APP_NAME.app" "$PACKAGE_DIR/$APP_NAME.app"

cat > "$PACKAGE_DIR/安装并启用自动启动.command" <<'INSTALLER'
#!/bin/zsh
set -euo pipefail

APP_NAME="算力码表"
BUNDLE_ID="dev.codex.balance-dashboard"
LABEL="dev.codex.balance-dashboard.watch-codex"
SCRIPT_DIR="${0:A:h}"
SOURCE_APP="$SCRIPT_DIR/$APP_NAME.app"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME.app"
WATCHER_DIR="$HOME/Library/Application Support/CodexBalanceDashboard"
WATCHER_SCRIPT="$WATCHER_DIR/watch-codex.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "找不到 $APP_NAME.app。请把安装脚本和 app 放在同一个文件夹里。"
  read -r "?按回车退出。"
  exit 1
fi

mkdir -p "$DEST_DIR" "$WATCHER_DIR" "$HOME/Library/LaunchAgents"
/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$PLIST" >/dev/null 2>&1 || true
/usr/bin/pkill -x CodexBalance >/dev/null 2>&1 || true
/bin/sleep 1
rm -rf "$DEST_APP"
/usr/bin/ditto "$SOURCE_APP" "$DEST_APP"
/usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

cat > "$WATCHER_SCRIPT" <<'WATCHER'
#!/bin/zsh
set -u

APP_PATH="$HOME/Applications/算力码表.app"
OLD_APP_PATH="$HOME/Applications/Codex算力宝.app"
BUILD_LOCK="$HOME/Library/Application Support/CodexBalanceDashboard/build.lock"
BUNDLE_ID="dev.codex.balance-dashboard"

resolve_dashboard_app() {
  local candidates=(
    "$APP_PATH"
    "$OLD_APP_PATH"
    "$HOME/Desktop/算力码表.app"
    "$HOME/Applications/算力码表.app"
    "/Applications/算力码表.app"
    "$HOME/Desktop/Codex算力宝.app"
    "$HOME/Applications/Codex算力宝.app"
    "/Applications/Codex算力宝.app"
    "$HOME/Desktop/算力余额宝.app"
    "$HOME/Applications/算力余额宝.app"
    "/Applications/算力余额宝.app"
    "$HOME/Desktop/Codex 算力浮窗.app"
    "$HOME/Applications/Codex 算力浮窗.app"
    "/Applications/Codex 算力浮窗.app"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done

  /usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" | /usr/bin/head -n 1
}

is_codex_running() {
  /usr/bin/pgrep -f "Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1 ||
    /usr/bin/pgrep -x "Codex" >/dev/null 2>&1 ||
    /usr/bin/pgrep -f "Contents/Resources/codex app-server" >/dev/null 2>&1
}

is_claude_running() {
  # 只认 Claude Code CLI（精确进程名），不把 Claude Desktop 当触发条件
  /usr/bin/pgrep -x "claude" >/dev/null 2>&1
}

while true; do
  if is_codex_running || is_claude_running; then
    if [[ -e "$BUILD_LOCK" ]]; then
      NOW=$(/bin/date +%s)
      MODIFIED=$(/usr/bin/stat -f %m "$BUILD_LOCK" 2>/dev/null || echo 0)
      if (( NOW - MODIFIED < 300 )); then
        /bin/sleep 5
        continue
      fi
      /bin/rm -f "$BUILD_LOCK"
    elif ! /usr/bin/pgrep -x "CodexBalance" >/dev/null 2>&1; then
      DASHBOARD_APP="$(resolve_dashboard_app)"
      if [[ -n "$DASHBOARD_APP" ]]; then
        /usr/bin/open "$DASHBOARD_APP"
      fi
    fi
  fi
  /bin/sleep 5
done
WATCHER

/bin/chmod +x "$WATCHER_SCRIPT"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$WATCHER_SCRIPT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/$LABEL.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/$LABEL.err.log</string>
</dict>
</plist>
PLIST

/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$PLIST"
/usr/bin/open "$DEST_APP"

echo
echo "安装完成：$DEST_APP"
echo "已启用：打开 Codex 时自动启动算力码表。"
echo "以后可以在算力码表的设置里关闭这个选项。"
echo
read -r "?按回车退出。"
INSTALLER

chmod +x "$PACKAGE_DIR/安装并启用自动启动.command"

cat > "$PACKAGE_DIR/诊断数据.command" <<'DIAGNOSE'
#!/bin/zsh
set -euo pipefail

REPORT="$HOME/Desktop/算力码表诊断-$(/bin/date +%Y%m%d-%H%M%S).txt"
LABEL="dev.codex.balance-dashboard.watch-codex"

count_root() {
  local root="$1"
  local files=0
  local token_lines=0
  local rate_lines=0
  local latest="无"
  local file

  if [[ ! -d "$root" ]]; then
    echo "目录不存在：$root"
    return
  fi

  while IFS= read -r -d '' file; do
    files=$((files + 1))
    token_lines=$((token_lines + $(/usr/bin/grep -c '"token_count"' "$file" 2>/dev/null || true)))
    rate_lines=$((rate_lines + $(/usr/bin/grep -c '"rate_limits"' "$file" 2>/dev/null || true)))
  done < <(/usr/bin/find "$root" -type f -name '*.jsonl' -print0 2>/dev/null)

  latest="$(/usr/bin/find "$root" -type f -name '*.jsonl' -exec /usr/bin/stat -f "%m %Sm %N" -t "%Y-%m-%d %H:%M:%S" {} + 2>/dev/null | /usr/bin/sort -nr | /usr/bin/head -n 1 | /usr/bin/cut -d' ' -f2- || true)"
  [[ -n "$latest" ]] || latest="无"

  echo "目录：$root"
  echo "  JSONL 文件：$files"
  echo "  token_count 行：$token_lines"
  echo "  rate_limits 行：$rate_lines"
  echo "  最新日志：$latest"
}

count_claude_root() {
  local root="$1"
  local files=0
  local usage_lines=0
  local latest="无"
  local file

  if [[ ! -d "$root" ]]; then
    echo "目录不存在：$root"
    return
  fi

  while IFS= read -r -d '' file; do
    files=$((files + 1))
    usage_lines=$((usage_lines + $(/usr/bin/grep -c '"usage"' "$file" 2>/dev/null || true)))
  done < <(/usr/bin/find "$root" -type f -name '*.jsonl' -print0 2>/dev/null)

  latest="$(/usr/bin/find "$root" -type f -name '*.jsonl' -exec /usr/bin/stat -f "%m %Sm %N" -t "%Y-%m-%d %H:%M:%S" {} + 2>/dev/null | /usr/bin/sort -nr | /usr/bin/head -n 1 | /usr/bin/cut -d' ' -f2- || true)"
  [[ -n "$latest" ]] || latest="无"

  echo "目录：$root"
  echo "  JSONL 文件：$files"
  echo "  usage 行：$usage_lines"
  echo "  最新日志：$latest"
}

latest_balance_event() {
  local root="$1"
  local line

  if [[ ! -d "$root" ]]; then
    return
  fi

  line="$(/usr/bin/find "$root" -type f -name '*.jsonl' -print0 2>/dev/null |
    /usr/bin/xargs -0 /usr/bin/grep -h '"token_count".*"rate_limits"' 2>/dev/null |
    /usr/bin/sort |
    /usr/bin/tail -n 1 || true)"

  [[ -n "$line" ]] || return

  LINE="$line" /usr/bin/perl -MJSON::PP -MTime::Piece -e '
    my $line = $ENV{"LINE"} // "";
    my $obj = eval { decode_json($line) };
    exit 0 unless $obj && $obj->{payload} && $obj->{payload}->{rate_limits};
    my $limits = $obj->{payload}->{rate_limits};
    my $primary = $limits->{primary} || {};
    my $secondary = $limits->{secondary} || {};
    my $primary_used = $primary->{used_percent};
    my $secondary_used = $secondary->{used_percent};
    my $primary_left = defined $primary_used ? sprintf("%.0f%%", 100 - $primary_used) : "--";
    my $secondary_left = defined $secondary_used ? sprintf("%.0f%%", 100 - $secondary_used) : "--";
    my $primary_reset = defined $primary->{resets_at} ? scalar localtime($primary->{resets_at}) : "--";
    my $secondary_reset = defined $secondary->{resets_at} ? scalar localtime($secondary->{resets_at}) : "--";
    print "  最新余额事件：", ($obj->{timestamp} // "--"), "\n";
    print "  5小时余额：$primary_left，重置：$primary_reset\n";
    print "  7天余额：$secondary_left，重置：$secondary_reset\n";
    print "  primary 原始字段：", JSON::PP->new->canonical->encode($primary), "\n";
    print "  secondary 原始字段：", JSON::PP->new->canonical->encode($secondary), "\n";
  ' 2>/dev/null || true
}

{
  echo "算力码表诊断"
  echo "生成时间：$(/bin/date '+%Y-%m-%d %H:%M:%S')"
  echo "用户：$USER"
  echo "系统：$(/usr/bin/sw_vers -productVersion)"
  echo "架构：$(/usr/bin/uname -m)"
  echo
  echo "Codex 进程："
  /bin/ps -axo pid,comm,args | /opt/homebrew/bin/rg -i 'Codex.app|codex app-server' 2>/dev/null || \
    /bin/ps -axo pid,comm,args | /usr/bin/grep -Ei 'Codex.app|codex app-server' | /usr/bin/grep -v grep || true
  echo
  echo "算力码表进程："
  /usr/bin/pgrep -fl CodexBalance || true
  echo
  echo "数据目录检查："
  count_root "$HOME/.codex/sessions"
  latest_balance_event "$HOME/.codex/sessions"
  echo
  count_root "$HOME/.codex/browser/sessions"
  latest_balance_event "$HOME/.codex/browser/sessions"
  echo
  count_root "$HOME/Library/Application Support/Codex/sessions"
  latest_balance_event "$HOME/Library/Application Support/Codex/sessions"
  echo
  count_root "$HOME/Library/Application Support/com.openai.codex/sessions"
  latest_balance_event "$HOME/Library/Application Support/com.openai.codex/sessions"
  echo
  echo "===== Claude Code ====="
  echo "Claude CLI 进程："
  /usr/bin/pgrep -xl claude || echo "  未运行"
  echo
  count_claude_root "$HOME/.claude/projects"
  echo
  echo "Claude 余额来源（只验存在性，不输出内容）："
  if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    echo "  ~/.claude/.credentials.json：存在"
  else
    echo "  ~/.claude/.credentials.json：不存在"
  fi
  if /usr/bin/security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
    echo "  Keychain[Claude Code-credentials]：存在"
  else
    echo "  Keychain[Claude Code-credentials]：不存在（本机 Claude 双环显示「暂无数据」）"
  fi
  echo
  echo "口径说明：Claude 本机 token = input + cache_creation + cache_read + output（含 cache_read）。"
  echo "官方总量与设备合计的差额含网页 Chat / Cowork 等非 CLI 消耗，属正常现象。"
  echo
  echo "自动启动监听器："
  /bin/launchctl print "gui/$(/usr/bin/id -u)/$LABEL" 2>&1 | /usr/bin/sed -n '1,80p' || true
  echo
  echo "监听器脚本："
  /usr/bin/sed -n '1,80p' "$HOME/Library/Application Support/CodexBalanceDashboard/watch-codex.sh" 2>&1 || true
  echo
  echo "iCloud 同步快照（新目录，按工具命名）："
  NEW_SYNC_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/算力码表/设备统计"
  echo "目录：$NEW_SYNC_DIR"
  if [[ -d "$NEW_SYNC_DIR" ]]; then
    /bin/ls -1 "$NEW_SYNC_DIR"/*.json 2>/dev/null | while IFS= read -r snapshot; do
      /usr/bin/stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" "$snapshot"
    done || true
  else
    echo "目录不存在；请确认 iCloud Drive 已开启，并在两台 Mac 都打开一次新版算力码表。"
  fi
  echo
  echo "iCloud 同步快照（旧目录，迁移源）："
  SYNC_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/APP安装包/算力码表/sync"
  echo "目录：$SYNC_DIR"
  if [[ -d "$SYNC_DIR" ]]; then
    /bin/ls -lah "$SYNC_DIR" 2>&1 || true
    echo
    /bin/ls -1 "$SYNC_DIR"/*.json 2>/dev/null | while IFS= read -r snapshot; do
      /usr/bin/stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" "$snapshot"
    done || true
  else
    echo "目录不存在；请确认 iCloud Drive 已开启，并在两台 Mac 都打开一次算力码表。"
  fi
} > "$REPORT"

echo "诊断完成：$REPORT"
/usr/bin/open -R "$REPORT"
read -r "?请把桌面上的诊断 txt 发给我，按回车退出。"
DIAGNOSE

chmod +x "$PACKAGE_DIR/诊断数据.command"

cat > "$PACKAGE_DIR/README-先看我.txt" <<'README'
算力码表安装包

安装：
1. 双击“安装并启用自动启动.command”。
2. 如果 macOS 提示不信任，右键脚本选择“打开”。
3. 安装完成后 app 会打开，并且已启用“打开 Codex 时自动启动”。

安装位置：
~/Applications/算力码表.app

隐私：
算力码表只读本机 Codex 会话日志，不上传、不修改你的 Codex 文件。
如果你有两台 Mac，它只会把按天/按月聚合后的 Token 快照写到 iCloud，不会同步原始对话日志。

双 Mac 同步：
1. 两台 Mac 都安装并打开一次算力码表。
2. iCloud Drive 会同步这个目录：
   ~/Library/Mobile Documents/com~apple~CloudDocs/APP安装包/算力码表/sync
3. 里面正常会出现 macbook-pro.json 和 mac-studio.json。
4. Token 趋势里可以同时勾选 MacBook Pro、Mac Studio、总算力。

源码项目：
不要把源码项目直接放进 iCloud 盘里运行。建议用 Git/GitHub 管源码，两台 Mac 各自 clone 或拉取更新；iCloud 只放安装包和同步快照。

关闭自动启动：
打开算力码表 -> 展开 -> 齿轮设置 -> 关闭“打开 Codex 时自动启动”。

没有数据：
1. 先在那台 Mac 上打开 Codex，并随便跑一次对话或 /status。
2. 等 5 秒后点算力码表左上角刷新。
3. 仍然没有数据时，双击“诊断数据.command”，把桌面生成的诊断 txt 发给我。

数据不准：
1. 请确认安装的是最新安装包。新版会同时扫描多个 Codex 会话目录。
2. 在那台 Mac 的 Codex 里输入 /status，等 5 秒后刷新算力码表。
3. 如果仍然不一致，运行“诊断数据.command”，诊断里会列出每个目录最新余额事件。

系统要求：
macOS 14 或更新版本。当前包为 Apple Silicon Mac 使用。
README

ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ZIP_PATH"
cp "$ZIP_PATH" "$DESKTOP_ZIP"

echo "Transfer package: $ZIP_PATH"
echo "Desktop copy: $DESKTOP_ZIP"
