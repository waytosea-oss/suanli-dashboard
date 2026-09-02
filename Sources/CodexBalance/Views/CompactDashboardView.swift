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
        ForEach(Array(store.displayTools.enumerated()), id: \.element.id) { index, tool in
          if index > 0 {
            Rectangle()
              .fill(Color.white.opacity(0.08))
              .frame(width: 1)
              .padding(.vertical, isMini ? 16 : 22)
          }
          heroColumn(tool)
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

  private func heroColumn(_ tool: DisplayTool) -> some View {
    HeroRingGroupView(
      name: tool.name,
      event: tool.event,
      family: tool.colorFamily,
      palette: palette,
      mini: isMini,
      unavailable: tool.unavailable,
      centerText: tool.centerText
    )
    .id("\(palette.rawValue)-\(isMini)-\(tool.id.rawValue)")
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onTapGesture {
      store.selectedToolTab = .tool(tool.id)
      store.isCompact = false
    }
    .help(tool.errorMessage ?? L("展开并查看 %@ 分区", tool.name))
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
    .help("刷新".l10n)
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
    .help("展开".l10n)
  }

  private func resetText(_ date: Date?, mode: CountdownMode) -> String {
    BalanceFormatters.resetCountdownShort(date, mode: mode)
  }
}
