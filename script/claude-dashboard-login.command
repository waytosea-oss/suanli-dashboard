#!/bin/zsh
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
AUTH_DIR="$HOME/Library/Application Support/CodexBalanceDashboard/claude-auth"
mkdir -p "$AUTH_DIR"
chmod 700 "$AUTH_DIR"
if ! command -v claude >/dev/null 2>&1; then
  echo '未找到 Claude Code，请先安装 Claude Code。'
  exit 1
fi
# This separate Claude configuration gets its own OAuth grant and keychain entry.
# Do not copy the normal CLI refresh token: refresh-token rotation consumes it.
CLAUDE_CONFIG_DIR="$AUTH_DIR" claude auth login --claudeai
printf '%s\n' 'Dedicated Claude authorization for the compute dashboard.' > "$AUTH_DIR/.dashboard-auth"
echo '独立登录完成，码表将自动同步。'
pkill -x CodexBalance 2>/dev/null || true
if [[ -d "$HOME/Applications/算力码表.app" ]]; then
  open "$HOME/Applications/算力码表.app"
else
  open -a '算力码表'
fi
