import Foundation
import UIKit

/// 崩溃收集：把未捕获异常 / 信号写到 Documents，下次启动自动上报到服务端。
///
/// 信号处理里**只做最低限度的事**（写文件 + _exit），不能调用 URLSession。
enum CrashLogger {
    private static var docs: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
    }

    private static var pendingDir: String { docs + "/crashes" }

    static func install() {
        try? FileManager.default.createDirectory(atPath: pendingDir, withIntermediateDirectories: true)

        NSSetUncaughtExceptionHandler { ex in
            CrashLogger.record(name: ex.name.rawValue, reason: ex.reason ?? "",
                               stack: ex.callStackSymbols)
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                CrashLogger.record(name: "signal \(s)", reason: "",
                                   stack: Thread.callStackSymbols)
                _exit(s)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func record(name: String, reason: String, stack: [String]) {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let ios = UIDevice.current.systemVersion
        let text = "name: \(name)\nreason: \(reason)\nbuild: \(build)\nios: \(ios)\n---\n"
            + stack.joined(separator: "\n")
        let path = pendingDir + "/crash_\(timestamp()).txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        AppLog.w("crash | \(name) \(reason.prefix(80))")
    }

    static func pendingFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: pendingDir))?.map { pendingDir + "/" + $0 } ?? []
    }

    /// 下次启动时把攒下的崩溃日志发到服务端（失败就留着，下回再发）
    static func uploadPending() {
        let files = pendingFiles()
        guard !files.isEmpty else { return }
        AppLog.w("crash | 待上报 \(files.count) 条")
        for f in files {
            guard let log = try? String(contentsOfFile: f, encoding: .utf8) else {
                try? FileManager.default.removeItem(atPath: f)
                continue
            }
            let name = (f as NSString).lastPathComponent
            Net.callPanel("/api/crash", json: [
                "name": name,
                "ios": UIDevice.current.systemVersion,
                "build": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?",
                "app": "credpush",
                "log": log,
            ], headers: ["X-Cred-Token": Cfg.pushToken], timeout: 25) { r in
                switch r {
                case .success:
                    try? FileManager.default.removeItem(atPath: f)
                    AppLog.w("crash | 已上报 \(name)")
                case .failure(let e):
                    AppLog.w("crash | 上报失败（下次再试）：\(e.localizedDescription)")
                }
            }
        }
    }
}
