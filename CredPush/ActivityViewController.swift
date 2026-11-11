import UIKit

/// 动态：诊断（容器权限 / 线路测速 / 服务器健康）+ 余额历史 + 日志
final class ActivityViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let out = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        title = "动态"

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
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

        stack.addArrangedSubview(Theme.label("DIAGNOSTICS", size: 11, weight: .semibold, color: Theme.dim))
        stack.addArrangedSubview(Theme.label("诊断", size: 28, weight: .bold))
        stack.addArrangedSubview(diagCard())
        stack.addArrangedSubview(historyCard())
        stack.addArrangedSubview(logCard())
    }

    // MARK: - 诊断

    private func diagCard() -> UIView {
        let v = Theme.card(16)
        let t = Theme.label("一键自检", size: 12, color: Theme.dim)
        let b1 = Theme.roundedButton("容器权限", color: Theme.cyan, target: self, action: #selector(testScan))
        let b2 = Theme.roundedButton("线路测速", color: Theme.amber, target: self, action: #selector(testRoutes))
        let b3 = Theme.roundedButton("服务器健康", color: Theme.green, target: self, action: #selector(testHealth))
        let b4 = Theme.roundedButton("Crane 检测", color: Theme.cyan, target: self, action: #selector(testCrane))
        let row = Theme.hstack([b1, b2, b3], spacing: 8)
        row.distribution = .fillEqually
        let row2 = Theme.hstack([b4], spacing: 8)

        out.backgroundColor = UIColor(hex: 0x070B11)
        // ★ 底色固定是深色，文字也不能跟着主题变（浅色模式的 Theme.muted 在近黑底上只有 3.8:1）。
        out.textColor = UIColor(hex: 0x9FB2C8)
        out.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        out.isEditable = false
        out.layer.cornerRadius = 12
        out.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        out.text = "点上面任意一个按钮开始…"
        out.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        out.translatesAutoresizingMaskIntoConstraints = false

        let col = Theme.vstack([t, row, row2, out], spacing: 10)
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

    private func say(_ s: String) {
        out.text += (out.text.isEmpty ? "" : "\n") + s
        let end = NSRange(location: (out.text as NSString).length, length: 0)
        out.scrollRangeToVisible(end)
    }

    @objc private func testScan() {
        out.text = "== 容器权限自检 =="
        let (sessions, lines) = Scanner.harvest()
        for l in lines.prefix(12) { say(l) }
        say(sessions.isEmpty ? "✗ 没读到会话（权限或 App 未登录）"
                             : "✓ 读到 \(sessions.count) 条会话")
    }

    @objc private func testRoutes() {
        out.text = "== 线路测速（/api/auth）=="
        let bases = Cfg.bases()
        say("候选：\(bases.count) 条")
        func step(_ i: Int) {
            guard i < bases.count else { say("完成"); return }
            let t0 = Date()
            Net.call(bases[i] + "/api/auth", method: "POST",
                     json: ["password": Cfg.password], timeout: 8) { [weak self] r in
                guard let self = self else { return }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                switch r {
                case .success: self.say("  \(bases[i])  \(ms)ms  ✓")
                case .failure: self.say("  \(bases[i])  \(ms)ms  ✗")
                }
                step(i + 1)
            }
        }
        step(0)
    }

    @objc private func testCrane() {
        out.text = "== Crane 检测 ==\u{0A}检测中…（在后台跑，不会卡界面）"
        AppLog.w("crane | 检测开始")
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            func add(_ t: String) { lines.append(t); AppLog.w("crane | " + t) }

            add("cranectl: " + (Crane.exists(Crane.cranectl) ? "存在 ✓" : "不存在 ✗"))
            add("uiopen:   " + (Crane.exists(Crane.uiopen) ? "存在 ✓" : "不存在 ✗"))
            add("defaults: " + (Crane.exists(Crane.defaultsBin) ? "存在 ✓" : "不存在 ✗"))
            add("jbroot: " + (Crane.jbrootPath.isEmpty ? "找不到" : Crane.jbrootPath))
            for pth in ["/usr/local/bin/cranectl", "/bin/ls",
                        "/var/containers/Bundle/Application"] {
                add("  " + pth + " exists=" + (FileManager.default.fileExists(atPath: pth) ? "1" : "0"))
            }
            // 区分「沙盒读不到」和「能读但执行不了」
            if let d = try? Data(contentsOf: URL(fileURLWithPath: Crane.cranectl)) {
                add("读 cranectl: ✓ " + String(d.count) + " 字节")
            } else {
                add("读 cranectl: ✗（沙盒不允许读）")
            }
            if let d = try? Data(contentsOf: URL(fileURLWithPath: "/var/mobile/Library/Preferences/com.opa334.craneprefs.plist")) {
                add("读 craneprefs: ✓ " + String(d.count) + " 字节")
            } else {
                add("读 craneprefs: ✗")
            }
            if Crane.available() {
                let (rc, text) = Crane.run(Crane.cranectl, ["--list", Crane.appBundle], timeout: 8)
                add("cranectl --list rc=\(rc)")
                for line in text.components(separatedBy: "\u{0A}").prefix(8) { add("  " + line) }
                if text.isEmpty { add("  （没有输出）") }
                let active = Crane.activeContainerID()
                add("当前容器: " + (active.isEmpty ? "读不到" : String(active.prefix(8)) + "…"))
                add("中国移动运行中: " + (Crane.chinaMobilePid() > 0 ? "是" : "否"))
            } else {
                add("→ 这台设备没有越狱工具（或沙盒不让访问 /usr/local/bin）")
                add("扫描/推送仍可用；切容器/自动拉起不可用")
            }
            DispatchQueue.main.async {
                self.out.text = lines.joined(separator: "\u{0A}")
                let end = NSRange(location: (self.out.text as NSString).length, length: 0)
                self.out.scrollRangeToVisible(end)
            }
        }
    }

    @objc private func testHealth() {
        out.text = "== 服务器健康 =="
        Net.callPanel("/api/health", json: [:], timeout: 60) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .failure(let e):
                self.say("✗ \(e.localizedDescription)")
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                let rows = d["accounts"] as? [[String: Any]] ?? []
                self.say("时间 \(d["t"] as? String ?? "?")，\(rows.count) 个号")
                for a in rows {
                    let ph = (a["phone"] as? String) ?? "?"
                    let age = Num.int(a["jwt_age_min"])
                    let lr = a["last_renew"] as? [String: Any]
                    let ok = (lr?["ok"] as? Bool) ?? false
                    let when = (lr?["t"] as? String) ?? "—"
                    self.say("\(ph.prefix(3))****\(ph.suffix(4))  凭证 \(age.map { "\($0 / 60)h" } ?? "?")  "
                             + (ok ? "✓" : "✗") + "  \(when)")
                }
            }
        }
    }

    // MARK: - 历史

    private func historyCard() -> UIView {
        let v = Theme.card(16)
        let t = Theme.label("余额变化（最近 30 条）", size: 12, color: Theme.dim)
        let text = UITextView()
        text.backgroundColor = .clear
        text.textColor = Theme.muted
        text.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.isEditable = false
        text.text = "点右上角「刷新」拉取…"
        text.translatesAutoresizingMaskIntoConstraints = false
        text.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        text.tag = 100
        let btn = Theme.roundedButton("拉取历史", color: Theme.cardHi, target: self, action: #selector(loadHistory))
        btn.setTitleColor(Theme.textOn(Theme.cardHi), for: .normal)
        let col = Theme.vstack([t, text, btn], spacing: 8)
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

    @objc private func loadHistory() {
        Net.callPanel("/api/history", json: ["limit": 30], timeout: 60) { [weak self] r in
            guard let self = self, let v = self.view.viewWithTag(100) as? UITextView else { return }
            switch r {
            case .failure(let e):
                v.text = "✗ \(e.localizedDescription)"
            case .success(let obj):
                let d = obj as? [String: Any] ?? [:]
                let items = d["items"] as? [[String: Any]] ?? []
                if items.isEmpty { v.text = "还没有历史（多刷新几次账号页就会有）"; return }
                v.text = items.map {
                    "\(($0["t"] as? String) ?? "")  \(((($0["phone"] as? String) ?? "").suffix(4)))  \((Num.int($0["balance"])) ?? 0)"
                }.joined(separator: "\n")
            }
        }
    }

    // MARK: - 日志

    private func logCard() -> UIView {
        let v = Theme.card(16)
        let t = Theme.label("运行日志", size: 12, color: Theme.dim)
        let text = UITextView()
        text.backgroundColor = UIColor(hex: 0x070B11)
        // 同上：固定深色底 → 用固定的浅色字，别跟主题走
        text.textColor = UIColor(hex: 0x8FA3BA)
        text.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = false
        text.text = LocalStore.logTail(60)
        text.layer.cornerRadius = 12
        text.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let btn = Theme.roundedButton("导出日志", color: Theme.cardHi, target: self, action: #selector(exportLog))
        btn.setTitleColor(Theme.textOn(Theme.cardHi), for: .normal)
        let col = Theme.vstack([t, text, btn], spacing: 8)
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

    @objc private func exportLog() {
        let items = [LocalStore.logPath]
        let a = UIActivityViewController(activityItems: items, applicationActivities: nil)
        present(a, animated: true)
    }
}
