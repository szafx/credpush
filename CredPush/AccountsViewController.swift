import UIKit

/// 账号总览：卡片可点开展开，展开后有券明细 + 开关 + 操作按钮。
final class AccountsViewController: UIViewController, UIGestureRecognizerDelegate {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let refresh = UIRefreshControl()
    private let hint = Theme.label("", size: 12, color: Theme.dim, lines: 2)
    private let summary = Theme.label("", size: 12, color: Theme.dim, lines: 2)

    private var items: [[String: Any]] = []
    private var expanded = Set<String>()
    private var busy = false
    private var acting = false
    private var lastLoaded: Date?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        title = "账号"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "刷新", style: .plain, target: self, action: #selector(pull))
        navigationItem.rightBarButtonItem?.tintColor = Theme.cyan

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.refreshControl = refresh
        refresh.addTarget(self, action: #selector(pull), for: .valueChanged)
        refresh.tintColor = Theme.cyan
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 12
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

        load(force: false)
    }

    /// 每次回到「账号」页：距上次成功加载超过 5 分钟就自动查一次
    /// （此时服务端缓存也正好过期，等于真去问中国移动）
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !busy else { return }
        if let t = lastLoaded, Date().timeIntervalSince(t) < 300 { return }
        load(force: false)
    }

    @objc private func pull() { load(force: true) }

    private func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func setBusy(_ b: Bool) {
        busy = b
        navigationItem.rightBarButtonItem?.isEnabled = !b
        if !b { refresh.endRefreshing() }
    }

    // MARK: - 数据

    func load(force: Bool) {
        guard !busy else { return }
        if items.isEmpty, let d = LocalStore.load("accounts_cache.json"),
           let arr = d["items"] as? [[String: Any]], !arr.isEmpty {
            items = arr
            hint.text = "缓存 · " + ((d["t"] as? String) ?? "")
            render()
        }
        setBusy(true)
        if force { hint.text = "正在逐个号查数据（约 1~3 分钟）…"; render() }
        // ★ 先直接查：面板 cookie 有效期 30 天，通常不用每次重新登录。
        //   只有 401 才去 /api/auth，省掉一次跨 Cloudflare 的往返（实测约 2~3 秒）。
        // 连内置 Tailscale 最多等 6 秒；没配授权码就立刻放行，不影响正常使用。
        Tsnet.shared.startIfNeeded { [weak self] in
            self?.fetchAccounts(force: force, retryAuth: true)
        }
    }

    private func fetchAccounts(force: Bool, retryAuth: Bool) {
        Net.callPanel("/api/accounts", json: ["force": force],
                 timeout: 240) { [weak self] r in
            guard let self = self else { return }
            if case .failure(let e) = r, retryAuth,
               e.localizedDescription.contains("401") {
                // cookie 过期了：登录一次再重试
                Net.callPanel("/api/auth", json: ["password": Cfg.password]) { [weak self] ar in
                    guard let self = self else { return }
                    if case .failure(let ae) = ar {
                        self.setBusy(false)
                        self.hint.text = "登录面板失败：\(ae.localizedDescription)"
                        self.toast("登录失败", ok: false)
                        self.render()
                        return
                    }
                    self.fetchAccounts(force: force, retryAuth: false)
                }
                return
            }
            self.setBusy(false)
            switch r {
            case .failure(let e):
                self.hint.text = "读取失败：\(e.localizedDescription)"
                self.toast("刷新失败", ok: false)
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                self.items = d["items"] as? [[String: Any]] ?? []
                AccountCache.known = Set(self.items.compactMap { $0["phone"] as? String })
                AccountCache.uid = [:]
                for it in self.items {
                    if let ph = it["phone"] as? String, let u = it["app_uid"] as? String, !u.isEmpty {
                        AccountCache.uid[ph] = u
                    }
                }
                AccountCache.dead = Set(self.items.filter {
                    !((($0["err"] as? String) ?? "").isEmpty)
                }.compactMap { $0["phone"] as? String })
                AccountCache.updated = Date()
                LocalStore.save("accounts_cache.json", d)
                let newly = AccountCache.dead.subtracting(AccountCache.notifiedDead)
                if !newly.isEmpty {
                    Notifier.alert("\(newly.count) 个号掉线",
                                   newly.map { String($0.suffix(4)) }.joined(separator: "、")
                                   + " —— 去「凭证」页扫描推送")
                    AccountCache.notifiedDead = AccountCache.dead
                } else if AccountCache.dead.isEmpty {
                    AccountCache.notifiedDead = []
                }
                self.lastLoaded = Date()
                self.hint.text = (d["t"] as? String).map { "更新于 \($0)" } ?? ""
                let n = self.items.count
                let t = (d["t"] as? String).map { " · \($0)" } ?? ""
                self.toast("已更新 \(n) 个号\(t)")
            }
            self.render()
        }
    }

    // MARK: - 渲染

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(makeHeader())
        if items.isEmpty {
            stack.addArrangedSubview(makeEmptyCard())
        } else {
            for it in items {
                let phone = (it["phone"] as? String) ?? ""
                stack.addArrangedSubview(makeCard(it, phone: phone))
            }
        }
        let foot = Theme.label("点卡片展开明细 · 下拉刷新", size: 11, color: Theme.dim, lines: 1)
        foot.textAlignment = .center
        stack.addArrangedSubview(foot)
    }

    private func makeHeader() -> UIView {
        let eyebrow = Theme.label("CONTROL DECK", size: 11, weight: .semibold, color: Theme.dim)
        let title = Theme.label("我的号码", size: 28, weight: .bold)

        var alive = 0, bad = 0, bean = 0, flow = 0, fee = 0
        for it in items {
            if ((it["err"] as? String) ?? "").isEmpty { alive += 1 } else { bad += 1 }
            if let b = Num.int(it["balance"]) { bean += b }
            else if let b = Num.int(it["last_balance"]) { bean += b }
            for c in (it["coupons"] as? [[String: Any]]) ?? [] {
                if (c["cat"] as? String) == "FLOW" { flow += 1 } else { fee += 1 }
            }
        }
        let s1 = statChip("\(alive)/\(items.count)", "在线", Theme.green)
        let s2 = statChip("\(bean)", "AI豆·全部\(items.count)号", Theme.cyan)
        let s3 = statChip("\(flow)", "流量券", Theme.amber)
        let s4 = statChip("\(bad)", "异常", bad > 0 ? Theme.red : Theme.dim)
        let stats = Theme.hstack([s1, s2, s3, s4], spacing: 8)
        stats.distribution = .fillEqually

        var parts: [UIView] = [eyebrow, title]
        if !AccountCache.dead.isEmpty { parts.append(banner()) }
        parts.append(stats)
        parts.append(hint)
        let head = Theme.vstack(parts, spacing: 8)
        head.setCustomSpacing(14, after: title)
        return head
    }

    private func statChip(_ value: String, _ caption: String, _ color: UIColor) -> UIView {
        let v = Theme.card(10)
        let n = Theme.label(value, size: 18, weight: .bold, color: color, mono: true)
        let c = Theme.label(caption, size: 10, color: Theme.dim)
        let s = Theme.vstack([n, c], spacing: 2)
        v.addSubview(s)
        s.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            s.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            s.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        return v
    }

    private func makeEmptyCard() -> UIView {
        let v = Theme.card(18)
        let t = Theme.label("还没有数据", size: 16, weight: .semibold)
        let d = Theme.label("点右上角「刷新」，或下拉重试。", size: 13, color: Theme.muted, lines: 0)
        let s = Theme.vstack([t, d], spacing: 6)
        v.addSubview(s)
        s.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            s.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            s.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        return v
    }

    // MARK: - 单张卡

    private func makeCard(_ it: [String: Any], phone: String) -> UIView {
        let v = Theme.card(16)
        let isOpen = expanded.contains(phone)

        let masked = phone.count >= 7 ? "\(phone.prefix(3)) **** \(phone.suffix(4))" : phone
        let err = (it["err"] as? String) ?? ""
        let age = Num.int(it["token_age_min"])

        let stateColor: UIColor
        let stateText: String
        if !err.isEmpty { stateColor = Theme.red; stateText = "掉线" }
        else if let a = age, a >= 18 * 60 { stateColor = Theme.amber; stateText = "快到期" }
        else { stateColor = Theme.green; stateText = "正常" }

        let dot = Theme.dot(stateColor)
        let name = Theme.label(masked, size: 16, weight: .semibold, mono: true)
        let state = Theme.pill(stateText, color: stateColor)
        let chevron = UIImageView(image: UIImage(systemName: isOpen ? "chevron.up" : "chevron.down"))
        chevron.tintColor = Theme.dim
        chevron.contentMode = .scaleAspectFit
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let head = Theme.hstack([dot, name, Theme.spacer(), state, chevron], spacing: 8)

        // AI豆 + 任务
        let bal = Num.int(it["balance"])
        let lastBal = Num.int(it["last_balance"])
        let beanText: String = bal.map { "\($0)" } ?? lastBal.map { "≈\($0)" } ?? "—"
        let beanColor: UIColor = bal != nil ? Theme.cyan : Theme.dim
        let bean = Theme.label(beanText, size: 30, weight: .bold, color: beanColor, mono: true)
        let beanCol = Theme.vstack([bean, Theme.label("AI豆", size: 11, color: Theme.dim)], spacing: 0)
        let done = Num.int(it["tasks_done"]), total = Num.int(it["tasks_total"])
        var taskNum = Theme.label((done != nil && total != nil) ? "\(done!)/\(total!)" : "—",
                                  size: 18, weight: .semibold, mono: true)
        taskNum.textAlignment = .right
        var taskCap = Theme.label("任务完成", size: 11, color: Theme.dim)
        taskCap.textAlignment = .right
        if let p = Num.int(it["pending"]), p > 0 {
            taskCap = Theme.label("待领 \(p)", size: 11, color: Theme.amber)
            taskCap.textAlignment = .right
        }
        let row2 = Theme.hstack([beanCol, Theme.spacer(),
                                 Theme.vstack([taskNum, taskCap], spacing: 0)], spacing: 12)

        let bar = LifeBar()
        bar.set(hours: age.map { $0 / 60 }, dead: !err.isEmpty)

        var pills: [UIView] = []
        if let signed = it["signed"] as? Bool {
            var txt = signed ? "已签" : "未签"
            if let acc = it["accumulate"], !(acc is NSNull) { txt += " · \(acc)天" }
            pills.append(Theme.pill(txt, color: signed ? Theme.green : Theme.amber))
        }
        let coupons = (it["coupons"] as? [[String: Any]]) ?? []
        if !coupons.isEmpty {
            let soon = coupons.compactMap { Num.int($0["daysLeft"]) }.min()
            var txt = "券 \(coupons.count)"
            if let s = soon { txt += " · \(s)天" }
            pills.append(Theme.pill(txt, color: (soon ?? 99) <= 3 ? Theme.amber : Theme.cyan))
        }

        var parts: [UIView] = [head, row2, bar]
        if !pills.isEmpty { parts.append(Theme.hstack(pills, spacing: 6)) }

        if isOpen {
            parts.append(divider())
            parts.append(couponSection(coupons))
            parts.append(toggleRow(it, phone: phone))
            parts.append(detailLink(phone))
            parts.append(ageLine(age, err: err))
        }

        let col = Theme.vstack(parts, spacing: 10)
        col.setCustomSpacing(4, after: row2)
        col.setCustomSpacing(6, after: bar)
        v.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])

        let g = UITapGestureRecognizer(target: self, action: #selector(toggle(_:)))
        g.delegate = self
        g.cancelsTouchesInView = false      // 别把卡片里按钮的点按吃掉
        v.addGestureRecognizer(g)
        v.tag = items.firstIndex { ($0["phone"] as? String) == phone } ?? -1
        return v
    }

    /// 顶部掉线红条：点一下跳到凭证页
    private func banner() -> UIView {
        let v = Theme.card(12)
        v.backgroundColor = Theme.red.withAlphaComponent(0.12)
        v.layer.borderColor = Theme.red.withAlphaComponent(0.5).cgColor
        let n = AccountCache.dead.count
        let t = Theme.label("\(n) 个号掉线", size: 13, weight: .semibold, color: Theme.red)
        let d = Theme.label("去「凭证」扫码推送", size: 11, color: Theme.muted)
        let s = Theme.vstack([t, d], spacing: 2)
        let arrow = Theme.label("›", size: 20, weight: .bold, color: Theme.red)
        let row = Theme.hstack([s, Theme.spacer(), arrow], spacing: 8)
        v.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        let g = UITapGestureRecognizer(target: self, action: #selector(goCred))
        v.addGestureRecognizer(g)
        return v
    }

    @objc private func goCred() {
        tabBarController?.selectedIndex = 1
    }

    /// 展开区底部：查看详情
    private func detailLink(_ phone: String) -> UIView {
        let l = Theme.label("查看详情（任务 / 券 / 操作）  ›", size: 12.5, weight: .medium, color: Theme.cyan)
        let v = UIView()
        v.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -2),
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        ])
        let g = UITapGestureRecognizer(target: self, action: #selector(openDetail(_:)))
        v.addGestureRecognizer(g)
        v.accessibilityIdentifier = phone
        return v
    }

    @objc private func openDetail(_ g: UITapGestureRecognizer) {
        guard let ph = g.view?.accessibilityIdentifier else { return }
        tap()
        navigationController?.pushViewController(AccountDetailViewController(phone: ph), animated: true)
    }

    private func divider() -> UIView {
        let d = UIView()
        d.backgroundColor = Theme.line
        d.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return d
    }

    private func couponSection(_ coupons: [[String: Any]]) -> UIView {
        let title = Theme.label("券", size: 11, weight: .semibold, color: Theme.dim)
        var rows: [UIView] = [title]
        if coupons.isEmpty {
            rows.append(Theme.label("没有券", size: 12, color: Theme.dim))
        } else {
            let sorted = coupons.sorted { ((Num.int($0["daysLeft"])) ?? 999) < ((Num.int($1["daysLeft"])) ?? 999) }
            for c in sorted {
                let cat = (c["cat"] as? String) == "FLOW" ? "流量券" : "话费券"
                let name = (c["name"] as? String) ?? "券"
                let days = Num.int(c["daysLeft"])
                let left = Theme.label("\(cat) · \(name)", size: 12.5, weight: .medium,
                                       color: Theme.text, lines: 1)
                let when = Theme.label(days.map { "剩 \($0) 天" } ?? "—",
                                       size: 11, color: (days ?? 99) <= 3 ? Theme.red : Theme.dim,
                                       mono: true)
                when.setContentHuggingPriority(.required, for: .horizontal)
                rows.append(Theme.hstack([left, Theme.spacer(), when], spacing: 8))
            }
        }
        return Theme.vstack(rows, spacing: 6)
    }

    /// 三个「自动」开关：点一下立刻保存，失败弹回原状态
    private func toggleRow(_ it: [String: Any], phone: String) -> UIView {
        let sw = (it["switches"] as? [String: Any]) ?? [:]

        func cell(_ title: String, _ key: String, _ path: String) -> UIView {
            let l = Theme.label(title, size: 11, color: Theme.dim)
            let s = UISwitch()
            s.isOn = (sw[key] as? Bool) ?? false
            s.onTintColor = Theme.cyan
            s.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
            s.accessibilityIdentifier = "\(phone)|\(path)|\(key)"
            s.addTarget(self, action: #selector(autoChanged(_:)), for: .valueChanged)
            return Theme.vstack([l, s], spacing: 2, align: .center)
        }

        let row = Theme.hstack([
            cell("自动签到", "mark", "/api/auto_mark"),
            cell("自动领豆", "claim", "/api/auto_claim"),
            cell("自动换券", "exchange", "/api/auto_exchange"),
        ], spacing: 6)
        row.distribution = .fillEqually
        return row
    }

    @objc private func autoChanged(_ sender: UISwitch) {
        guard let parts = sender.accessibilityIdentifier?.components(separatedBy: "|"),
              parts.count == 3 else { return }
        let phone = parts[0], path = parts[1], key = parts[2]
        let want = sender.isOn
        tap()
        Net.callPanel(path, json: ["phone": phone, "on": want], timeout: 60) { [weak self] r in
            guard let self = self else { return }
            var ok = true
            var msg = ""
            switch r {
            case .failure(let e):
                ok = false; msg = e.localizedDescription
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                ok = (d["ok"] as? Bool) ?? false
                msg = (d["msg"] as? String) ?? ""
            }
            if ok {
                if let i = self.items.firstIndex(where: { ($0["phone"] as? String) == phone }) {
                    var sw = (self.items[i]["switches"] as? [String: Any]) ?? [:]
                    sw[key] = want
                    self.items[i]["switches"] = sw
                }
            } else {
                sender.setOn(!want, animated: true)
                self.alert(title: "设置失败", message: msg.isEmpty ? "服务端没有确认" : msg)
            }
        }
    }

    private func ageLine(_ age: Int?, err: String) -> UIView {
        let t = Theme.label(age == nil ? "凭证：未知" : "凭证：已用 \(age! / 60) 小时",
                            size: 12, color: Theme.dim)
        if err.isEmpty { return t }
        let e = Theme.label("✗ " + err, size: 12, color: Theme.red, lines: 3)
        return Theme.vstack([t, e], spacing: 4)
    }

    // MARK: - 手势

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 点到卡片里的开关/按钮时，不要让卡片跟着展开/收起
        return !(touch.view is UIControl)
    }

    @objc private func toggle(_ g: UITapGestureRecognizer) {
        guard let v = g.view, v.tag >= 0, v.tag < items.count else { return }
        let phone = (items[v.tag]["phone"] as? String) ?? ""
        tap()
        if expanded.contains(phone) { expanded.remove(phone) } else { expanded.insert(phone) }
        UIView.transition(with: scroll, duration: 0.22, options: .transitionCrossDissolve) {
            self.render()
        }
    }

    private var toastView: UIView?

    /// 顶部小气泡：刷新成功/失败给个明确反馈
    private func toast(_ text: String, ok: Bool = true) {
        toastView?.removeFromSuperview()
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = ok ? UIColor(hex: 0x1C2A3A) : Theme.red
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = 1
        container.layer.borderColor = (ok ? Theme.line : UIColor.clear).cgColor

        let l = Theme.label(text, size: 13, weight: .semibold, color: ok ? Theme.text : .white)
        l.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            l.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            l.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            l.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            container.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])

        container.alpha = 0
        container.transform = CGAffineTransform(translationX: 0, y: -12)
        UIView.animate(withDuration: 0.22) {
            container.alpha = 1
            container.transform = .identity
        }
        toastView = container
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            UIView.animate(withDuration: 0.3, animations: {
                container.alpha = 0
                container.transform = CGAffineTransform(translationX: 0, y: -12)
            }) { _ in
                if self?.toastView === container { container.removeFromSuperview() }
            }
        }
    }

    private func alert(title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
}
