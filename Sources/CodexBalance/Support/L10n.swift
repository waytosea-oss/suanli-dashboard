import Foundation

/// 本地化取词：以中文原文为 key，跟随系统语言。
/// 未翻译的 key 自动回退中文原文。
extension String {
  var l10n: String {
    NSLocalizedString(self, bundle: .module, comment: "")
  }
}

/// 带参数的本地化格式串
func L(_ key: String, _ arguments: CVarArg...) -> String {
  String(format: key.l10n, arguments: arguments)
}
