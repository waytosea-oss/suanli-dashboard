import Foundation

/// CodexBalanceCore 模块内的本地化取词（中文原文为 key，回退中文）
public extension String {
  var coreL10n: String {
    NSLocalizedString(self, bundle: .module, comment: "")
  }
}

func LC(_ key: String, _ arguments: CVarArg...) -> String {
  String(format: key.coreL10n, arguments: arguments)
}
