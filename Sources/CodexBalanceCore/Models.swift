import Foundation

/// 可监控的算力平台。前两个（Codex / Claude）读本机日志 + 官方订阅额度接口；
/// 其余是按量付费平台，用用户自己的 API Key 读「账户余额」。
/// 枚举顺序即设置面板「添加平台」菜单里的顺序。
public enum ToolID: String, CaseIterable, Codable, Identifiable, Sendable {
  case codex
  case claude
  case glm
  case grok
  case deepseek
  case moonshot
  case siliconflow
  case openrouter

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    case .glm: "GLM"
    case .grok: "Grok"
    case .deepseek: "DeepSeek"
    case .moonshot: "Kimi"
    case .siliconflow: "SiliconFlow"
    case .openrouter: "OpenRouter"
    }
  }

  /// 设置面板里的副标题（平台全名）
  public var vendorName: String {
    switch self {
    case .codex: "OpenAI Codex"
    case .claude: "Claude Code"
    case .glm: "智谱 GLM Coding Plan"
    case .grok: "SuperGrok（grok.com 订阅）"
    case .deepseek: "DeepSeek 开放平台"
    case .moonshot: "Moonshot / Kimi 开放平台"
    case .siliconflow: "硅基流动 SiliconFlow"
    case .openrouter: "OpenRouter"
    }
  }

  /// 徽章 / Touch Bar 上的单字母章
  public var letter: String {
    switch self {
    case .codex: "C"
    case .claude: "A"
    case .glm: "G"
    case .grok: "X"
    case .deepseek: "D"
    case .moonshot: "K"
    case .siliconflow: "S"
    case .openrouter: "O"
    }
  }

  /// 数据形态：订阅额度（百分比窗口）还是预付费余额（金额）
  public var kind: ProviderKind {
    switch self {
    case .codex, .claude: .subscriptionWindows
    case .glm, .grok: .apiSubscription
    case .deepseek, .moonshot, .siliconflow, .openrouter: .prepaidBalance
    }
  }

  /// 只有 Codex / Claude 在本机留有会话日志（token 看板、最近会话、iCloud 同步都依赖它）
  public var hasLocalLogs: Bool { kind == .subscriptionWindows }

  /// 需要用户填 API Key 的平台（预付费余额 + API 拉取的订阅窗口）
  public var usesAPIKey: Bool { kind != .subscriptionWindows }

  /// 点设置面板里的 ❓ 弹出的分步指南：各家取凭证的路径都不一样，一步一条
  public var credentialGuide: [String] {
    switch self {
    case .codex, .claude: return []
    case .glm: return [
      "打开 bigmodel.cn 并登录（用买了 GLM Coding Plan 的那个账号）",
      "右上角头像 → 「API Keys」（或直接打开下面的链接）",
      "点「添加新的 API Key」，随便起个名，复制生成的 Key",
      "回到这里贴进「API Key」栏 → 保存。海外版 z.ai 的 Key 也可以用",
      "这个 Key 和你配给 Claude Code / Z Code 的是同一把，不用新建也行"
    ]
    case .grok: return [
      "用 Chrome 或 Edge 打开 grok.com，确认已登录 SuperGrok 账号",
      "按 ⌥⌘I 打开开发者工具，顶部标签点「Application」（藏在 » 里就点开）",
      "左栏 Storage → Cookies → https://grok.com",
      "右边列表找 Name 是「sso」的那一行，双击它的 Value，⌘A 全选，⌘C 复制",
      "回到这里 ⌘V 贴进输入栏 → 保存。Safari 用户：开发 → 显示网页检查器 → 储存空间 → Cookies",
      "这是你的登录态，只存本机；过期后这里会提示「无效或已过期」，重贴一次即可"
    ]
    case .deepseek: return [
      "打开 platform.deepseek.com 并登录",
      "左侧菜单「API keys」→「创建 API key」",
      "Key 只在创建时显示一次，立刻复制",
      "贴进「API Key」栏 → 保存；「满额基准」填你平时充值的金额（如 100），环才有比例"
    ]
    case .moonshot: return [
      "打开 platform.moonshot.cn 并登录",
      "左侧「API Key 管理」→「新建」",
      "复制生成的 sk- 开头的 Key",
      "贴进「API Key」栏 → 保存；「满额基准」填充值金额，留空则按历史最高余额"
    ]
    case .siliconflow: return [
      "打开 cloud.siliconflow.cn 并登录",
      "左侧「API 密钥」→「新建 API 密钥」",
      "点密钥可复制",
      "贴进「API Key」栏 → 保存；「满额基准」填充值金额"
    ]
    case .openrouter: return [
      "打开 openrouter.ai 并登录",
      "右上角头像 → Keys →「Create Key」",
      "建议给 Key 设一个 Credit limit，这样环会按上限画比例；不设就只显示已消耗",
      "复制 sk-or- 开头的 Key，贴进「API Key」栏 → 保存"
    ]
    }
  }

  /// 设置面板凭证输入框的标签：绝大多数是 API Key，SuperGrok 没有公开接口，用的是 grok.com 登录 Cookie
  public var credentialLabel: String {
    self == .grok ? "grok.com 的 sso Cookie" : "API Key"
  }

  /// 取色族序号：0 暖(Codex) 1 冷(Claude) 2 青绿 3 紫 4 橙 5 靛 6 绿(GLM) 7 银(Grok)
  public var colorFamily: Int {
    switch self {
    case .codex: 0
    case .claude: 1
    case .glm: 6
    case .grok: 7
    case .deepseek: 2
    case .moonshot: 3
    case .siliconflow: 4
    case .openrouter: 5
    }
  }

  /// 去哪里拿 API Key（设置面板帮助链接）
  public var apiKeyHelpURL: URL? {
    switch self {
    case .codex, .claude: nil
    case .glm: URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys")
    case .grok: URL(string: "https://grok.com")
    case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
    case .moonshot: URL(string: "https://platform.moonshot.cn/console/api-keys")
    case .siliconflow: URL(string: "https://cloud.siliconflow.cn/account/ak")
    case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
    }
  }

  /// 余额接口的币种符号（显示用）
  public var currencySymbol: String {
    switch self {
    case .openrouter: "$"
    case .deepseek, .moonshot, .siliconflow: "¥"
    case .codex, .claude, .glm, .grok: ""
    }
  }
}

public enum ProviderKind: String, Codable, Sendable {
  /// 订阅制：接口返回 5 时 / 7 天等滚动窗口的已用百分比
  case subscriptionWindows
  /// 预付费：接口返回账户余额金额，本工具据此折算「剩余比例」画环
  case prepaidBalance
  /// 订阅制但要用 API Key 去官方用量接口拉窗口（智谱 GLM Coding Plan）
  case apiSubscription
}

public struct LimitWindow: Equatable, Sendable {
  public var usedPercent: Double
  public var remainingPercent: Double
  public var windowMinutes: Double
  public var resetsAt: Date?
  public var inferredReset: Bool

  public init(
    usedPercent: Double,
    remainingPercent: Double,
    windowMinutes: Double,
    resetsAt: Date?,
    inferredReset: Bool = false
  ) {
    self.usedPercent = usedPercent
    self.remainingPercent = remainingPercent
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
    self.inferredReset = inferredReset
  }
}

public struct TokenUsage: Equatable, Sendable {
  public var totalTokens: Int
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var lastTotalTokens: Int
  public var lastInputTokens: Int
  public var lastOutputTokens: Int
  public var lastReasoningOutputTokens: Int

  public init(
    totalTokens: Int = 0,
    inputTokens: Int = 0,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 0,
    reasoningOutputTokens: Int = 0,
    lastTotalTokens: Int = 0,
    lastInputTokens: Int = 0,
    lastOutputTokens: Int = 0,
    lastReasoningOutputTokens: Int = 0
  ) {
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.lastTotalTokens = lastTotalTokens
    self.lastInputTokens = lastInputTokens
    self.lastOutputTokens = lastOutputTokens
    self.lastReasoningOutputTokens = lastReasoningOutputTokens
  }
}

public enum TokenUsageCategory: String, CaseIterable, Identifiable, Sendable {
  case coding
  case presentation
  case imageDesign
  case documents
  case research
  case other

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .coding: "编程".coreL10n
    case .presentation: "PPT/演示".coreL10n
    case .imageDesign: "图片/视觉".coreL10n
    case .documents: "文档/表格".coreL10n
    case .research: "研究浏览".coreL10n
    case .other: "其他".coreL10n
    }
  }
}

/// 带标签的额度窗口：支持每工具任意个窗口（如 Codex 仅 7天；Claude 5时+周·全部+周·Fable）
public struct LabeledWindow: Equatable, Sendable {
  public var label: String        // 「7天」「5时」「周·全部」「周·Fable」等
  public var window: LimitWindow
  public var isHourScale: Bool    // 倒计时格式用：true=时分制，false=天时制

  public init(label: String, window: LimitWindow, isHourScale: Bool) {
    self.label = label
    self.window = window
    self.isHourScale = isHourScale
  }
}

public struct RateLimitEvent: Identifiable, Equatable, Sendable {
  public var id: String { "\(limitID)-\(timestamp.timeIntervalSince1970)" }
  public var timestamp: Date
  public var sourceName: String
  public var sourcePath: String
  public var limitID: String
  public var limitName: String
  public var planType: String?
  public var primary: LimitWindow?
  public var secondary: LimitWindow?
  public var reachedType: String?
  /// N 窗口列表（新结构）；为空时由 primary/secondary 合成，保证旧数据兼容
  public var windows: [LabeledWindow]
  public var usage: TokenUsage
  public var usageCategory: TokenUsageCategory
  public var projectName: String
  public var projectPath: String

  public init(
    timestamp: Date,
    sourceName: String,
    sourcePath: String,
    limitID: String,
    limitName: String,
    planType: String? = nil,
    primary: LimitWindow? = nil,
    secondary: LimitWindow? = nil,
    reachedType: String? = nil,
    windows: [LabeledWindow] = [],
    usage: TokenUsage = TokenUsage(),
    usageCategory: TokenUsageCategory = .other,
    projectName: String = "未知项目".coreL10n,
    projectPath: String = ""
  ) {
    self.timestamp = timestamp
    self.sourceName = sourceName
    self.sourcePath = sourcePath
    self.limitID = limitID
    self.limitName = limitName
    self.planType = planType
    self.primary = primary
    self.secondary = secondary
    self.reachedType = reachedType
    self.windows = windows
    self.usage = usage
    self.usageCategory = usageCategory
    self.projectName = projectName
    self.projectPath = projectPath
  }
}

public extension RateLimitEvent {
  /// 统一出口：显式 windows 优先；否则由 primary/secondary 合成（旧行为）
  var resolvedWindows: [LabeledWindow] {
    if !windows.isEmpty { return windows }
    var list: [LabeledWindow] = []
    if let primary {
      let hourScale = primary.windowMinutes > 0 && primary.windowMinutes <= 24 * 60
      list.append(LabeledWindow(label: hourScale ? "5时".coreL10n : "7天".coreL10n, window: primary, isHourScale: hourScale))
    }
    if let secondary {
      let hourScale = secondary.windowMinutes > 0 && secondary.windowMinutes <= 24 * 60
      list.append(LabeledWindow(label: hourScale ? "5时".coreL10n : "7天".coreL10n, window: secondary, isHourScale: hourScale))
    }
    return list
  }

  /// 最紧张（剩余最少）的窗口——浮窗中心大数字/单条模式用
  var tightestWindow: LabeledWindow? {
    resolvedWindows.min { $0.window.remainingPercent < $1.window.remainingPercent }
  }

  /// 瓶颈窗口（主视觉用）：剩余% 最低者；60 分钟内即将重置的窗口按满额计
  /// （马上就刷新的紧张没有意义）；打平时取重置更远者。
  var bottleneckWindow: LabeledWindow? {
    let now = Date()
    func effectiveRemaining(_ labeled: LabeledWindow) -> Double {
      if let resets = labeled.window.resetsAt, resets.timeIntervalSince(now) < 60 * 60 {
        return 100
      }
      return labeled.window.remainingPercent
    }
    return resolvedWindows.min { lhs, rhs in
      let l = effectiveRemaining(lhs), r = effectiveRemaining(rhs)
      if abs(l - r) > 2 { return l < r }
      let lReset = lhs.window.resetsAt ?? .distantFuture
      let rReset = rhs.window.resetsAt ?? .distantFuture
      return lReset > rReset
    }
  }
}

public struct TokenBucket: Identifiable, Equatable, Codable, Sendable {
  public var id: String { key }
  public var key: String
  public var label: String
  public var totalTokens: Int
  public var inputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var calls: Int
  /// Claude 专用 cache 口径，Codex 文件可缺省（解码为 0）
  public var cacheCreationInputTokens: Int
  public var cacheReadInputTokens: Int

  public init(
    key: String,
    label: String,
    totalTokens: Int = 0,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    reasoningOutputTokens: Int = 0,
    calls: Int = 0,
    cacheCreationInputTokens: Int = 0,
    cacheReadInputTokens: Int = 0
  ) {
    self.key = key
    self.label = label
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.calls = calls
    self.cacheCreationInputTokens = cacheCreationInputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(String.self, forKey: .key)
    label = try container.decode(String.self, forKey: .label)
    totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
    calls = try container.decodeIfPresent(Int.self, forKey: .calls) ?? 0
    cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
    cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
  }
}

public struct TokenUsageEvent: Identifiable, Equatable, Sendable {
  public var id: String { "\(sourceName)-\(timestamp.timeIntervalSince1970)-\(totalTokens)" }
  public var timestamp: Date
  public var sourceName: String
  public var totalTokens: Int
  public var inputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var category: TokenUsageCategory
  public var projectName: String
  public var projectPath: String

  public init(
    timestamp: Date,
    sourceName: String,
    totalTokens: Int,
    inputTokens: Int,
    outputTokens: Int,
    reasoningOutputTokens: Int,
    category: TokenUsageCategory = .other,
    projectName: String = "未知项目".coreL10n,
    projectPath: String = ""
  ) {
    self.timestamp = timestamp
    self.sourceName = sourceName
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.category = category
    self.projectName = projectName
    self.projectPath = projectPath
  }
}

public struct TokenProjectBucket: Identifiable, Equatable, Sendable {
  public var id: String { projectPath.isEmpty ? projectName : projectPath }
  public var projectName: String
  public var projectPath: String
  public var totalTokens: Int
  public var calls: Int

  public init(
    projectName: String,
    projectPath: String = "",
    totalTokens: Int = 0,
    calls: Int = 0
  ) {
    self.projectName = projectName
    self.projectPath = projectPath
    self.totalTokens = totalTokens
    self.calls = calls
  }
}

public struct TokenCategoryBucket: Identifiable, Equatable, Sendable {
  public var id: String { category.rawValue }
  public var category: TokenUsageCategory
  public var totalTokens: Int
  public var inputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var calls: Int

  public init(
    category: TokenUsageCategory,
    totalTokens: Int = 0,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    reasoningOutputTokens: Int = 0,
    calls: Int = 0
  ) {
    self.category = category
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.calls = calls
  }
}

public struct AccountTokenUsage: Equatable, Sendable {
  public var daily: [TokenBucket]
  public var monthly: [TokenBucket]
  public var updatedAt: Date?
  public var unavailableReason: String?

  public init(
    daily: [TokenBucket] = [],
    monthly: [TokenBucket] = [],
    updatedAt: Date? = nil,
    unavailableReason: String? = nil
  ) {
    self.daily = daily
    self.monthly = monthly
    self.updatedAt = updatedAt
    self.unavailableReason = unavailableReason
  }
}

/// 设备标识：由本机名自动生成的 slug（如 "tilos-macbook-pro"），支持任意台数设备。
/// 旧版固定的 "macbook-pro" / "mac-studio" 仍是合法取值，旧 iCloud 文件无需迁移。
public enum DeviceIdentity {
  /// 把主机名/自定义名转成文件名安全的 slug
  public static func slug(from name: String) -> String {
    let lowered = name.lowercased()
      .replacingOccurrences(of: ".local", with: "")
      .replacingOccurrences(of: "的", with: "-")
    let mapped = lowered.map { ch -> Character in
      (ch.isLetter || ch.isNumber) ? ch : "-"
    }
    var slug = String(mapped)
    while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "mac" : slug
  }

  public static func fileName(deviceID: String, app: ToolID) -> String {
    "\(deviceID)-\(app.rawValue).json"
  }
}


public struct CodexDeviceTokenUsage: Identifiable, Equatable, Codable, Sendable {
  public var id: String { deviceID }
  public var schemaVersion: Int
  /// schemaVersion 1 的旧文件没有该字段，解码缺省为 .codex
  public var app: ToolID
  public var deviceID: String
  public var deviceName: String
  public var hostName: String
  public var updatedAt: Date
  public var todayTokens: Int
  public var monthTokens: Int
  public var sampleCount: Int
  public var daily: [TokenBucket]
  public var monthly: [TokenBucket]

  public init(
    schemaVersion: Int = 2,
    app: ToolID = .codex,
    deviceID: String,
    deviceName: String,
    hostName: String,
    updatedAt: Date,
    todayTokens: Int,
    monthTokens: Int,
    sampleCount: Int,
    daily: [TokenBucket],
    monthly: [TokenBucket]
  ) {
    self.schemaVersion = schemaVersion
    self.app = app
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.hostName = hostName
    self.updatedAt = updatedAt
    self.todayTokens = todayTokens
    self.monthTokens = monthTokens
    self.sampleCount = sampleCount
    self.daily = daily
    self.monthly = monthly
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    app = try container.decodeIfPresent(ToolID.self, forKey: .app) ?? .codex
    deviceID = try container.decode(String.self, forKey: .deviceID)
    deviceName = try container.decode(String.self, forKey: .deviceName)
    hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? ""
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    todayTokens = try container.decodeIfPresent(Int.self, forKey: .todayTokens) ?? 0
    monthTokens = try container.decodeIfPresent(Int.self, forKey: .monthTokens) ?? 0
    sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
    daily = try container.decodeIfPresent([TokenBucket].self, forKey: .daily) ?? []
    monthly = try container.decodeIfPresent([TokenBucket].self, forKey: .monthly) ?? []
  }
}

public struct TokenStats: Equatable, Sendable {
  public var todayTokens: Int
  public var monthTokens: Int
  public var last7DaysTokens: Int
  public var sampleCount: Int
  public var daily: [TokenBucket]
  public var monthly: [TokenBucket]
  public var categoryBreakdown: [TokenCategoryBucket]
  public var todayTopProjects: [TokenProjectBucket]
  public var monthTopProjects: [TokenProjectBucket]
  public var recentUsageEvents: [TokenUsageEvent]
  public var accountUsage: AccountTokenUsage?
  public var deviceUsage: [CodexDeviceTokenUsage]

  public init(
    todayTokens: Int = 0,
    monthTokens: Int = 0,
    last7DaysTokens: Int = 0,
    sampleCount: Int = 0,
    daily: [TokenBucket] = [],
    monthly: [TokenBucket] = [],
    categoryBreakdown: [TokenCategoryBucket] = [],
    todayTopProjects: [TokenProjectBucket] = [],
    monthTopProjects: [TokenProjectBucket] = [],
    recentUsageEvents: [TokenUsageEvent] = [],
    accountUsage: AccountTokenUsage? = nil,
    deviceUsage: [CodexDeviceTokenUsage] = []
  ) {
    self.todayTokens = todayTokens
    self.monthTokens = monthTokens
    self.last7DaysTokens = last7DaysTokens
    self.sampleCount = sampleCount
    self.daily = daily
    self.monthly = monthly
    self.categoryBreakdown = categoryBreakdown
    self.todayTopProjects = todayTopProjects
    self.monthTopProjects = monthTopProjects
    self.recentUsageEvents = recentUsageEvents
    self.accountUsage = accountUsage
    self.deviceUsage = deviceUsage
  }
}

public struct CodexStatus: Equatable, Sendable {
  public var generatedAt: Date
  public var codexHome: String
  public var sessionsRoot: String
  public var scannedFiles: Int
  public var eventCount: Int
  public var main: RateLimitEvent?
  public var limits: [RateLimitEvent]
  public var trend: [RateLimitEvent]
  public var tokenStats: TokenStats
  public var recentEvents: [RateLimitEvent]

  public init(
    generatedAt: Date = Date(),
    codexHome: String,
    sessionsRoot: String,
    scannedFiles: Int = 0,
    eventCount: Int = 0,
    main: RateLimitEvent? = nil,
    limits: [RateLimitEvent] = [],
    trend: [RateLimitEvent] = [],
    tokenStats: TokenStats = TokenStats(),
    recentEvents: [RateLimitEvent] = []
  ) {
    self.generatedAt = generatedAt
    self.codexHome = codexHome
    self.sessionsRoot = sessionsRoot
    self.scannedFiles = scannedFiles
    self.eventCount = eventCount
    self.main = main
    self.limits = limits
    self.trend = trend
    self.tokenStats = tokenStats
    self.recentEvents = recentEvents
  }
}
