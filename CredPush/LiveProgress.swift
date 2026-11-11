import ActivityKit
import UIKit

/// 灵动岛 / 锁屏「实时活动」的控制端。
///
/// 中国移动在前台时，这个活动会以胶囊形式**常驻在灵动岛**上显示当前步骤；
/// App 被挂起后卡片保留最后状态，直到我们调用 end。
///
/// ⚠️ App 最低支持 iOS 15，而 ActivityKit 是 16.1+、ActivityContent 是 16.2+，
///    所以真正的实现包在 `@available(iOS 16.1, *)` 的 Box 里，外层只做转发。
final class LiveProgress {
    static let shared = LiveProgress()

    static var supported: Bool {
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    var isActive: Bool {
        if #available(iOS 16.1, *) { return LiveBox.shared.activity != nil }
        return false
    }

    func start(name: String) {
        if #available(iOS 16.1, *) { LiveBox.shared.start(name: name) }
    }

    func update(step: Int, short: String, detail: String) {
        if #available(iOS 16.1, *) {
            LiveBox.shared.update(step: step, short: short, detail: detail)
        }
    }

    func end(_ detail: String) {
        if #available(iOS 16.1, *) { LiveBox.shared.end(detail) }
    }

    func endAll() {
        if #available(iOS 16.1, *) { LiveBox.shared.endAll() }
    }
}

// MARK: - 实际实现（iOS 16.1+）

@available(iOS 16.1, *)
final class LiveBox {
    static let shared = LiveBox()
    var activity: Activity<CredActivityAttributes>?
    /// 当前步骤与它的开始时间：**只有步骤变了才重置计时**
    /// （轮询每 1.5 秒会重复发「等待登录」，不能每次都归零）
    private var currentStep = -1
    private var stepStart = Date()

    func start(name: String) {
        currentStep = 0
        stepStart = Date()
        endAll()
        let attrs = CredActivityAttributes(name: name)
        let st = CredActivityAttributes.ContentState(step: 0, short: "准备中",
                                                     detail: "即将切换容器", stepStartedAt: Date())
        do {
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: st, staleDate: Date().addingTimeInterval(600))
                activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            } else {
                activity = try Activity.request(attributes: attrs, contentState: st, pushType: nil)
            }
            AppLog.w("live | 已创建活动 \(activity?.id.prefix(8) ?? "-")")
        } catch {
            AppLog.w("live | 创建失败：\(error.localizedDescription)")
            activity = nil
        }
    }

    func update(step: Int, short: String, detail: String) {
        guard let a = activity else { return }
        // ★ 只有换步才重置计时
        if step != currentStep {
            currentStep = step
            stepStart = Date()
        }
        let st = CredActivityAttributes.ContentState(step: step, short: short,
                                                     detail: detail, stepStartedAt: stepStart)
        Task {
            if #available(iOS 16.2, *) {
                await a.update(ActivityContent(state: st, staleDate: nil))
            } else {
                await a.update(using: st)
            }
        }
    }

    func end(_ detail: String) {
        guard let a = activity else { return }
        activity = nil
        let st = CredActivityAttributes.ContentState(step: 6, short: detail,
                                                     detail: "", stepStartedAt: Date())
        Task {
            if #available(iOS 16.2, *) {
                await a.end(ActivityContent(state: st, staleDate: nil),
                            dismissalPolicy: .after(Date().addingTimeInterval(8)))
            } else {
                await a.end(using: st, dismissalPolicy: .after(Date().addingTimeInterval(8)))
            }
        }
    }

    func endAll() {
        activity = nil
        Task {
            for a in Activity<CredActivityAttributes>.activities {
                if #available(iOS 16.2, *) {
                    await a.end(nil, dismissalPolicy: .immediate)
                } else {
                    await a.end(dismissalPolicy: .immediate)
                }
            }
        }
    }
}
