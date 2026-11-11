import UIKit

/// 帮助：把「掉线怎么恢复 / 每个开关什么意思」写进 App 里
final class HelpViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        title = "帮助"

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
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

        add("一句话", "这个 App 是「移动号自动化」的遥控器：账本和干活都在家里那台服务器上，App 负责看状态 + 在凭证掉线时把新的 App 会话推回去。")
        add("掉线了怎么办", "1. 手机上打开**那个号**的「中国移动」（Crane 分身里对应的那个），确认已登录\n2. 回 App →「凭证」→ 扫描\n3. 看列表里掉线号标了 ✓，点「推送」\n4. 服务器会换票认号并写回凭据，20 分钟内自动接上")
        add("为什么需要打开中国移动", "服务端一个手机号只保留**一份** App 会话。你在手机上冷启动/重登，我们的那份就失效了 —— 所以要重新从手机里把新会话取出来。")
        add("三个自动开关", "自动签到：每天把签到做了\n自动领AI豆：把「已完成待领」的奖励领掉，也会自动做拉得起 App 的任务\n自动换话费券：每天 8:00 抢 5 元券，平时攒豆、月底才降档")
        add("线路怎么选", "IPv6 直连：最快，但要家里放行端口\n内置 Tailscale：不占系统 VPN，推荐\n备用地址：系统 Tailscale（需要开着系统 App）\nCloudflare：最慢但最稳，兜底用\n开几个就按顺序试几个；只开一个就只走它。")
        add("扫描/推送分开", "扫描只读容器、不联网；推送才会把会话发给服务器。所以扫描可以放心点。")
        add("新账号", "扫描到服务端没登记过的号会弹窗问你要不要加入；加入后和其它号一样（面板显示、自动任务、每 20 分钟续期）。")
        add("日志在哪", "「动态」页可看可导出（Documents/credpush.log）。出问题先把日志发我。")
    }

    private func add(_ title: String, _ body: String) {
        let v = Theme.card(16)
        let t = Theme.label(title, size: 15, weight: .semibold)
        let b = Theme.label(body, size: 13, color: Theme.muted, lines: 0)
        let col = Theme.vstack([t, b], spacing: 6)
        v.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: v.layoutMarginsGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: v.layoutMarginsGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: v.layoutMarginsGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: v.layoutMarginsGuide.trailingAnchor),
        ])
        stack.addArrangedSubview(v)
    }
}
