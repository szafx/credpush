import UIKit
import UserNotifications

/// 凭证页：**按账号列登录状态**，能一键补回/清理。
final class CredViewController: UIViewController {
    // MARK: - 数据

    struct CredRow {
        enum Status { case upToDate, changed, expired, noSession, newAccount, notOnDevice }
        var phone: String
        var container: String
        var sessions: [FoundSession]
        var status: Status
        var hasMatch: Bool
        var cacheBytes: Int64
    }

    private var rows: [CredRow] = []
    /// 当前容器名（在后台算好，render 时不再 spawn，避免卡主线程）
    private var activeName: String = ""
    /// 本机容器数量（后台扫描结果）
    private var containerCount = 0
    private var scanning = false
    private var busy = false

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scan() }
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
            var rs: [CredRow] = []
            var onDevice = Set<String>()
            for c in containers {
                // ★ 只有「真正添加成功」的号才显示：UserPhone 为空 = 没登录完成，
                //   这些空容器（重复点新增账号留下的）一律不进列表。
                if c.phone.isEmpty { continue }
                let sessions = Scanner.readSessions(container: c.path, phone: c.phone)
                let serverUid = AccountCache.uid[c.phone] ?? ""
                let hasMatch = !serverUid.isEmpty && sessions.contains { $0.uid == serverUid }
                let known = AccountCache.known.contains(c.phone)
                let dead = AccountCache.dead.contains(c.phone)
                let st: CredRow.Status
                if sessions.isEmpty { st = .noSession }
                else if !known { st = .newAccount }
                else if !hasMatch { st = .changed }   // ★ 容器里有服务端不认识的会话 → 可以推
                else if dead { st = .expired }        // 容器里就是服务端那份，但服务端说它死了
                else { st = .upToDate }
                let bytes = CacheCleaner.size(CacheCleaner.cacheDir(c.path))
                rs.append(CredRow(phone: c.phone, container: c.path, sessions: sessions,
                                  status: st, hasMatch: hasMatch, cacheBytes: bytes))
                if !c.phone.isEmpty { onDevice.insert(c.phone) }
            }
            // 服务端有、本机没有容器的号
            for ph in AccountCache.known.sorted() where !onDevice.contains(ph) {
                rs.append(CredRow(phone: ph, container: "", sessions: [], status: .notOnDevice,
                                  hasMatch: false, cacheBytes: 0))
            }
            rs.sort { a, b in
                func rank(_ s: CredRow.Status) -> Int {
                    switch s {
                    case .expired: return 0
                    case .changed: return 1
                    case .newAccount: return 2
                    case .noSession: return 3
                    case .upToDate: return 4
                    case .notOnDevice: return 5
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

        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(actionBar())
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
        let masked = r.phone.count >= 7 ? "\(r.phone.prefix(3)) **** \(r.phone.suffix(4))"
            : (r.phone.isEmpty ? "(未命名容器)" : r.phone)
        let (text, color): (String, UIColor) = {
            switch r.status {
            case .upToDate: return ("已是最新", Theme.green)
            case .changed: return ("会话已更新", Theme.amber)
            case .expired: return ("登录已过期", Theme.red)
            case .noSession: return ("没有会话", Theme.dim)
            case .newAccount: return ("新账号", Theme.cyan)
            case .notOnDevice: return ("在其它设备", Theme.dim)
            }
        }()

        let head = Theme.hstack([Theme.dot(color), Theme.label(masked, size: 15, weight: .semibold, mono: true),
                                 Theme.spacer(), Theme.pill(text, color: color)], spacing: 8)

        var sub = ""
        switch r.status {
        case .upToDate: sub = "\(r.sessions.count) 条会话（服务端那份在）"
        case .changed: sub = "\(r.sessions.count) 条会话，但都不是服务端那份"
        case .expired: sub = "服务端换票失败，需要在手机上重新登录一次"
        case .noSession: sub = "容器里没有会话"
        case .newAccount: sub = r.phone.isEmpty
            ? "容器还没登录完成（登录成功后会自动识别手机号）"
            : "服务端还没登记这个号"
        case .notOnDevice: sub = "本机没有这个号的容器（可能在另一台 iPhone 上）"
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
        case .expired, .changed, .noSession:
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
        pushSessions(r.sessions, allowNew: r.status == .newAccount)
    }

    @objc private func doPushAll() {
        let list = rows.filter { ($0.status == .changed || $0.status == .newAccount) && !$0.phone.isEmpty }
        pushSessions(list.flatMap { $0.sessions }, allowNew: true)
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
                             title: "重新获取 \(masked)")
            }
            // ★ 先重推现有会话（含最新的那条）：195 这种「服务端说过期、但容器里其实有一条还能用」
            //   的情况，以前只能靠用户再登录一次；现在一次点击就能重试。
            if r.sessions.isEmpty {
                startFlow()
            } else {
                self.pushSessions(r.sessions, allowNew: false) { ok in
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
            let (rc, out) = Crane.run(Crane.cranectl, ["--wipe", Crane.appBundle, "name:" + ph])
            AppLog.w("crane | wipe \(ph) rc=\(rc) \(out.prefix(60))")
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
                         createIfMissing: Bool, title: String) {
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
                                   createIfMissing: createIfMissing,
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
        statusLabel.text = "推送 \(sessions.count) 条…"
        Tsnet.shared.startIfNeeded { [weak self] in
            guard let self = self else { return }
            let body: [String: Any] = [
                "sessions": sessions.map { ["raw": $0.raw, "phone": $0.phone] },
                "allowNew": allowNew,
                "device": UIDevice.current.name,
                "ios": UIDevice.current.systemVersion,
                "app": "credpush/1.0",
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
