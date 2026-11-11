import Foundation
import UIKit

struct NetError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

/// 极简网络层：URLSession + 自动带 cookie（面板登录靠 cookie）
enum Net {
    // Cloudflare 见到非浏览器 UA 会 1010，所以统一用浏览器 UA
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Mobile/15E148 Safari/604.1"

    @discardableResult
    static func call(_ urlStr: String,
                     method: String = "GET",
                     json: [String: Any]? = nil,
                     headers: [String: String] = [:],
                     timeout: TimeInterval = 40,
                     done: @escaping (Result<Any, Error>) -> Void) -> URLSessionDataTask? {
        guard let url = URL(string: urlStr) else {
            done(.failure(NetError(msg: "地址不合法：\(urlStr)")))
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("https://ydhf.szafx.icu/", forHTTPHeaderField: "Referer")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json = json {
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err {
                    done(.failure(NetError(msg: err.localizedDescription)))
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if code >= 400 {
                    done(.failure(NetError(msg: "HTTP \(code)：\(raw.prefix(200))")))
                    return
                }
                let obj: Any = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? raw
                done(.success(obj))
            }
        }
        task.resume()
        return task
    }

    /// 面板类接口：按 Cfg.bases() 依次尝试（备用地址=Tailscale 直连，给 4 秒；主地址给完整超时）
    static func callPanel(_ path: String, method: String = "POST",
                          json: [String: Any]? = nil,
                          headers: [String: String] = [:],
                          timeout: TimeInterval = 240,
                          done: @escaping (Result<Any, Error>) -> Void) {
        var bases = Cfg.bases()
        guard !bases.isEmpty else {
            done(.failure(NetError(msg: "没有配置服务器地址")))
            return
        }
        func attempt(_ i: Int) {
            guard i < bases.count else {
                done(.failure(NetError(msg: "所有服务器地址都连不上")))
                return
            }
            let isLast = (i == bases.count - 1)
            let t = isLast ? timeout : min(8, timeout)   // 中转线路常要 4~6 秒，4 秒太短
            let t0 = Date()
            call(bases[i] + path, method: method, json: json, headers: headers, timeout: t) { r in
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if case .success = r {
                    if Cfg.lastGood != bases[i] { Cfg.lastGood = bases[i] }
                    AppLog.w("net | \(path) @ \(bases[i]) \(ms)ms")
                    done(r)
                    return
                }
                AppLog.w("net | \(path) @ \(bases[i]) 失败 \(ms)ms，试下一条")
                if i + 1 < bases.count { attempt(i + 1) } else { done(r) }
            }
        }
        attempt(0)
    }

    /// 清掉面板 cookie（换密码 / 退出时用）
    static func clearCookies() {
        let store = HTTPCookieStorage.shared
        for c in store.cookies ?? [] where c.domain.contains("szafx.icu") || c.domain.contains("10086") {
            store.deleteCookie(c)
        }
    }
}
