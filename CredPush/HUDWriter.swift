import Foundation

/// 把浮窗进度写到共享文件，交给越狱 tweak（CredHUD）显示。
///
/// 路径：`/var/mobile/Library/Preferences/credpush_hud.json`
/// * App 已有 `no-sandbox` + `/var/mobile/Library/` 读写权限（见 project.yml）
/// * 没装 tweak 时写文件也无害（没人读）
/// * **只在换步时写**；计时由 tweak 自己按 `startedAt` 走，不需要每秒写文件
enum HUDWriter {
    static let path = "/var/mobile/Library/Preferences/credpush_hud.json"

    static func update(title: String,
                       step: Int,
                       total: Int,
                       short: String,
                       detail: String,
                       startedAt: Date) {
        let d: [String: Any] = [
            "visible": true,
            "title": title,
            "step": step,
            "total": total,
            "short": short,
            "detail": detail,
            "startedAt": startedAt.timeIntervalSince1970,
        ]
        write(d)
    }

    static func hide() {
        write(["visible": false])
    }

    private static func write(_ d: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
