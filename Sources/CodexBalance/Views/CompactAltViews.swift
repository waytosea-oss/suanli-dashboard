import CodexBalanceCore
import SwiftUI

/// 折叠态「长条」样式：两行水平进度条（上 Codex / 下 Claude），
/// 每行只显示 5 小时 / 7 天中更紧张（剩余更少）的窗口，小字标注窗口与倒计时。
struct CompactBarsView: View {
  var quad = false
  @EnvironmentObject private var store: DashboardStore
  @State private var isHovering = false
  private var palette: DashboardPalette { store.palette }
  private var backgroundOpacity: Double { store.compactBackgroundOpacity }

  var body: some View {
    ZStack {
      compactBackground(cornerRadius: 10, palette: palette, opacity: backgroundOpacity)

      VStack(spacing: quad ? 8 : 4) {
        ForEach(store.displayTools) { tool in
          ToolBarBlock(
            letter: tool.letter, event: tool.event, family: tool.colorFamily,
            palette: palette, quad: quad,
            unavailable: tool.unavailable, valueText: tool.centerText
          )
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)

      if isHovering {
        VStack {
          HStack {
            Spacer()
            hoverButton(systemImage: "arrow.clockwise", help: "刷新".l10n) {
              store.refresh()
            }
            hoverButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "展开".l10n) {
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
    .help("点击展开完整面板".l10n)
  }

}

/// 折叠态「徽章」样式：等宽单元内 [字母章][瓶颈大数字][卫星点列]；
/// quad 版在数字右侧竖排其余窗口的小数字（最多 2 个）。窗口数任意。
struct CompactBadgeView: View {
  var quad = false
  @EnvironmentObject private var store: DashboardStore
  private var palette: DashboardPalette { store.palette }
  private var backgroundOpacity: Double { store.compactBackgroundOpacity }

  var body: some View {
    ZStack {
      compactBackground(cornerRadius: 13, palette: palette, opacity: backgroundOpacity)

      HStack(spacing: 5) {
        ForEach(Array(store.displayTools.enumerated()), id: \.element.id) { index, tool in
          if index > 0 {
            Rectangle()
              .fill(Color.white.opacity(0.12))
              .frame(width: 1, height: 12)
          }
          BadgeUnit(
            letter: tool.letter, event: tool.event, family: tool.colorFamily,
            palette: palette, quad: quad,
            unavailable: tool.unavailable, valueText: tool.centerText
          )
        }
      }
      .padding(.horizontal, 8)
    }
    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { store.isCompact = false }
    .help(badgeHelpText)
  }

  private var badgeHelpText: String {
    func describe(_ tool: DisplayTool) -> String {
      if let error = tool.errorMessage, tool.unavailable { return "\(tool.name): \(error)" }
      guard !tool.unavailable, let event = tool.event else { return L("%@: 暂无数据", tool.name) }
      if let balance = tool.balance {
        let ratio = balance.remainingPercent.map { " · " + BalanceFormatters.percent($0) } ?? ""
        return "\(tool.name): \(balance.amountText)\(ratio)"
      }
      let parts = event.resolvedWindows.map {
        "\($0.label) \(BalanceFormatters.percent($0.window.remainingPercent))"
      }
      return "\(tool.name): \(parts.joined(separator: " · "))"
    }
    return (store.displayTools.map(describe) + ["点击展开完整面板".l10n]).joined(separator: "\n")
  }
}

/// 徽章单元：字母章 + 瓶颈大数字 + 卫星指示（点列 / quad 小数字列）
private struct BadgeUnit: View {
  var letter: String
  var event: RateLimitEvent?
  var family: Int
  var palette: DashboardPalette
  var quad: Bool
  var unavailable: Bool
  /// 预付费平台：大数字位置显示金额
  var valueText: String? = nil

  private var windows: [LabeledWindow] { event?.resolvedWindows ?? [] }
  private var bottleneck: LabeledWindow? { event?.bottleneckWindow }
  private var bottleneckIndex: Int {
    guard let bottleneck else { return 0 }
    return windows.firstIndex { $0.label == bottleneck.label } ?? 0
  }

  private func color(_ index: Int) -> Color {
    unavailable ? Color.white.opacity(0.25) : palette.windowColor(family: family, index: index)
  }

  /// 除瓶颈外的其余窗口（按紧张度排序）
  private var others: [(index: Int, labeled: LabeledWindow)] {
    windows.enumerated()
      .filter { $0.offset != bottleneckIndex }
      .sorted { $0.element.window.remainingPercent < $1.element.window.remainingPercent }
      .map { (index: $0.offset, labeled: $0.element) }
  }

  var body: some View {
    HStack(spacing: 3) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(unavailable ? Color.white.opacity(0.16) : color(bottleneckIndex))
        .frame(width: 11, height: 11)
        .overlay(
          Text(letter)
            .font(.system(size: 7.5, weight: .heavy, design: .rounded))
            .foregroundStyle(unavailable ? DashboardColors.subtleText : Color.black.opacity(0.75))
        )

      Text(unavailable ? "--" : (valueText ?? "\(Int((bottleneck?.window.remainingPercent ?? 0).rounded()))"))
        .font(.system(size: quad ? 12.5 : 11.5, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(unavailable ? DashboardColors.subtleText : color(bottleneckIndex))
        .frame(minWidth: 19, alignment: .trailing)

      if quad {
        // quad：其余窗口小数字竖排（最多 2，超出折叠为灰点）
        if !others.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(others.prefix(2), id: \.index) { item in
              Text(unavailable ? "--" : "\(Int(item.labeled.window.remainingPercent.rounded()))")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color(item.index))
            }
            if others.count > 2 {
              Circle().fill(Color.white.opacity(0.4)).frame(width: 2, height: 2)
            }
          }
        }
      } else if windows.count > 1 {
        // 非 quad：卫星点列（越耗越实）
        VStack(spacing: 2) {
          ForEach(Array(windows.enumerated()), id: \.offset) { index, labeled in
            Circle()
              .fill(color(index).opacity(0.30 + 0.70 * (1 - min(1, max(0, labeled.window.remainingPercent / 100)))))
              .frame(width: 2.5, height: 2.5)
              .overlay(Circle().stroke(index == bottleneckIndex ? Color.white.opacity(0.5) : .clear, lineWidth: 0.5))
          }
        }
      }
    }
  }
}

/// 长条块：主条行（瓶颈窗口）+（quad 时）卫星微条行。窗口数任意，版式不变。
private struct ToolBarBlock: View {
  var letter: String
  var event: RateLimitEvent?
  var family: Int
  var palette: DashboardPalette
  var quad: Bool
  var unavailable: Bool
  /// 预付费平台：百分比位置显示金额
  var valueText: String? = nil

  private var windows: [LabeledWindow] { event?.resolvedWindows ?? [] }
  private var bottleneck: LabeledWindow? { event?.bottleneckWindow }
  private var bottleneckIndex: Int {
    guard let bottleneck else { return 0 }
    return windows.firstIndex { $0.label == bottleneck.label } ?? 0
  }

  private func color(_ index: Int) -> Color {
    unavailable ? Color.white.opacity(0.25) : palette.windowColor(family: family, index: index)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      // 主条行
      HStack(spacing: 5) {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
          .fill(unavailable ? Color.white.opacity(0.16) : color(bottleneckIndex))
          .overlay(
            Text(letter)
              .font(.system(size: 8, weight: .heavy, design: .rounded))
              .foregroundStyle(unavailable ? DashboardColors.subtleText : Color.black.opacity(0.75))
          )
          .frame(width: 13, height: 13)

        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule(style: .continuous)
              .fill((unavailable ? Color.white : color(bottleneckIndex)).opacity(0.15))
            Capsule(style: .continuous)
              .fill(unavailable ? Color.clear : color(bottleneckIndex))
              .frame(width: max(6, proxy.size.width * CGFloat(min(1, max(0, (bottleneck?.window.remainingPercent ?? 0) / 100)))))
          }
        }
        .frame(height: 7)

        VStack(alignment: .trailing, spacing: 0) {
          Text(unavailable ? "--" : (valueText ?? BalanceFormatters.percent(bottleneck?.window.remainingPercent)))
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(unavailable ? DashboardColors.subtleText : color(bottleneckIndex))
          Text(unavailable ? "暂无".l10n : (valueText != nil ? "账户余额".l10n : "\(bottleneck?.label ?? "--") \(BalanceFormatters.resetCountdownShort(bottleneck?.window.resetsAt, mode: (bottleneck?.isHourScale ?? false) ? .hours : .days))"))
            .font(.system(size: 7.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DashboardColors.subtleText)
        }
        .frame(width: 66, alignment: .trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      }
      .frame(height: 19)

      // 卫星微条行（仅 quad；缩进对齐主条左缘）
      if quad, windows.count > 0 {
        HStack(spacing: 8) {
          ForEach(Array(windows.enumerated()), id: \.offset) { index, labeled in
            HStack(spacing: 3) {
              Circle()
                .fill(color(index))
                .frame(width: 5, height: 5)
                .overlay(Circle().stroke(index == bottleneckIndex ? Color.white.opacity(0.5) : .clear, lineWidth: 0.5))
              ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color(index))
                  .frame(width: max(2, 28 * CGFloat(min(1, max(0, labeled.window.remainingPercent / 100)))))
              }
              .frame(width: 28, height: 3)
              Text(unavailable ? "--" : "\(Int(labeled.window.remainingPercent.rounded()))")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.75))
            }
            .help("\(labeled.label) · \(BalanceFormatters.percent(labeled.window.remainingPercent)) · \(BalanceFormatters.resetCountdownShort(labeled.window.resetsAt, mode: labeled.isHourScale ? .hours : .days))")
          }
          Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .frame(height: 10)
      }
    }
    .help(unavailable ? "暂无数据".l10n : "")
  }
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
