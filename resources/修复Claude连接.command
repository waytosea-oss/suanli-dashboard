#!/bin/zsh
# 算力码表 · Claude 连接修复脚本 v2
# 变更：不再只认不带后缀的 "Claude Code-credentials"。
# 新版 Claude Code 会把账号 token 写进带哈希后缀的条目（-0a7b6ecb 之类），
# 不带后缀的那个往往是旧的甚至只含 mcpOAuth。这里遍历全部条目，
# 取含 claudeAiOauth.accessToken 且到期最晚的一份。
set -e
echo "扫描钥匙串中的 Claude 凭据条目..."

SERVICES=$(security dump-keychain 2>/dev/null \
  | grep -o '"svce"<blob>="Claude Code-credentials[^"]*"' \
  | sed 's/.*="\(.*\)"/\1/' | sort -u)

if [ -z "$SERVICES" ]; then
  echo "❌ 钥匙串里没有任何 Claude Code 凭据条目。"
  echo "   请先在终端运行 claude，输入 /login 完成登录，再运行本脚本。"
  read -r "?按回车退出。"; exit 1
fi

COUNT=$(echo "$SERVICES" | wc -l | tr -d ' ')
echo "找到 $COUNT 个条目，逐个读取（可能弹一次授权框，点「始终允许」）..."

TMPJSON=$(mktemp)
echo "[]" > "$TMPJSON"
while IFS= read -r SVC; do
  [ -z "$SVC" ] && continue
  RAW=$(security find-generic-password -s "$SVC" -w 2>/dev/null || true)
  [ -z "$RAW" ] && continue
  python3 - "$SVC" "$RAW" "$TMPJSON" <<'PY'
import json, sys, os
svc, raw, store = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    o = json.loads(raw).get("claudeAiOauth", {})
except Exception:
    raise SystemExit
if not o.get("accessToken"):
    raise SystemExit
items = json.load(open(store))
items.append({"svc": svc, "accessToken": o["accessToken"],
              "refreshToken": o.get("refreshToken"),
              "expiresAt": o.get("expiresAt") or 0})
json.dump(items, open(store, "w"))
PY
done <<< "$SERVICES"

python3 - "$TMPJSON" <<'PY'
import json, sys, os, time, datetime
items = json.load(open(sys.argv[1]))
if not items:
    print("❌ 所有条目都不含账号 token（可能只有各插件的 mcpOAuth）。")
    print("   请在终端运行 claude，输入 /login 重新登录后再试。")
    raise SystemExit(1)
best = max(items, key=lambda x: x["expiresAt"] or 0)
exp = best["expiresAt"]
ee = (exp/1000) if exp and exp > 1e12 else (exp or (time.time()+3600))
now = time.time()
print(f"选中条目: {best['svc']}")
print("  到期:", datetime.datetime.fromtimestamp(ee).strftime("%m-%d %H:%M"),
      f"({(ee-now)/3600:+.1f}h)", "✅ 有效" if ee > now else "⚠️ 已过期（仍写入，靠 refreshToken 续期）")
cache = {"accessToken": best["accessToken"], "refreshToken": best.get("refreshToken"),
         "expiresAtEpoch": ee}
p = os.path.expanduser("~/Library/Application Support/CodexBalanceDashboard/claude-oauth-cache.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
if os.path.exists(p):
    import shutil; shutil.copy(p, p + ".bak.beforefix")
tmp = p + ".tmp"; json.dump(cache, open(tmp, "w")); os.replace(tmp, p)
print("✅ 已注入码表缓存（原缓存已备份为 .bak.beforefix）")
PY
RC=$?
rm -f "$TMPJSON"
[ $RC -ne 0 ] && { read -r "?按回车退出。"; exit $RC; }

pkill -x CodexBalance 2>/dev/null || true
sleep 1
open "$HOME/Applications/算力码表.app" 2>/dev/null || open -a "算力码表" 2>/dev/null || true
echo "✅ 完成！码表已重启，Claude 环将在一分钟内亮起。"
read -r "?按回车关闭窗口。"
