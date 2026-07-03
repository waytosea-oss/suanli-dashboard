import Foundation

public enum BalanceFormatters {
  public static func percent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "--" }
    return "\(Int(value.rounded()))%"
  }

  public static func compactNumber(_ value: Int?) -> String {
    guard let value else { return "--" }
    if value >= 100_000_000 {
      return compactChineseUnit(Double(value) / 100_000_000, unit: "亿")
    }
    if value >= 10_000 {
      return compactChineseUnit(Double(value) / 10_000, unit: "万")
    }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
  }

  private static func compactChineseUnit(_ value: Double, unit: String) -> String {
    if value >= 100 || value.rounded(.down) == value {
      return "\(Int(value.rounded()))\(unit)"
    }
    return String(format: "%.1f%@", value, unit)
  }

  public static func exactNumber(_ value: Int?) -> String {
    guard let value else { return "--" }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
  }

  public static func resetCountdown(_ date: Date?, mode: CountdownMode = .auto, now: Date = Date()) -> String {
    guard let date else { return "--" }
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let minutes = seconds / 60
    let hours = minutes / 60
    let days = hours / 24

    switch mode {
    case .hours:
      if hours <= 0 {
        return "\(max(1, minutes))分钟"
      }
      return "\(hours)小时\(minutes % 60)分钟"
    case .days:
      if days <= 0 {
        return "\(hours)小时"
      }
      return "\(days)天\(hours % 24)小时"
    case .auto:
      if days > 0 {
        return "\(days)天\(hours % 24)小时"
      }
      if hours > 0 {
        return "\(hours)小时\(minutes % 60)分钟"
      }
      return "\(max(1, minutes))分钟"
    }
  }

  public static func resetCountdownShort(_ date: Date?, mode: CountdownMode = .auto, now: Date = Date()) -> String {
    guard let date else { return "--" }
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let minutes = seconds / 60
    let hours = minutes / 60
    let days = hours / 24

    switch mode {
    case .hours:
      if hours <= 0 {
        return "\(max(1, minutes))分"
      }
      return "\(hours)时\(minutes % 60)分"
    case .days:
      if days <= 0 {
        return "\(hours)时"
      }
      return "\(days)天\(hours % 24)时"
    case .auto:
      if days > 0 {
        return "\(days)天\(hours % 24)时"
      }
      if hours > 0 {
        return "\(hours)时\(minutes % 60)分"
      }
      return "\(max(1, minutes))分"
    }
  }

  public static func time(_ date: Date?) -> String {
    guard let date else { return "--" }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  public static func relativeAge(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "无余额事件" }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 {
      return "刚刚"
    }
    let minutes = seconds / 60
    if minutes < 60 {
      return "\(minutes)分钟前"
    }
    let hours = minutes / 60
    if hours < 24 {
      return "\(hours)小时\(minutes % 60)分钟前"
    }
    let days = hours / 24
    return "\(days)天前"
  }

  public static func dateTime(_ date: Date?) -> String {
    guard let date else { return "--" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter.string(from: date)
  }
}

public enum CountdownMode: Sendable {
  case auto
  case hours
  case days
}
