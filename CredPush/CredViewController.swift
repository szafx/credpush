import UIKit
import UserNotifications

/// 凭证页：**按账号列登录状态**，能一键补回/清理。
final class CredViewController: UIViewController {
    // MARK: - 数据

    struct CredRow {
        enum Status { case upToDate, changed, expired, noSession, newAccount, notOnDevice, remoteOnly }
        var phone: String
        var container: String
        var sessions: [FoundSession]
        var status: Status
        var hasMatch: Bool
        var cacheBytes: Int64
        /// 额外说明（例如：会话在另一个容器里，而那个容器登记的是别的号）
        var note: String = ""
        /// ★ 2026-11-15：这一行属于哪个容器（「默认容器」/ Crane 里起的名字）——
        ///   两行同号时靠它区分
        var containerName: String = ""
        /// ★ 2026-11-15：容器在 Crane 里的 id（DEFAULT / UUID）。切容器、清空数据都按 id，
        ///   不再拿手机号去猜（默认容器的 Crane 名字不一定等于行里的号）
        var craneID: String = ""
        /// ★ 2026-11-15：容器 plist 里登记的号码（可能和实际会话不一致）
        var plistPhone: String = ""
        /// ★ 2026-11-15：这一行的号是按「会话 UID」认出来的，不是 plist 登记的
        var identityBySession: Bool = false
    }

    /// 138 **** 1234
    static func maskPhone(_ p: String) -> String {
        p.count >= 7 ? "\(p.prefix(3)) **** \(p.suffix(4))" : p
    }

    private var rows: [CredRow] = []
    /// 当前容器名（在后台算好，render 时不再 spawn，避免卡主线程）
    private var activeName: String = ""
    /// 本机容器数量（后台扫描结果）
    private var containerCount = 0
    private var scanning = false
    private var busy = false
    /// 最近一次推送**尝试**的时间（哪怕失败）
    private var lastPushAt: TimeInterval = 0
    /// 最近一次推的那条会话（uid 拼起来的 key）——冷却按**会话**算，不是按时间一刀切：
    /// 10 分钟内如果中国移动又换发了新会话，照样要推。
    private var lastPushedKey: String = ""

    // MARK: - UI

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let refresh = UIRefreshControl()
    private let statusLabel = Theme.label("", size: 12, color: Theme.dim, lines: 2)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        title = "凭证"

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.refreshControl = refresh
        refresh.tintColor = Theme.cyan
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationCenter.default.addObserver(self, selector: #selector(handleBecameActive),
                                               name: Notification.Name("AppBecameActive"), object: nil)
        // ★ 越狱看门狗 creddaemon 拉起来的补抓请求（credpush://pull）
        NotificationCenter.default.addObserver(self, selector: #selector(handlePullRequest),
                                               name: PullRequest.changed, object: nil)
        renderLoading()
        scan()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        CacheCleaner.purgeOldBackups()
        // 上次「重新获取 / 新增账号」超时的，回前台继续补抓
        resumePendingIfAny()
        if rows.isEmpty && !scanning { scan() }
        // 容器信息（UserPhone）可能是刚写下去的：1.5 秒后再扫一次，避免"新容器扫不到"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scan() }
    }

    /// 从中国移动切回本 App：上次没等到的，这里续上
    @objc private func handleBecameActive() {
        resumePendingIfAny()
        // ★ 2026-11-15：回前台先用 /api/state 刷一次 uid / source / alive（几十毫秒），再扫。
        //   否则凭证页会拿旧的服务端 UID 去比，把已经同步好的会话误报成「会话已更新」。
        AccountCache.quickUnchanged { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scan() }
        }
    }

    /// 守护进程（creddaemon）发现新会话 → 拉起 App 补抓
    @objc private func handlePullRequest() {
        // 用户自己发起的流程正在跑：那条路自己会推、自己会杀掉中国移动回到本 App，别插手
        if Reacquire.shared.isRunning || Reacquire.shared.hasPending {
            _ = PullRequest.take()
            PullRequest.returnToChinaMobile = false
            return
        }
        AccountCache.updated = nil
        if scanning {
            // 正在扫：等这一轮结束再来一次（pendingContainer 还在，下一轮 take 走）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.handlePullRequest()
            }
        } else {
            scan()
        }
    }

    /// 上次没等到凭证的：回前台立刻试一次，不行就每 2 秒重试（最多 60 秒）
    private func resumePendingIfAny() {
        if let r = Reacquire.shared.resumeIfNeeded() {
            resumeTimer?.invalidate(); resumeTimer = nil
            statusLabel.text = "回前台补抓到了新会话"
            // ★ 推整批候选会话（新会话在第一位），别只推一条 —— 见 Reacquire.pushAndFinish 的注释
            pushSessions(r.sessions, allowNew: r.allowNew)
            scan()
            return
        }
        // ★ 流程还在跑（超时回调可能还没执行）也算：下一拍 resumeIfNeeded() 会自动接上
        guard Reacquire.shared.hasPending || Reacquire.shared.isRunning else { return }
        resumeTimer?.invalidate()
        var ticks = 0
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            ticks += 1
            if let r = Reacquire.shared.resumeIfNeeded() {
                t.invalidate()
                self.resumeTimer = nil
                self.statusLabel.text = "回前台补抓到了新会话"
                self.pushSessions(r.sessions, allowNew: r.allowNew)
                self.scan()
            } else if ticks >= 30 {
                t.invalidate()
                self.resumeTimer = nil
                self.statusLabel.text = "还没等到凭证；登录完成后点「重新扫描」即可"
            }
        }
    }

    // MARK: - 扫描

    @objc private func reload() {
        refresh.endRefreshing()
        scan()
    }

    private func renderLoading() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(Theme.label("扫描本机容器…", size: 13, color: Theme.dim))
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        statusLabel.text = "正在扫描本机容器…"
        let needAccounts = (AccountCache.updated == nil)
        let work = { [weak self] in self?.doScan() }
        if needAccounts {
            AccountCache.refresh { work() }
        } else {
            work()
        }
    }

    private func doScan() {
        DispatchQueue.global(qos: .userInitiated).async {
            let containers = Scanner.allContainers()
            // ★ 容器显示名：主容器叫「默认」，Crane 分身用用户起的名字（如 19523001434）
            let craneNames = Dictionary(uniqueKeysWithValues: Crane.list().map { ($0.id, $0.name) })
            func containerLabel(_ path: String) -> String {
                if path.isEmpty { return "" }
                if !path.contains("/___Crane_Containers/") { return "默认容器" }
                let cid = (path as NSString).lastPathComponent
                return craneNames[cid] ?? String(cid.prefix(8))
            }
            /// 容器在 Crane 里的 id（DEFAULT / UUID）—— 切容器、清空数据都按它定位
            func craneID(_ path: String) -> String {
                if path.isEmpty { return "" }
                if !path.contains("/___Crane_Containers/") { return "DEFAULT" }
                return (path as NSString).lastPathComponent
            }
            // 扫描在后台线程跑：先把账号状态拷一份，避免和前台刷新打架
            let knownSet = AccountCache.known
            let deadSet = AccountCache.dead
            let srcMap = AccountCache.source
            let aliveMap = AccountCache.alive
            let uidMap = AccountCache.uid

            /// 这一组会话里，哪个服务端账号的 UID 命中得最多（用来判断容器真正的身份）
            func resolvePhone(_ sessions: [FoundSession], fallback: String) -> (phone: String, bySession: Bool) {
                var best = "", bestCount = 0
                for (ph, su) in uidMap where !su.isEmpty {
                    let n = sessions.filter { $0.uid == su }.count
                    if n == 0 { continue }
                    if n > bestCount || (n == bestCount && ph == fallback) {
                        bestCount = n; best = ph
                    }
                }
                if best.isEmpty { return (fallback, false) }
                return (best, best != fallback)
            }

            var rs: [CredRow] = []
            var onDevice = Set<String>()
            // ★ 2026-11-15：uid -> (容器路径, 命中次数)。跨容器认领取「命中最多」的那个；
            //   以前是后写覆盖，会把 180 的会话归到最后一个恰好出现过它的容器上。
            var uidContainer: [String: (path: String, count: Int)] = [:]

            for c in containers {
                // ★ 只有「真正添加成功」的号才显示：UserPhone 为空 = 没登录完成，
                //   这些空容器（重复点新增账号留下的）一律不进列表。
                if c.phone.isEmpty { continue }
                let sessions = Scanner.readSessions(container: c.path, phone: c.phone)
                for se in sessions where !se.uid.isEmpty {
                    let n = sessions.filter { $0.uid == se.uid }.count
                    if let prev = uidContainer[se.uid], prev.count >= n { continue }
                    uidContainer[se.uid] = (path: c.path, count: n)
                }
                // ★ 2026-11-15：容器的身份按「会话 UID」认，而不是只信 plist 的 UserPhone。
                //   典型：默认容器 plist 写着 153、里面其实是 180 的会话 → 以前会多出一行假 153。
                let res = resolvePhone(sessions, fallback: c.phone)
                let phone = res.phone
                let serverUid = uidMap[phone] ?? ""
                let hasMatch = !serverUid.isEmpty && sessions.contains { $0.uid == serverUid }
                let known = knownSet.contains(phone)
                let dead = deadSet.contains(phone)
                // ★ 2026-11-15：服务端可能持有「现签会话」（模板铸出来的，手机容器里没有）。
                //   这种情况不该显示成「新会话」，而是「服务器侧有效」。
                let srcMint = ((srcMap[phone] ?? "app") == "mint")
                let aliveOK = (aliveMap[phone] ?? true)
                let st: CredRow.Status
                if sessions.isEmpty { st = .noSession }
                else if !known { st = .newAccount }
                else if !hasMatch && srcMint && aliveOK { st = .remoteOnly }
                else if !hasMatch { st = .changed }   // ★ 容器里有服务端不认识的会话 → 可以推
                else if dead { st = .expired }        // 容器里就是服务端那份，但服务端说它死了
                else { st = .upToDate }
                let bytes = CacheCleaner.size(CacheCleaner.cacheDir(c.path))
                rs.append(CredRow(phone: phone, container: c.path, sessions: sessions,
                                  status: st, hasMatch: hasMatch, cacheBytes: bytes,
                                  note: res.bySession
                                      ? "容器登记的是 \(CredViewController.maskPhone(c.phone))（按会话 UID 认成本号）"
                                      : "",
                                  containerName: containerLabel(c.path),
                                  craneID: craneID(c.path),
                                  plistPhone: c.phone,
                                  identityBySession: res.bySession))
                onDevice.insert(phone)
            }
            // 服务端有、本机没有「登记为该号」的容器
            // ★ 2026-11-15：先按 UID 跨容器认领 —— 用户把某个容器切成别的号后，
            //   原号的会话常常还留在那个容器里，不能因此判成「在其它设备」。
            for ph in knownSet.sorted() where !onDevice.contains(ph) {
                let su = uidMap[ph] ?? ""
                let srcMint = ((srcMap[ph] ?? "app") == "mint")
                let aliveOK = (aliveMap[ph] ?? true)
                if !su.isEmpty, let hit = uidContainer[su] {
                    rs.append(CredRow(phone: ph, container: hit.path, sessions: [],
                                      status: srcMint ? .remoteOnly : .upToDate,
                                      hasMatch: true, cacheBytes: 0,
                                      note: "会话在「\(containerLabel(hit.path))」里（按 UID 归到别的号）",
                                      containerName: containerLabel(hit.path),
                                      craneID: craneID(hit.path)))
                } else if srcMint && aliveOK {
                    rs.append(CredRow(phone: ph, container: "", sessions: [],
                                      status: .remoteOnly, hasMatch: false, cacheBytes: 0))
                } else {
                    rs.append(CredRow(phone: ph, container: "", sessions: [], status: .notOnDevice,
                                      hasMatch: false, cacheBytes: 0))
                }
            }
            rs.sort { a, b in
                func rank(_ s: CredRow.Status) -> Int {
                    switch s {
                    case .expired: return 0
                    case .changed: return 1
                    case .newAccount: return 2
                    case .noSession: return 3
                    case .upToDate: return 4
                    case .remoteOnly: return 5
                    case .notOnDevice: return 6
                    }
                }
                if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
                return a.phone < b.phone
            }
            // 当前容器：在后台算（会 spawn cranectl/defaults，绝不能放主线程）
            var actName = ""
            if Crane.available() {
                let act = Crane.activeContainerID()
                for c in Crane.list() where c.id == act { actName = c.name }
            }
            let nContainers = containers.filter { !$0.phone.isEmpty }.count

            // ★ 给 creddaemon 写「服务端当前那条会话」提示（避免 cookie 延迟落盘造成的误触发）。
            //   服务端没返回 app_sid 时 AccountCache.sid8 是空的 → 什么都不写，行为同以前。
            for (ph, sid) in AccountCache.sid8 {
                if let r = rs.first(where: { $0.phone == ph && !$0.container.isEmpty }) {
                    self.writeDaemonHint(container: r.container, sid8: sid)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.rows = rs
                self.containerCount = nContainers
                self.activeName = actName
                self.scanning = false
                let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                self.statusLabel.text = rs.isEmpty
                    ? "没有找到中国移动的容器（检查权限或 App 是否安装）"
                    : "扫描完成 · \(nContainers) 个容器 · \(t)"
                self.render()

                // ★ creddaemon 触发的补抓：扫完送 1~2 条**候选**会话
                //   （不按状态门控 —— 中国移动冷启动会顶掉旧会话，服务端要等下一轮续期
                //    失败才知道；但整批推会把有效的那条连坐，2026-11-12 实测）
                let want = PullRequest.take()
                if !want.isEmpty {
                    let hit = self.rows.filter {
                        !$0.container.isEmpty
                            && ($0.container as NSString).lastPathComponent == want
                    }
                    let sessions = hit.flatMap { $0.sessions }
                    let phone = hit.first?.phone ?? ""
                    let cands = self.pullCandidates(sessions, phone: phone)
                    if !cands.isEmpty {
                        // ★ 一次送 1~2 条候选（服务端逐条验、第一条成功即停）。
                        //   去重按**整组会话**：同一组 5 分钟内推过才跳过；出现新会话照推。
                        let key = cands.map { $0.uid }.sorted().joined(separator: ",")
                        let now = Date().timeIntervalSince1970
                        if key == self.lastPushedKey && now - self.lastPushAt < 300 {
                            self.statusLabel.text = "这几条会话刚推过，跳过"
                            self.finishPull()
                        } else {
                            self.pushSessions(cands, allowNew: false) { _ in
                                self.finishPull()
                            }
                        }
                    } else {
                        self.statusLabel.text = "守护进程已触发，但该容器没有可推的会话"
                        self.finishPull()
                    }
                }
            }
        }
    }

    // MARK: - 渲染

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        stack.addArrangedSubview(Theme.label("LOCAL CREDENTIALS", size: 11, weight: .semibold, color: Theme.dim))
        stack.addArrangedSubview(Theme.label("登录状态", size: 28, weight: .bold))
        let desc = Theme.label("本机每个号码的登录凭证。已是最新的不用管；过期或换了会话的，可以一键补回。",
                               size: 13, color: Theme.muted, lines: 0)
        stack.addArrangedSubview(desc)

        if Crane.available() {
            stack.addArrangedSubview(activeContainerCard())
        } else {
            stack.addArrangedSubview(hintCard("这台设备没有 Crane 命令行，只能手动切容器 / 打开中国移动。"))
        }

        if rows.isEmpty {
            stack.addArrangedSubview(hintCard("没有扫描到中国移动的容器。"))
        } else {
            for r in rows { stack.addArrangedSubview(rowCard(r)) }
        }

        stack.addArrangedSubview(daemonCard())
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(actionBar())
    }

    /// 守护进程触发的补抓处理完了：如果 App 是被它从后台/冷启动拉起来的，
    /// 就把用户**送回中国移动**（不杀它）。
    /// ★ 用户自己点「重新获取 / 新增账号」走的不是这条路 —— 那条在 Reacquire 里
    ///   成功后是「杀掉中国移动 + 回到本 App」，保持原样。
    private func finishPull() {
        guard PullRequest.returnToChinaMobile else { return }
        PullRequest.returnToChinaMobile = false
        if Crane.available() {
            Crane.run(Crane.uiopen, ["--bundleid", Crane.appBundle], timeout: 8)
        }
    }

    /// 容器里「最新」的那条会话。
    /// ★ 排序以 **cookie 创建时间** 为准（有的新会话只在 Cookies.binarycookies 里，
    ///   WAL 里没有位置、recency=-1）；没有创建时间的才退回 WAL 偏移。
    ///   （2026-11-13 事故 B：只按偏移排会挑中旧会话，推上去就是「登录状态已过期」。）
    private func newestSession(_ sessions: [FoundSession]) -> FoundSession? {
        sessions.max { a, b in
            switch (a.createdAt, b.createdAt) {
            case let (x?, y?):
                if x != y { return x < y }
            case (_?, nil):
                return false          // 有创建时间的更可信
            case (nil, _?):
                return true
            default:
                break
            }
            return a.recency < b.recency
        }
    }

    /// 守护进程触发补抓时要送的候选（最多 `Cfg.pullCandidates` 条）。
    /// 排序：① cookie 创建时间最新 ② WAL 偏移最大 ③ **服务端已有的那条排最后**
    /// （容器里 UID 和服务端 app_uid 一样 = 没换过，没必要先推它）。
    /// 服务端是逐条验、第一条成功即停，所以多送一条只是多一次 appTokenLogin。
    private func pullCandidates(_ sessions: [FoundSession], phone: String) -> [FoundSession] {
        let serverUid = AccountCache.uid[phone] ?? ""
        let sorted = sessions.sorted { a, b in
            switch (a.createdAt, b.createdAt) {
            case let (x?, y?):
                if x != y { return x > y }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            return a.recency > b.recency
        }
        let changed = sorted.filter { $0.uid != serverUid }
        let ordered = changed.isEmpty ? sorted : changed + sorted.filter { $0.uid == serverUid }
        return Array(ordered.prefix(max(1, Cfg.pullCandidates)))
    }

    /// 给 creddaemon 写「服务端当前那条会话」的前 8 位。
    /// daemon 用它避免「cookie 延迟落盘」造成的误触发（2026-11-14 00:03 实测：
    /// 会话根本没变，只是 cookie 晚落盘，daemon 却把我们 App 拉到前台打断了用户）。
    private func writeDaemonHint(container: String, sid8: String) {
        guard !container.isEmpty, !sid8.isEmpty else { return }
        let cid = (container as NSString).lastPathComponent
        let dir = "/var/mobile/Library/CredDaemon/hint"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (sid8 + "\n").write(toFile: dir + "/" + cid + ".sid",
                                 atomically: true, encoding: .utf8)
    }

    /// 越狱看门狗 creddaemon 的心跳（装在越狱机上才有）。
    /// 目的是让「守护进程静默死掉」这件事**看得见**，而不是等用户发现登录后没自动推。
    private func daemonCard() -> UIView {
        let p = "/var/mobile/Library/CredDaemon/heartbeat.json"
        var text = "凭证守护：未安装 / 未运行 —— 在中国移动登录后需要手动切回 App"
        var color = Theme.red
        if let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let ts = (o["ts"] as? NSNumber)?.doubleValue {
            let age = Date().timeIntervalSince1970 - ts
            let total = (o["triggers"] as? NSNumber)?.intValue ?? 0
            if age <= 120 {
                text = "凭证守护：正常（\(Int(age)) 秒前心跳 · 本次已触发 \(total) 次）"
                color = Theme.green
            } else {
                text = "凭证守护：⚠️ 已 \(Int(age / 60)) 分钟没有心跳 —— 登录后需要手动切回 App"
            }
        }
        let v = Theme.card(14)
        let l = Theme.label(text, size: 12, color: color, lines: 0)
        v.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            l.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            l.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            l.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        return v
    }

    private func activeContainerCard() -> UIView {
        let v = Theme.card(14)
        let title = Theme.label("当前容器", size: 11, color: Theme.dim)
        let value = Theme.label(activeName.isEmpty ? "默认" : activeName,
                                size: 15, weight: .semibold, mono: true)
        let col = Theme.vstack([title, value], spacing: 2)
        v.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        return v
    }

    private func hintCard(_ text: String) -> UIView {
        let v = Theme.card(14)
        let l = Theme.label(text, size: 12, color: Theme.dim, lines: 0)
        v.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            l.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            l.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            l.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        return v
    }

    private func rowCard(_ r: CredRow) -> UIView {
        let v = Theme.card(14)
        let masked = r.phone.isEmpty ? "(未命名容器)" : CredViewController.maskPhone(r.phone)
        let (text, color): (String, UIColor) = {
            switch r.status {
            case .upToDate: return ("已是最新", Theme.green)
            case .changed: return ("会话已更新", Theme.amber)
            case .expired: return ("登录已过期", Theme.red)
            case .noSession: return ("没有会话", Theme.dim)
            case .newAccount: return ("新账号", Theme.cyan)
            case .notOnDevice: return ("在其它设备", Theme.dim)
            case .remoteOnly: return ("服务器侧有效", Theme.green)
            }
        }()

        var headViews: [UIView] = [Theme.dot(color),
                                   Theme.label(masked, size: 15, weight: .semibold, mono: true)]
        // ★ 2026-11-15：把容器名带上（默认容器 / Crane 名）—— 两行同号时一眼分得清
        if !r.containerName.isEmpty && r.containerName != r.phone {
            headViews.append(Theme.label(r.containerName, size: 11, color: Theme.dim))
        }
        headViews.append(Theme.spacer())
        headViews.append(Theme.pill(text, color: color))
        let head = Theme.hstack(headViews, spacing: 8)

        var sub: String
        if r.sessions.isEmpty && !r.note.isEmpty {
            // 跨容器认领的行：没有会话可数，直接说它在哪个容器里
            sub = r.note
        } else {
        switch r.status {
        case .upToDate: sub = "\(r.sessions.count) 条会话（服务端那份在）"
        case .changed: sub = "\(r.sessions.count) 条会话，但都不是服务端那份"
        case .expired: sub = "服务端换票失败，需要在手机上重新登录一次"
        case .noSession: sub = "容器里没有会话"
        case .newAccount: sub = r.phone.isEmpty
            ? "容器还没登录完成（登录成功后会自动识别手机号）"
            : "服务端还没登记这个号"
        case .notOnDevice: sub = "本机没有这个号的容器（可能在另一台 iPhone 上）"
        case .remoteOnly: sub = "服务端用的是现签会话（手机里没有这条）；在手机上打开一次该号会自动对齐"
        }
            if !r.note.isEmpty {
                // ★ 身份说明放最前面：后面的「最新会话 / 推送方式 / 缓存」可以被截断，这条不能
                sub = r.note + " · " + sub
            }
        }
        // ★ 2026-11-15：显示容器里「最新一条会话」的创建时间 —— 一眼看出最近有没有更新过
        if let newest = r.sessions.compactMap({ $0.createdAt }).max() {
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm"
            let mins = Int(max(0, Date().timeIntervalSince(newest)) / 60)
            let ago: String
            if mins < 1 { ago = "刚刚" }
            else if mins < 60 { ago = "\(mins) 分钟前" }
            else if mins < 60 * 24 { ago = "\(mins / 60) 小时前" }
            else { ago = "\(mins / (60 * 24)) 天前" }
            sub += " · 最新会话 \(df.string(from: newest))（\(ago)）"
        } else if !r.sessions.isEmpty {
            sub += " · 最新会话时间未知"
        }
        // ★ 2026-11-15：最近一次会话是「谁推的」—— 一眼看出直推还是拉起 App
        if let v = AccountCache.via[r.phone], !v.isEmpty {
            let word: String
            switch v {
            case "daemon":    word = "daemon 直推"     // 看门狗直接推，没碰 App
            case "pull":      word = "daemon 拉起"     // daemon 拉起 App 后自动推
            case "reacquire": word = "App 重新获取"    // 用户点「重新获取」
            default:          word = "手动推送"        // 用户点「推送」
            }
            // 时间已经由「最新会话 xx:xx」显示了，这里只补一个方式标签（省字数）
            sub += " · \(word)"
        }
        if r.cacheBytes > 0 {
            sub += " · 缓存 " + CacheCleaner.fmt(r.cacheBytes)
        }

        var parts: [UIView] = [head]
        if !sub.isEmpty {
            parts.append(Theme.label(sub, size: 11, color: Theme.dim, lines: 2))
        }
        let btns = buttons(for: r)
        if !btns.isEmpty {
            let row = Theme.hstack(btns, spacing: 8)
            row.distribution = .fillEqually
            parts.append(row)
        }

        let col = Theme.vstack(parts, spacing: 8)
        v.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        return v
    }

    private func smallButton(_ title: String, _ color: UIColor, _ sel: Selector,
                             tag: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = Theme.rounded(13, .semibold)
        b.setTitleColor(Theme.textOn(color), for: .normal)   // 黑底就白字，不再"一片黑"
        b.backgroundColor = color
        b.layer.cornerRadius = 10
        b.layer.cornerCurve = .continuous
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.accessibilityIdentifier = tag
        b.addTarget(self, action: sel, for: .touchUpInside)
        return b
    }

    private func buttons(for r: CredRow) -> [UIView] {
        var out: [UIView] = []
        let canReacquire = Crane.available() && !r.container.isEmpty
        switch r.status {
        case .expired, .changed, .noSession, .remoteOnly:
            if canReacquire {
                out.append(smallButton("重新获取", Theme.cyan, #selector(doReacquire(_:)),
                                       tag: r.phone))
            }
            if r.status == .changed {   // 会话是新的但服务端还旧，直接推
                out.append(smallButton("推送", Theme.green, #selector(doPushRow(_:)),
                                       tag: r.phone))
            }
        case .newAccount:
            // ★ 未命名容器（UserPhone 为空）= 还没登录完成，里面的会话不可用，别给"推送"
            if !r.phone.isEmpty {
                out.append(smallButton("推送并添加", Theme.green, #selector(doPushRow(_:)),
                                       tag: r.phone))
            }
        case .upToDate:
            if r.cacheBytes > 1_500_000 {
                out.append(smallButton("清理缓存 " + CacheCleaner.fmt(r.cacheBytes),
                                       Theme.cardHi, #selector(doClean(_:)), tag: r.phone))
            }
            out.append(smallButton("清空数据", Theme.cardHi, #selector(doWipe(_:)), tag: r.phone))
        case .notOnDevice:
            break
        }
        return out
    }

    private func actionBar() -> UIView {
        let v = Theme.card(14)
        let scanBtn = smallButton("重新扫描", Theme.cardHi, #selector(reload), tag: "scan")
        scanBtn.setTitleColor(Theme.textOn(Theme.cardHi), for: .normal)
        // ★ 未命名容器（phone 为空）不算「待推送」——里面的会话是登录前的，推上去必被拒
        let pushable = rows.filter { ($0.status == .changed || $0.status == .newAccount) && !$0.phone.isEmpty }
        let pushBtn = smallButton(pushable.isEmpty ? "没有待推送" : "推送 \(pushable.count) 个号",
                                  Theme.green, #selector(doPushAll), tag: "pushall")
        pushBtn.isEnabled = !pushable.isEmpty
        pushBtn.alpha = pushable.isEmpty ? 0.4 : 1
        let addBtn = smallButton("＋ 新增账号", Theme.cyan, #selector(doAddAccount), tag: "add")
        let row = Theme.hstack([scanBtn, pushBtn], spacing: 8)
        row.distribution = .fillEqually
        let row2 = Theme.hstack([addBtn], spacing: 8)
        row2.distribution = .fillEqually
        let col = Theme.vstack([row, row2], spacing: 8)
        v.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        return v
    }

    // MARK: - 动作

    private func row(phone: String) -> CredRow? {
        return rows.first { $0.phone == phone }
    }

    @objc private func doPushRow(_ sender: UIButton) {
        guard let ph = sender.accessibilityIdentifier, let r = row(phone: ph) else { return }
        let one = newestSession(r.sessions).map { [$0] } ?? r.sessions
        pushSessions(one, allowNew: r.status == .newAccount)
    }

    @objc private func doPushAll() {
        let list = rows.filter { ($0.status == .changed || $0.status == .newAccount) && !$0.phone.isEmpty }
        var perPhone: [String: [FoundSession]] = [:]
        for r in list { perPhone[r.phone, default: []].append(contentsOf: r.sessions) }
        var picked: [FoundSession] = []
        for (_, ss) in perPhone { if let n = newestSession(ss) { picked.append(n) } }
        pushSessions(picked, allowNew: true)
    }

    @objc private func doReacquire(_ sender: UIButton) {
        guard let ph = sender.accessibilityIdentifier, let r = row(phone: ph) else { return }
        let masked = ph.count >= 7 ? String(ph.suffix(4)) : ph
        confirm("重新获取 \(masked)",
                "会先把容器里现有的会话再推一遍；如果都不行，再切到该号的 Crane 容器、打开中国移动等你登录，拿到新凭证后自动关闭并推送。") { [weak self] in
            guard let self = self else { return }
            let startFlow = {
                self.runFlow(name: ph, container: r.container,
                             known: Set(r.sessions.map { $0.uid }), createIfMissing: false,
                             craneID: r.craneID,
                             title: "重新获取 \(masked)")
            }
            // ★ 先重推现有会话（含最新的那条）：195 这种「服务端说过期、但容器里其实有一条还能用」
            //   的情况，以前只能靠用户再登录一次；现在一次点击就能重试。
            if r.sessions.isEmpty {
                startFlow()
            } else {
                let one = self.newestSession(r.sessions).map { [$0] } ?? r.sessions
                self.pushSessions(one, allowNew: false) { ok in
                    if ok {
                        self.toast("已用现有会话重新推送成功", ok: true)
                        self.scan()
                    } else {
                        startFlow()
                    }
                }
            }
        }
    }

    /// 清空容器数据（Crane 自带的 --wipe）
    @objc private func doWipe(_ sender: UIButton) {
        guard let ph = sender.accessibilityIdentifier, let r = row(phone: ph) else { return }
        let masked = ph.count >= 7 ? String(ph.suffix(4)) : ph
        confirm("清空 \(masked) 的容器数据",
                "会删除该容器的全部数据（Crane --wipe），**这个号要重新登录**。确定？") { [weak self] in
            guard let self = self else { return }
            // ★ 2026-11-15：有容器 id 就按 id 清（DEFAULT / UUID）—— 别按手机号猜容器名，
            //   否则默认容器的行可能把另一个同号容器清掉
            let target = r.craneID.isEmpty ? ("name:" + ph) : r.craneID
            let (rc, out) = Crane.run(Crane.cranectl, ["--wipe", Crane.appBundle, target])
            AppLog.w("crane | wipe \(target) rc=\(rc) \(out.prefix(60))")
            self.toast(rc == 0 ? "已清空 \(masked) 的数据" : "清空失败（\(rc)）", ok: rc == 0)
            self.scan()
        }
    }

    /// 新增账号：输入名字 → 建容器 → 切过去 → 拉起中国移动 → 等新凭证
    @objc private func doAddAccount() {
        let a = UIAlertController(title: "新增账号",
                                  message: "给新容器起个名字（必须填完整手机号，例如 13567948458）。\u{0A}会新建一个 Crane 容器并打开中国移动登录。\u{0A}⚠️ 登录页请用「短信验证码登录」，不要点「本机号码一键登录」（那是这台手机 SIM 的号）。",
                                  preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = "例如 19900001111"
            tf.keyboardType = .numberPad
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "开始", style: .default) { [weak self, weak a] _ in
            let name = (a?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self?.runFlow(name: name, container: nil, known: [], createIfMissing: true,
                          title: "新增账号 \(name)")
        })
        present(a, animated: true)
    }

    /// 统一的「切容器 → 拉起 → 等凭证」流程（带步骤卡片 + 倒计时 + 进度通知）
    private func runFlow(name: String, container: String?, known: Set<String>,
                         createIfMissing: Bool, craneID: String = "", title: String) {
        let steps = ["关闭旧进程", "切换 Crane 容器", "打开中国移动",
                     "等待登录完成", "读取凭证", "关闭中国移动"]
        let hud = StepHUD.show(in: view, title: title, steps: steps) { [weak self] in
            // ★ 取消要真的取消：停轮询、清 pending、收掉灵动岛
            Reacquire.shared.cancel()
            self?.statusLabel.text = "已取消"
        }
        hud.setStep(0, detail: "即将切换…")
        hud.countdown(seconds: 2) { [weak self] in
            guard let self = self else { return }
            Reacquire.shared.start(name: name, container: container, known: known,
                                   createIfMissing: createIfMissing, craneID: craneID,
                                   stage: { st, detail in
                // 切走后界面看不到，但回到前台时还能看到进度
                hud.setStep(st.rawValue, detail: detail)
                self.statusLabel.text = detail
            }, done: { ok, msg, fresh in
                hud.finish(ok, detail: msg)
                self.statusLabel.text = msg
                if ok {
                    // ★ 流程内部已经「先推送验证、通过才杀 App」了，这里不再重复推送
                    LiveProgress.shared.end("已完成")
                } else {
                    self.toast(msg, ok: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    hud.dismiss()
                    self.scan()
                }
            })
        }
    }

    @objc private func doClean(_ sender: UIButton) {
        guard let ph = sender.accessibilityIdentifier, let r = row(phone: ph) else { return }
        // 前置条件：服务端已有这个号最新那份
        guard r.hasMatch else {
            toast("服务端还没有这个号的最新会话，先推送再清理", ok: false)
            return
        }
        confirm("清理缓存",
                "删除该容器的 NSURLCache（约 \(CacheCleaner.fmt(r.cacheBytes))），会先备份，登录态不受影响。") { [weak self] in
            guard let self = self else { return }
            let res = CacheCleaner.clean(container: r.container)
            self.toast(res.ok ? "已清理 " + CacheCleaner.fmt(res.freed) : res.msg, ok: res.ok)
            self.statusLabel.text = res.msg
            self.scan()
        }
    }

    private func pushSessions(_ sessions: [FoundSession], allowNew: Bool,
                              completion: ((Bool) -> Void)? = nil) {
        // ★ busy 时不要静默丢弃：调用方（比如「重新获取」的前置重推）要靠回调决定下一步
        guard !busy else {
            toast("正在推送中，请稍候", ok: false)
            completion?(false)
            return
        }
        guard !sessions.isEmpty else {
            toast("没有可推送的会话", ok: false)
            completion?(false)
            return
        }
        busy = true
        lastPushAt = Date().timeIntervalSince1970
        lastPushedKey = sessions.map { $0.uid }.sorted().joined(separator: ",")
        statusLabel.text = "推送 \(sessions.count) 条…"
        Tsnet.shared.startIfNeeded { [weak self] in
            guard let self = self else { return }
            let body: [String: Any] = [
                "sessions": sessions.map { ["raw": $0.raw, "phone": $0.phone] },
                "allowNew": allowNew,
                "device": UIDevice.current.name,
                "ios": UIDevice.current.systemVersion,
                "app": "credpush/1.0",
                "via": "app",
            ]
            Net.callPanel("/api/cred/push", json: body,
                          headers: ["X-Cred-Token": Cfg.pushToken], timeout: 180) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                switch r {
                case .failure(let e):
                    self.statusLabel.text = "推送失败：\(e.localizedDescription)"
                    self.toast("推送失败", ok: false)
                    LiveProgress.shared.end("结束")
                    completion?(false)
                case .success(let obj):
                    let d = obj as? [String: Any] ?? [:]
                    let items = d["items"] as? [[String: Any]] ?? []
                    var okN = 0
                    for it in items {
                        if (it["ok"] as? Bool) == true { okN += 1 }
                        let nick = (it["nick"] as? String) ?? (it["phone"] as? String) ?? "?"
                        AppLog.w("push | \(nick) \(it["ok"] as? Bool == true ? "OK" : "FAIL") \((it["msg"] as? String) ?? "")")
                    }
                    self.statusLabel.text = okN > 0 ? "已更新 \(okN) 个号" : "服务端没有接受"
                    self.toast(okN > 0 ? "已更新 \(okN) 个号" : "没有更新", ok: okN > 0)
                    // ★ 全部步骤结束（成功/失败都算任务收尾）：这时才收浮窗
                    LiveProgress.shared.end(okN > 0 ? "已完成" : "结束")
                    completion?(okN > 0)
                }
                // 重新拉一次服务端状态
                AccountCache.updated = nil
                AccountCache.refresh { self.scan() }
            }
        }
    }

    // MARK: - 小工具

    private func confirm(_ title: String, _ msg: String, _ run: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in run() })
        present(a, animated: true)
    }

    private var toastView: UIView?
    private var resumeTimer: Timer?
    private func toast(_ text: String, ok: Bool = true) {
        toastView?.removeFromSuperview()
        let c = UIView()
        c.translatesAutoresizingMaskIntoConstraints = false
        // ★ 同 AccountsViewController：深色底 + Theme.text 在浅色模式下是黑底黑字。
        let bg = ok ? UIColor(hex: 0x1C2A3A) : Theme.red
        c.backgroundColor = bg
        c.layer.cornerRadius = 18
        c.layer.cornerCurve = .continuous
        let l = Theme.label(text, size: 13, weight: .semibold, color: Theme.textOn(bg), lines: 2)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textAlignment = .center
        c.addSubview(l)
        view.addSubview(c)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: c.topAnchor, constant: 10),
            l.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -10),
            l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 16),
            l.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -16),
            c.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            c.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            c.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        c.alpha = 0
        UIView.animate(withDuration: 0.2) { c.alpha = 1 }
        toastView = c
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            UIView.animate(withDuration: 0.3, animations: { c.alpha = 0 }) { _ in c.removeFromSuperview() }
        }
    }
}
