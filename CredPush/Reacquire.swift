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
    /// 用户点了「取消」：所有轮询/超时回调看到它就停
    private var cancelled = false
    /// 已被服务端拒绝的会话 UID（未登录的冷启动会话）—— 不再重复尝试
    private var rejected = Set<String>()
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
        cancelled = false
        rejected.removeAll()
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
            if createIfMissing && !Crane.list().contains(where: { $0.name == name }) {
                // ★ 已存在同名容器就不要再 create —— 反复 create 会产生多个同名容器，
                //   流程按名字只取第一个时可能拿到空的那个（2026-11-12 实测）
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
        if cancelled { return }
        if Date() > deadline {
            timeout(name: name, known: known, allowNew: allowNew, done: done)
            return
        }
        // 同名容器可能不止一个（重复创建过）：逐个看，优先「登录完成 + 有新会话」的那个
        let paths: [String] = container.map { [$0] } ?? containerPaths(name: name)
        guard !paths.isEmpty else {
            stage(.waiting, "等待容器出现…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.poll(name: name, container: container, known: known, allowNew: allowNew,
                           deadline: deadline, stage: stage, done: done)
            }
            return
        }
        var fresh: FoundSession?
        var candidates: [FoundSession] = []
        for p in paths where Scanner.phoneFromPrefs(p) == name {
            let got = Scanner.readSessions(container: p, phone: name)
            // ★ 新会话可能不止一条（冷启动 + 登录各一条）：挑**最新**的，别挑第一条
            let news = got.filter { !known.contains($0.uid) && !rejected.contains($0.uid) }
            if let f = news.max(by: { $0.recency < $1.recency }) {
                fresh = f
                candidates = got
                break
            }
        }
        if let fresh = fresh {
            // ★ 只推**最新的那一条**（上面已经按 recency 挑出来了）。
            //   2026-11-12 实测：整批推时前面几条失效的会先把服务端打到「登录状态已过期」，
            //   同一批里真正有效的那条也被连坐；单独推最新那条是 ok 的。
            stage(.reading, "验证会话…")
            pushAndFinish(fresh, candidates: candidates, name: name, known: known,
                          allowNew: allowNew, deadline: deadline, stage: stage, done: done)
            return
        }
        stage(.waiting, "等待登录完成…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.poll(name: name, container: container, known: known, allowNew: allowNew,
                       deadline: deadline, stage: stage, done: done)
        }
    }

    /// 把候选会话推给服务端验证；成功才收尾（杀 App + 回前台）
    /// candidates 是整个容器的会话列表，fresh 排最前；服务端自己挑能用的那条。
    private func pushAndFinish(_ fresh: FoundSession, candidates: [FoundSession], name: String,
                               known: Set<String>, allowNew: Bool, deadline: Date,
                               stage: @escaping (Stage, String) -> Void,
                               done: @escaping (Bool, String, FoundSession?) -> Void) {
        // ★ 只推最新这一条（整批会把有效的那条连坐）
        let list: [FoundSession] = [fresh]
        let body: [String: Any] = [
            "sessions": list.map { ["raw": $0.raw, "phone": $0.phone] },
            "allowNew": allowNew,
            "device": UIDevice.current.name,
            "ios": UIDevice.current.systemVersion,
            "app": "credpush/1.0",
        ]
        Net.callPanel("/api/cred/push", json: body,
                      headers: ["X-Cred-Token": Cfg.pushToken], timeout: 60) { [weak self] r in
            guard let self = self, !self.cancelled else { return }
            var ok = false
            var why = ""
            switch r {
            case .success(let obj):
                let items = (obj as? [String: Any])?["items"] as? [[String: Any]] ?? []
                for it in items {
                    if (it["ok"] as? Bool) == true { ok = true }
                    why = (it["msg"] as? String) ?? ""
                }
            case .failure(let e):
                why = e.localizedDescription
            }
            AppLog.w("push | 验证 \(fresh.uid.prefix(8))（本批 \(list.count) 条）\(ok ? "OK" : "FAIL \(why)")")
            if ok {
                stage(.reading, "拿到新凭证")
                stage(.closing, "关闭中国移动…")
                Crane.killChinaMobile()
                Crane.run(Crane.uiopen,
                          ["--bundleid", Bundle.main.bundleIdentifier ?? "com.szafx.credpush"],
                          timeout: 8)
                self.endBackground()
                self.running = false
                self.pending = nil
                stage(.done, "完成")
                done(true, "已拿到新凭证（已自动推送）", fresh)
            } else {
                // ★ 整批都不行：把这些 UID 全记为 rejected，**不要**反复重推同一批
                //   （连续大量 appTokenLogin 可能触发服务端风控，2026-11-12 怀疑点之一）
                for c in list { self.rejected.insert(c.uid) }
                stage(.waiting, "本批会话无效，继续等待登录…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.poll(name: name, container: nil, known: known, allowNew: allowNew,
                               deadline: deadline, stage: stage, done: done)
                }
            }
        }
    }

    private func timeout(name: String,
                         known: Set<String>,
                         allowNew: Bool,
                         done: @escaping (Bool, String, FoundSession?) -> Void) {
        if cancelled { return }
        endBackground()
        running = false
        // ★ 不管容器此刻认不认得出，都要登记 —— 回前台后按「Crane 名字」再找一次。
        pending = (name, known, allowNew)
        AppLog.w("reacquire | 等待超时，等回前台续上（name=\(name)）")
        // ★ 超时不收浮窗：用户可能还在登录，浮窗要留到「全部完成 / 主动取消」
        LiveProgress.shared.note("等待中 · 切回 App 继续")
        done(false, "还没等到新凭证 —— 切回 App 后会自动再检查", nil)
    }

    /// 回前台时调用：上次没等到就再扫一次。
    /// 返回 (该容器的全部候选会话, 是否允许新账号)，**新会话排最前**；
    /// 没等到返回 nil（pending 保留，调用方可重试）。
    func resumeIfNeeded() -> (sessions: [FoundSession], allowNew: Bool)? {
        guard let pend = pending else { return nil }
        for path in containerPaths(name: pend.name) where Scanner.phoneFromPrefs(path) == pend.name {
            let got = Scanner.readSessions(container: path, phone: pend.name)
            if let fresh = got.first(where: { !pend.known.contains($0.uid) }) {
                pending = nil
                Crane.killChinaMobile()
                Crane.run(Crane.uiopen,
                          ["--bundleid", Bundle.main.bundleIdentifier ?? "com.szafx.credpush"],
                          timeout: 8)
                var list: [FoundSession] = [fresh]
                for c in got where c.uid != fresh.uid { list.append(c) }
                // 浮窗不在这里收 —— 等推送完成再收
                return (list, pend.allowNew)
            }
        }
        return nil
    }

    func clearPending() { pending = nil }

    /// 用户点「取消」：真的停下来（以前只改了个文案，轮询和灵动岛都还在跑）
    func cancel() {
        cancelled = true
        running = false
        pending = nil
        endBackground()
        LiveProgress.shared.end("已取消")
        AppLog.w("reacquire | 用户取消")
    }

    // MARK: - 辅助

    /// 按容器名找路径（取第一个）。
    func containerPath(name: String) -> String? { containerPaths(name: name).first }

    /// 同名容器可能有多个（反复创建）：
    /// ① 先列「UserPhone 已写（= 登录完成）」的；
    /// ② 再补上只按 Crane 名字匹配到的（可能是还没登录的空容器）。
    func containerPaths(name: String) -> [String] {
        var out: [String] = []
        for c in Scanner.allContainers() where c.phone == name {
            if !out.contains(c.path) { out.append(c.path) }
        }
        for c in Crane.list() where c.name == name {
            if let p = Scanner.path(forCraneID: c.id), !out.contains(p) { out.append(p) }
        }
        return out
    }

    private func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}
