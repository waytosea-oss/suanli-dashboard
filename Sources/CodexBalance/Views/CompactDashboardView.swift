import CodexBalanceCore
import SwiftUI

/// 折叠态方案 B：一个胶囊内左右并排两组同心双环（左 Codex 暖色对 / 右 Claude 冷色对）。
/// 点击左半边展开并定位到 Codex 分区，点击右半边定位到 Claude 分区。
struct CompactDashboardView: View {
  @EnvironmentObject private var store: DashboardStore

  var body: some View {
    switch store.compactStyle {
    case .rings: CompactRingsView()
    case .bars: CompactBarsView(quad: false)
    case .barsQuad: CompactBarsView(quad: true)
    case .badge: CompactBadgeView(quad: false)
    case .badgeQuad: CompactBadgeView(quad: true)
    }
  }
}

/// 原「方案 B 双环」样式，抽出为独立视图供样式切换。
struct CompactRingsView: View {
  @EnvironmentObject private var store: DashboardStore
  private var isMini: Bool { store.compactSizeMode == .mini }
  private var palette: DashboardPalette { store.palette }
  private var backgroundOpacity: Double { store.compactBackgroundOpacity }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(.ultraThinMaterial)
        .opacity(backgroundOpacity)
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              palette.gradientStart.opacity(backgroundOpacity * 0.48),
              palette.panel.opacity(backgroundOpacity * 0.31),
              palette.gradientEnd.opacity(backgroundOpacity * 0.42)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.07 + backgroundOpacity * 0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(backgroundOpacity * 0.22), radius: 12, x: 0, y: 8)

      HStack(spacing: 0) {
        if store.codexToolEnabled {
          toolColumn(
            label: "Codex",
            tab: .codex,
            primary: store.primary,
            secondary: store.secondary,
            primaryColor: palette.fiveHour,
            secondaryColor: palette.weekly,
            unavailable: store.status?.main == nil
          )
        }
        if store.codexToolEnabled && store.claudeToolEnabled {
          Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, isMini ? 18 : 26)
        }
        if store.claudeToolEnabled {
          toolColumn(
            label: "Claude",
            tab: .claude,
            primary: store.claudePrimary,
            secondary: store.claudeSecondary,
            primaryColor: palette.claudeFiveHour,
            secondaryColor: palette.claudeWeekly,
            unavailable: !store.claudeBalanceAvailable
          )
        }
      }
      .padding(.top, isMini ? 14 : 18)
      .padding(.bottom, isMini ? 4 : 6)

      VStack {
        HStack(alignment: .top) {
          refreshButton
          Spacer()
          expandButton
        }
        Spacer()
      }
      .padding(isMini ? 6 : 8)
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func toolColumn(
    label: String,
    tab: DashboardToolTab,
    primary: LimitWindow?,
    secondary: LimitWindow?,
    primaryColor: Color,
    secondaryColor: Color,
    unavailable: Bool
  ) -> some View {
    VStack(spacing: isMini ? 2 : 4) {
      ConcentricGaugeView(
        primary: primary,
        secondary: secondary,
        palette: palette,
        compact: true,
        mini: isMini,
        primaryColorOverride: primaryColor,
        secondaryColorOverride: secondaryColor,
        toolLabel: label,
        unavailable: unavailable
      )
      .id("\(palette.rawValue)-\(isMini)-\(label)")
      .frame(width: isMini ? 96 : 126, height: isMini ? 96 : 126)

      HStack(alignment: .bottom) {
        Text(unavailable ? "--" : resetText(primary?.resetsAt, mode: .hours))
          .foregroundStyle(unavailable ? DashboardColors.subtleText : primaryColor)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(unavailable ? "--" : resetText(secondary?.resetsAt, mode: .days))
          .foregroundStyle(unavailable ? DashboardColors.subtleText : secondaryColor)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .font(.system(size: isMini ? 9.5 : 11.5, weight: .heavy, design: .rounded))
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .padding(.horizontal, isMini ? 6 : 10)
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onTapGesture {
      store.selectedToolTab = tab
      store.isCompact = false
    }
    .help("展开并查看 \(label) 分区")
  }

  private var refreshButton: some View {
    Button {
      store.refresh()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: isMini ? 10 : 13, weight: .bold))
        Text(store.refreshIntervalOption.title)
          .font(.system(size: isMini ? 11 : 13, weight: .heavy, design: .rounded))
          .monospacedDigit()
      }
      .foregroundStyle(DashboardColors.text)
      .frame(width: isMini ? 43 : 52, height: isMini ? 23 : 28)
      .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: isMini ? 7 : 8, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: isMini ? 7 : 8, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help("刷新")
  }

  private var expandButton: some View {
    Button {
      store.isCompact = false
    } label: {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.system(size: isMini ? 11 : 14, weight: .heavy))
        .foregroundStyle(DashboardColors.text)
        .frame(width: isMini ? 25 : 32, height: isMini ? 23 : 28)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: isMini ? 7 : 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: isMini ? 7 : 8, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help("展开")
  }

  private func resetText(_ date: Date?, mode: CountdownMode) -> String {
    BalanceFormatters.resetCountdownShort(date, mode: mode)
  }
}
