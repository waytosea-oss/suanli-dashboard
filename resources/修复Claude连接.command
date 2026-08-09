#!/bin/zsh
# 算力码表 · Claude 连接修复脚本
# 用途：长期未开机导致续期链断裂后，先在终端运行 claude → /login 重新登录，
# 然后双击本脚本：用 Apple 的 security 工具读取新凭据并注入码表缓存。
# 全程不触发任何钥匙串授权弹框（security 是系统自带已授权工具）。
set -e
echo "读取 Claude Code 凭据..."
RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
if [ -z "$RAW" ]; then
  echo "❌ 未找到凭据。请先在终端运行 claude，输入 /login 完成登录后再运行本脚本。"
  read -r "?按回车退出。"; exit 1
fi
python3 - "$RAW" <<'PY'
import json,sys,os,time
o=json.loads(sys.argv[1]).get("claudeAiOauth",{})
if not o.get("accessToken"):
    print("❌ 凭据不含账号 token，请重新 /login 后再试"); sys.exit(1)
exp=o.get("expiresAt")
cache={"accessToken":o["accessToken"],"refreshToken":o.get("refreshToken"),
       "expiresAtEpoch":(exp/1000) if exp else time.time()+3600}
path=os.path.expanduser("~/Library/Application Support/CodexBalanceDashboard/claude-oauth-cache.json")
os.makedirs(os.path.dirname(path),exist_ok=True)
tmp=path+".tmp"; json.dump(cache,open(tmp,"w")); os.replace(tmp,path)
print("✅ 凭据已注入码表缓存")
PY
pkill -x CodexBalance 2>/dev/null || true
sleep 1
open "$HOME/Applications/算力码表.app" 2>/dev/null || open -a "算力码表" 2>/dev/null || true
echo "✅ 完成！码表已重启，Claude 环将在一分钟内亮起。"
read -r "?按回车关闭窗口。"
