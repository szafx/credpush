import Foundation

/// 流程进度 —— **只驱动越狱浮窗（CredHUD tweak）**。
///
/// 2026-11-12 用户要求：**去掉灵动岛 / 锁屏实时活动，也去掉通知横幅**。
/// 现在进度统一写到 NSUserDefaults 共享域 `com.szafx.credhud`，由 SpringBoard 里的
/// CredHUD.dylib 显示成一个可拖动的小卡片（见 `tweak/Tweak.xm`）。
///
/// 保留原来的 `start / update / end` 接口，Reacquire 那边不用改调用方式。
final class LiveProgress {
    static let shared = LiveProgress()

    private var currentStep = -1
    private var stepStart = Date()
    private var title = ""
    private var visible = false

    var isActive: Bool { visible }

    func start(name: String) {
        currentStep = 0
        stepStart = Date()
        title = name
        visible = true
        HUDWriter.update(title: name, step: 0, total: 6, short: "准备中",
                         detail: "即将切换容器", startedAt: stepStart)
    }

    func update(step: Int, short: String, detail: String) {
        // ★ 只有换步才重置计时
        if step != currentStep {
            currentStep = step
            stepStart = Date()
        }
        HUDWriter.update(title: title, step: step, total: 6,
                         short: short, detail: detail, startedAt: stepStart)
    }

    /// 不改步骤，只更新说明（比如超时了但浮窗要留着等用户登录）
    func note(_ detail: String) {
        HUDWriter.update(title: title, step: max(currentStep, 0), total: 6,
                         short: "等待中", detail: detail, startedAt: stepStart)
    }

    func end(_ detail: String) {
        visible = false
        HUDWriter.hide()
    }

    func endAll() {
        visible = false
        HUDWriter.hide()
    }
}
