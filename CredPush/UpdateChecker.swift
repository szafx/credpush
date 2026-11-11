import Foundation
import UIKit

/// 热更新：启动/回前台时问服务端要最新 build 号，比本地大就弹窗 → 交 TrollStore 安装。
///
/// 服务端：
///   GET /api/app/version?app=credpush → {"ok":true,"build":123,"url":"…/dl/credpush.ipa","notes":"…"}
///   GET /dl/credpush.ipa               → IPA 本体
enum UpdateChecker {
    static let appKey = "credpush"

    static func currentBuild() -> Int {
        Int((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0") ?? 0
    }

    static func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// 检查更新。completion 一定会回一次（成功/已最新/失败），用于界面反馈。
    static func check(in presenter: UIViewController, completion: ((String) -> Void)? = nil) {
        Net.callPanel("/api/app/version?app=\(appKey)", method: "GET",
                      headers: ["X-Cred-Token": Cfg.pushToken], timeout: 20) { r in
            switch r {
            case .failure(let e):
                AppLog.w("update | 检查失败：\(e.localizedDescription)")
                completion?("检查失败：" + e.localizedDescription)
            case .success(let obj):
                guard let d = obj as? [String: Any] else {
                    completion?("返回格式异常")
                    return
                }
                let remote = (d["build"] as? Int) ?? 0
                AppLog.w("update | 本地 \(currentBuild()) 服务端 \(remote)")
                if remote > currentBuild() {
                    completion?("发现新版本 build \(remote)")
                    checkResult(d, in: presenter)
                } else {
                    completion?("已是最新（build \(currentBuild())）")
                }
            }
        }
    }

    private static func checkResult(_ d: [String: Any], in presenter: UIViewController) {
        guard let build = d["build"] as? Int, build > currentBuild() else { return }
        let urlStr = (d["url"] as? String) ?? ""
        let notes = (d["notes"] as? String) ?? ""
        guard !urlStr.isEmpty else { return }

        // 点过「稍后」的版本 6 小时内不再烦人
        let ud = UserDefaults.standard
        if ud.integer(forKey: "dismissBuild") == build {
            let t = ud.double(forKey: "dismissAt")
            if Date().timeIntervalSince1970 - t < 6 * 3600 { return }
        }

        let a = UIAlertController(
            title: "发现新版本",
            message: "当前 build \(currentBuild()) → 最新 \(build)\n\(notes)\n\n点「立即更新」会交给 TrollStore 安装（保留数据）。",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "稍后", style: .cancel) { _ in
            ud.set(build, forKey: "dismissBuild")
            ud.set(Date().timeIntervalSince1970, forKey: "dismissAt")
        })
        a.addAction(UIAlertAction(title: "立即更新", style: .default) { _ in
            install(urlStr)
        })
        presenter.present(a, animated: true)
    }

    static func install(_ ipaURL: String) {
        let enc = ipaURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ipaURL
        if let u = URL(string: "apple-magnifier://install?url=\(enc)") {
            UIApplication.shared.open(u, options: [:], completionHandler: nil)
        }
    }
}
