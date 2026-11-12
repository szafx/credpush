import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    static weak var shared: AppDelegate?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashLogger.install()
        LiveProgress.shared.endAll()      // 清掉上次崩溃残留的灵动岛卡片

        let w = UIWindow(frame: UIScreen.main.bounds)
        AppDelegate.shared = self
        w.overrideUserInterfaceStyle = Theme.uiStyle
        w.rootViewController = AppDelegate.makeRoot()
        w.makeKeyAndVisible()
        window = w
        // 冷启动时如果是被 creddaemon 的 credpush://pull 拉起来的
        if let u = launchOptions?[.url] as? URL, PullRequest.handle(u) {
            // 冷启动就是被 daemon 拉起来的：推完要把用户送回中国移动
            PullRequest.returnToChinaMobile = true
            (w.rootViewController as? UITabBarController)?.selectedIndex = 1
        }
        return true
    }

    /// 越狱看门狗（creddaemon）拉起：credpush://pull?c=<容器id>
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard PullRequest.handle(url) else { return false }
        // 只有「本来不在前台、被 URL 拉起来」才在推完后送回中国移动；
        // 用户本来就在用移动工具集时不要把他拽走
        PullRequest.returnToChinaMobile = (app.applicationState != .active)
        (window?.rootViewController as? UITabBarController)?.selectedIndex = 1
        return true
    }

    /// 构建四个 tab（外观切换时会整棵重建）
    static func makeRoot() -> UITabBarController {
        let accounts = UINavigationController(rootViewController: AccountsViewController())
        accounts.tabBarItem = UITabBarItem(title: "账号",
                                           image: UIImage(systemName: "person.2.fill"), tag: 0)

        let cred = UINavigationController(rootViewController: CredViewController())
        cred.tabBarItem = UITabBarItem(title: "凭证",
                                       image: UIImage(systemName: "key.fill"), tag: 1)

        let activity = UINavigationController(rootViewController: ActivityViewController())
        activity.tabBarItem = UITabBarItem(title: "动态",
                                           image: UIImage(systemName: "waveform.path.ecg"), tag: 2)

        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.tabBarItem = UITabBarItem(title: "设置",
                                           image: UIImage(systemName: "gearshape.fill"), tag: 3)

        let tabs = UITabBarController()
        tabs.viewControllers = [accounts, cred, activity, settings]

        // 全局外观
        let bg = Theme.bg
        let text = Theme.text
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.card
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                     appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = Theme.muted
            item.normal.titleTextAttributes = [.foregroundColor: Theme.muted]
            item.selected.iconColor = Theme.cyan
            item.selected.titleTextAttributes = [.foregroundColor: Theme.cyan]
        }
        tabs.tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) { tabs.tabBar.scrollEdgeAppearance = appearance }

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.titleTextAttributes = [.foregroundColor: text]
        nav.largeTitleTextAttributes = [.foregroundColor: text]
        for c in [accounts, cred, activity, settings] {
            c.navigationBar.standardAppearance = nav
            c.navigationBar.scrollEdgeAppearance = nav
            c.navigationBar.compactAppearance = nav
            c.navigationBar.tintColor = Theme.cyan
        }

        // 预热内置 Tailscale（没配授权码会立刻返回）
        Tsnet.shared.startIfNeeded()
        return tabs
    }

    /// 切换外观后重建整个界面
    func rebuildUI() {
        guard let w = window else { return }
        w.overrideUserInterfaceStyle = Theme.uiStyle
        w.rootViewController = AppDelegate.makeRoot()
        if let root = w.rootViewController?.view {
            root.alpha = 0
            UIView.animate(withDuration: 0.22) { root.alpha = 1 }
        }
    }

    // 每次回到前台都查一次（内部有节流；「稍后」的版本 6 小时内不再弹）
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard let root = window?.rootViewController else { return }
        NotificationCenter.default.post(name: Notification.Name("AppBecameActive"), object: nil)
        if !didUploadCrashes {
            didUploadCrashes = true
            CrashLogger.uploadPending()
        }
        let now = Date().timeIntervalSince1970
        if now - lastUpdateCheck < 60 { return }
        lastUpdateCheck = now
        UpdateChecker.check(in: root)
    }

    private var lastUpdateCheck: TimeInterval = 0
    private var didUploadCrashes = false
}
