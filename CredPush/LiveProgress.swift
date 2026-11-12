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
    /// 最新状态：活动创建是异步的，创建期间收到的 update 先存这里，建好后补上
    private var latest: CredActivityAttributes.ContentState?
    /// 浮窗（CredHUD tweak）显示的标题
    private var hudTitle = ""

    func start(name: String) {
        currentStep = 0
        stepStart = Date()
        hudTitle = name
        // 越狱浮窗（CredHUD tweak）：只写文件，没有 tweak 时无害
        HUDWriter.update(title: name, step: 0, total: 6, short: "准备中",
                         detail: "即将切换容器", startedAt: stepStart)
        let st = CredActivityAttributes.ContentState(step: 0, short: "准备中",
                                                     detail: "即将切换容器", stepStartedAt: Date())
        latest = st
        activity = nil
        let attrs = CredActivityAttributes(name: name,
                                           build: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "")
        AppLog.w("live | 启动：现有活动 \(Activity<CredActivityAttributes>.activities.count) 个；"
                 + "areActivitiesEnabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
        Task {
            // ★ 先把旧活动**等它们真的结束**，再创建新的。
            //   以前 `endAll()` 是异步 Task：它可能在新活动建好之后才跑，把**新活动一起 end 掉** ——
            //   表现就是「灵动岛全程什么都没有」（2026-11-11 实测，195 那次）。
            for a in Activity<CredActivityAttributes>.activities {
                if #available(iOS 16.2, *) {
                    await a.end(nil, dismissalPolicy: .immediate)
                } else {
                    await a.end(dismissalPolicy: .immediate)
                }
            }
            do {
                let act: Activity<CredActivityAttributes>
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: st, staleDate: Date().addingTimeInterval(600))
                    act = try Activity.request(attributes: attrs, content: content, pushType: nil)
                } else {
                    act = try Activity.request(attributes: attrs, contentState: st, pushType: nil)
                }
                self.activity = act
                AppLog.w("live | 已创建活动 \(act.id.prefix(8))")
                if let cur = self.latest { await self.apply(cur, to: act) }
            } catch {
                AppLog.w("live | 创建失败：\(error.localizedDescription)")
                self.activity = nil
            }
        }
    }

    func update(step: Int, short: String, detail: String) {
        // ★ 只有换步才重置计时
        if step != currentStep {
            currentStep = step
            stepStart = Date()
        }
        let st = CredActivityAttributes.ContentState(step: step, short: short,
                                                     detail: detail, stepStartedAt: stepStart)
        latest = st          // 活动还在创建中时先存着，建好后立刻补上
        HUDWriter.update(title: hudTitle, step: step, total: 6,
                         short: short, detail: detail, startedAt: stepStart)
        guard let a = activity else { return }
        Task { await apply(st, to: a) }
    }

    private func apply(_ st: CredActivityAttributes.ContentState,
                       to a: Activity<CredActivityAttributes>) async {
        if #available(iOS 16.2, *) {
            // ★ 3 分钟没有新状态就标记为过期：App 被系统挂起、流程其实已经停了时，
            //   灵动岛会自动变暗，而不是一直显示「进行中」。
            await a.update(ActivityContent(state: st, staleDate: Date().addingTimeInterval(180)))
        } else {
            await a.update(using: st)
        }
    }

    func end(_ detail: String) {
        HUDWriter.hide()
        guard let a = activity else { return }
        activity = nil
        latest = nil
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
        latest = nil
        HUDWriter.hide()
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
