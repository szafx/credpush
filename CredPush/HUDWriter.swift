import Foundation

/// 把浮窗进度写进共享的 NSUserDefaults 域，交给越狱 tweak（CredHUD）显示。
///
/// 为什么不用裸 JSON 文件：SpringBoard 的沙盒**读不了** `/var/mobile/Library/Preferences/`
/// 下的任意新文件（实测 `NSData dataWithContentsOfFile:` 返回 nil）。而 `NSUserDefaults`
/// 走 cfprefsd，App 和 SpringBoard 都能正常读写同一个域 —— 这也是 iOS 上跨进程传状态的标准做法。
///
/// 域：`com.szafx.credhud`
/// 只在**换步**时写；计时由 tweak 自己按 `startedAt` 走。
enum HUDWriter {
    static let suiteName = "com.szafx.credhud"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func update(title: String,
                       step: Int,
                       total: Int,
                       short: String,
                       detail: String,
                       startedAt: Date) {
        let d = defaults
        d.set(true, forKey: "visible")
        d.set(title, forKey: "title")
        d.set(step, forKey: "step")
        d.set(total, forKey: "total")
        d.set(short, forKey: "short")
        d.set(detail, forKey: "detail")
        d.set(startedAt.timeIntervalSince1970, forKey: "startedAt")
        // ★ 带上自己的 pid：tweak 用它判断「调用方还在不在」——
        //   App 被强制关闭/崩溃后浮窗要自动收掉
        d.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: "pid")
        d.synchronize()
    }

    static func hide() {
        let d = defaults
        d.set(false, forKey: "visible")
        d.synchronize()
    }
}
