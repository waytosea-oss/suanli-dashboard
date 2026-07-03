import CodexBalanceCore
import SwiftUI

/// 折叠态「长条」样式：两行水平进度条（上 Codex / 下 Claude），
/// 每行只显示 5 小时 / 7 天中更紧张（剩余更少）的窗口，小字标注窗口与倒计时。
struct CompactBarsView: View {
  @EnvironmentObject private var store: DashboardStore
  @State private var isHovering = false
  private var palette: DashboardPalette { store.palette }
  private var backgroundOpacity: Double { store.compactBackgroundOpacity }

  var body: some View {
    ZStack {
      compactBackground(cornerRadius: 10, palette: palette, opacity: backgroundOpacity)

      VStack(spacing: 4) {
        ToolBarRow(
          letter: "C",
          primary: store.primary,
          secondary: store.secondary,
          primaryColor: palette.fiveHour,
          secondaryColor: palette.weekly,
          unavailable: store.status?.main == nil
        )
        ToolBarRow(
          letter: "A",
          primary: store.claudePrimary,
          secondary: store.claudeSecondary,
          primaryColor: palette.claudeFiveHour,
          secondaryColor: palette.claudeWeekly,
          unavailable: !store.claudeBalanceAvailable
        )
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)

      if isHovering {
        VStack {
          HStack {
            Spacer()
            hoverButton(systemImage: "arrow.clockwise", help: "刷新") {
              store.refresh()
            }
            hoverButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "展开") {
              store.isCompact = false
            }
          }
          Spacer()
        }
        .padding(3)
        .transition(.opacity)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { store.isCompact = false }
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
    }
    .help("点击展开完整面板")
  }
}

/// 折叠态「徽章」样式：一个小胶囊，[C 色块][百分比] | [A 色块][百分比]，
/// 每个工具显示更紧张窗口的整数百分比；悬浮提示完整信息，点击展开。
struct CompactBadgeView: View {
  @EnvironmentObject private var store: DashboardStore
  private var palette: DashboardPalette { store.palette }
  private var backgroundOpacity: Double { store.compactBackgroundOpacity }

  var body: some View {
    ZStack {
      compactBackground(cornerRadius: 13, palette: palette, opacity: backgroundOpacity)

      HStack(spacing: 5) {
        badgeUnit(
          letter: "C",
          window: tighterWindow(store.primary, store.secondary),
          color: tighterColor(
            store.primary, store.secondary,
            primaryColor: palette.fiveHour, secondaryColor: palette.weekly
          ),
          unavailable: store.status?.main == nil
        )
        Rectangle()
          .fill(Color.white.opacity(0.12))
          .frame(width: 1, height: 12)
        badgeUnit(
          letter: "A",
          window: tighterWindow(store.claudePrimary, store.claudeSecondary),
          color: tighterColor(
            store.claudePrimary, store.claudeSecondary,
            primaryColor: palette.claudeFiveHour, secondaryColor: palette.claudeWeekly
          ),
          unavailable: !store.claudeBalanceAvailable
        )
      }
      .padding(.horizontal, 8)
    }
    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { store.isCompact = false }
    .help(badgeHelpText)
  }

  private func badgeUnit(letter: String, window: LimitWindow?, color: Color, unavailable: Bool) -> some View {
    HStack(spacing: 3) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(unavailable ? Color.white.opacity(0.16) : color)
        .frame(width: 11, height: 11)
        .overlay(
          Text(letter)
            .font(.system(size: 7.5, weight: .heavy, design: .rounded))
            .foregroundStyle(unavailable ? DashboardColors.subtleText : Color.black.opacity(0.75))
        )
      Text(unavailable ? "--" : "\(Int((window?.remainingPercent ?? 0).rounded()))")
        .font(.system(size: 11.5, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(unavailable ? DashboardColors.subtleText : Color(red: 0.93, green: 0.93, blue: 0.93))
        .frame(minWidth: 19, alignment: .trailing)
    }
  }

  private var badgeHelpText: String {
    func describe(_ name: String, _ primary: LimitWindow?, _ secondary: LimitWindow?, unavailable: Bool) -> String {
      guard !unavailable else { return "\(name): 暂无数据" }
      let p = primary.map { "5时 \(Int($0.remainingPercent.rounded()))%" } ?? "5时 --"
      let s = secondary.map { "7天 \(Int($0.remainingPercent.rounded()))%" } ?? "7天 --"
      return "\(name): \(p) · \(s)"
    }
    return describe("Codex", store.primary, store.secondary, unavailable: store.status?.main == nil)
      + "\n" + describe("Claude", store.claudePrimary, store.claudeSecondary, unavailable: !store.claudeBalanceAvailable)
      + "\n点击展开完整面板"
  }
}

/// 单行工具进度条：色块字母 + 进度条（更紧张窗口）+ 百分比 + 窗口标签/倒计时小字。
private struct ToolBarRow: View {
  var letter: String
  var primary: LimitWindow?
  var secondary: LimitWindow?
  var primaryColor: Color
  var secondaryColor: Color
  var unavailable: Bool

  private var tighterIsPrimary: Bool {
    guard let primary, let secondary else { return primary != nil }
    return primary.remainingPercent <= secondary.remainingPercent
  }

  private var window: LimitWindow? { tighterIsPrimary ? primary : secondary }
  private var color: Color { tighterIsPrimary ? primaryColor : secondaryColor }
  private var windowTag: String { tighterIsPrimary ? "5时" : "7天" }

  var body: some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        .fill(unavailable ? Color.white.opacity(0.16) : color)
        .frame(width: 13, height: 13)
        .overlay(
          Text(letter)
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundStyle(unavailable ? DashboardColors.subtleText : Color.black.opacity(0.75))
        )

      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule(style: .continuous)
            .fill((unavailable ? Color.white : color).opacity(0.15))
          Capsule(style: .continuous)
            .fill(unavailable ? Color.clear : color)
            .frame(
              width: max(
                6,
                proxy.size.width * CGFloat(min(1, max(0, (window?.remainingPercent ?? 0) / 100)))
              )
            )
        }
      }
      .frame(height: 7)

      VStack(alignment: .trailing, spacing: 0) {
        Text(unavailable ? "--" : "\(Int((window?.remainingPercent ?? 0).rounded()))%")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(unavailable ? DashboardColors.subtleText : color)
        Text(unavailable ? "暂无" : "\(windowTag) \(BalanceFormatters.resetCountdownShort(window?.resetsAt, mode: tighterIsPrimary ? .hours : .days))")
          .font(.system(size: 7.5, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(DashboardColors.subtleText)
      }
      .frame(width: 62, alignment: .trailing)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
    }
    .frame(height: 19)
    .help(rowHelpText)
  }

  private var rowHelpText: String {
    guard !unavailable else { return "暂无数据" }
    let p = primary.map { "5时 \(Int($0.remainingPercent.rounded()))% 重置 \(BalanceFormatters.resetCountdownShort($0.resetsAt, mode: .hours))" } ?? "5时 --"
    let s = secondary.map { "7天 \(Int($0.remainingPercent.rounded()))% 重置 \(BalanceFormatters.resetCountdownShort($0.resetsAt, mode: .days))" } ?? "7天 --"
    return "\(p) · \(s)"
  }
}

private func tighterWindow(_ primary: LimitWindow?, _ secondary: LimitWindow?) -> LimitWindow? {
  guard let primary else { return secondary }
  guard let secondary else { return primary }
  return primary.remainingPercent <= secondary.remainingPercent ? primary : secondary
}

private func tighterColor(
  _ primary: LimitWindow?,
  _ secondary: LimitWindow?,
  primaryColor: Color,
  secondaryColor: Color
) -> Color {
  guard let primary else { return secondaryColor }
  guard let secondary else { return primaryColor }
  return primary.remainingPercent <= secondary.remainingPercent ? primaryColor : secondaryColor
}

private func hoverButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Image(systemName: systemImage)
      .font(.system(size: 9, weight: .heavy))
      .foregroundStyle(DashboardColors.text)
      .frame(width: 18, height: 16)
      .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
  .buttonStyle(.plain)
  .help(help)
}

/// 折叠态通用底板（与双环样式一致的材质+渐变+描边）。
@ViewBuilder
func compactBackground(cornerRadius: CGFloat, palette: DashboardPalette, opacity: Double) -> some View {
  RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    .fill(.ultraThinMaterial)
    .opacity(opacity)
  RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    .fill(
      LinearGradient(
        colors: [
          palette.gradientStart.opacity(opacity * 0.48),
          palette.panel.opacity(opacity * 0.31),
          palette.gradientEnd.opacity(opacity * 0.42)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(Color.white.opacity(0.07 + opacity * 0.08), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(opacity * 0.22), radius: 12, x: 0, y: 8)
}
