import Foundation

// MARK: - 通用平台数据模型

/// 预付费平台的账户余额。
/// `reference` 是画环用的「满额基准」：默认取历史最高余额（高水位），用户也可在设置里手填。
/// 没有基准就画不出比例——这时环只显示金额，弧长按 0 处理，绝不编一个百分比出来。
public struct BalanceMetric: Equatable, Sendable {
  public var amount: Double              // 当前可用余额
  public var currencySymbol: String      // ¥ / $
  public var reference: Double?          // 满额基准；nil = 未知
  public var grantedAmount: Double?      // 平台赠送部分（DeepSeek/Kimi 有）
  public var toppedUpAmount: Double?     // 自己充值部分
  public var usedAmount: Double?         // 已消耗（OpenRouter 直接给）

  public init(
    amount: Double,
    currencySymbol: String,
    reference: Double? = nil,
    grantedAmount: Double? = nil,
    toppedUpAmount: Double? = nil,
    usedAmount: Double? = nil
  ) {
    self.amount = amount
    self.currencySymbol = currencySymbol
    self.reference = reference
    self.grantedAmount = grantedAmount
    self.toppedUpAmount = toppedUpAmount
    self.usedAmount = usedAmount
  }

  /// 剩余比例 0~100；基准未知或为 0 时返回 nil（界面显示金额、环不画弧）
  public var remainingPercent: Double? {
    guard let reference, reference > 0 else { return nil }
    return max(0, min(100, amount / reference * 100))
  }

  /// 金额的紧凑文本：¥12.3 / $0.88 / ¥1.2万
  public var amountText: String {
    let absolute = abs(amount)
    let body: String
    if absolute >= 10_000 {
      body = String(format: "%.1f万", amount / 10_000)
    } else if absolute >= 100 {
      body = String(format: "%.0f", amount)
    } else {
      body = String(format: "%.2f", amount)
    }
    return currencySymbol + body
  }
}

/// 一次抓取的结果：任意平台统一成这一个结构，展示层不再关心来源。
public struct ProviderSnapshot: Equatable, Sendable {
  public var provider: ToolID
  public var fetchedAt: Date
  public var windows: [LabeledWindow]   // 订阅制平台：N 个百分比窗口
  public var balance: BalanceMetric?    // 预付费平台：余额
  public var sourceName: String
  public var errorMessage: String?      // 拉取失败原因（Key 无效 / 网络 / 限流）

  public init(
    provider: ToolID,
    fetchedAt: Date,
    windows: [LabeledWindow] = [],
    balance: BalanceMetric? = nil,
    sourceName: String,
    errorMessage: String? = nil
  ) {
    self.provider = provider
    self.fetchedAt = fetchedAt
    self.windows = windows
    self.balance = balance
    self.sourceName = sourceName
    self.errorMessage = errorMessage
  }

  public var isAvailable: Bool {
    errorMessage == nil && (!windows.isEmpty || balance != nil)
  }

  /// 把余额折成一个 LabeledWindow，让现有的环/条/徽章视图零改动复用。
  /// label 直接写金额（「¥12.30」），比例来自 remainingPercent。
  public var resolvedWindows: [LabeledWindow] {
    if !windows.isEmpty { return windows }
    guard let balance else { return [] }
    let remaining = balance.remainingPercent ?? 0
    return [
      LabeledWindow(
        label: balance.amountText,
        window: LimitWindow(
          usedPercent: 100 - remaining,
          remainingPercent: remaining,
          windowMinutes: 0,
          resetsAt: nil
        ),
        isHourScale: false
      )
    ]
  }
}

// MARK: - API Key 存储

/// 第三方平台的 API Key 与「满额基准」。
///
/// **明文 JSON 文件，权限 0600，不进钥匙串。**
/// 钥匙串一旦被未签名的重编译二进制访问就会弹授权框，本项目历史上因此
/// 出过五次密码风暴，最终把钥匙串代码整个删掉了。这里沿用同一条纪律：
/// 自有目录、自有文件、只读不弹框。README 里明示了这一点。
public final class ProviderKeyStore: @unchecked Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var apiKey: String
    /// 用户手填的满额基准；nil 时用高水位
    public var referenceAmount: Double?
    /// 历史最高余额（自动记录），作为默认基准
    public var highWaterAmount: Double?

    public init(apiKey: String, referenceAmount: Double? = nil, highWaterAmount: Double? = nil) {
      self.apiKey = apiKey
      self.referenceAmount = referenceAmount
      self.highWaterAmount = highWaterAmount
    }

    /// 生效的画环基准
    public var effectiveReference: Double? {
      if let referenceAmount, referenceAmount > 0 { return referenceAmount }
      if let highWaterAmount, highWaterAmount > 0 { return highWaterAmount }
      return nil
    }
  }

  private let fileURL: URL
  private let lock = NSLock()
  private var cache: [String: Entry]?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexBalanceDashboard/provider-keys.json")
  }

  public func entry(for provider: ToolID) -> Entry? {
    load()[provider.rawValue]
  }

  public func setAPIKey(_ key: String?, for provider: ToolID) {
    mutate { entries in
      let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if trimmed.isEmpty {
        entries.removeValue(forKey: provider.rawValue)
      } else {
        var entry = entries[provider.rawValue] ?? Entry(apiKey: trimmed)
        entry.apiKey = trimmed
        entries[provider.rawValue] = entry
      }
    }
  }

  public func setReferenceAmount(_ amount: Double?, for provider: ToolID) {
    mutate { entries in
      guard var entry = entries[provider.rawValue] else { return }
      entry.referenceAmount = (amount ?? 0) > 0 ? amount : nil
      entries[provider.rawValue] = entry
    }
  }

  /// 抓到新余额后调用：只涨不跌，作为默认基准
  public func recordObservedBalance(_ amount: Double, for provider: ToolID) {
    mutate { entries in
      guard var entry = entries[provider.rawValue] else { return }
      if amount > (entry.highWaterAmount ?? 0) {
        entry.highWaterAmount = amount
        entries[provider.rawValue] = entry
      }
    }
  }

  public func allProvidersWithKeys() -> [ToolID] {
    load().keys.compactMap(ToolID.init(rawValue:))
  }

  private func load() -> [String: Entry] {
    lock.lock(); defer { lock.unlock() }
    if let cache { return cache }
    guard let data = try? Data(contentsOf: fileURL),
          let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
    else {
      cache = [:]
      return [:]
    }
    cache = decoded
    return decoded
  }

  private func mutate(_ body: (inout [String: Entry]) -> Void) {
    lock.lock(); defer { lock.unlock() }
    var entries = cache ?? ((try? Data(contentsOf: fileURL))
      .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:])
    body(&entries)
    cache = entries
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(entries) else { return }
    try? data.write(to: fileURL, options: [.atomic])
    // 仅本用户可读写：Key 是钱
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}

// MARK: - 按量付费平台余额抓取

/// 用 API Key 读各平台账户余额。每个平台一个小解析器，接口都是各家官方文档公开的：
///   DeepSeek     GET https://api.deepseek.com/user/balance
///   Moonshot     GET https://api.moonshot.cn/v1/users/me/balance
///   SiliconFlow  GET https://api.siliconflow.cn/v1/user/info
///   OpenRouter   GET https://openrouter.ai/api/v1/auth/key
///
/// 节流：每平台 4 分钟一次；失败后指数退避（1→2→4→8→16 分钟封顶），
/// 免得 Key 填错时每 5 秒打一次接口。
public final class APIKeyBalanceSource: @unchecked Sendable {
  private let keyStore: ProviderKeyStore
  private let session: URLSession
  private let lock = NSLock()
  private var cache: [ToolID: ProviderSnapshot] = [:]
  private var inFlight: Set<ToolID> = []
  private var failures: [ToolID: (count: Int, until: Date)] = [:]

  public static let fetchInterval: TimeInterval = 240

  public init(keyStore: ProviderKeyStore, session: URLSession = .shared) {
    self.keyStore = keyStore
    self.session = session
  }

  public func cachedSnapshot(for provider: ToolID) -> ProviderSnapshot? {
    lock.lock(); defer { lock.unlock() }
    return cache[provider]
  }

  /// 触发后台刷新（有节流）；结果通过 completion 回到调用方（主线程由调用方保证）
  public func refreshInBackground(
    _ provider: ToolID,
    force: Bool = false,
    completion: @escaping @Sendable (ProviderSnapshot) -> Void
  ) {
    let now = Date()
    lock.lock()
    if inFlight.contains(provider) { lock.unlock(); return }
    if !force {
      if let cached = cache[provider], now.timeIntervalSince(cached.fetchedAt) < Self.fetchInterval {
        lock.unlock(); return
      }
      if let failure = failures[provider], failure.until > now {
        lock.unlock(); return
      }
    }
    inFlight.insert(provider)
    lock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let snapshot = self.fetch(provider, now: Date())
      self.lock.lock()
      self.inFlight.remove(provider)
      if snapshot.errorMessage == nil {
        self.cache[provider] = snapshot
        self.failures[provider] = nil
      } else {
        let count = (self.failures[provider]?.count ?? 0) + 1
        let delay = min(60 * pow(2.0, Double(count - 1)), 16 * 60)
        self.failures[provider] = (count, Date().addingTimeInterval(delay))
        // 失败时保留上次成功值，只把错误挂上去
        if var previous = self.cache[provider] {
          previous.errorMessage = snapshot.errorMessage
          self.cache[provider] = previous
        } else {
          self.cache[provider] = snapshot
        }
      }
      let result = self.cache[provider] ?? snapshot
      self.lock.unlock()
      completion(result)
    }
  }

  /// 同步抓取（测试与「测试连接」按钮用）
  public func fetch(_ provider: ToolID, now: Date = Date()) -> ProviderSnapshot {
    guard provider.usesAPIKey else {
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: "", errorMessage: "不是 API Key 平台")
    }
    guard let entry = keyStore.entry(for: provider), !entry.apiKey.isEmpty else {
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName, errorMessage: "未填写 API Key".coreL10n)
    }
    guard let url = Self.endpoint(for: provider) else {
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName, errorMessage: "不支持的平台")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 12
    if provider == .glm {
      // 智谱用量监控接口：Authorization 直接放 Key，不带 Bearer
      request.setValue(entry.apiKey, forHTTPHeaderField: "Authorization")
      request.setValue("zh-CN,zh", forHTTPHeaderField: "Accept-Language")
    } else {
      request.setValue("Bearer \(entry.apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let semaphore = DispatchSemaphore(value: 0)
    let box = FetchResultBox()
    session.dataTask(with: request) { data, response, error in
      defer { semaphore.signal() }
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      box.set(data: data, status: code, error: error)
    }.resume()
    _ = semaphore.wait(timeout: .now() + 13)

    let (data, status, error) = box.value
    if let error {
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName,
                              errorMessage: LC("网络错误：%@", error.localizedDescription))
    }
    switch status {
    case 200..<300: break
    case 401, 403:
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName, errorMessage: "API Key 无效或已过期".coreL10n)
    case 429:
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName, errorMessage: "接口限流，稍后重试".coreL10n)
    case 0:
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName, errorMessage: "请求超时".coreL10n)
    default:
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName, errorMessage: LC("接口返回 HTTP %d", status))
    }
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName, errorMessage: "返回内容无法解析".coreL10n)
    }
    return Self.snapshot(from: object, provider: provider, keyStore: keyStore, now: now)
  }

  // MARK: 解析（纯函数，可测）

  public static func endpoint(for provider: ToolID) -> URL? {
    switch provider {
    case .deepseek: URL(string: "https://api.deepseek.com/user/balance")
    case .moonshot: URL(string: "https://api.moonshot.cn/v1/users/me/balance")
    case .siliconflow: URL(string: "https://api.siliconflow.cn/v1/user/info")
    case .openrouter: URL(string: "https://openrouter.ai/api/v1/auth/key")
    case .glm: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
    case .codex, .claude: nil
    }
  }

  /// 把各家 JSON 统一成 ProviderSnapshot。keyStore 用来取「满额基准」并记录高水位。
  public static func snapshot(
    from object: [String: Any],
    provider: ToolID,
    keyStore: ProviderKeyStore?,
    now: Date
  ) -> ProviderSnapshot {
    if provider == .glm { return glmSnapshot(from: object, now: now) }
    let symbol = provider.currencySymbol
    var balance: BalanceMetric?

    switch provider {
    case .deepseek:
      // {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}
      if let infos = object["balance_infos"] as? [[String: Any]] {
        let preferred = infos.first { ($0["currency"] as? String) == "CNY" } ?? infos.first
        if let preferred, let total = number(preferred["total_balance"]) {
          balance = BalanceMetric(
            amount: total, currencySymbol: symbol,
            grantedAmount: number(preferred["granted_balance"]),
            toppedUpAmount: number(preferred["topped_up_balance"])
          )
        }
      }
    case .moonshot:
      // {"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3.00},"status":true}
      if let data = object["data"] as? [String: Any], let available = number(data["available_balance"]) {
        balance = BalanceMetric(
          amount: available, currencySymbol: symbol,
          grantedAmount: number(data["voucher_balance"]),
          toppedUpAmount: number(data["cash_balance"])
        )
      }
    case .siliconflow:
      // {"code":20000,"status":true,"data":{"balance":"0.88","totalBalance":"0.88","chargeBalance":"0.00",...}}
      if let data = object["data"] as? [String: Any],
         let total = number(data["totalBalance"]) ?? number(data["balance"]) {
        balance = BalanceMetric(
          amount: total, currencySymbol: symbol,
          grantedAmount: number(data["balance"]),
          toppedUpAmount: number(data["chargeBalance"])
        )
      }
    case .openrouter:
      // {"data":{"label":"...","usage":1.2,"limit":10,"limit_remaining":8.8,"is_free_tier":false}}
      if let data = object["data"] as? [String: Any] {
        let usage = number(data["usage"])
        let limit = number(data["limit"])
        let remaining = number(data["limit_remaining"])
        if let remaining {
          balance = BalanceMetric(amount: remaining, currencySymbol: symbol, reference: limit, usedAmount: usage)
        } else if let usage {
          // 无额度上限的 Key：只知道花了多少，画不出剩余比例
          balance = BalanceMetric(amount: -usage, currencySymbol: symbol, reference: nil, usedAmount: usage)
        }
      }
    case .codex, .claude, .glm:
      break
    }

    guard var metric = balance else {
      return ProviderSnapshot(provider: provider, fetchedAt: now, sourceName: provider.vendorName,
                              errorMessage: "接口返回里没有余额字段".coreL10n)
    }
    // 基准：OpenRouter 自带 limit；其余用用户手填值或历史高水位
    if metric.reference == nil, let keyStore {
      if metric.amount > 0 { keyStore.recordObservedBalance(metric.amount, for: provider) }
      metric.reference = keyStore.entry(for: provider)?.effectiveReference
    }
    return ProviderSnapshot(provider: provider, fetchedAt: now, balance: metric, sourceName: provider.vendorName)
  }

  /// 各家把数字有的当字符串、有的当 number 返回，统一处理
  private static func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespaces)) }
    return nil
  }
}

private final class FetchResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: (Data?, Int, Error?) = (nil, 0, nil)
  func set(data: Data?, status: Int, error: Error?) {
    lock.lock(); storage = (data, status, error); lock.unlock()
  }
  var value: (Data?, Int, Error?) {
    lock.lock(); defer { lock.unlock() }
    return storage
  }
}


// MARK: - 智谱 GLM Coding Plan（订阅窗口，走用量监控接口）

extension APIKeyBalanceSource {
  /// {"code":200,"success":true,"data":{"level":"pro","limits":[
  ///   {"type":"TOKENS_LIMIT","number":5,"unit":"HOUR","percentage":44,"nextResetTime":1770000000000},
  ///   {"type":"TOKENS_LIMIT","number":7,"unit":"DAY","percentage":53,"nextResetTime":...},
  ///   {"type":"TIME_LIMIT","percentage":7,"usage":1000,"currentValue":72,"remaining":928}]}}
  /// percentage = 已用百分比；nextResetTime = 毫秒时间戳；number==5 的 TOKENS_LIMIT 是 5 小时窗口，另一个是每周。
  public static func glmSnapshot(from object: [String: Any], now: Date) -> ProviderSnapshot {
    let name = ToolID.glm.vendorName
    guard let data = object["data"] as? [String: Any],
          let limits = data["limits"] as? [[String: Any]]
    else {
      let message = (object["msg"] as? String).map { LC("接口返回：%@", $0) } ?? "接口返回里没有额度字段".coreL10n
      return ProviderSnapshot(provider: .glm, fetchedAt: now, sourceName: name, errorMessage: message)
    }
    var windows: [LabeledWindow] = []
    let tokenLimits = limits.filter { ($0["type"] as? String) == "TOKENS_LIMIT" }
    for limit in tokenLimits {
      guard let used = number(limit["percentage"]) else { continue }
      let isFiveHour = number(limit["number"]) == 5
        || ((limit["unit"] as? String)?.uppercased().hasPrefix("HOUR") ?? false)
      let reset = number(limit["nextResetTime"]).map { Date(timeIntervalSince1970: $0 / 1000) }
      windows.append(LabeledWindow(
        label: isFiveHour ? "5时" : "周",
        window: LimitWindow(
          usedPercent: used, remainingPercent: max(0, 100 - used),
          windowMinutes: isFiveHour ? 300 : 7 * 24 * 60, resetsAt: reset
        ),
        isHourScale: isFiveHour
      ))
    }
    // 5 小时窗口排前面
    windows.sort { $0.isHourScale && !$1.isHourScale }
    if let mcp = limits.first(where: { ["MCP_LIMIT", "TIME_LIMIT"].contains($0["type"] as? String ?? "") }),
       let used = number(mcp["percentage"]) {
      let reset = number(mcp["nextResetTime"]).map { Date(timeIntervalSince1970: $0 / 1000) }
      windows.append(LabeledWindow(
        label: "MCP",
        window: LimitWindow(usedPercent: used, remainingPercent: max(0, 100 - used), windowMinutes: 30 * 24 * 60, resetsAt: reset),
        isHourScale: false
      ))
    }
    guard !windows.isEmpty else {
      return ProviderSnapshot(provider: .glm, fetchedAt: now, sourceName: name, errorMessage: "接口返回里没有额度字段".coreL10n)
    }
    let level = (data["level"] as? String).map { " · " + $0.uppercased() } ?? ""
    return ProviderSnapshot(provider: .glm, fetchedAt: now, windows: windows, sourceName: name + level)
  }
}
