import UIKit

/// 单号详情：任务 / 券 / 开关 / 凭证，以及「立即续期」「删除账号」
final class AccountDetailViewController: UIViewController {
    private let phone: String
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var item: [String: Any] = [:]
    private var busy = false

    init(phone: String) {
        self.phone = phone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        title = phone.count >= 7 ? "\(phone.prefix(3)) **** \(phone.suffix(4))" : phone
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "刷新", style: .plain,
                                                            target: self, action: #selector(load))
        navigationItem.rightBarButtonItem?.tintColor = Theme.cyan

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.refreshControl = UIRefreshControl()
        scroll.refreshControl?.tintColor = Theme.cyan
        scroll.refreshControl?.addTarget(self, action: #selector(load), for: .valueChanged)
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

        renderLoading()
        load()
    }

    @objc private func load() {
        guard !busy else { return }
        busy = true
        Net.callPanel("/api/account/detail", json: ["phone": phone], timeout: 180) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            self.scroll.refreshControl?.endRefreshing()
            switch r {
            case .failure(let e):
                self.renderError(e.localizedDescription)
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                if let it = d["item"] as? [String: Any] {
                    self.item = it
                    self.render()
                } else {
                    self.renderError((d["msg"] as? String) ?? "没有数据")
                }
            }
        }
    }

    // MARK: - 渲染

    private func renderLoading() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(Theme.label("读取中…", size: 13, color: Theme.dim))
    }

    private func renderError(_ msg: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let v = Theme.card(16)
        let t = Theme.label("读取失败", size: 15, weight: .semibold, color: Theme.red)
        let d = Theme.label(msg, size: 12, color: Theme.muted, lines: 0)
        let s = Theme.vstack([t, d], spacing: 6)
        v.addSubview(s)
        s.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            s.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            s.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        stack.addArrangedSubview(v)
    }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(overviewCard())
        stack.addArrangedSubview(switchesCard())
        stack.addArrangedSubview(tasksCard())
        stack.addArrangedSubview(couponsCard())
        stack.addArrangedSubview(actionsCard())
    }

    private func overviewCard() -> UIView {
        let v = Theme.card(16)
        let bal = Num.int(item["balance"])
        let lastBal = Num.int(item["last_balance"])
        let beanText = bal.map { "\($0)" } ?? lastBal.map { "≈\($0)" } ?? "—"
        let bean = Theme.label(beanText, size: 34, weight: .bold,
                               color: bal != nil ? Theme.cyan : Theme.dim, mono: true)
        let done = Num.int(item["tasks_done"]), total = Num.int(item["tasks_total"])
        let pending = Num.int(item["pending"])
        let signed = item["signed"] as? Bool
        let acc = item["accumulate"]
        let age = Num.int(item["token_age_min"])
        let err = (item["err"] as? String) ?? ""

        var bits: [String] = []
        if let d = done, let t = total { bits.append("任务 \(d)/\(t)") }
        if let p = pending, p > 0 { bits.append("待领 \(p)") }
        if let s = signed { bits.append(s ? "今日已签" : "今日未签") }
        if let a = acc, !(a is NSNull) { bits.append("累计 \(a) 天") }
        let line1 = Theme.label(bits.joined(separator: " · "), size: 13, color: Theme.muted)
        let ageText = Theme.label(age.map { "凭证已用 \($0 / 60) 小时" } ?? "凭证未知",
                                  size: 12, color: Theme.dim)
        var rows: [UIView] = [Theme.label("AI豆", size: 11, color: Theme.dim), bean,
                              line1, ageText]
        if !err.isEmpty {
            rows.append(Theme.label("✗ " + err, size: 12, color: Theme.red, lines: 3))
        }
        let col = Theme.vstack(rows, spacing: 6)
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

    private func switchesCard() -> UIView {
        let v = Theme.card(16)
        let sw = (item["switches"] as? [String: Any]) ?? [:]
        let title = Theme.label("自动任务", size: 12, color: Theme.dim)
        func row(_ name: String, _ key: String, _ path: String) -> UIView {
            let l = Theme.label(name, size: 14, weight: .medium)
            let s = UISwitch()
            s.onTintColor = Theme.cyan
            s.isOn = (sw[key] as? Bool) ?? false
            s.accessibilityIdentifier = key + "|" + path
            s.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
            return Theme.hstack([l, Theme.spacer(), s], spacing: 12)
        }
        let col = Theme.vstack([title,
                                row("自动签到", "mark", "/api/auto_mark"),
                                row("自动领AI豆", "claim", "/api/auto_claim"),
                                row("自动换话费券", "exchange", "/api/auto_exchange")], spacing: 10)
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

    @objc private func toggled(_ s: UISwitch) {
        guard let parts = s.accessibilityIdentifier?.components(separatedBy: "|"), parts.count == 2 else { return }
        let want = s.isOn
        Net.callPanel(parts[1], json: ["phone": phone, "on": want], timeout: 60) { [weak self] r in
            guard let self = self else { return }
            var ok = true
            var msg = ""
            switch r {
            case .failure(let e): ok = false; msg = e.localizedDescription
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                ok = (d["ok"] as? Bool) ?? false
                msg = (d["msg"] as? String) ?? ""
            }
            if !ok {
                s.setOn(!want, animated: true)
                self.alert("设置失败", msg.isEmpty ? "服务端没有确认" : msg)
            }
        }
    }

    private func tasksCard() -> UIView {
        let v = Theme.card(16)
        let tasks = (item["tasks"] as? [[String: Any]]) ?? []
        var rows: [UIView] = [Theme.label("任务（\(tasks.count)）", size: 12, color: Theme.dim)]
        if tasks.isEmpty {
            rows.append(Theme.label(item["detail_err"].map { "读不到任务：\($0)" } ?? "没有任务",
                                    size: 12, color: Theme.dim, lines: 2))
        } else {
            // 先列待领、再列未做，已完成的折叠成一行
            let pending = tasks.filter { (($0["status"] as? String) == "1") }
            let todo = tasks.filter { (($0["status"] as? String) == "0") }
            let doneN = tasks.count - pending.count - todo.count
            for t in pending {
                rows.append(taskRow(t, tag: "待领", color: Theme.amber))
            }
            for t in todo.prefix(20) {
                rows.append(taskRow(t, tag: "未做", color: Theme.dim))
            }
            if todo.count > 20 {
                rows.append(Theme.label("…还有 \(todo.count - 20) 个未做", size: 11, color: Theme.dim))
            }
            if doneN > 0 {
                rows.append(Theme.label("已完成 \(doneN) 个", size: 11, color: Theme.green))
            }
        }
        let col = Theme.vstack(rows, spacing: 6)
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

    private func taskRow(_ t: [String: Any], tag: String, color: UIColor) -> UIView {
        let name = (t["name"] as? String) ?? "?"
        let l = Theme.label(name, size: 12.5, color: Theme.text, lines: 2)
        let p = Theme.pill(tag, color: color)
        return Theme.hstack([l, Theme.spacer(), p], spacing: 8)
    }

    private func couponsCard() -> UIView {
        let v = Theme.card(16)
        let cs = (item["coupons"] as? [[String: Any]]) ?? []
        var rows: [UIView] = [Theme.label("我的卡券（共 \(cs.count) 张）· 点「兑换」可在这台手机上用掉",
                                          size: 12, color: Theme.dim, lines: 2)]
        if cs.isEmpty {
            rows.append(Theme.label("没有券", size: 12, color: Theme.dim))
        } else {
            // 按「名字 + 到期」合并显示，但保留**第一条**（带券号）用于兑换
            var order: [String] = []
            var groups: [String: (name: String, kind: String, days: Int?, n: Int, first: [String: Any])] = [:]
            for c in cs {
                let name = (c["name"] as? String) ?? "券"
                let exp = (c["expireAt"] as? String) ?? ""
                let kind = (c["kind"] as? String)
                    ?? ((c["cat"] as? String) == "FLOW" ? "流量券" : "话费券")
                let days = Num.int(c["daysLeft"])
                let k = name + "|" + exp
                if var g = groups[k] {
                    g.n += 1
                    groups[k] = g
                } else {
                    order.append(k)
                    groups[k] = (name, kind, days, 1, c)
                }
            }
            let sorted = order.sorted { (groups[$0]!.days ?? 999) < (groups[$1]!.days ?? 999) }
            for k in sorted {
                guard let g = groups[k] else { continue }
                let left = Theme.label("\(g.kind) · \(g.name)" + (g.n > 1 ? " ×\(g.n)" : ""),
                                       size: 12.5, color: Theme.text, lines: 1)
                let right = Theme.label(g.days.map { "剩 \($0) 天" } ?? "—", size: 11,
                                        color: (g.days ?? 99) <= 3 ? Theme.red : Theme.dim,
                                        mono: true)
                right.setContentHuggingPriority(.required, for: .horizontal)
                let btn = UIButton(type: .system)
                btn.setTitle("兑换", for: .normal)
                btn.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
                btn.tintColor = Theme.cyan
                btn.setContentHuggingPriority(.required, for: .horizontal)
                let no = (g.first["no"] as? String) ?? ""
                let nm = g.name
                btn.addAction(UIAction { [weak self] _ in self?.beginUse(no: no, name: nm) },
                              for: .touchUpInside)
                rows.append(Theme.hstack([left, Theme.spacer(), right, btn], spacing: 8))
            }
        }
        let col = Theme.vstack(rows, spacing: 6)
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


    // MARK: - 用券（走面板的 /api/coupon/*，不碰 App 自己那条会话）

    private func beginUse(no: String, name: String) {
        guard !no.isEmpty else { alert("不能兑换", "这张券没有券号"); return }
        let a = UIAlertController(
            title: name,
            message: "用掉这张券？
会给 \(phone) 发一条短信验证码",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "发送验证码", style: .default) { [weak self] _ in
            self?.sendCouponCode(no: no, name: name)
        })
        present(a, animated: true)
    }

    private func sendCouponCode(no: String, name: String) {
        Net.callPanel("/api/coupon/send", json: ["phone": phone, "pcard_no": no], timeout: 90) {
            [weak self] r in
            guard let self = self else { return }
            switch r {
            case .failure(let e):
                self.alert("发送失败", e.localizedDescription)
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                if (d["ok"] as? Bool) == true {
                    self.askCouponCode(no: no, name: name)
                } else {
                    self.alert("发送失败", (d["msg"] as? String) ?? "未知错误")
                }
            }
        }
    }

    private func askCouponCode(no: String, name: String) {
        let a = UIAlertController(title: "输入验证码", message: "\(name)
短信已发到 \(phone)",
                                  preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = "短信验证码"
            tf.keyboardType = .numberPad
            tf.autocorrectionType = .no
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "提交", style: .default) { [weak self] _ in
            let code = (a.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.submitCoupon(no: no, name: name, code: code)
        })
        present(a, animated: true)
    }

    private func submitCoupon(no: String, name: String, code: String) {
        guard code.count >= 4 else { alert("验证码不对", "至少要 4 位"); return }
        Net.callPanel("/api/coupon/use",
                      json: ["phone": phone, "pcard_no": no, "code": code],
                      timeout: 150) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .failure(let e):
                self.alert("兑换失败", e.localizedDescription)
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                if (d["ok"] as? Bool) == true {
                    self.alert("✓ 兑换成功", "\(name) 已提交，24 小时内到账")
                    self.load()
                } else {
                    var m = (d["msg"] as? String) ?? "未知错误"
                    if let h = d["hint"] as? String, !h.isEmpty { m += "
" + h }
                    self.alert("兑换失败", m)
                }
            }
        }
    }

    private func alert(_ title: String, _ msg: String) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    private func actionsCard() -> UIView {
        let v = Theme.card(16)
        let renew = Theme.roundedButton("立即续期", color: Theme.cyan, target: self,
                                        action: #selector(doRenew))
        let del = Theme.roundedButton("删除这个号", color: Theme.red, target: self,
                                      action: #selector(doDelete))
        let col = Theme.vstack([renew, del], spacing: 10)
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

    @objc private func doRenew() {
        confirm("立即续期", "用现有凭据立刻续一次？") {
            Net.callPanel("/api/acc/renew", json: ["phone": self.phone], timeout: 120) { [weak self] r in
                guard let self = self else { return }
                var msg = ""
                switch r {
                case .failure(let e): msg = "失败：" + e.localizedDescription
                case .success(let obj):
                    let d = obj as? [String: Any] ?? [:]
                    msg = ((d["ok"] as? Bool) ?? false ? "✓ " : "✗ ") + ((d["msg"] as? String) ?? "")
                }
                self.alert("续期结果", msg)
                self.load()
            }
        }
    }

    @objc private func doDelete() {
        confirm("删除账号", "会删掉凭据文件并关掉三个自动开关，确定？") {
            Net.callPanel("/api/acc/delete", json: ["phone": self.phone], timeout: 60) { [weak self] r in
                guard let self = self else { return }
                var msg = ""
                switch r {
                case .failure(let e): msg = "失败：" + e.localizedDescription
                case .success(let obj):
                    let d = obj as? [String: Any] ?? [:]
                    msg = ((d["ok"] as? Bool) ?? false ? "✓ " : "✗ ") + ((d["msg"] as? String) ?? "")
                }
                self.alert("删除结果", msg)
                if msg.hasPrefix("✓") { self.navigationController?.popViewController(animated: true) }
            }
        }
    }

    private func confirm(_ title: String, _ msg: String, _ run: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "确定", style: .destructive) { _ in run() })
        present(a, animated: true)
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
}
