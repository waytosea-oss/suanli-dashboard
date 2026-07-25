import CodexBalanceCore
import SwiftUI

/// 「主环 + 卫星胶囊行」组：每工具一个等大主环（瓶颈窗口），
/// 其余窗口降维为底部微型胶囊条。窗口数 1~N 版式不变，从结构上消解不对称。
struct HeroRingGroupView: View {
  var name: String
  var event: RateLimitEvent?
  var cool: Bool                    // 冷族(Claude)/暖族(Codex)取色
  var palette: DashboardPalette
  var mini = false
  var unavailable = false

  private var windows: [LabeledWindow] { event?.resolvedWindows ?? [] }
  private var bottleneck: LabeledWindow? { event?.bottleneckWindow }
  private var bottleneckIndex: Int {
    guard let bottleneck else { return 0 }
    return windows.firstIndex { $0.label == bottleneck.label } ?? 0
  }

  private var ringSize: CGFloat { mini ? 64 : 84 }
  private var ringWidth: CGFloat { mini ? 7 : 9 }

  private func color(_ index: Int) -> Color {
    unavailable ? Color.white.opacity(0.25) : palette.windowColor(cool: cool, index: index)
  }

  var body: some View {
    VStack(spacing: mini ? 2 : 4) {
      Text(name)
        .font(.system(size: mini ? 9 : 10, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.55))

      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
        Circle()
          .trim(from: 0, to: CGFloat(max(0.01, min(1, (bottleneck?.window.remainingPercent ?? 0) / 100))))
          .stroke(color(bottleneckIndex), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .shadow(color: color(bottleneckIndex).opacity(0.30), radius: 8)

        VStack(spacing: mini ? 0 : 1) {
          Text(unavailable ? "--" : BalanceFormatters.percent(bottleneck?.window.remainingPercent))
            .font(.system(size: mini ? 18 : 22, weight: .heavy, design: .rounded))
            .foregroundStyle(unavailable ? DashboardColors.subtleText : Color.white.opacity(0.92))
            .monospacedDigit()
          Text(unavailable ? "暂无数据".l10n : (bottleneck?.label ?? "--"))
            .font(.system(size: mini ? 8 : 9, weight: .semibold))
            .foregroundStyle(color(bottleneckIndex))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          if !mini, !unavailable, let bottleneck {
            Text(BalanceFormatters.resetCountdownShort(
              bottleneck.window.resetsAt,
              mode: bottleneck.isHourScale ? .hours : .days
            ))
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
            .monospacedDigit()
          }
        }
        .frame(width: ringSize - ringWidth * 2 - 4)
      }
      .frame(width: ringSize, height: ringSize)
      .padding(.vertical, 2)

      SatelliteCapsuleRow(
        windows: windows,
        bottleneckIndex: bottleneckIndex,
        cool: cool,
        palette: palette,
        mini: mini,
        unavailable: unavailable
      )
      .frame(height: mini ? 10 : 12)
    }
  }
}

/// 卫星胶囊行：每窗口一个微型进度胶囊，瓶颈窗口加白描边
struct SatelliteCapsuleRow: View {
  var windows: [LabeledWindow]
  var bottleneckIndex: Int
  var cool: Bool
  var palette: DashboardPalette
  var mini = false
  var unavailable = false

  private var capsuleWidth: CGFloat {
    let base: CGFloat = mini ? 18 : 22
    let maxTotal: CGFloat = mini ? 84 : 114
    let gap: CGFloat = mini ? 5 : 6
    guard windows.count > 1 else { return base }
    return min(base, (maxTotal - gap * CGFloat(windows.count - 1)) / CGFloat(windows.count))
  }

  var body: some View {
    HStack(spacing: mini ? 5 : 6) {
      ForEach(Array(windows.enumerated()), id: \.offset) { index, labeled in
        let tint = unavailable ? Color.white.opacity(0.25) : palette.windowColor(cool: cool, index: index)
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.12))
          Capsule()
            .fill(tint)
            .frame(width: max(2, capsuleWidth * CGFloat(min(1, max(0, labeled.window.remainingPercent / 100)))))
        }
        .frame(width: capsuleWidth, height: mini ? 4 : 5)
        .overlay(
          Capsule().stroke(
            index == bottleneckIndex ? Color.white.opacity(0.5) : Color.clear,
            lineWidth: 1
          )
        )
        .help("\(labeled.label) · \(BalanceFormatters.percent(labeled.window.remainingPercent)) · \(BalanceFormatters.resetCountdownShort(labeled.window.resetsAt, mode: labeled.isHourScale ? .hours : .days))")
      }
      if windows.isEmpty {
        Capsule().fill(Color.white.opacity(0.12)).frame(width: capsuleWidth, height: mini ? 4 : 5)
      }
    }
  }
}

/// 展开面板用：主环右侧的「窗口速览」竖列——全部 N 窗口，每行 label + 微条 + % + 倒计时
struct WindowQuickListView: View {
  var event: RateLimitEvent?
  var cool: Bool
  var palette: DashboardPalette
  var unavailable = false

  private var windows: [LabeledWindow] { event?.resolvedWindows ?? [] }
  private var bottleneckLabel: String? { event?.bottleneckWindow?.label }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(windows.enumerated()), id: \.offset) { index, labeled in
        let tint = unavailable ? Color.white.opacity(0.25) : palette.windowColor(cool: cool, index: index)
        let isBottleneck = labeled.label == bottleneckLabel
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(labeled.label)
              .font(.system(size: 11, weight: isBottleneck ? .heavy : .semibold))
              .foregroundStyle(isBottleneck ? tint : Color.white.opacity(0.75))
            Spacer(minLength: 4)
            Text(BalanceFormatters.percent(labeled.window.remainingPercent))
              .font(.system(size: 15, weight: .heavy, design: .rounded))
              .foregroundStyle(tint)
              .monospacedDigit()
            Text(BalanceFormatters.resetCountdownShort(
              labeled.window.resetsAt,
              mode: labeled.isHourScale ? .hours : .days
            ))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.5))
            .monospacedDigit()
            .frame(width: 56, alignment: .trailing)
          }
          ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.10))
            GeometryReader { proxy in
              Capsule()
                .fill(tint)
                .frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, labeled.window.remainingPercent / 100)))))
            }
          }
          .frame(height: 5)
        }
      }
      if windows.isEmpty {
        Text(unavailable ? "暂无数据".l10n : "--")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }
}


/// 展开态大主环：∅~180、环宽 14，环心大号数字 + label + 倒计时，下方卫星胶囊行
struct ExpandedHeroRing: View {
  var event: RateLimitEvent?
  var cool: Bool
  var palette: DashboardPalette
  var unavailable = false

  private var windows: [LabeledWindow] { event?.resolvedWindows ?? [] }
  private var bottleneck: LabeledWindow? { event?.bottleneckWindow }
  private var bottleneckIndex: Int {
    guard let bottleneck else { return 0 }
    return windows.firstIndex { $0.label == bottleneck.label } ?? 0
  }

  private func color(_ index: Int) -> Color {
    unavailable ? Color.white.opacity(0.25) : palette.windowColor(cool: cool, index: index)
  }

  var body: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 14, lineCap: .round))
        Circle()
          .trim(from: 0, to: CGFloat(max(0.01, min(1, (bottleneck?.window.remainingPercent ?? 0) / 100))))
          .stroke(color(bottleneckIndex), style: StrokeStyle(lineWidth: 14, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .shadow(color: color(bottleneckIndex).opacity(0.32), radius: 10)

        VStack(spacing: 2) {
          Text(unavailable ? "--" : BalanceFormatters.percent(bottleneck?.window.remainingPercent))
            .font(.system(size: 40, weight: .heavy, design: .rounded))
            .foregroundStyle(unavailable ? DashboardColors.subtleText : Color.white.opacity(0.92))
            .monospacedDigit()
          Text(unavailable ? "暂无数据".l10n : (bottleneck?.label ?? "--"))
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(color(bottleneckIndex))
          if !unavailable, let bottleneck {
            Text(BalanceFormatters.resetCountdown(
              bottleneck.window.resetsAt,
              mode: bottleneck.isHourScale ? .hours : .days
            ))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.5))
            .monospacedDigit()
          }
        }
      }
      .frame(width: 168, height: 168)

      SatelliteCapsuleRow(
        windows: windows, bottleneckIndex: bottleneckIndex,
        cool: cool, palette: palette, unavailable: unavailable
      )
      .frame(height: 12)
    }
  }
}
