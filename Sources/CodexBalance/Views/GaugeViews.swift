import CodexBalanceCore
import SwiftUI

enum DashboardPalette: String, CaseIterable, Identifiable {
  case mintDawn
  case seaSaltBlue
  case forestSoda
  case peachSunset
  case wisteriaNight
  case lemonHarbor

  static let userDefaultsKey = "dashboardPalette"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .mintDawn: "薄荷晨光"
    case .seaSaltBlue: "海盐蓝风"
    case .forestSoda: "森林气泡"
    case .peachSunset: "桃桃晚霞"
    case .wisteriaNight: "紫藤星夜"
    case .lemonHarbor: "柠檬海岸"
    }
  }

  var subtitle: String {
    switch self {
    case .mintDawn: "清爽"
    case .seaSaltBlue: "安静"
    case .forestSoda: "轻快"
    case .peachSunset: "温柔"
    case .wisteriaNight: "专注"
    case .lemonHarbor: "明亮"
    }
  }

  var fiveHour: Color {
    switch self {
    case .mintDawn: Color(red: 0.39, green: 0.84, blue: 1.0)
    case .seaSaltBlue: Color(red: 0.38, green: 0.72, blue: 1.0)
    case .forestSoda: Color(red: 0.55, green: 0.88, blue: 1.0)
    case .peachSunset: Color(red: 1.0, green: 0.58, blue: 0.67)
    case .wisteriaNight: Color(red: 0.70, green: 0.62, blue: 1.0)
    case .lemonHarbor: Color(red: 0.47, green: 0.86, blue: 1.0)
    }
  }

  var weekly: Color {
    switch self {
    case .mintDawn: Color(red: 0.18, green: 0.91, blue: 0.72)
    case .seaSaltBlue: Color(red: 0.36, green: 0.94, blue: 0.84)
    case .forestSoda: Color(red: 0.38, green: 0.92, blue: 0.43)
    case .peachSunset: Color(red: 1.0, green: 0.76, blue: 0.36)
    case .wisteriaNight: Color(red: 0.44, green: 0.91, blue: 0.95)
    case .lemonHarbor: Color(red: 0.86, green: 0.93, blue: 0.32)
    }
  }

  /// Claude 冷色对：内环（5 小时）
  var claudeFiveHour: Color {
    switch self {
    case .mintDawn: Color(red: 0.52, green: 0.72, blue: 0.92)
    case .seaSaltBlue: Color(red: 0.52, green: 0.55, blue: 0.92)
    case .forestSoda: Color(red: 0.45, green: 0.66, blue: 0.92)
    case .peachSunset: Color(red: 0.52, green: 0.72, blue: 0.92)
    case .wisteriaNight: Color(red: 0.42, green: 0.66, blue: 0.95)
    case .lemonHarbor: Color(red: 0.50, green: 0.62, blue: 0.95)
    }
  }

  /// Claude 冷色对：外环（7 天）
  var claudeWeekly: Color {
    switch self {
    case .mintDawn: Color(red: 0.62, green: 0.58, blue: 0.95)
    case .seaSaltBlue: Color(red: 0.69, green: 0.66, blue: 0.93)
    case .forestSoda: Color(red: 0.60, green: 0.60, blue: 0.95)
    case .peachSunset: Color(red: 0.69, green: 0.66, blue: 0.93)
    case .wisteriaNight: Color(red: 0.70, green: 0.62, blue: 1.0)
    case .lemonHarbor: Color(red: 0.66, green: 0.60, blue: 0.95)
    }
  }

  var panel: Color {
    switch self {
    case .mintDawn: Color(red: 0.07, green: 0.10, blue: 0.12)
    case .seaSaltBlue: Color(red: 0.06, green: 0.10, blue: 0.16)
    case .forestSoda: Color(red: 0.06, green: 0.12, blue: 0.10)
    case .peachSunset: Color(red: 0.13, green: 0.08, blue: 0.10)
    case .wisteriaNight: Color(red: 0.08, green: 0.07, blue: 0.15)
    case .lemonHarbor: Color(red: 0.08, green: 0.11, blue: 0.10)
    }
  }

  var panelRaised: Color {
    switch self {
    case .mintDawn: Color(red: 0.10, green: 0.14, blue: 0.17)
    case .seaSaltBlue: Color(red: 0.10, green: 0.15, blue: 0.23)
    case .forestSoda: Color(red: 0.10, green: 0.16, blue: 0.13)
    case .peachSunset: Color(red: 0.18, green: 0.12, blue: 0.14)
    case .wisteriaNight: Color(red: 0.13, green: 0.11, blue: 0.22)
    case .lemonHarbor: Color(red: 0.13, green: 0.16, blue: 0.13)
    }
  }

  var gradientStart: Color {
    switch self {
    case .mintDawn: Color(red: 0.04, green: 0.12, blue: 0.12)
    case .seaSaltBlue: Color(red: 0.04, green: 0.10, blue: 0.18)
    case .forestSoda: Color(red: 0.04, green: 0.14, blue: 0.09)
    case .peachSunset: Color(red: 0.17, green: 0.08, blue: 0.10)
    case .wisteriaNight: Color(red: 0.08, green: 0.06, blue: 0.18)
    case .lemonHarbor: Color(red: 0.11, green: 0.14, blue: 0.08)
    }
  }

  var gradientEnd: Color {
    switch self {
    case .mintDawn: Color(red: 0.05, green: 0.08, blue: 0.10)
    case .seaSaltBlue: Color(red: 0.04, green: 0.07, blue: 0.13)
    case .forestSoda: Color(red: 0.04, green: 0.08, blue: 0.07)
    case .peachSunset: Color(red: 0.09, green: 0.06, blue: 0.08)
    case .wisteriaNight: Color(red: 0.05, green: 0.05, blue: 0.11)
    case .lemonHarbor: Color(red: 0.05, green: 0.09, blue: 0.09)
    }
  }
}

enum DashboardColors {
  static var selectedPalette: DashboardPalette {
    UserDefaults.standard.string(forKey: DashboardPalette.userDefaultsKey)
      .flatMap(DashboardPalette.init(rawValue:)) ?? .mintDawn
  }

  static var fiveHour: Color { selectedPalette.fiveHour }
  static var weekly: Color { selectedPalette.weekly }
  static var panel: Color { selectedPalette.panel }
  static var panelRaised: Color { selectedPalette.panelRaised }
  static var track: Color { Color.white.opacity(0.10) }
  static var text: Color { Color(red: 0.89, green: 0.95, blue: 0.97) }
  static var subtleText: Color { Color(red: 0.55, green: 0.64, blue: 0.68) }
}

struct ConcentricGaugeView: View {
  var primary: LimitWindow?
  var secondary: LimitWindow?
  var palette: DashboardPalette = DashboardColors.selectedPalette
  var compact = false
  var mini = false
  /// 覆盖默认主题色（Claude 用冷色对）
  var primaryColorOverride: Color?
  var secondaryColorOverride: Color?
  /// 环内工具名小字（方案 B 双组双环时显示）
  var toolLabel: String?
  /// 余额来源不可用：整组置灰、中间显示 --
  var unavailable = false

  private var primaryColor: Color {
    unavailable ? Color.white.opacity(0.28) : (primaryColorOverride ?? palette.fiveHour)
  }

  private var secondaryColor: Color {
    unavailable ? Color.white.opacity(0.22) : (secondaryColorOverride ?? palette.weekly)
  }

  private var primaryProgress: Double {
    unavailable ? 0 : (primary?.remainingPercent ?? 0) / 100
  }

  private var secondaryProgress: Double {
    unavailable ? 0 : (secondary?.remainingPercent ?? 0) / 100
  }

  private var outerSize: CGFloat {
    if compact { return mini ? 96 : 126 }
    return 252
  }

  private var innerSize: CGFloat {
    if compact { return mini ? 74 : 102 }
    return 190
  }

  private var outerLineWidth: CGFloat {
    if compact { return mini ? 8 : 11 }
    return 24
  }

  private var innerLineWidth: CGFloat {
    if compact { return mini ? 7 : 9.5 }
    return 22
  }

  var body: some View {
    ZStack {
      GaugeRing(progress: secondaryProgress, color: secondaryColor, lineWidth: outerLineWidth)
        .frame(width: outerSize, height: outerSize)
      GaugeRing(progress: primaryProgress, color: primaryColor, lineWidth: innerLineWidth)
        .frame(width: innerSize, height: innerSize)

      VStack(spacing: compact ? 1 : 2) {
        Text(unavailable ? "--" : BalanceFormatters.percent(secondary?.remainingPercent))
          .font(.system(size: compact ? (mini ? 13 : 15.5) : 28, weight: .bold, design: .rounded))
          .foregroundStyle(secondaryColor)
          .monospacedDigit()
        Text(unavailable ? "--" : BalanceFormatters.percent(primary?.remainingPercent))
          .font(.system(size: compact ? (mini ? 24 : 30) : 64, weight: .heavy, design: .rounded))
          .foregroundStyle(primaryColor)
          .monospacedDigit()
        if let toolLabel {
          Text(toolLabel)
            .font(.system(size: compact ? (mini ? 8.5 : 10) : 14, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
        }
      }
      .minimumScaleFactor(0.75)
    }
  }
}

struct GaugeRing: View {
  var progress: Double
  var color: Color
  var lineWidth: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .stroke(DashboardColors.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
      Circle()
        .trim(from: 0, to: CGFloat(max(0.01, min(1, progress))))
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-82))
        .shadow(color: color.opacity(0.34), radius: 11, x: 0, y: 0)
    }
  }
}

struct MiniMetricCard: View {
  var title: String
  var value: String
  var tint: Color
  var footnote: String
  var surface: Color = DashboardColors.panelRaised

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
        .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
        Spacer()
        Circle()
          .fill(tint)
          .frame(width: 8, height: 8)
      }
      Text(value)
        .font(.system(size: 30, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.58)
      Text(footnote)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(DashboardColors.subtleText)
        .lineLimit(1)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(surface.opacity(0.72))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    )
  }
}
