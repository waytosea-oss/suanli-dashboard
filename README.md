# 算力码表 suanli-dashboard

> macOS 悬浮仪表盘：同时监控 **OpenAI Codex** 与 **Claude Code** 的订阅额度余额、Token 消耗与趋势。支持 Touch Bar 常驻显示、多设备 iCloud 同步。

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## 它解决什么问题

重度使用 Codex / Claude Code 的人都遇到过：干着干着突然「额度用完了」。算力码表把两个工具的 **5 小时滚动窗口**和 **7 天窗口**余额变成一个始终可见的小仪表，让你随时知道还剩多少、什么时候重置。

## 功能

- **双工具监控**：Codex 与 Claude Code 可单选/多选，首次启动自动探测本机装了哪个
- **5 种悬浮样式**：双环 / 长条 / 长条·全（四进度条）/ 徽章 / 徽章·全（四数字），标准与迷你两档尺寸
- **Touch Bar 常驻**（带 Touch Bar 的机型）：
  - 全宽面板：四进度条 / 双进度条 / 四数字 / 双数字四种样式，大数字模式方便一眼读取
  - **「距刷新」下划线**：数字下方一条同色进度线，深色段 = 距额度刷新还要等的时间，走完即刷新——余额与时间两个维度一眼齐
  - 最近 AI 会话直达：显示最近 1–3 个会话标题，点按跳到对应 App
  - 可选保持常亮（防 Touch Bar 息屏）
  - 合盖用外接屏时，浮窗自动现身外接屏幕
- **Token 消耗看板**：今日/近 7 天/本月汇总、用途分布、项目 Top 3、14 天趋势图
- **多设备 iCloud 同步**：每台 Mac 的消耗各自统计、互相可见，任意台数自动加入趋势对比
- **自动避让**：可选让浮窗自动挪到屏幕上被遮挡最少的角落
- **6 套配色主题**，暖色 Codex / 冷色 Claude 永远可区分

## 安装

### 方式一：下载安装包（推荐）

1. 从 [Releases](../../releases) 下载最新的 `算力码表-安装包.zip`
2. 解压后双击 `安装并启用自动启动.command`
3. 它会把 App 装到 `~/Applications` 并配置自动启动（打开 Codex 或 Claude Code 时自动唤起）

> App 未做公证：首次打开如被拦截，到「系统设置 → 隐私与安全性」点「仍要打开」。

### 方式二：源码构建

```bash
git clone https://github.com/waytosea-oss/suanli-dashboard.git
cd suanli-dashboard
./script/create_transfer_package.sh   # 产物在 dist/
```

需要 Xcode Command Line Tools（Swift 6）。

## 余额数据从哪来

| 数据 | 来源 | 说明 |
|---|---|---|
| Codex 余额 | Codex app-server 本地 RPC / 会话日志 | 与官方 `/status` 一致 |
| Claude 余额 | 本机已有的 Claude Code OAuth 凭据 + 官方 usage 接口 | accessToken 过期自动用 refreshToken 续期 |
| Token 消耗 | 两个工具的本地会话日志（jsonl） | 逐条解析、跨文件去重 |
| 多设备数据 | iCloud Drive 聚合 JSON | 只含日期与数字 |

## 隐私原则

- **只读**两个工具的日志与凭据，绝不修改、绝不发起登录
- 凭据绝不写入日志、诊断报告或 iCloud
- 不上传任何数据；iCloud 只同步聚合后的日期/token 数字
- 找不到可靠数据来源时显示「暂无数据」，**永远不编数字**

## 常见问题

**Claude 环是灰的？** 本机需要用 Claude Code CLI 登录过一次（`claude` → `/login`），凭据进钥匙串后码表即可读取并长期自动续期。

**两台 Mac 数字不一样？** 余额是账号级的、两台一致；Token 消耗折线是按设备分开统计的，这是设计行为。

**Touch Bar 上没显示？** 只有带 Touch Bar 的机型生效；在设置 → 运行 里打开「Touch Bar 常驻余额」。

## 作者

**Tilo Liang**（[@waytosea-oss](https://github.com/waytosea-oss)）

一个被额度反复背刺之后决定把仪表盘做出来的人。如果这个工具帮到了你，给个 ⭐️ 就是最好的支持。

## 许可证

[MIT](LICENSE) © 2026 Tilo Liang
