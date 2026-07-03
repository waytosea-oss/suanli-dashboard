import CodexBalanceCore
import SwiftUI

struct ExpandedDashboardView: View {
  @EnvironmentObject private var store: DashboardStore
  @State private var showSettings = false
  private var palette: DashboardPalette { store.palette }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.ultraThinMaterial)
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              palette.gradientStart.opacity(0.78),
              palette.panel.opacity(0.62),
              palette.gradientEnd.opacity(0.76)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )

      ScrollView(showsIndicators: false) {
        VStack(spacing: 14) {
          header
          toolTabPicker
          if showSettings {
            settingsPanel
              .transition(.opacity.combined(with: .move(edge: .top)))
          }
          switch store.selectedToolTab {
          case .codex:
            gaugePanel
            overviewCards
            TokenStatsView(stats: store.tokenStats, palette: palette)
            recentEvents
          case .claude:
            claudeGaugePanel
            claudeOverviewCards
            TokenStatsView(
              stats: store.claudeTokenStats,
              palette: palette,
              primaryTint: palette.claudeFiveHour,
              secondaryTint: palette.claudeWeekly,
              showsTotalScope: false,
              boardCaption: "本机日志口径含 cache_read · 不含网页 Chat / Cowork 消耗".l10n
            )
            claudeRecentEvents
          case .all:
            allGaugePanel
            allSummaryBoard
            TokenStatsView(stats: store.tokenStats, palette: palette, boardTitle: "Codex · Token 消耗看板".l10n)
            TokenStatsView(
              stats: store.claudeTokenStats,
              palette: palette,
              primaryTint: palette.claudeFiveHour,
              secondaryTint: palette.claudeWeekly,
              showsTotalScope: false,
              boardTitle: "Claude · Token 消耗看板".l10n,
              boardCaption: "本机日志口径含 cache_read · 不含网页 Chat / Cowork 消耗".l10n
            )
          }
        }
        .padding(18)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .onAppear {
      store.refreshSettingsState()
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 4) {
        Text("算力码表")
          .font(.system(size: 26, weight: .heavy, design: .rounded))
          .foregroundStyle(DashboardColors.text)
        Text(headerSubtitle)
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
          .lineLimit(1)
      }
      Spacer()
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          showSettings.toggle()
        }
      } label: {
        Label("设置".l10n, systemImage: "gearshape.fill")
          .font(.system(size: 13, weight: .bold))
      }
      .buttonStyle(ToolButtonStyle(isSelected: showSettings))
      .help("打开设置".l10n)

      Button {
        store.isCompact = true
      } label: {
        Label("收起".l10n, systemImage: "arrow.down.right.and.arrow.up.left")
          .font(.system(size: 13, weight: .bold))
      }
      .buttonStyle(ToolButtonStyle())
      .help("收起浮窗".l10n)
    }
  }

  private var headerSubtitle: String {
    if let errorMessage = store.errorMessage {
      return L("读取失败: %@", errorMessage)
    }
    guard let status = store.status else { return "正在扫描本地 Codex 会话日志".l10n }
    guard let latestEvent = status.main else {
      return L("%d 个日志文件 · 没有余额事件 · 在这台 Mac 的 Codex 输入 /status", status.scannedFiles)
    }
    if latestEvent.sourceName == "Codex app-server" {
      return L("实时读取 Codex app-server · %@", BalanceFormatters.dateTime(latestEvent.timestamp))
    }
    return L("%d 个日志文件 · 最新余额 %@ · %@", status.scannedFiles, BalanceFormatters.relativeAge(latestEvent.timestamp), BalanceFormatters.dateTime(latestEvent.timestamp))
  }

  private var toolTabPicker: some View {
    HStack(spacing: 6) {
      ForEach(DashboardToolTab.allCases) { tab in
        ToolTabButton(
          tab: tab,
          palette: palette,
          isSelected: store.selectedToolTab == tab
        ) {
          withAnimation(.easeInOut(duration: 0.16)) {
            store.selectedToolTab = tab
          }
        }
      }
    }
  }

  private var claudeGaugePanel: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color.black.opacity(0.16),
              palette.panelRaised.opacity(0.70)
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )

      ConcentricGaugeView(
        primary: store.claudePrimary,
        secondary: store.claudeSecondary,
        palette: palette,
        primaryColorOverride: palette.claudeFiveHour,
        secondaryColorOverride: palette.claudeWeekly,
        unavailable: !store.claudeBalanceAvailable
      )
      .id("claude-\(palette.rawValue)")
      .frame(width: 292, height: 292)
      .padding(.top, 2)

      VStack {
        HStack {
          Spacer()
          Text(claudeFreshnessText)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(DashboardColors.subtleText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
              Capsule(style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
        Spacer()
      }
      .padding(14)

      VStack {
        Spacer()
        HStack(alignment: .bottom) {
          resetCorner(
            value: store.claudeBalanceAvailable
              ? BalanceFormatters.resetCountdown(store.claudePrimary?.resetsAt, mode: .hours)
              : "--",
            tint: palette.claudeFiveHour,
            alignment: .leading
          )
          Spacer()
          resetCorner(
            value: store.claudeBalanceAvailable
              ? BalanceFormatters.resetCountdown(store.claudeSecondary?.resetsAt, mode: .days)
              : "--",
            tint: palette.claudeWeekly,
            alignment: .trailing
          )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
      }
    }
    .frame(height: 320)
  }

  private var claudeFreshnessText: String {
    guard let event = store.claudeStatus?.main else {
      return "暂无数据 · 本机未读到 Claude 余额来源".l10n
    }
    return L("实时读取 %@ · %@", event.sourceName, BalanceFormatters.dateTime(event.timestamp))
  }

  private var claudeOverviewCards: some View {
    HStack(spacing: 12) {
      MiniMetricCard(
        title: "5 小时余额".l10n,
        value: store.claudeBalanceAvailable ? BalanceFormatters.percent(store.claudePrimary?.remainingPercent) : "--",
        tint: palette.claudeFiveHour,
        footnote: store.claudeBalanceAvailable ? L("已用 %@", BalanceFormatters.percent(store.claudePrimary?.usedPercent)) : "暂无数据".l10n,
        surface: palette.panelRaised
      )
      MiniMetricCard(
        title: "7 天余额".l10n,
        value: store.claudeBalanceAvailable ? BalanceFormatters.percent(store.claudeSecondary?.remainingPercent) : "--",
        tint: palette.claudeWeekly,
        footnote: store.claudeBalanceAvailable ? L("已用 %@", BalanceFormatters.percent(store.claudeSecondary?.usedPercent)) : "暂无数据".l10n,
        surface: palette.panelRaised
      )
      MiniMetricCard(
        title: "今日 Token".l10n,
        value: BalanceFormatters.compactNumber(store.claudeTokenStats.todayTokens),
        tint: DashboardColors.text,
        footnote: L("本月 %@", BalanceFormatters.compactNumber(store.claudeTokenStats.monthTokens)),
        surface: palette.panelRaised
      )
    }
  }

  private var claudeRecentEvents: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("最近余额事件".l10n)
        .font(.system(size: 14, weight: .heavy))
        .foregroundStyle(DashboardColors.text)
      if (store.claudeStatus?.recentEvents.isEmpty ?? true) {
        Text("暂无数据 · Claude 余额事件依赖本机 OAuth 凭据".l10n)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      } else {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(store.claudeStatus?.recentEvents.prefix(6) ?? []) { event in
            HStack(spacing: 8) {
              Text(BalanceFormatters.dateTime(event.timestamp))
                .foregroundStyle(DashboardColors.subtleText)
              Spacer()
              Text(BalanceFormatters.percent(event.primary?.remainingPercent))
                .foregroundStyle(palette.claudeFiveHour)
              Text(BalanceFormatters.percent(event.secondary?.remainingPercent))
                .foregroundStyle(palette.claudeWeekly)
            }
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.panelRaised.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
        }
      }
    }
  }

  private var allGaugePanel: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color.black.opacity(0.16), palette.panelRaised.opacity(0.70)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )

      HStack(spacing: 14) {
        VStack(spacing: 6) {
          ConcentricGaugeView(
            primary: store.primary,
            secondary: store.secondary,
            palette: palette,
            compact: true,
            toolLabel: "Codex",
            unavailable: store.status?.main == nil
          )
          .id("all-codex-\(palette.rawValue)")
          .frame(width: 150, height: 150)
          HStack {
            Text(BalanceFormatters.resetCountdownShort(store.primary?.resetsAt, mode: .hours))
              .foregroundStyle(palette.fiveHour)
            Text(BalanceFormatters.resetCountdownShort(store.secondary?.resetsAt, mode: .days))
              .foregroundStyle(palette.weekly)
          }
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .monospacedDigit()
        }
        .frame(maxWidth: .infinity)

        Rectangle()
          .fill(Color.white.opacity(0.08))
          .frame(width: 1)
          .padding(.vertical, 26)

        VStack(spacing: 6) {
          ConcentricGaugeView(
            primary: store.claudePrimary,
            secondary: store.claudeSecondary,
            palette: palette,
            compact: true,
            primaryColorOverride: palette.claudeFiveHour,
            secondaryColorOverride: palette.claudeWeekly,
            toolLabel: "Claude",
            unavailable: !store.claudeBalanceAvailable
          )
          .id("all-claude-\(palette.rawValue)")
          .frame(width: 150, height: 150)
          HStack {
            Text(store.claudeBalanceAvailable ? BalanceFormatters.resetCountdownShort(store.claudePrimary?.resetsAt, mode: .hours) : "--")
              .foregroundStyle(palette.claudeFiveHour)
            Text(store.claudeBalanceAvailable ? BalanceFormatters.resetCountdownShort(store.claudeSecondary?.resetsAt, mode: .days) : "--")
              .foregroundStyle(palette.claudeWeekly)
          }
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 12)
    }
    .frame(height: 230)
  }

  private var allSummaryBoard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Codex")
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(palette.weekly)
          .frame(width: 52, alignment: .leading)
        TokenSummaryStrip(stats: store.tokenStats, palette: palette)
      }
      HStack(spacing: 8) {
        Text("Claude")
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(palette.claudeWeekly)
          .frame(width: 52, alignment: .leading)
        TokenSummaryStrip(
          stats: store.claudeTokenStats,
          palette: palette,
          primaryTint: palette.claudeFiveHour,
          secondaryTint: palette.claudeWeekly
        )
      }
      Text("两个工具的 token 口径不同，不相加".l10n)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(DashboardColors.subtleText)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(12)
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.07), lineWidth: 1)
    )
  }

  private var gaugePanel: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color.black.opacity(0.16),
              palette.panelRaised.opacity(0.70)
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )

      ConcentricGaugeView(primary: store.primary, secondary: store.secondary, palette: palette)
        .id(palette.rawValue)
        .frame(width: 292, height: 292)
        .padding(.top, 2)

      if let freshnessText {
        VStack {
          HStack {
            Spacer()
            Text(freshnessText)
              .font(.system(size: 11, weight: .heavy))
              .foregroundStyle(DashboardColors.subtleText)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(
                Capsule(style: .continuous)
                  .fill(Color.white.opacity(0.055))
                  .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
              )
          }
          Spacer()
        }
        .padding(14)
      }

      VStack {
        Spacer()
        HStack(alignment: .bottom) {
          resetCorner(
            value: BalanceFormatters.resetCountdown(store.primary?.resetsAt, mode: .hours),
            tint: palette.fiveHour,
            alignment: .leading
          )
          Spacer()
          resetCorner(
            value: BalanceFormatters.resetCountdown(store.secondary?.resetsAt, mode: .days),
            tint: palette.weekly,
            alignment: .trailing
          )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
      }
    }
    .frame(height: 320)
  }

  private var freshnessText: String? {
    guard let event = store.status?.main else {
      return "无余额事件".l10n
    }
    if event.sourceName == "Codex app-server" {
      return nil
    }
    let age = Date().timeIntervalSince(event.timestamp)
    guard age > 10 * 60 else { return nil }
    return L("旧数据 %@，请在 Codex 输入 /status", BalanceFormatters.relativeAge(event.timestamp))
  }

  private func resetCorner(value: String, tint: Color, alignment: Alignment) -> some View {
    Text(value)
      .font(.system(size: 18, weight: .heavy, design: .rounded))
      .foregroundStyle(tint)
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.68)
      .frame(width: 168, alignment: alignment)
  }

  private func resetPill(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(value)
        .font(.system(size: 18, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.76)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(DashboardColors.panelRaised.opacity(0.76), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var overviewCards: some View {
    HStack(spacing: 12) {
      MiniMetricCard(
        title: "5 小时余额".l10n,
        value: BalanceFormatters.percent(store.primary?.remainingPercent),
        tint: palette.fiveHour,
        footnote: L("已用 %@", BalanceFormatters.percent(store.primary?.usedPercent)),
        surface: palette.panelRaised
      )
      MiniMetricCard(
        title: "7 天余额".l10n,
        value: BalanceFormatters.percent(store.secondary?.remainingPercent),
        tint: palette.weekly,
        footnote: L("已用 %@", BalanceFormatters.percent(store.secondary?.usedPercent)),
        surface: palette.panelRaised
      )
      MiniMetricCard(
        title: "今日 Token".l10n,
        value: BalanceFormatters.compactNumber(store.tokenStats.todayTokens),
        tint: DashboardColors.text,
        footnote: L("本月 %@", BalanceFormatters.compactNumber(store.tokenStats.monthTokens)),
        surface: palette.panelRaised
      )
    }
  }

  private var settingsPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("设置".l10n, systemImage: "gearshape.fill")
          .font(.system(size: 15, weight: .heavy))
          .foregroundStyle(DashboardColors.text)
        Spacer()
        Text("外观与运行".l10n)
          .font(.system(size: 11.5, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
      }

      settingsSection(title: "监控工具".l10n, systemImage: "wrench.and.screwdriver.fill") {
        HStack(spacing: 8) {
          toolChip(
            title: "Codex",
            subtitle: "OpenAI Codex",
            isOn: store.codexToolEnabled,
            tint: palette.fiveHour
          ) {
            store.codexToolEnabled.toggle()
          }
          toolChip(
            title: "Claude",
            subtitle: "Claude Code",
            isOn: store.claudeToolEnabled,
            tint: palette.claudeFiveHour
          ) {
            store.claudeToolEnabled.toggle()
          }
        }
        Text("按你实际使用的工具勾选，浮窗、Touch Bar 和面板都会跟随；至少保留一个".l10n)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }

      settingsSection(title: "外观".l10n, systemImage: "slider.horizontal.3") {
        settingsRow(title: "收起透明度".l10n, subtitle: "调整浮窗底板通透程度".l10n) {
          HStack(spacing: 10) {
            Slider(
              value: Binding(
                get: { store.compactBackgroundOpacity },
                set: { store.compactBackgroundOpacity = $0 }
              ),
              in: 0.30...0.94,
              step: 0.01
            )
            .frame(width: 190)

            Text("\(Int((store.compactBackgroundOpacity * 100).rounded()))%")
              .font(.system(size: 12, weight: .heavy, design: .rounded))
              .foregroundStyle(DashboardColors.text)
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }

        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text("悬浮样式".l10n)
              .font(.system(size: 12, weight: .heavy))
              .foregroundStyle(DashboardColors.text)
            Text("占用面积依次更小".l10n)
              .font(.system(size: 10.5, weight: .semibold))
              .foregroundStyle(DashboardColors.subtleText)
          }
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(CompactStyle.allCases) { style in
              CompactStyleCard(
                style: style,
                palette: palette,
                isSelected: store.compactStyle == style
              ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                  store.compactStyle = style
                }
              }
            }
          }
        }

        settingsRow(title: "自动避让".l10n, subtitle: "自动把浮窗挪到屏幕上被遮挡最少的角落".l10n) {
          Toggle("", isOn: Binding(
            get: { store.autoDodgeEnabled },
            set: { store.autoDodgeEnabled = $0 }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
        }

        settingsRow(title: "收起尺寸".l10n, subtitle: "选择标准或迷你浮窗".l10n) {
          HStack(spacing: 8) {
            ForEach(CompactSizeMode.allCases) { mode in
              SizeModeCard(
                mode: mode,
                palette: palette,
                isSelected: store.compactSizeMode == mode
              ) {
                store.compactSizeMode = mode
              }
            }
          }
        }

        settingsRow(title: "刷新频率".l10n, subtitle: "余额自动更新间隔".l10n) {
          HStack(spacing: 8) {
            Picker("", selection: Binding(
              get: { store.refreshIntervalOption },
              set: { store.refreshIntervalOption = $0 }
            )) {
              ForEach(RefreshIntervalOption.allCases) { option in
                Text(option.title).tag(option)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 154)

            Button {
              store.refresh()
            } label: {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(DashboardColors.text)
                .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                  RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            )
            .help("立即刷新".l10n)
          }
        }
      }

      settingsSection(title: "配色".l10n, systemImage: "paintpalette.fill") {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(DashboardPalette.allCases) { palette in
            PaletteButton(
              palette: palette,
              isSelected: store.palette == palette
            ) {
              withAnimation(.easeInOut(duration: 0.18)) {
                store.palette = palette
              }
            }
          }
        }
      }

      settingsSection(title: "运行".l10n, systemImage: "bolt.fill") {
        Button {
          store.setLaunchWithCodexEnabled(!store.launchWithCodexEnabled)
        } label: {
          HStack(alignment: .center, spacing: 12) {
            Image(systemName: store.launchWithCodexEnabled ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 17, weight: .heavy))
              .foregroundStyle(store.launchWithCodexEnabled ? palette.weekly : DashboardColors.subtleText)
              .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
              Text("打开 Codex / Claude 时自动启动".l10n)
                .font(.system(size: 12.5, weight: .heavy))
                .foregroundStyle(DashboardColors.text)
              Text("Codex 或 Claude Code 运行时自动唤起算力码表".l10n)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardColors.subtleText)
            }

            Spacer(minLength: 8)

            Text(store.launchWithCodexEnabled ? "已开启".l10n : "已关闭".l10n)
              .font(.system(size: 11.5, weight: .heavy))
              .foregroundStyle(store.launchWithCodexEnabled ? palette.weekly : DashboardColors.subtleText)
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(
                Capsule(style: .continuous)
                  .fill((store.launchWithCodexEnabled ? palette.weekly : Color.white).opacity(0.10))
              )
          }
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        )
        .help("切换打开 Codex / Claude 时自动启动".l10n)

        Button {
          store.touchBarEnabled.toggle()
        } label: {
          HStack(alignment: .center, spacing: 12) {
            Image(systemName: store.touchBarEnabled ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 17, weight: .heavy))
              .foregroundStyle(store.touchBarEnabled ? palette.weekly : DashboardColors.subtleText)
              .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
              Text("Touch Bar 常驻余额".l10n)
                .font(.system(size: 12.5, weight: .heavy))
                .foregroundStyle(DashboardColors.text)
              Text(store.touchBarSupported
                ? "在 Touch Bar 右侧常显 C/A 余额，点按唤出面板".l10n
                : "本机不支持 Touch Bar".l10n)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardColors.subtleText)
            }

            Spacer(minLength: 8)

            Text(store.touchBarEnabled ? "已开启".l10n : "已关闭".l10n)
              .font(.system(size: 11.5, weight: .heavy))
              .foregroundStyle(store.touchBarEnabled ? palette.weekly : DashboardColors.subtleText)
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(
                Capsule(style: .continuous)
                  .fill((store.touchBarEnabled ? palette.weekly : Color.white).opacity(0.10))
              )
          }
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        )
        .disabled(!store.touchBarSupported)
        .opacity(store.touchBarSupported ? 1 : 0.5)
        .help("在 Touch Bar Control Strip 常驻显示两个工具的余额".l10n)

        if store.touchBarEnabled {
          Button {
            store.touchBarKeepAwake.toggle()
          } label: {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: store.touchBarKeepAwake ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(store.touchBarKeepAwake ? palette.weekly : DashboardColors.subtleText)
                .frame(width: 20)

              VStack(alignment: .leading, spacing: 3) {
                Text("Touch Bar 保持常亮".l10n)
                  .font(.system(size: 12.5, weight: .heavy))
                  .foregroundStyle(DashboardColors.text)
                Text("阻止 Touch Bar 息屏；主屏幕也不会自动休眠，用电池时注意续航".l10n)
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(DashboardColors.subtleText)
              }

              Spacer(minLength: 8)

              Text(store.touchBarKeepAwake ? "已开启".l10n : "已关闭".l10n)
                .font(.system(size: 11.5, weight: .heavy))
                .foregroundStyle(store.touchBarKeepAwake ? palette.weekly : DashboardColors.subtleText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                  Capsule(style: .continuous)
                    .fill((store.touchBarKeepAwake ? palette.weekly : Color.white).opacity(0.10))
                )
            }
          }
          .buttonStyle(.plain)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.white.opacity(0.04))
              .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .stroke(Color.white.opacity(0.08), lineWidth: 1)
              )
          )
          .help("周期性向系统申报用户活跃，保持 Touch Bar 常亮".l10n)

          settingsRow(title: "显示 % 号", subtitle: "熟悉后可关掉，数字更大更干净".l10n) {
            Toggle("", isOn: Binding(
              get: { store.touchBarShowsPercentSign },
              set: { store.touchBarShowsPercentSign = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
          }

          settingsRow(title: "显示 5时/7天 标签".l10n, subtitle: "关闭后只留数值本身".l10n) {
            Toggle("", isOn: Binding(
              get: { store.touchBarShowsWindowTags },
              set: { store.touchBarShowsWindowTags = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
          }

          settingsRow(title: "显示最近会话".l10n, subtitle: "余额右侧显示最近 AI 会话，点击直达对应 App".l10n) {
            Toggle("", isOn: Binding(
              get: { store.touchBarShowsSessions },
              set: { store.touchBarShowsSessions = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
          }

          if store.touchBarShowsSessions {
            settingsRow(title: "会话数量".l10n, subtitle: "显示 1 个时字最大，一眼看清".l10n) {
              Picker("", selection: Binding(
                get: { store.touchBarSessionCount },
                set: { store.touchBarSessionCount = $0 }
              )) {
                Text("1 个".l10n).tag(1)
                Text("2 个".l10n).tag(2)
                Text("3 个".l10n).tag(3)
              }
              .labelsHidden()
              .pickerStyle(.segmented)
              .frame(width: 150)
            }
          }

          settingsRow(title: "Touch Bar 样式".l10n, subtitle: "全宽面板的呈现方式".l10n) {
            Picker("", selection: Binding(
              get: { store.touchBarStyle },
              set: { store.touchBarStyle = $0 }
            )) {
              ForEach(TouchBarPanelStyle.allCases) { style in
                Text(style.title).tag(style)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
          }
        }

        if let message = store.settingsMessage {
          Text(message)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DashboardColors.subtleText)
            .lineLimit(1)
        }
      }
      HStack(spacing: 6) {
        Text("算力码表 suanli-dashboard".l10n)
          .font(.system(size: 10.5, weight: .heavy))
          .foregroundStyle(DashboardColors.subtleText)
        Text("·")
          .foregroundStyle(DashboardColors.subtleText)
        Text("作者 Tilo Liang".l10n)
          .font(.system(size: 10.5, weight: .heavy))
          .foregroundStyle(DashboardColors.text.opacity(0.85))
        Text("·")
          .foregroundStyle(DashboardColors.subtleText)
        Text("MIT 开源".l10n)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
        Spacer()
        Button {
          if let url = URL(string: AppInfo.repositoryURL) {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Label("GitHub", systemImage: "link")
            .font(.system(size: 10.5, weight: .heavy))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DashboardColors.subtleText)
        .help("打开项目主页".l10n)
      }
      .padding(.top, 2)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.panelRaised.opacity(0.68))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    )
  }

  private func toolChip(
    title: String,
    subtitle: String,
    isOn: Bool,
    tint: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15, weight: .heavy))
          .foregroundStyle(isOn ? tint : DashboardColors.subtleText)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: 12.5, weight: .heavy))
            .foregroundStyle(isOn ? DashboardColors.text : DashboardColors.subtleText)
          Text(subtitle)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 44)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isOn ? tint.opacity(0.14) : Color.white.opacity(0.045))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(isOn ? tint.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help(isOn ? L("点击停用 %@ 监控", title) : L("点击启用 %@ 监控", title))
  }

  private func settingsSection<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.system(size: 12.5, weight: .heavy))
        .foregroundStyle(DashboardColors.text)

      VStack(alignment: .leading, spacing: 10) {
        content()
      }
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(0.045))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.white.opacity(0.07), lineWidth: 1)
          )
      )
    }
  }

  private func settingsRow<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder control: () -> Content
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(DashboardColors.text)
        Text(subtitle)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }
      Spacer(minLength: 12)
      control()
    }
  }

  private var recentEvents: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("最近余额事件".l10n)
        .font(.system(size: 14, weight: .heavy))
        .foregroundStyle(DashboardColors.text)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        ForEach(store.status?.recentEvents.prefix(6) ?? []) { event in
          HStack(spacing: 8) {
            Text(BalanceFormatters.dateTime(event.timestamp))
              .foregroundStyle(DashboardColors.subtleText)
            Spacer()
            Text(BalanceFormatters.percent(event.primary?.remainingPercent))
              .foregroundStyle(palette.fiveHour)
            Text(BalanceFormatters.percent(event.secondary?.remainingPercent))
              .foregroundStyle(palette.weekly)
          }
          .font(.system(size: 12, weight: .semibold))
          .monospacedDigit()
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(palette.panelRaised.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
    }
  }
}

private struct TokenStatsView: View {
  var stats: TokenStats
  var palette: DashboardPalette = DashboardColors.selectedPalette
  var primaryTint: Color?
  var secondaryTint: Color?
  var showsTotalScope = true
  var boardTitle = "Token 消耗看板".l10n
  var boardCaption: String?

  private var tintA: Color { primaryTint ?? palette.fiveHour }
  private var tintB: Color { secondaryTint ?? palette.weekly }
  private var recentDays: [TokenBucket] {
    Array(stats.daily.suffix(14))
  }
  private var recentMonths: [TokenBucket] {
    stats.monthly
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text(boardTitle)
          .font(.system(size: 16, weight: .heavy))
          .foregroundStyle(DashboardColors.text)
        Spacer()
        Text(L("样本 %d", stats.sampleCount))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }
      if let boardCaption {
        Text(boardCaption)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }

      TokenSummaryStrip(stats: stats, palette: palette, primaryTint: tintA, secondaryTint: tintB)
      TokenCategoryBoard(
        buckets: stats.categoryBreakdown,
        monthTotal: stats.monthTokens,
        palette: palette
      )
      TokenTopProjectsBoard(
        todayProjects: stats.todayTopProjects,
        monthProjects: stats.monthTopProjects,
        todayTotal: stats.todayTokens,
        monthTotal: stats.monthTokens,
        palette: palette,
        primaryTint: tintA,
        secondaryTint: tintB
      )

      TokenTrendPanel(
        stats: stats,
        localDailyBuckets: recentDays,
        localMonthlyBuckets: recentMonths,
        palette: palette,
        primaryTint: tintA,
        secondaryTint: tintB,
        showsTotalScope: showsTotalScope
      )
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.panelRaised.opacity(0.72))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    )
  }
}

private struct TokenCategoryBoard: View {
  var buckets: [TokenCategoryBucket]
  var monthTotal: Int
  var palette: DashboardPalette

  private var visibleBuckets: [TokenCategoryBucket] {
    buckets.filter { $0.totalTokens > 0 }.sorted { lhs, rhs in
      if lhs.totalTokens == rhs.totalTokens {
        return categoryOrder(lhs.category) < categoryOrder(rhs.category)
      }
      return lhs.totalTokens > rhs.totalTokens
    }
  }

  private var distributionTotal: Int {
    max(monthTotal, visibleBuckets.reduce(0) { $0 + $1.totalTokens }, 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("本月用途分布".l10n)
          .font(.system(size: 14, weight: .heavy))
          .foregroundStyle(DashboardColors.text)
        Spacer()
        Text(L("本月 %@", BalanceFormatters.compactNumber(distributionTotal)))
          .font(.system(size: 10.5, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
      }

      if visibleBuckets.isEmpty {
        Text("暂无可归类的本月 token 数据".l10n)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
          .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
      } else {
        HStack(alignment: .center, spacing: 18) {
          CategoryPieChart(
            buckets: visibleBuckets,
            total: distributionTotal,
            color: { categoryColor($0, palette: palette) }
          )
          .frame(width: 132, height: 132)

          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text("用途".l10n)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text("消耗".l10n)
                .frame(width: 88, alignment: .trailing)
              Text("占比".l10n)
                .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)

            ForEach(visibleBuckets) { bucket in
              PieLegendRow(
                bucket: bucket,
                total: distributionTotal,
                color: categoryColor(bucket.category, palette: palette)
              )
            }

            Text("按本月 token 事件上下文推断".l10n)
              .font(.system(size: 10.5, weight: .semibold))
              .foregroundStyle(DashboardColors.subtleText)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
        .padding(10)
        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
    .padding(12)
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.07), lineWidth: 1)
    )
  }

  private func categoryOrder(_ category: TokenUsageCategory) -> Int {
    TokenUsageCategory.allCases.firstIndex(of: category) ?? 99
  }

  private func categoryColor(_ category: TokenUsageCategory, palette: DashboardPalette) -> Color {
    switch category {
    case .coding: palette.fiveHour
    case .presentation: palette.weekly
    case .imageDesign: Color(red: 1.0, green: 0.58, blue: 0.67)
    case .documents: Color(red: 0.95, green: 0.78, blue: 0.38)
    case .research: Color(red: 0.70, green: 0.62, blue: 1.0)
    case .other: DashboardColors.subtleText
    }
  }
}

private struct CategoryPieChart: View {
  var buckets: [TokenCategoryBucket]
  var total: Int
  var color: (TokenUsageCategory) -> Color

  private var segments: [PieSegment] {
    var cursor = 0.0
    return buckets.map { bucket in
      let ratio = Double(bucket.totalTokens) / Double(max(total, 1))
      let segment = PieSegment(
        id: bucket.category.rawValue,
        start: cursor,
        end: cursor + ratio,
        color: color(bucket.category)
      )
      cursor += ratio
      return segment
    }
  }

  var body: some View {
    ZStack {
      ForEach(segments) { segment in
        PieSliceShape(
          startAngle: .degrees(segment.start * 360 - 90),
          endAngle: .degrees(segment.end * 360 - 90)
        )
        .fill(segment.color)
        .overlay(
          PieSliceShape(
            startAngle: .degrees(segment.start * 360 - 90),
            endAngle: .degrees(segment.end * 360 - 90)
          )
          .stroke(Color.black.opacity(0.18), lineWidth: 1)
        )
      }

      Circle()
        .fill(.ultraThinMaterial.opacity(0.82))
        .frame(width: 62, height: 62)
        .overlay(
          Circle()
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )

      VStack(spacing: 3) {
        Text("本月".l10n)
          .font(.system(size: 10.5, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
        Text(BalanceFormatters.compactNumber(total))
          .font(.system(size: 17, weight: .heavy, design: .rounded))
          .foregroundStyle(DashboardColors.text)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.66)
      }
    }
    .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 8)
  }
}

private struct PieSegment: Identifiable {
  var id: String
  var start: Double
  var end: Double
  var color: Color
}

private struct PieSliceShape: Shape {
  var startAngle: Angle
  var endAngle: Angle

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    var path = Path()
    path.move(to: center)
    path.addArc(
      center: center,
      radius: radius,
      startAngle: startAngle,
      endAngle: endAngle,
      clockwise: false
    )
    path.closeSubpath()
    return path
  }
}

private struct PieLegendRow: View {
  var bucket: TokenCategoryBucket
  var total: Int
  var color: Color

  private var percent: Double {
    Double(bucket.totalTokens) / Double(max(total, 1))
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)

      Text(bucket.category.label)
        .font(.system(size: 12.5, weight: .heavy))
        .foregroundStyle(DashboardColors.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)

      Text(BalanceFormatters.compactNumber(bucket.totalTokens))
        .font(.system(size: 13.5, weight: .heavy, design: .rounded))
        .foregroundStyle(color)
        .monospacedDigit()
        .frame(width: 88, alignment: .trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.66)

      Text("\(Int((percent * 100).rounded()))%")
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .foregroundStyle(DashboardColors.text)
        .monospacedDigit()
        .frame(width: 42, alignment: .trailing)
    }
    .padding(.horizontal, 9)
    .frame(height: 25)
    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .help("\(bucket.category.label): \(BalanceFormatters.exactNumber(bucket.totalTokens)) tokens")
  }
}

private struct TokenTopProjectsBoard: View {
  var todayProjects: [TokenProjectBucket]
  var monthProjects: [TokenProjectBucket]
  var todayTotal: Int
  var monthTotal: Int
  var palette: DashboardPalette
  var primaryTint: Color?
  var secondaryTint: Color?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("项目消耗 Top 3".l10n)
          .font(.system(size: 14, weight: .heavy))
          .foregroundStyle(DashboardColors.text)
        Spacer()
        Text("优先显示项目别名".l10n)
          .font(.system(size: 10.5, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
      }

      VStack(spacing: 10) {
        ProjectRankStrip(
          title: "今日".l10n,
          projects: todayProjects,
          total: todayTotal,
          tint: primaryTint ?? palette.fiveHour
        )
        ProjectRankStrip(
          title: "本月".l10n,
          projects: monthProjects,
          total: monthTotal,
          tint: secondaryTint ?? palette.weekly
        )
      }
    }
    .padding(12)
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.07), lineWidth: 1)
    )
  }
}

private struct ProjectRankStrip: View {
  var title: String
  var projects: [TokenProjectBucket]
  var total: Int
  var tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(.system(size: 12.5, weight: .heavy))
          .foregroundStyle(DashboardColors.text)
        Spacer()
        Text(BalanceFormatters.compactNumber(total))
          .font(.system(size: 11.5, weight: .heavy, design: .rounded))
          .foregroundStyle(tint)
          .monospacedDigit()
      }

      HStack(spacing: 8) {
        if projects.isEmpty {
          Text("暂无数据".l10n)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DashboardColors.subtleText)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
        } else {
          ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
            ProjectRankTile(
              rank: index + 1,
              project: project,
              total: max(total, 1),
              tint: tint
            )
          }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct ProjectRankTile: View {
  var rank: Int
  var project: TokenProjectBucket
  var total: Int
  var tint: Color

  private var percent: Int {
    Int((Double(project.totalTokens) / Double(max(total, 1)) * 100).rounded())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Text("\(rank)")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .foregroundStyle(tint)
          .frame(width: 18, height: 18)
          .background(tint.opacity(0.16), in: Circle())
        Text(project.projectName)
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(DashboardColors.text)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }

      Text("\(BalanceFormatters.compactNumber(project.totalTokens)) · \(percent)%")
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 58)
    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .help(project.projectPath.isEmpty ? project.projectName : project.projectPath)
  }
}

private struct TokenSummaryStrip: View {
  var stats: TokenStats
  var palette: DashboardPalette
  var primaryTint: Color?
  var secondaryTint: Color?

  var body: some View {
    HStack(spacing: 8) {
      TokenSummaryPill(title: "今日".l10n, value: stats.todayTokens, tint: primaryTint ?? palette.fiveHour)
      TokenSummaryPill(title: "近 7 天".l10n, value: stats.last7DaysTokens, tint: secondaryTint ?? palette.weekly)
      TokenSummaryPill(title: "本月".l10n, value: stats.monthTokens, tint: DashboardColors.text)
    }
  }
}

private struct TokenSummaryPill: View {
  var title: String
  var value: Int
  var tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 11, weight: .heavy))
        .foregroundStyle(DashboardColors.subtleText)
      Text(BalanceFormatters.compactNumber(value))
        .font(.system(size: 19, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.72)
      Text(BalanceFormatters.exactNumber(value))
        .font(.system(size: 10.5, weight: .bold))
        .foregroundStyle(DashboardColors.subtleText)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.07), lineWidth: 1)
    )
  }
}

private enum TokenTrendPeriod: String, CaseIterable, Identifiable {
  case daily
  case monthly

  var id: String { rawValue }

  var title: String {
    switch self {
    case .daily: "按天".l10n
    case .monthly: "按月".l10n
    }
  }

  var subtitle: String {
    switch self {
    case .daily: "最近 14 天".l10n
    case .monthly: "最近 6 个月".l10n
    }
  }
}

private struct TokenTrendScopeInfo: Identifiable, Hashable {
  var id: String        // deviceID 或 "total"
  var title: String
  var isTotal: Bool
}

private struct TokenTrendSeries: Identifiable {
  var info: TokenTrendScopeInfo
  var buckets: [TokenBucket]
  var tint: Color

  var id: String { info.id }
  var title: String { info.title }

  var totalTokens: Int {
    buckets.reduce(0) { $0 + $1.totalTokens }
  }

  var averageTokens: Int {
    guard !buckets.isEmpty else { return 0 }
    return totalTokens / buckets.count
  }

  var peakBucket: TokenBucket? {
    buckets.max { $0.totalTokens < $1.totalTokens }
  }
}

private struct TokenTrendPanel: View {
  var stats: TokenStats
  var localDailyBuckets: [TokenBucket]
  var localMonthlyBuckets: [TokenBucket]
  var palette: DashboardPalette
  var primaryTint: Color?
  var secondaryTint: Color?
  /// Claude 暂无官方总量：不显示「总算力」线，避免用设备相加伪造总量
  var showsTotalScope = true
  @State private var selectedPeriod: TokenTrendPeriod = .daily
  /// 记「被取消勾选」的集合：设备列表是动态的（iCloud 快照陆续出现），新设备默认选中
  @State private var deselectedScopes: Set<String> = []

  /// 动态设备列表（本机排最前，由 SyncStore 保证）+ 可选「总算力」
  private var availableScopes: [TokenTrendScopeInfo] {
    var scopes = stats.deviceUsage.map {
      TokenTrendScopeInfo(id: $0.deviceID, title: $0.deviceName, isTotal: false)
    }
    if scopes.isEmpty {
      scopes = [TokenTrendScopeInfo(id: "local", title: "当前设备".l10n, isTotal: false)]
    }
    if showsTotalScope {
      scopes.append(TokenTrendScopeInfo(id: "total", title: "总算力".l10n, isTotal: true))
    }
    return scopes
  }

  private var selectedScopeInfos: [TokenTrendScopeInfo] {
    availableScopes.filter { !deselectedScopes.contains($0.id) }
  }

  private var series: [TokenTrendSeries] {
    selectedScopeInfos.map { trendSeries(for: $0) }
  }

  private var visibleSeries: [TokenTrendSeries] {
    if series.isEmpty, let first = availableScopes.first {
      return [trendSeries(for: first)]
    }
    return series
  }

  private var localBuckets: [TokenBucket] {
    switch selectedPeriod {
    case .daily: localDailyBuckets
    case .monthly: localMonthlyBuckets
    }
  }

  private var deviceUsageByID: [String: CodexDeviceTokenUsage] {
    Dictionary(uniqueKeysWithValues: stats.deviceUsage.map { ($0.deviceID, $0) })
  }

  private var templateBuckets: [TokenBucket] {
    for usage in stats.deviceUsage {
      let buckets = periodBuckets(of: usage)
      if !buckets.isEmpty { return buckets }
    }
    return localBuckets
  }

  private var subtitle: String {
    stats.deviceUsage.count <= 1
      ? L("%@ · 其他设备打开码表后自动加入对比", selectedPeriod.subtitle)
      : L("%@ · iCloud 可多选对比", selectedPeriod.subtitle)
  }

  private var maxTokens: Double {
    let maxValue = visibleSeries
      .flatMap { $0.buckets.map(\.totalTokens) }
      .max() ?? 0
    return max(Double(maxValue), 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Token 趋势".l10n)
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(DashboardColors.text)
          Text(subtitle)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
        }
        Spacer()
        HStack(spacing: 7) {
          ForEach(availableScopes) { scope in
            TokenTrendScopeToggleButton(
              title: scope.title,
              tint: color(for: scope),
              isSelected: !deselectedScopes.contains(scope.id),
              isUnavailable: scope.isTotal && stats.deviceUsage.isEmpty
            ) {
              toggleScope(scope)
            }
          }
        }

        Picker("", selection: $selectedPeriod) {
          ForEach(TokenTrendPeriod.allCases) { period in
            Text(period.title).tag(period)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 132)
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          ForEach(visibleSeries) { item in
            TokenTrendSeriesSummary(series: item)
          }
          Spacer(minLength: 0)
        }

        TokenMultiLineTrendChart(series: visibleSeries, maxTokens: maxTokens)
          .frame(height: 218)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
      .stroke(Color.white.opacity(0.07), lineWidth: 1)
    )
  }

  private func trendSeries(for scope: TokenTrendScopeInfo) -> TokenTrendSeries {
    let buckets: [TokenBucket]
    if scope.isTotal {
      buckets = totalBuckets()
    } else if let usage = deviceUsageByID[scope.id] {
      buckets = periodBuckets(of: usage)
    } else {
      buckets = localBuckets
    }
    return TokenTrendSeries(info: scope, buckets: buckets, tint: color(for: scope))
  }

  /// 设备线按顺序取色（最多循环使用），总量线固定用主题次色
  private func color(for scope: TokenTrendScopeInfo) -> Color {
    if scope.isTotal {
      return secondaryTint ?? palette.weekly
    }
    let deviceColors: [Color] = [
      primaryTint ?? palette.fiveHour,
      Color(red: 1.0, green: 0.47, blue: 0.30),
      Color(red: 0.70, green: 0.62, blue: 1.0),
      Color(red: 0.36, green: 0.86, blue: 0.74),
      Color(red: 0.95, green: 0.65, blue: 0.85)
    ]
    let index = stats.deviceUsage.firstIndex { $0.deviceID == scope.id } ?? 0
    return deviceColors[index % deviceColors.count]
  }

  private func toggleScope(_ scope: TokenTrendScopeInfo) {
    withAnimation(.easeInOut(duration: 0.16)) {
      if deselectedScopes.contains(scope.id) {
        deselectedScopes.remove(scope.id)
      } else {
        guard selectedScopeInfos.count > 1 else { return }
        deselectedScopes.insert(scope.id)
      }
    }
  }

  private func periodBuckets(of usage: CodexDeviceTokenUsage) -> [TokenBucket] {
    switch selectedPeriod {
    case .daily:
      return Array(usage.daily.suffix(14))
    case .monthly:
      return Array(usage.monthly.suffix(6))
    }
  }

  private func zeroBuckets() -> [TokenBucket] {
    templateBuckets.map {
      TokenBucket(key: $0.key, label: $0.label)
    }
  }

  private func totalBuckets() -> [TokenBucket] {
    let sources = stats.deviceUsage.map { periodBuckets(of: $0) }.filter { !$0.isEmpty }
    guard !sources.isEmpty else { return zeroBuckets() }

    let template = templateBuckets
    let byKey = sources.reduce(into: [String: TokenBucket]()) { result, buckets in
      for bucket in buckets {
        var current = result[bucket.key] ?? TokenBucket(key: bucket.key, label: bucket.label)
        current.totalTokens += bucket.totalTokens
        current.inputTokens += bucket.inputTokens
        current.outputTokens += bucket.outputTokens
        current.reasoningOutputTokens += bucket.reasoningOutputTokens
        current.calls += bucket.calls
        result[bucket.key] = current
      }
    }

    return template.map { bucket in
      byKey[bucket.key] ?? TokenBucket(key: bucket.key, label: bucket.label)
    }
  }
}

private struct TokenTrendScopeToggleButton: View {
  var title: String
  var tint: Color
  var isSelected: Bool
  var isUnavailable: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Circle()
          .fill(tint.opacity(isSelected ? 0.95 : 0.38))
          .frame(width: 7, height: 7)
        Text(title)
          .font(.system(size: 11.5, weight: .heavy, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        Image(systemName: isSelected ? "checkmark" : "plus")
          .font(.system(size: 8.5, weight: .black))
          .opacity(isSelected ? 0.95 : 0.62)
      }
      .foregroundStyle(isSelected ? tint : DashboardColors.subtleText)
      .padding(.horizontal, 9)
      .frame(height: 28)
      .background(
        Capsule(style: .continuous)
          .fill(tint.opacity(isSelected ? 0.18 : 0.07))
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(tint.opacity(isSelected ? 0.48 : 0.16), lineWidth: 1)
      )
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(.plain)
    .opacity(isUnavailable ? 0.56 : 1)
    .help(isUnavailable ? "等待其他设备的 iCloud 同步快照".l10n : L("切换 %@", title))
  }
}

private struct TokenTrendSeriesSummary: View {
  var series: TokenTrendSeries

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Circle()
          .fill(series.tint)
          .frame(width: 7, height: 7)
        Text(series.title)
          .font(.system(size: 10.5, weight: .heavy))
          .foregroundStyle(DashboardColors.subtleText)
      }

      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(BalanceFormatters.compactNumber(series.totalTokens))
          .font(.system(size: 18, weight: .heavy, design: .rounded))
          .foregroundStyle(series.tint)
        Text("tokens")
          .font(.system(size: 9.5, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
      }

      Text(L("均值 %@ · 峰值 %@ %@", BalanceFormatters.compactNumber(series.averageTokens), series.peakBucket?.label ?? "-", BalanceFormatters.compactNumber(series.peakBucket?.totalTokens ?? 0)))
        .font(.system(size: 9.8, weight: .bold, design: .rounded))
        .foregroundStyle(DashboardColors.subtleText.opacity(0.92))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .monospacedDigit()
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .frame(minWidth: 126, maxWidth: 168, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(series.tint.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(series.tint.opacity(0.24), lineWidth: 1)
    )
  }
}

private struct TokenTrendInlineNotice: View {
  var missingTitles: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 10, weight: .black))
      Text(L("等待 %@ 的 iCloud 快照；另一台 Mac 打开后会自动出现", missingTitles))
        .font(.system(size: 10.5, weight: .bold))
    }
    .foregroundStyle(DashboardColors.subtleText)
    .padding(.horizontal, 9)
    .frame(height: 24, alignment: .leading)
    .background(Color.white.opacity(0.045), in: Capsule(style: .continuous))
  }
}

private struct TokenTrendUnavailableView: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "lock.doc")
        .font(.system(size: 28, weight: .bold))
        .foregroundStyle(DashboardColors.subtleText)
      Text("暂未读到 Codex 个人资料总用量".l10n)
        .font(.system(size: 13.5, weight: .heavy))
        .foregroundStyle(DashboardColors.text)
      Text("请确认两台 Mac 都已打开算力码表；读到 iCloud 快照后会自动显示真实对比。".l10n)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(DashboardColors.subtleText)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct TokenMultiLineTrendChart: View {
  var series: [TokenTrendSeries]
  var maxTokens: Double
  @State private var hoveredIndex: Int?

  private var longestCount: Int {
    series.map { $0.buckets.count }.max() ?? 0
  }

  private var labelBuckets: [TokenBucket] {
    series.first?.buckets ?? []
  }

  private var firstLabel: String {
    labelBuckets.first?.label ?? "-"
  }

  private var middleLabel: String {
    guard !labelBuckets.isEmpty else { return "-" }
    return labelBuckets[labelBuckets.count / 2].label
  }

  private var lastLabel: String {
    labelBuckets.last?.label ?? "-"
  }

  var body: some View {
    VStack(spacing: 7) {
      GeometryReader { proxy in
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.12))

          ChartGrid()
            .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

          ForEach(series) { item in
            let values = values(for: item)

            TrendAreaShape(values: values, maxValue: maxTokens)
              .fill(
                LinearGradient(
                  colors: [item.tint.opacity(0.18), item.tint.opacity(0.018)],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
              .padding(.horizontal, 8)
              .padding(.vertical, 12)

            TrendLineShape(values: values, maxValue: maxTokens)
              .stroke(item.tint.opacity(0.92), style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
              .padding(.horizontal, 8)
              .padding(.vertical, 12)

            ForEach(Array(item.buckets.enumerated()), id: \.element.key) { index, bucket in
              Circle()
                .fill(pointFill(for: bucket, tint: item.tint, index: index))
                .frame(width: pointSize(for: bucket, index: index), height: pointSize(for: bucket, index: index))
                .position(point(at: index, values: values, in: insetSize(proxy.size), inset: 8))
                .opacity(pointOpacity(index: index))
                .help("\(item.title) \(bucket.label): \(BalanceFormatters.exactNumber(bucket.totalTokens)) tokens")
            }
          }

          if let hoveredIndex, let hoverPoint = hoverPoint(for: hoveredIndex, in: proxy.size) {

            Path { path in
              path.move(to: CGPoint(x: hoverPoint.x, y: 12))
              path.addLine(to: CGPoint(x: hoverPoint.x, y: proxy.size.height - 12))
            }
            .stroke(Color.white.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            ForEach(series) { item in
              let values = values(for: item)
              if item.buckets.indices.contains(hoveredIndex) {
                Circle()
                  .strokeBorder(Color.white.opacity(0.92), lineWidth: 2)
                  .background(Circle().fill(item.tint))
                  .frame(width: 13, height: 13)
                  .position(point(at: hoveredIndex, values: values, in: insetSize(proxy.size), inset: 8))
              }
            }

            TrendMultiHoverTooltip(series: series, index: hoveredIndex)
              .position(tooltipPosition(near: hoverPoint, in: proxy.size))
          }

          VStack(alignment: .leading) {
            Text(BalanceFormatters.compactNumber(Int(maxTokens)))
            Spacer()
            Text("0")
          }
          .font(.system(size: 10.5, weight: .bold, design: .rounded))
          .foregroundStyle(DashboardColors.subtleText)
          .monospacedDigit()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .padding(.leading, 10)
          .padding(.vertical, 9)

          Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                hoveredIndex = nearestIndex(to: location, in: proxy.size)
              case .ended:
                hoveredIndex = nil
              }
            }
        }
      }

      HStack {
        Text(firstLabel)
        Spacer()
        Text(middleLabel)
        Spacer()
        Text(lastLabel)
      }
      .font(.system(size: 10.5, weight: .bold, design: .rounded))
      .foregroundStyle(DashboardColors.subtleText)
      .monospacedDigit()
      .padding(.horizontal, 4)
    }
  }

  private func insetSize(_ size: CGSize) -> CGSize {
    CGSize(width: max(size.width - 16, 1), height: max(size.height - 24, 1))
  }

  private func values(for item: TokenTrendSeries) -> [Double] {
    item.buckets.map { Double($0.totalTokens) }
  }

  private func point(at index: Int, values: [Double], in size: CGSize, inset: CGFloat) -> CGPoint {
    guard values.indices.contains(index) else { return CGPoint(x: inset, y: inset) }
    let xRatio = values.count <= 1 ? 0.5 : CGFloat(index) / CGFloat(values.count - 1)
    let yRatio = CGFloat(min(1, max(0, values[index] / maxTokens)))
    return CGPoint(
      x: inset + size.width * xRatio,
      y: 12 + size.height * (1 - yRatio)
    )
  }

  private func nearestIndex(to location: CGPoint, in size: CGSize) -> Int? {
    guard longestCount > 0 else { return nil }
    let chartSize = insetSize(size)
    let clampedX = min(max(location.x - 8, 0), chartSize.width)
    let ratio = chartSize.width <= 0 ? 0 : clampedX / chartSize.width
    let index = Int((ratio * CGFloat(longestCount - 1)).rounded())
    return min(max(index, 0), longestCount - 1)
  }

  private func pointFill(for bucket: TokenBucket, tint: Color, index: Int) -> Color {
    if hoveredIndex == index {
      return tint
    }
    return bucket.totalTokens == 0 ? tint.opacity(0.35) : tint
  }

  private func pointSize(for bucket: TokenBucket, index: Int) -> CGFloat {
    if hoveredIndex == index {
      return 10
    }
    return bucket.totalTokens == 0 ? 5 : 7
  }

  private func pointOpacity(index: Int) -> Double {
    guard let hoveredIndex else { return 0.78 }
    return hoveredIndex == index ? 1 : 0.24
  }

  private func hoverPoint(for index: Int, in size: CGSize) -> CGPoint? {
    guard let first = series.first(where: { $0.buckets.indices.contains(index) }) else { return nil }
    return point(at: index, values: values(for: first), in: insetSize(size), inset: 8)
  }

  private func tooltipPosition(near point: CGPoint, in size: CGSize) -> CGPoint {
    let tooltipSize = CGSize(width: 208, height: 92)
    let x = min(max(point.x, tooltipSize.width / 2 + 8), size.width - tooltipSize.width / 2 - 8)
    let preferredY = point.y - 66
    let fallbackY = point.y + 66
    let rawY = preferredY < tooltipSize.height / 2 + 8 ? fallbackY : preferredY
    let y = min(max(rawY, tooltipSize.height / 2 + 8), size.height - tooltipSize.height / 2 - 8)
    return CGPoint(x: x, y: y)
  }
}

private struct TrendMultiHoverTooltip: View {
  var series: [TokenTrendSeries]
  var index: Int

  private var rows: [(title: String, tint: Color, bucket: TokenBucket)] {
    series.compactMap { item in
      guard item.buckets.indices.contains(index) else { return nil }
      return (item.title, item.tint, item.buckets[index])
    }
  }

  private var label: String {
    rows.first?.bucket.label ?? "-"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: 11, weight: .heavy))
        .foregroundStyle(DashboardColors.subtleText)

      ForEach(rows, id: \.title) { row in
        HStack(spacing: 7) {
          Circle()
            .fill(row.tint)
            .frame(width: 7, height: 7)
          Text(row.title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
          Spacer()
          Text(BalanceFormatters.compactNumber(row.bucket.totalTokens))
            .font(.system(size: 12.5, weight: .heavy, design: .rounded))
            .foregroundStyle(row.tint)
        }
      }
    }
    .monospacedDigit()
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: 208, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.black.opacity(0.58))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    )
    .shadow(color: Color.black.opacity(0.24), radius: 8, x: 0, y: 5)
  }
}

private struct ChartGrid: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    for index in 1...3 {
      let y = rect.minY + rect.height * CGFloat(index) / 4
      path.move(to: CGPoint(x: rect.minX + 8, y: y))
      path.addLine(to: CGPoint(x: rect.maxX - 8, y: y))
    }
    return path
  }
}

private struct TrendLineShape: Shape {
  var values: [Double]
  var maxValue: Double

  func path(in rect: CGRect) -> Path {
    var path = Path()
    for point in points(in: rect) {
      if path.isEmpty {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    return path
  }

  func points(in rect: CGRect) -> [CGPoint] {
    guard !values.isEmpty else { return [] }
    return values.enumerated().map { index, value in
      let xRatio = values.count <= 1 ? 0.5 : CGFloat(index) / CGFloat(values.count - 1)
      let yRatio = CGFloat(min(1, max(0, value / max(maxValue, 1))))
      return CGPoint(
        x: rect.minX + rect.width * xRatio,
        y: rect.maxY - rect.height * yRatio
      )
    }
  }
}

private struct TrendAreaShape: Shape {
  var values: [Double]
  var maxValue: Double

  func path(in rect: CGRect) -> Path {
    let line = TrendLineShape(values: values, maxValue: maxValue).points(in: rect)
    guard let first = line.first, let last = line.last else { return Path() }
    var path = Path()
    path.move(to: CGPoint(x: first.x, y: rect.maxY))
    path.addLine(to: first)
    for point in line.dropFirst() {
      path.addLine(to: point)
    }
    path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

private struct ToolButtonStyle: ButtonStyle {
  var isSelected = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(DashboardColors.text)
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(configuration.isPressed ? 0.14 : (isSelected ? 0.13 : 0.07)))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.white.opacity(isSelected ? 0.20 : 0.10), lineWidth: 1)
          )
      )
  }
}

private struct PaletteButton: View {
  var palette: DashboardPalette
  var isSelected: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        ZStack {
          Circle()
            .fill(palette.weekly)
            .frame(width: 22, height: 22)
            .offset(x: 5)
          Circle()
            .fill(palette.fiveHour)
            .frame(width: 22, height: 22)
            .offset(x: -5)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(palette.title)
            .font(.system(size: 11.5, weight: .heavy))
            .foregroundStyle(DashboardColors.text)
            .lineLimit(1)
          Text(palette.subtitle)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .frame(height: 40)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.045))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(isSelected ? palette.weekly.opacity(0.72) : Color.white.opacity(0.08), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help(palette.title)
  }
}


// MARK: - 可视化选择组件

/// 悬浮样式预览卡：直接画出该样式的微缩样子
private struct CompactStyleCard: View {
  var style: CompactStyle
  var palette: DashboardPalette
  var isSelected: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 7) {
        ZStack {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.black.opacity(0.32))
          preview
        }
        .frame(height: 56)

        VStack(spacing: 1) {
          Text(style.title)
            .font(.system(size: 11.5, weight: .heavy))
            .foregroundStyle(DashboardColors.text)
          Text(style.subtitle)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(DashboardColors.subtleText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(isSelected ? Color.white.opacity(0.11) : Color.white.opacity(0.04))
          .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .stroke(isSelected ? palette.weekly.opacity(0.75) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help(style.subtitle)
  }

  @ViewBuilder
  private var preview: some View {
    switch style {
    case .rings:
      HStack(spacing: 10) {
        miniRings(outer: palette.weekly, inner: palette.fiveHour)
        miniRings(outer: palette.claudeWeekly, inner: palette.claudeFiveHour)
      }
    case .bars:
      VStack(alignment: .leading, spacing: 6) {
        miniBar(color: palette.fiveHour, ratio: 0.86, label: "C")
        miniBar(color: palette.claudeFiveHour, ratio: 0.63, label: "A")
      }
      .padding(.horizontal, 12)
    case .barsQuad:
      VStack(alignment: .leading, spacing: 3) {
        miniBar(color: palette.fiveHour, ratio: 0.86, label: "C")
        miniBar(color: palette.weekly, ratio: 0.98, label: "")
        miniBar(color: palette.claudeFiveHour, ratio: 0.63, label: "A")
        miniBar(color: palette.claudeWeekly, ratio: 0.44, label: "")
      }
      .padding(.horizontal, 12)
    case .badgeQuad:
      HStack(spacing: 4) {
        Circle().fill(palette.fiveHour).frame(width: 5, height: 5)
        Text("87")
          .font(.system(size: 9.5, weight: .heavy, design: .rounded))
          .foregroundStyle(palette.fiveHour)
        Text("/")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
        Text("100")
          .font(.system(size: 9.5, weight: .heavy, design: .rounded))
          .foregroundStyle(palette.weekly)
        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 8)
        Circle().fill(palette.claudeFiveHour).frame(width: 5, height: 5)
        Text("84")
          .font(.system(size: 9.5, weight: .heavy, design: .rounded))
          .foregroundStyle(palette.claudeFiveHour)
        Text("/")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
        Text("62")
          .font(.system(size: 9.5, weight: .heavy, design: .rounded))
          .foregroundStyle(palette.claudeWeekly)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        Capsule(style: .continuous)
          .fill(Color.black.opacity(0.5))
          .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
      )
    case .badge:
      HStack(spacing: 5) {
        Circle().fill(palette.fiveHour).frame(width: 5, height: 5)
        Text("87")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .foregroundStyle(DashboardColors.text)
        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 8)
        Circle().fill(palette.claudeFiveHour).frame(width: 5, height: 5)
        Text("62")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .foregroundStyle(DashboardColors.text)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule(style: .continuous)
          .fill(Color.black.opacity(0.5))
          .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
      )
    }
  }

  private func miniRings(outer: Color, inner: Color) -> some View {
    ZStack {
      Circle().stroke(outer.opacity(0.25), lineWidth: 3.5).frame(width: 32, height: 32)
      Circle().trim(from: 0, to: 0.8).stroke(outer, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        .rotationEffect(.degrees(-90)).frame(width: 32, height: 32)
      Circle().stroke(inner.opacity(0.25), lineWidth: 3).frame(width: 20, height: 20)
      Circle().trim(from: 0, to: 0.62).stroke(inner, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90)).frame(width: 20, height: 20)
    }
  }

  private func miniBar(color: Color, ratio: CGFloat, label: String) -> some View {
    HStack(spacing: 5) {
      Text(label)
        .font(.system(size: 8, weight: .black))
        .foregroundStyle(.black)
        .frame(width: 11, height: 11)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color))
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(color.opacity(0.22))
          Capsule().fill(color).frame(width: proxy.size.width * ratio)
        }
      }
      .frame(height: 6)
    }
  }
}

/// 收起尺寸卡：按真实比例画出两种浮窗大小
private struct SizeModeCard: View {
  var mode: CompactSizeMode
  var palette: DashboardPalette
  var isSelected: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .stroke(isSelected ? palette.weekly : DashboardColors.subtleText, lineWidth: 1.5)
          .frame(
            width: mode == .standard ? 30 : 21,
            height: mode == .standard ? 19 : 13
          )
        Text(mode.title)
          .font(.system(size: 11.5, weight: .heavy))
          .foregroundStyle(isSelected ? DashboardColors.text : DashboardColors.subtleText)
      }
      .padding(.horizontal, 11)
      .frame(height: 34)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color.white.opacity(0.11) : Color.white.opacity(0.04))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(isSelected ? palette.weekly.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }
}

/// 顶部工具切换按钮：带工具色点
private struct ToolTabButton: View {
  var tab: DashboardToolTab
  var palette: DashboardPalette
  var isSelected: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        switch tab {
        case .codex:
          Circle().fill(palette.fiveHour).frame(width: 7, height: 7)
        case .claude:
          Circle().fill(palette.claudeFiveHour).frame(width: 7, height: 7)
        case .all:
          HStack(spacing: -2) {
            Circle().fill(palette.fiveHour).frame(width: 7, height: 7)
            Circle().fill(palette.claudeFiveHour).frame(width: 7, height: 7)
          }
        }
        Text(tab.title)
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(isSelected ? DashboardColors.text : DashboardColors.subtleText)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 30)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.035))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.06), lineWidth: 1)
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
