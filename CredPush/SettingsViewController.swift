import UIKit

/// 设置：服务器地址 / 面板密码 / 推送令牌 / 自动扫描
final class SettingsViewController: UIViewController {
    private let baseField = SettingsViewController.field("https://ydhf.szafx.icu")
    private let altField = SettingsViewController.field("http://100.98.108.55:8900")
    private let ipv6Field = SettingsViewController.field("http://[240e:…]:8900（可留空）")
    private let tsKeyField = SettingsViewController.field("tskey-auth-…（内置 Tailscale）", secure: true)
    private let tsStatus = Theme.label("", size: 11, color: Theme.dim, lines: 2)
    private let passField = SettingsViewController.field("面板密码", secure: true)
    private let tokenField = SettingsViewController.field("推送令牌", secure: true)
    private let autoSwitch = UISwitch()
    private let saved = Theme.label("", size: 12, color: Theme.green)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        title = "设置"

        baseField.text = Cfg.base
        altField.text = Cfg.altBase
        ipv6Field.text = Cfg.ipv6Base
        tsKeyField.text = Cfg.tsAuthKey
        passField.text = Cfg.password
        tokenField.text = Cfg.pushToken
        autoSwitch.isOn = Cfg.autoScan
        autoSwitch.onTintColor = Theme.cyan

        let eyebrow = Theme.label("SETTINGS", size: 11, weight: .semibold, color: Theme.dim)
        let head = Theme.label("连接与令牌", size: 28, weight: .bold)
        let desc = Theme.label("面板密码和网页版同一个；推送令牌是服务器上的 cred_push.token。",
                               size: 13, color: Theme.muted, lines: 0)

        // 外观：深色 / 浅色 / 黑白
        let appearanceCard = Theme.card(16)
        let seg = UISegmentedControl(items: ThemeMode.allCases.map { $0.title })
        seg.selectedSegmentIndex = ThemeMode.allCases.firstIndex(of: Theme.mode) ?? 0
        seg.selectedSegmentTintColor = Theme.cyan
        seg.setTitleTextAttributes([.foregroundColor: Theme.textOn(Theme.cyan)], for: .selected)
        seg.setTitleTextAttributes([.foregroundColor: Theme.muted], for: .normal)
        seg.addTarget(self, action: #selector(themeChanged(_:)), for: .valueChanged)
        let apTitle = Theme.label("外观", size: 12, color: Theme.dim)
        let apNote = Theme.label("换外观会重建界面（当前页会刷新）", size: 10, color: Theme.dim, lines: 1)
        let apCol = Theme.vstack([apTitle, seg, apNote], spacing: 8)
        appearanceCard.addSubview(apCol)
        apCol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            apCol.topAnchor.constraint(equalTo: appearanceCard.layoutMarginsGuide.topAnchor),
            apCol.bottomAnchor.constraint(equalTo: appearanceCard.layoutMarginsGuide.bottomAnchor),
            apCol.leadingAnchor.constraint(equalTo: appearanceCard.layoutMarginsGuide.leadingAnchor),
            apCol.trailingAnchor.constraint(equalTo: appearanceCard.layoutMarginsGuide.trailingAnchor),
        ])

        let serverCard = Theme.card(16)
        let serverCol = Theme.vstack([
            fieldRow("服务器", baseField),
            fieldRow("IPv6 直连", ipv6Field),
            fieldRow("备用地址", altField),
            fieldRow("TS 授权码", tsKeyField),
            fieldRow("面板密码", passField),
            fieldRow("推送令牌", tokenField),
        ], spacing: 12)
        serverCard.addSubview(serverCol)
        serverCol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            serverCol.topAnchor.constraint(equalTo: serverCard.layoutMarginsGuide.topAnchor),
            serverCol.bottomAnchor.constraint(equalTo: serverCard.layoutMarginsGuide.bottomAnchor),
            serverCol.leadingAnchor.constraint(equalTo: serverCard.layoutMarginsGuide.leadingAnchor),
            serverCol.trailingAnchor.constraint(equalTo: serverCard.layoutMarginsGuide.trailingAnchor),
        ])

        let routeCard = Theme.card(16)
        let routeTitle = Theme.label("线路（开几个就按顺序试几个）", size: 12, color: Theme.dim)
        func routeRow(_ title: String, _ key: String, _ detail: String, _ sw: UISwitch) -> UIView {
            let t = Theme.label(title, size: 14, weight: .medium)
            let d = Theme.label(detail, size: 10, color: Theme.dim, lines: 1)
            let left = Theme.vstack([t, d], spacing: 2)
            sw.onTintColor = Theme.cyan
            switch key {
            case "useIPv6": sw.isOn = Cfg.useIPv6
            case "useTsnet": sw.isOn = Cfg.useTsnet
            case "useAlt": sw.isOn = Cfg.useAlt
            case "useCf": sw.isOn = Cfg.useCf
            default: sw.isOn = true
            }
            sw.accessibilityIdentifier = key
            sw.addTarget(self, action: #selector(routeChanged(_:)), for: .valueChanged)
            return Theme.hstack([left, Theme.spacer(), sw], spacing: 12)
        }
        let routeCol = Theme.vstack([
            routeTitle,
            routeRow("IPv6 直连", "useIPv6", "填了地址才生效；最快，不占通道", UISwitch()),
            routeRow("内置 Tailscale", "useTsnet", "App 内置 tsnet，不需要系统 VPN", UISwitch()),
            routeRow("备用地址", "useAlt", "系统 Tailscale 的 http://100.98.108.55:8900", UISwitch()),
            routeRow("Cloudflare", "useCf", "ydhf.szafx.icu，最慢但最省心", UISwitch()),
        ], spacing: 10)
        routeCard.addSubview(routeCol)
        routeCol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            routeCol.topAnchor.constraint(equalTo: routeCard.layoutMarginsGuide.topAnchor),
            routeCol.bottomAnchor.constraint(equalTo: routeCard.layoutMarginsGuide.bottomAnchor),
            routeCol.leadingAnchor.constraint(equalTo: routeCard.layoutMarginsGuide.leadingAnchor),
            routeCol.trailingAnchor.constraint(equalTo: routeCard.layoutMarginsGuide.trailingAnchor),
        ])

        let autoCard = Theme.card(16)
        let autoTitle = Theme.label("打开「凭证」页时自动扫描", size: 14, weight: .medium)
        let autoSub = Theme.label("关掉后只能手动点按钮", size: 11, color: Theme.dim)
        let autoLeft = Theme.vstack([autoTitle, autoSub], spacing: 2)
        let autoRow = Theme.hstack([autoLeft, Theme.spacer(), autoSwitch], spacing: 12)
        autoCard.addSubview(autoRow)
        autoRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            autoRow.topAnchor.constraint(equalTo: autoCard.layoutMarginsGuide.topAnchor),
            autoRow.bottomAnchor.constraint(equalTo: autoCard.layoutMarginsGuide.bottomAnchor),
            autoRow.leadingAnchor.constraint(equalTo: autoCard.layoutMarginsGuide.leadingAnchor),
            autoRow.trailingAnchor.constraint(equalTo: autoCard.layoutMarginsGuide.trailingAnchor),
        ])

        let moreCard = Theme.card(16)
        func moreBtn(_ title: String, _ sel: Selector) -> UIButton {
            let b = Theme.roundedButton(title, color: Theme.cardHi, target: self, action: sel)
            b.setTitleColor(Theme.text, for: .normal)
            return b
        }
        let moreCol = Theme.vstack([
            Theme.label("其它", size: 12, color: Theme.dim),
            moreBtn("帮助与说明", #selector(openHelp)),
            moreBtn("检查更新", #selector(checkUpdate)),
            moreBtn("导出日志", #selector(exportLog)),
            Theme.label("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
                        + " (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))",
                        size: 11, color: Theme.dim),
        ], spacing: 8)
        moreCard.addSubview(moreCol)
        moreCol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            moreCol.topAnchor.constraint(equalTo: moreCard.layoutMarginsGuide.topAnchor),
            moreCol.bottomAnchor.constraint(equalTo: moreCard.layoutMarginsGuide.bottomAnchor),
            moreCol.leadingAnchor.constraint(equalTo: moreCard.layoutMarginsGuide.leadingAnchor),
            moreCol.trailingAnchor.constraint(equalTo: moreCard.layoutMarginsGuide.trailingAnchor),
        ])

        let save = UIButton(type: .system)
        save.setTitle("保存", for: .normal)
        save.titleLabel?.font = Theme.rounded(16, .semibold)
        save.setTitleColor(Theme.textOn(Theme.cyan), for: .normal)
        save.backgroundColor = Theme.cyan
        save.layer.cornerRadius = 14
        save.layer.cornerCurve = .continuous
        save.heightAnchor.constraint(equalToConstant: 50).isActive = true
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let about = Theme.label("凭证助手 1.0 · 只在这台越狱设备上用\n"
                                + "扫描范围：/var/mobile/Containers/Data/Application 下 cn.10086.app 的容器（含 Crane 分身）",
                                size: 11, color: Theme.dim, lines: 0)

        tsStatus.text = "内置 Tailscale：" + Tsnet.shared.status
        let col = Theme.vstack([eyebrow, head, desc, appearanceCard, serverCard, routeCard, tsStatus, autoCard,
                                moreCard, save, saved, about], spacing: 12)
        col.setCustomSpacing(6, after: head)
        col.setCustomSpacing(18, after: desc)
        col.setCustomSpacing(20, after: autoCard)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .onDrag
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        col.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(col)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            col.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            col.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            col.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            col.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        scroll.addGestureRecognizer(tap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tsStatus.text = "内置 Tailscale：" + Tsnet.shared.status
        if !Cfg.tsAuthKey.isEmpty {
            Tsnet.shared.startIfNeeded { [weak self] in
                self?.tsStatus.text = "内置 Tailscale：" + Tsnet.shared.status
            }
        }
    }

    @objc private func routeChanged(_ sw: UISwitch) {
        guard let key = sw.accessibilityIdentifier else { return }
        UserDefaults.standard.set(sw.isOn, forKey: key)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if key == "useTsnet" && sw.isOn && !Cfg.tsAuthKey.isEmpty {
            Tsnet.shared.startIfNeeded { [weak self] in
                self?.tsStatus.text = "内置 Tailscale：" + Tsnet.shared.status
            }
        }
        tsStatus.text = "内置 Tailscale：" + Tsnet.shared.status
    }

    @objc private func themeChanged(_ seg: UISegmentedControl) {
        let modes = ThemeMode.allCases
        guard seg.selectedSegmentIndex >= 0, seg.selectedSegmentIndex < modes.count else { return }
        Theme.mode = modes[seg.selectedSegmentIndex]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AppDelegate.shared?.rebuildUI()
    }

    @objc private func openHelp() {
        navigationController?.pushViewController(HelpViewController(), animated: true)
    }

    @objc private func checkUpdate() {
        saved.text = "正在检查更新…"
        saved.alpha = 1
        UpdateChecker.check(in: self) { [weak self] msg in
            guard let self = self else { return }
            self.saved.text = msg
            self.saved.alpha = 1
            if msg.hasPrefix("检查失败") {
                self.alert("检查更新失败", msg)
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    @objc private func exportLog() {
        let a = UIActivityViewController(activityItems: [LocalStore.logPath], applicationActivities: nil)
        present(a, animated: true)
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    @objc private func saveTapped() {
        view.endEditing(true)
        var base = (baseField.text ?? "").trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "https://ydhf.szafx.icu" }
        while base.hasSuffix("/") { base.removeLast() }
        Cfg.base = base
        Cfg.ipv6Base = (ipv6Field.text ?? "").trimmingCharacters(in: .whitespaces)
        Cfg.altBase = (altField.text ?? "").trimmingCharacters(in: .whitespaces)
        let oldKey = Cfg.tsAuthKey
        Cfg.tsAuthKey = (tsKeyField.text ?? "").trimmingCharacters(in: .whitespaces)
        if Cfg.tsAuthKey != oldKey { Tsnet.shared.restart() }
        Cfg.password = (passField.text ?? "").trimmingCharacters(in: .whitespaces)
        Cfg.pushToken = (tokenField.text ?? "").trimmingCharacters(in: .whitespaces)
        Cfg.autoScan = autoSwitch.isOn
        Net.clearCookies()          // 密码可能换了，旧 cookie 作废
        saved.text = "已保存（回「账号」下拉刷新）"
        saved.alpha = 1
        UIView.animate(withDuration: 1.6, delay: 1.2, options: [], animations: {
            self.saved.alpha = 0
        }, completion: nil)
    }

    // MARK: - 小组件

    private func fieldRow(_ title: String, _ field: UITextField) -> UIView {
        let t = Theme.label(title, size: 12, color: Theme.dim)
        t.widthAnchor.constraint(equalToConstant: 68).isActive = true
        return Theme.hstack([t, field], spacing: 10)
    }

    static func field(_ placeholder: String, secure: Bool = false) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder
        f.isSecureTextEntry = secure
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.keyboardType = .URL
        f.textColor = Theme.text
        f.font = Theme.mono(14)
        f.backgroundColor = Theme.cardHi
        f.layer.cornerRadius = 10
        f.layer.borderWidth = 1
        f.layer.borderColor = Theme.line.cgColor
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        f.leftViewMode = .always
        f.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return f
    }
}
