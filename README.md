# 算力码表 · AI Balance Dashboard

一个 macOS 悬浮小组件，**同时监控 Codex 和 Claude Code 两个 AI 编程工具的额度余额与 token 消耗**。

## 功能

- 🎯 **双工具余额双环**：Codex（暖色）+ Claude（冷色）各一组同心双环，外环 7 天限额、内环 5 小时限额，带重置倒计时
- 📊 **Token 消耗看板**：今日/近 7 天/本月用量、本月用途分布（饼图）、项目消耗 Top 3、最近 14 天趋势折线
- 💻 **多设备对比**：通过 iCloud Drive 同步各台 Mac 的用量聚合数据，趋势图可多选对比（只同步聚合数字，不上传任何内容）
- 🪟 **三种悬浮样式**：双环 / 长条双进度条 / 极简徽章，占屏面积依次更小；支持标准/迷你两档尺寸、透明度调节、六套配色主题
- 🤚 **自动避让**：可选自动把浮窗挪到屏幕四角中被其他窗口遮挡最少的位置
- ⌨️ **Touch Bar 常驻**（带 Touch Bar 的机型）：整条 Touch Bar 显示两工具 5时/7天 四条进度条；可选防息屏常亮
- 🚀 **自动启动**：检测到 Codex 或 Claude Code 进程时自动唤起（LaunchAgent）

## 数据来源与隐私

- Codex：本机会话日志 `~/.codex/sessions` + Codex app-server 实时接口 + 官方账号统计
- Claude Code：本机会话日志 `~/.claude/projects/*.jsonl`（按消息 uuid 去重）+ 官方 usage 接口（OAuth）
- **只读**两个工具的日志与已有凭据；不发起登录、不修改任何配置；accessToken 过期自动用 refreshToken 续期，续期缓存只存在本机
- iCloud 只同步聚合后的日期/数字，不含 prompt、回复、路径等任何内容
- 拿不到可靠数据源时显示「暂无数据」，绝不编造数字

## 安装

### 方式一：下载安装包（推荐）

从 [Releases](../../releases) 下载最新 zip，解压后双击 `安装并启用自动启动.command`。
它会把 app 装到 `~/Applications/算力码表.app` 并配置自动启动。

首次运行时钥匙串授权弹框请选「始终允许」（用于读取 Claude Code 的 OAuth 凭据显示余额）。

### 方式二：源码构建

需要 macOS 14+ 与 Xcode Command Line Tools：

```bash
git clone <本仓库>
cd <仓库目录>
./script/build_and_run.sh          # 构建并运行
./script/create_transfer_package.sh # 构建分发安装包（输出到 dist/）
```

## 已知限制

- 设备维度目前内置为 `MacBook Pro` / `Mac Studio` 两台（`CodexDeviceID`），其他设备组合需自行修改枚举
- iCloud 同步目录写死为 `iCloud Drive/APP安装包/算力码表/`（可通过环境变量 `CODEX_BALANCE_SYNC_DIR` 覆盖）
- Touch Bar 常驻使用了 DFRFoundation 私有接口（Pock 同款机制），未来 macOS 版本可能失效；失效时不影响其他功能
- Claude 余额需要本机有 Claude Code CLI 的登录凭据（终端跑一次 `claude` 登录即可）

## License

MIT
