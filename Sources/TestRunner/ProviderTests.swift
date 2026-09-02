import Foundation
import Testing

@testable import CodexBalanceCore

@Suite("按量付费平台余额解析")
struct ProviderParserTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func json(_ text: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
  }

  private func tempKeyStore() -> ProviderKeyStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("provider-keys-\(UUID().uuidString).json")
    return ProviderKeyStore(fileURL: url)
  }

  @Test func deepseekParsesStringNumbersAndGrantedSplit() {
    let object = json("""
    {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}
    """)
    let store = tempKeyStore()
    store.setAPIKey("sk-test", for: .deepseek)
    let snapshot = APIKeyBalanceSource.snapshot(from: object, provider: .deepseek, keyStore: store, now: now)
    #expect(snapshot.errorMessage == nil)
    #expect(snapshot.balance?.amount == 110)
    #expect(snapshot.balance?.grantedAmount == 10)
    #expect(snapshot.balance?.toppedUpAmount == 100)
    #expect(snapshot.balance?.currencySymbol == "¥")
    // 首次抓取即记录高水位 → 基准 110 → 剩余 100%
    #expect(snapshot.balance?.reference == 110)
    #expect(snapshot.balance?.remainingPercent == 100)
    #expect(snapshot.resolvedWindows.first?.label == "¥110")
  }

  @Test func deepseekPrefersCNYWhenMultipleCurrencies() {
    let object = json("""
    {"balance_infos":[{"currency":"USD","total_balance":"1.00"},{"currency":"CNY","total_balance":"8.50"}]}
    """)
    let snapshot = APIKeyBalanceSource.snapshot(from: object, provider: .deepseek, keyStore: nil, now: now)
    #expect(snapshot.balance?.amount == 8.5)
  }

  @Test func moonshotParsesAvailableBalance() {
    let object = json("""
    {"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"status":true}
    """)
    let snapshot = APIKeyBalanceSource.snapshot(from: object, provider: .moonshot, keyStore: nil, now: now)
    #expect(snapshot.errorMessage == nil)
    #expect(abs((snapshot.balance?.amount ?? 0) - 49.58894) < 0.0001)
    #expect(snapshot.balance?.currencySymbol == "¥")
    // 无 keyStore → 无基准 → 不编百分比
    #expect(snapshot.balance?.remainingPercent == nil)
    #expect(snapshot.resolvedWindows.first?.window.remainingPercent == 0)
  }

  @Test func siliconflowUsesTotalBalance() {
    let object = json("""
    {"code":20000,"status":true,"data":{"id":"1","balance":"0.88","totalBalance":"5.88","chargeBalance":"5.00"}}
    """)
    let snapshot = APIKeyBalanceSource.snapshot(from: object, provider: .siliconflow, keyStore: nil, now: now)
    #expect(snapshot.balance?.amount == 5.88)
    #expect(snapshot.balance?.toppedUpAmount == 5.0)
  }

  @Test func openrouterUsesLimitAsReference() {
    let object = json("""
    {"data":{"label":"k","usage":1.2,"limit":10,"limit_remaining":8.8,"is_free_tier":false}}
    """)
    let snapshot = APIKeyBalanceSource.snapshot(from: object, provider: .openrouter, keyStore: nil, now: now)
    #expect(snapshot.balance?.amount == 8.8)
    #expect(snapshot.balance?.reference == 10)
    #expect(snapshot.balance?.usedAmount == 1.2)
    #expect(snapshot.balance?.currencySymbol == "$")
    #expect(abs((snapshot.balance?.remainingPercent ?? 0) - 88) < 0.001)
  }

  @Test func openrouterWithoutLimitReportsUsageOnly() {
    let object = json("""
    {"data":{"label":"k","usage":3.5,"limit":null,"limit_remaining":null}}
    """)
    let snapshot = APIKeyBalanceSource.snapshot(from: object, provider: .openrouter, keyStore: nil, now: now)
    #expect(snapshot.errorMessage == nil)
    #expect(snapshot.balance?.usedAmount == 3.5)
    #expect(snapshot.balance?.remainingPercent == nil)
  }

  @Test func missingBalanceFieldIsAnErrorNotZero() {
    let snapshot = APIKeyBalanceSource.snapshot(from: json("{\"ok\":true}"), provider: .deepseek, keyStore: nil, now: now)
    #expect(snapshot.errorMessage != nil)
    #expect(snapshot.balance == nil)
    #expect(!snapshot.isAvailable)
  }

  @Test func manualReferenceBeatsHighWater() {
    let store = tempKeyStore()
    store.setAPIKey("sk-x", for: .deepseek)
    store.recordObservedBalance(50, for: .deepseek)
    store.setReferenceAmount(200, for: .deepseek)
    let object = json("{\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"50\"}]}")
    let snapshot = APIKeyBalanceSource.snapshot(from: object, provider: .deepseek, keyStore: store, now: now)
    #expect(snapshot.balance?.reference == 200)
    #expect(snapshot.balance?.remainingPercent == 25)
  }

  @Test func highWaterOnlyRises() {
    let store = tempKeyStore()
    store.setAPIKey("sk-x", for: .moonshot)
    store.recordObservedBalance(80, for: .moonshot)
    store.recordObservedBalance(30, for: .moonshot)
    #expect(store.entry(for: .moonshot)?.highWaterAmount == 80)
  }

  @Test func amountTextFormatting() {
    #expect(BalanceMetric(amount: 12.3, currencySymbol: "¥").amountText == "¥12.30")
    #expect(BalanceMetric(amount: 256.7, currencySymbol: "¥").amountText == "¥257")
    #expect(BalanceMetric(amount: 12_345, currencySymbol: "¥").amountText == "¥1.2万")
    #expect(BalanceMetric(amount: 0.88, currencySymbol: "$").amountText == "$0.88")
  }
}

@Suite("ProviderKeyStore 文件存取")
struct ProviderKeyStoreTests {
  @Test func roundTripAndRemoval() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("provider-keys-\(UUID().uuidString).json")
    let store = ProviderKeyStore(fileURL: url)
    #expect(store.entry(for: .deepseek) == nil)
    store.setAPIKey("  sk-abc  ", for: .deepseek)
    #expect(store.entry(for: .deepseek)?.apiKey == "sk-abc")
    #expect(store.allProvidersWithKeys() == [.deepseek])

    // 另起一个实例读同一文件 → 落盘成功
    let reread = ProviderKeyStore(fileURL: url)
    #expect(reread.entry(for: .deepseek)?.apiKey == "sk-abc")

    // 文件权限 0600
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs?[.posixPermissions] as? Int) == 0o600)

    store.setAPIKey("", for: .deepseek)
    #expect(store.entry(for: .deepseek) == nil)
  }
}

@Suite("ToolID 元数据")
struct ToolIDMetadataTests {
  @Test func kindsAndLettersAreConsistent() {
    for tool in ToolID.allCases {
      #expect(tool.letter.count == 1)
      if tool.usesAPIKey {
        #expect(APIKeyBalanceSource.endpoint(for: tool) != nil)
        #expect(tool.apiKeyHelpURL != nil)
        #expect(!tool.hasLocalLogs)
        if tool.kind == .prepaidBalance { #expect(!tool.currencySymbol.isEmpty) }
      } else {
        #expect(tool.hasLocalLogs)
        #expect(APIKeyBalanceSource.endpoint(for: tool) == nil)
      }
    }
    let families = Set(ToolID.allCases.map(\.colorFamily))
    #expect(families.count == ToolID.allCases.count)
  }
}


@Suite("智谱 GLM Coding Plan 解析")
struct GLMParserTests {
  @Test func parsesFiveHourWeeklyAndMCP() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let object: [String: Any] = [
      "code": 200, "success": true,
      "data": [
        "level": "pro",
        "limits": [
          ["type": "TOKENS_LIMIT", "number": 7, "unit": "DAY", "percentage": 53, "nextResetTime": 1_700_400_000_000],
          ["type": "TOKENS_LIMIT", "number": 5, "unit": "HOUR", "percentage": 44, "nextResetTime": 1_700_010_000_000],
          ["type": "TIME_LIMIT", "percentage": 7, "usage": 1000, "currentValue": 72, "remaining": 928]
        ] as [[String: Any]]
      ] as [String: Any]
    ]
    let snap = APIKeyBalanceSource.glmSnapshot(from: object, now: now)
    #expect(snap.isAvailable)
    #expect(snap.windows.map(\.label) == ["5时", "周", "MCP"])
    #expect(snap.windows[0].window.remainingPercent == 56)
    #expect(snap.windows[0].isHourScale)
    #expect(snap.windows[0].window.resetsAt == Date(timeIntervalSince1970: 1_700_010_000))
    #expect(snap.windows[1].window.remainingPercent == 47)
    #expect(!snap.windows[1].isHourScale)
    #expect(snap.windows[2].window.remainingPercent == 93)
    #expect(snap.sourceName.contains("PRO"))
  }

  @Test func missingLimitsIsAnErrorNotZero() {
    let snap = APIKeyBalanceSource.glmSnapshot(from: ["code": 401, "msg": "令牌已过期", "success": false], now: Date())
    #expect(!snap.isAvailable)
    #expect(snap.windows.isEmpty)
    #expect(snap.errorMessage?.contains("令牌已过期") == true)
  }

  @Test func glmIsAnAPIKeySubscriptionProvider() {
    #expect(ToolID.glm.kind == .apiSubscription)
    #expect(ToolID.glm.usesAPIKey)
    #expect(ToolID.glm.currencySymbol.isEmpty)
    #expect(APIKeyBalanceSource.endpoint(for: .glm)?.host == "open.bigmodel.cn")
  }
}
