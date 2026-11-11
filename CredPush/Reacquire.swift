import UIKit
import UserNotifications

/// 「重新获取 / 新增账号」的执行器：
///   切容器 → 拉起中国移动 → 后台轮询新会话 → 关掉它 → 交给调用方推送
///
/// iOS 限制：拉起中国移动后我们就进后台了，**界面看不到**。
/// 所以这里每到一个阶段就发一条**本地通知横幅**（会显示在中国移动的屏幕顶部）。
final class Reacquire {
    static let shared = Reacquire()

    enum Stage: Int, CaseIterable {
        case prepare, switchContainer, launch, waiting, reading, closing, done
        var text: String {
            switch self {
            case .prepare: return "关闭旧的进程"
            case .switchContainer: return "切换 Crane 容器"
            case .launch: return "打开中国移动"
            case .waiting: return "等待中国移动登录"
            case .reading: return "读取凭证"
            case .closing: return "关闭中国移动"
            case .done: return "完成"
            }
        }
        /// 发送给用户看的通知文案（在中国移动顶上弹出的）
        var banner: (String, String)? {
            switch self {
            case .launch: return ("① 正在打开中国移动", "请稍等，App 会自动完成后续步骤")
            case .waiting: return ("② 中国移动已打开", "正在等待登录完成…拿到凭证后会自动关闭并返回")
            case .reading: return ("③ 正在读取凭证", "")
            case .closing: return ("④ 已获取凭证", "正在关闭中国移动，随后自动返回")
            default: return nil
            }
        }
    }

    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var running = false
    private var stageHandler: ((Stage, String) -> Void)?

    /// 超时后没抓到，记下来；回前台再续。
    /// ★ 只记「名字 + 已知会话 + 是否新账号」——**不记容器路径**：
    ///   新建容器在登录完成前 UserPhone 是空的，路径根本认不出来（2026-11-11 视频实测）。
    private(set) var pending: (name: String, known: Set<String>, allowNew: Bool)?
    var hasPending: Bool { pending != nil }

    var isRunning: Bool { running }

    // MARK: - 启动

    /// - Parameters:
    ///   - name: 容器名（手机号或自定义名）
    ///   - container: 容器路径（新增账号时传 nil，创建后再找）
    ///   - known: 开始前该容器已有的会话 UID（用来判断"新的"）
    ///   - createIfMissing: 容器不存在时先创建
    func start(name: String,
               container: String?,
               known: Set<String>,
               createIfMissing: Bool = false,
               stage: @escaping (Stage, String) -> Void,
               done: @escaping (Bool, String, FoundSession?) -> Void) {
        guard !running else { done(false, "已经有一个在进行中", nil); return }
        guard Crane.available() else {
            done(false, "这台设备没有 Crane 命令行", nil)
            return
        }
        running = true
        stageHandler = stage
        LiveProgress.shared.start(name: name)
        // 每个阶段同时：更新界面卡片 + 更新灵动岛
        let emit: (Stage, String) -> Void = { st, detail in
            stage(st, detail)
            LiveProgress.shared.update(step: st.rawValue, short: st.text, detail: detail)
        }

        emit(.prepare, "正在准备…")
        Crane.killChinaMobile()

        // ★ 新增账号时容器可能已经存在（重名 / 上次没删）：先把已有会话记成 known，
        //   否则登录后会抓到旧会话、当成"新的"推上去。
        var baseline = known
        if createIfMissing, known.isEmpty, let p = containerPath(name: name) {
            baseline = Set(Scanner.readSessions(container: p, phone: name).map { $0.uid })
        }
        let allowNew = createIfMissing
        // 新账号要人工输短信验证码，30 秒根本不够；给 3 分钟。
        // （App 在后台只能活 ~30 秒，超时后靠回前台 resumeIfNeeded() 继续补抓）
        let wait: TimeInterval = createIfMissing ? 180 : 120

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if createIfMissing {
                emit(.switchContainer, "创建容器 \(name)…")
                _ = Crane.run(Crane.cranectl, ["--create", Crane.appBundle, name])
            }
            emit(.switchContainer, "切换到容器 \(name)…")
            guard Crane.switchTo(name: name) else {
                self.running = false
                LiveProgress.shared.end("切换容器失败")
                done(false, "切换容器失败", nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                emit(.launch, "打开中国移动…")
                self.banner(.launch)
                guard Crane.launchChinaMobile() else {
                    self.running = false
                    LiveProgress.shared.end("拉起失败")
                    done(false, "拉起中国移动失败", nil)
                    return
                }
                self.bgTask = UIApplication.shared.beginBackgroundTask(withName: "reacquire") { [weak self] in
                    self?.timeout(name: name, known: baseline, allowNew: allowNew, done: done)
                }
                self.poll(name: name, container: container, known: baseline, allowNew: allowNew,
                          deadline: Date().addingTimeInterval(wait),
                          stage: emit, done: done)
            }
        }
    }

    // MARK: - 轮询

    private func poll(name: String, container: String?, known: Set<String>,
                      allowNew: Bool,
                      deadline: Date,
                      stage: @escaping (Stage, String) -> Void,
                      done: @escaping (Bool, String, FoundSession?) -> Void) {
        if Date() > deadline {
            timeout(name: name, known: known, allowNew: allowNew, done: done)
            return
        }
        // 容器路径可能因为新建而变化，每轮重新找（新容器靠 Crane 名字 → id 认）
        let path = container ?? containerPath(name: name)
        guard let p = path else {
            stage(.waiting, "等待容器出现…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.poll(name: name, container: container, known: known, allowNew: allowNew,
                           deadline: deadline, stage: stage, done: done)
            }
            return
        }
        let got = Scanner.readSessions(container: p, phone: name)
        if let fresh = got.first(where: { !known.contains($0.uid) }) {
            stage(.reading, "拿到新凭证")
            stage(.closing, "关闭中国移动…")
            banner(.closing)
            Crane.killChinaMobile()
            endBackground()
            running = false
            pending = nil
            stage(.done, "完成")
            LiveProgress.shared.end("已获取凭证")
            done(true, "已拿到新凭证", fresh)
            return
        }
        stage(.waiting, "等待登录完成…")
        banner(.waiting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.poll(name: name, container: container, known: known, allowNew: allowNew,
                       deadline: deadline, stage: stage, done: done)
        }
    }

    private func timeout(name: String,
                         known: Set<String>,
                         allowNew: Bool,
                         done: @escaping (Bool, String, FoundSession?) -> Void) {
        endBackground()
        running = false
        // ★ 不管容器此刻认不认得出，都要登记 —— 回前台后按「Crane 名字」再找一次。
        pending = (name, known, allowNew)
        AppLog.w("reacquire | 等待超时，等回前台续上（name=\(name)）")
        bannerDone(ok: false)
        LiveProgress.shared.end("等待中 · 切回 App 继续")
        done(false, "还没等到新凭证 —— 切回 App 后会自动再检查", nil)
    }

    /// 回前台时调用：上次没等到就再扫一次。
    /// 返回 (新会话, 是否允许新账号)；没等到返回 nil（pending 保留，调用方可重试）。
    func resumeIfNeeded() -> (session: FoundSession, allowNew: Bool)? {
        guard let p = pending else { return nil }
        guard let path = containerPath(name: p.name) else { return nil }
        let got = Scanner.readSessions(container: path, phone: p.name)
        if let fresh = got.first(where: { !p.known.contains($0.uid) }) {
            pending = nil
            Crane.killChinaMobile()
            LiveProgress.shared.end("已获取凭证")
            return (fresh, p.allowNew)
        }
        return nil
    }

    func clearPending() { pending = nil }

    // MARK: - 辅助

    /// 按容器名找路径。
    /// ① 已登录的容器：按 UserPhone 认（最快）；
    /// ② 新建容器：UserPhone 要等登录完成才写进 plist，所以按 Crane 的「名字 → id → 目录」认。
    func containerPath(name: String) -> String? {
        for c in Scanner.allContainers() where c.phone == name {
            return c.path
        }
        if let c = Crane.list().first(where: { $0.name == name }),
           let p = Scanner.path(forCraneID: c.id) {
            return p
        }
        return nil
    }

    /// 进度优先显示在灵动岛；**只有在灵动岛没起来时**才退回通知横幅
    private func banner(_ s: Stage) {
        guard !LiveProgress.shared.isActive else { return }
        guard let (t, b) = s.banner else { return }
        Notifier.alert(t, b)
    }

    private func bannerDone(ok: Bool) {
        guard !LiveProgress.shared.isActive else { return }
        Notifier.alert(ok ? "✓ 凭证已获取" : "⏸ 等待中",
                       ok ? "已关闭中国移动，返回 App 即可看到结果"
                          : "切回 App 后会自动再检查一次")
    }

    private func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}
