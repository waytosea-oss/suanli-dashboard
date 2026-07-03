import Foundation

public enum ToolID: String, CaseIterable, Codable, Identifiable, Sendable {
  case codex
  case claude

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }
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
    case .coding: "编程"
    case .presentation: "PPT/演示"
    case .imageDesign: "图片/视觉"
    case .documents: "文档/表格"
    case .research: "研究浏览"
    case .other: "其他"
    }
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
    usage: TokenUsage = TokenUsage(),
    usageCategory: TokenUsageCategory = .other,
    projectName: String = "未知项目",
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
    self.usage = usage
    self.usageCategory = usageCategory
    self.projectName = projectName
    self.projectPath = projectPath
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
    projectName: String = "未知项目",
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

public enum CodexDeviceID: String, CaseIterable, Codable, Identifiable, Sendable {
  case macBookPro = "macbook-pro"
  case macStudio = "mac-studio"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .macBookPro: "MacBook Pro"
    case .macStudio: "Mac Studio"
    }
  }

  public var fileName: String {
    "\(rawValue).json"
  }

  public func fileName(for app: ToolID) -> String {
    "\(rawValue)-\(app.rawValue).json"
  }
}

public struct CodexDeviceTokenUsage: Identifiable, Equatable, Codable, Sendable {
  public var id: CodexDeviceID { deviceID }
  public var schemaVersion: Int
  /// schemaVersion 1 的旧文件没有该字段，解码缺省为 .codex
  public var app: ToolID
  public var deviceID: CodexDeviceID
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
    deviceID: CodexDeviceID,
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
    deviceID = try container.decode(CodexDeviceID.self, forKey: .deviceID)
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
