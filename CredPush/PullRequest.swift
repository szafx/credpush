import Foundation

/// 越狱看门狗（creddaemon）用 `credpush://pull?c=<容器id>` 让 App 做一次补抓 + 推送。
/// 这样用户在中国移动里登录完成后，不用手动切回 App。
enum PullRequest {
    static let changed = Notification.Name("CredPullRequested")

    /// 待处理的容器 id（容器目录名，如 121753FF-…）。空 = 没有请求。
    private(set) static var pendingContainer: String = ""

    /// 这次 pull 是不是把 App 从后台/冷启动拉起来的？是的话推完要送回中国移动。
    static var returnToChinaMobile = false

    /// 处理一个 URL；不是我们的就返回 false。
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "credpush" else { return false }
        guard (url.host ?? "").lowercased() == "pull" else { return false }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value ?? ""
        pendingContainer = c
        AppLog.w("pull | 守护进程请求补抓 container=\(c.isEmpty ? "-" : c)")
        NotificationCenter.default.post(name: changed, object: nil)
        return true
    }

    /// 取走待处理的请求（只取一次）
    static func take() -> String {
        let c = pendingContainer
        pendingContainer = ""
        return c
    }
}
