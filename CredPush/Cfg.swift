import Foundation

/// 全局配置（都存 UserDefaults，App 重启不丢）
enum Cfg {
    private static let d = UserDefaults.standard

    static var base: String {
        get {
            let v = (d.string(forKey: "base") ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "https://ydhf.szafx.icu" : v
        }
        set { d.set(newValue, forKey: "base") }
    }

    /// 面板密码（和网页版同一个）—— 内嵌默认值，设置页可改
    static let defaultPassword = Secrets.password
    /// 推送令牌（服务端 C:\mima-panel\cred_push.token 的副本）—— 内嵌默认值
    static let defaultPushToken = Secrets.pushToken

    static var password: String {
        get {
            let v = d.string(forKey: "password") ?? ""
            return v.isEmpty ? defaultPassword : v
        }
        set { d.set(newValue, forKey: "password") }
    }

    /// 推送令牌：为空就用内嵌默认值（Settings 页留空 = 用默认）
    static var pushToken: String {
        get {
            let v = d.string(forKey: "pushToken") ?? ""
            return v.isEmpty ? defaultPushToken : v
        }
        set { d.set(newValue, forKey: "pushToken") }
    }

    /// 打开「凭证」页时自动扫描推送
    static var autoScan: Bool {
        get { d.object(forKey: "autoScan") == nil ? true : d.bool(forKey: "autoScan") }
        set { d.set(newValue, forKey: "autoScan") }
    }

    /// 备用地址（例如 Tailscale 直连 http://100.98.108.55:8900）。
    /// 通则优先走它（毫秒级），不通自动退回主地址。
    static var altBase: String {
        get { d.string(forKey: "altBase") ?? "http://100.98.108.55:8900" }
        set { d.set(newValue, forKey: "altBase") }
    }

    /// Tailscale 授权码（tskey-…）：首次连内置 tsnet 时用，之后身份存 Documents/tsnet
    /// ★ 内嵌一份默认值：iOS 的 cfprefsd 会缓存旧值，外部写 plist 后 App 可能读不到
    static let defaultTsAuthKey = Secrets.tsAuthKey
    static var tsAuthKey: String {
        get {
            let v = d.string(forKey: "tsAuthKey") ?? ""
            return v.isEmpty ? defaultTsAuthKey : v
        }
        set { d.set(newValue, forKey: "tsAuthKey") }
    }

    /// IPv6 直连地址（例如 http://[240e:xxxx::1]:8900），留空则不用。
    /// 有 IPv6 就先走它——不占通道、不绕 CF、最快。
    static var ipv6Base: String {
        get { d.string(forKey: "ipv6Base") ?? "" }
        set { d.set(newValue, forKey: "ipv6Base") }
    }

    static func normalize(_ s: String) -> String {
        var b = s.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    // ---- 线路开关（设置页四个 Switch）----
    private static func flag(_ k: String) -> Bool {
        d.object(forKey: k) == nil ? true : d.bool(forKey: k)
    }
    private static func setFlag(_ k: String, _ v: Bool) { d.set(v, forKey: k) }

    static var useIPv6: Bool { get { flag("useIPv6") } set { setFlag("useIPv6", newValue) } }
    static var useTsnet: Bool { get { flag("useTsnet") } set { setFlag("useTsnet", newValue) } }
    static var useAlt: Bool { get { flag("useAlt") } set { setFlag("useAlt", newValue) } }
    static var useCf: Bool { get { flag("useCf") } set { setFlag("useCf", newValue) } }

    /// 上次成功连上的线路（只用于日志）
    static var lastGood: String {
        get { d.string(forKey: "lastGood") ?? "" }
        set { d.set(newValue, forKey: "lastGood") }
    }

    /// 依次尝试的地址：IPv6 直连 → 内置 Tailscale → 备用（系统尾网）→ 主地址（CF）
    static func bases() -> [String] {
        var out: [String] = []
        let v6 = normalize(ipv6Base)
        // 只把**开着**的线路放进来；开几个就按下面顺序试几个
        if useIPv6 && !v6.isEmpty { out.append(v6) }
        if useTsnet && Tsnet.shared.ready && !out.contains(Tsnet.shared.localBase) {
            out.append(Tsnet.shared.localBase)
        }
        if useAlt {
            let alt = normalize(altBase)
            if !alt.isEmpty && !out.contains(alt) { out.append(alt) }
        }
        if useCf {
            let main = normalize(base)
            if !main.isEmpty && !out.contains(main) { out.append(main) }
        }
        if out.isEmpty {                       // 全关了也别把 App 憋死
            let main = normalize(base)
            if !main.isEmpty { out.append(main) }
        }
        return out
    }

    static func url(_ path: String) -> String {
        var b = normalize(base)
        while b.hasSuffix("/") { b.removeLast() }
        return b + path
    }
}

/// 「账号」页读到的最新快照，给「凭证」页判断「只推掉线的号」
enum AccountCache {
    static var known: Set<String> = []
    static var dead: Set<String> = []
    /// phone -> 服务端当前持有的 App 会话 UID（扫描时比对该号有没有重新登录过）
    static var uid: [String: String] = [:]
    static var updated: Date?
    /// 已经推送过本地通知的掉线集合（避免重复弹）
    static var notifiedDead: Set<String> = []

    /// 需要时主动拉一次账号状态（凭证页没进过「账号」页时用）
    static func refresh(completion: @escaping () -> Void) {
        func fetch(_ retry: Bool) {
            Net.callPanel("/api/accounts", json: ["force": false], timeout: 90) { r in
                if case .failure(let e) = r, retry, e.localizedDescription.contains("401") {
                    Net.callPanel("/api/auth", json: ["password": Cfg.password]) { _ in fetch(false) }
                    return
                }
                if case .success(let obj) = r, let d = obj as? [String: Any] {
                    let items = d["items"] as? [[String: Any]] ?? []
                    known = Set(items.compactMap { $0["phone"] as? String })
                    uid = [:]
                    for it in items {
                        if let ph = it["phone"] as? String, let u = it["app_uid"] as? String, !u.isEmpty {
                            uid[ph] = u
                        }
                    }
                    dead = Set(items.filter {
                        !((($0["err"] as? String) ?? "").isEmpty)
                    }.compactMap { $0["phone"] as? String })
                    updated = Date()
                }
                completion()
            }
        }
        fetch(true)
    }
}


/// 兼容取值：移动接口的余额/任务数有时是字符串（"96"），有时是数字
enum Num {
    /// 浮点（面板的流量余量是小数，例如 12391.3）
    static func dbl(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String:
            if let i = Int(s) { return i }
            if let d = Double(s) { return Int(d) }
            return nil
        case let d as Double: return Int(d)
        default: return nil
        }
    }
}
