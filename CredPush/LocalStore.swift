import Foundation
import UserNotifications

/// 本地缓存：账号快照 / 健康数据，断网也能看上次的状态
enum LocalStore {
    private static var docs: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
    }

    static func save(_ name: String, _ obj: Any) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: URL(fileURLWithPath: docs + "/" + name))
    }

    static func load(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: docs + "/" + name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func logTail(_ lines: Int = 200) -> String {
        guard let s = try? String(contentsOfFile: docs + "/credpush.log", encoding: .utf8) else {
            return "（还没有日志）"
        }
        let arr = s.split(separator: "\n")
        return arr.suffix(lines).joined(separator: "\n")
    }

    static var logPath: String { docs + "/credpush.log" }
}

/// 本地通知（掉线提醒）
enum Notifier {
    static func alert(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let r = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r, withCompletionHandler: nil)
    }
}
