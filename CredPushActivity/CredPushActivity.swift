import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CredWidgetBundle: WidgetBundle {
    var body: some Widget {
        CredProgressWidget()
    }
}

/// 灵动岛进度卡片（iOS 16.1+）
///   紧凑（中国移动在前台）：左「等待」右「4/6」
///   最小：钥匙图标
///   展开 / 锁屏：步骤 + 说明 + 进度条 + 已用计时（系统自动走秒）
struct CredProgressWidget: Widget {
    private let steps = ["关闭旧进程", "切换容器", "打开中国移动", "等待登录", "读取凭证", "关闭中国移动"]
    /// 紧凑态用的 2 字标签（灵动岛空间很小）
    private let shortNames = ["准备", "切换", "打开", "等待", "读取", "关闭"]
    private let accent = Color(red: 0.22, green: 0.78, blue: 0.96)

    private func idx(_ s: CredActivityAttributes.ContentState) -> Int {
        max(0, min(s.step, steps.count - 1))
    }
    private func denom(_ s: CredActivityAttributes.ContentState) -> String {
        "\(min(s.step + 1, steps.count))/\(steps.count)"
    }

    private func timerText(_ started: Date) -> Text {
        // 系统托管的计时文本，会自己每秒走，不需要我们更新
        Text(started, style: .timer)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CredActivityAttributes.self) { context in
            // 锁屏卡片
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundColor(accent)
                    Text(context.attributes.name).font(.subheadline).bold()
                    Spacer()
                    timerText(context.state.stepStartedAt)
                        .font(.caption).monospacedDigit().foregroundColor(accent)
                    Text(denom(context.state)).font(.footnote).bold().foregroundColor(accent)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(context.state.short).font(.title3).bold()
                    Text("第 \(min(context.state.step + 1, steps.count)) 步 / \(steps.count)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text(context.state.detail.isEmpty ? " " : context.state.detail)
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                ProgressView(value: Double(min(context.state.step + 1, steps.count)),
                             total: Double(steps.count))
                    .tint(accent)
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 0.07, green: 0.10, blue: 0.14))
            .activitySystemActionForegroundColor(accent)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "key.fill").foregroundColor(accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(context.state.short).font(.subheadline).bold()
                            Text(denom(context.state)).font(.caption).bold().foregroundColor(accent)
                        }
                        Text(context.state.detail)
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 已用时间，系统每秒自动更新
                    timerText(context.state.stepStartedAt)
                        .font(.caption).monospacedDigit().foregroundColor(accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text(context.attributes.name)
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text("第 \(min(context.state.step + 1, steps.count)) / \(steps.count) 步")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            } compactLeading: {
                // 当前步骤（2 字）
                Text(shortNames[idx(context.state)])
                    .font(.caption2).bold().foregroundColor(accent)
            } compactTrailing: {
                // 进度 n/6
                Text(denom(context.state))
                    .font(.caption2).bold().monospacedDigit().foregroundColor(accent)
            } minimal: {
                Image(systemName: "key.fill").foregroundColor(accent)
            }
            .keylineTint(accent)
        }
    }
}
