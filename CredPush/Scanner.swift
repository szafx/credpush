import Foundation

struct FoundSession {
    let raw: String
    let source: String
    /// 容器对应的手机号（来自容器自己的 UserPhone）
    let phone: String
    /// 会话里的 UID：用来判断「服务端那份」和「容器里的」是不是同一条
    let uid: String
}

/// 扫「中国移动」App 的容器（主容器 + Crane 分身），挖出 App 会话。
enum Scanner {
    static let bundleID = "cn.10086.app"
    static let appsRoot = "/var/mobile/Containers/Data/Application"
    static let cranePrefs = "/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"

    // MARK: - 容器

    /// 从容器自己的 `Library/Preferences/cn.10086.app.plist` 读 UserPhone
    static func phoneFromPrefs(_ container: String) -> String {
        let p = container + "/Library/Preferences/cn.10086.app.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let d = raw as? [String: Any] else { return "" }
        for k in ["UserPhone", "kHNCaiYunUserPhone", "theUserAccountID"] {
            if let v = d[k] as? String {
                let t = v.trimmingCharacters(in: .whitespaces)
                if t.count == 11 && t.hasPrefix("1") { return t }
            }
        }
        return ""
    }

    /// 这个目录是不是中国移动的数据容器
    static func isOurs(_ p: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: p + "/Library/Caches/cn.10086.app") { return true }
        let meta = p + "/.com.apple.mobile_container_manager.metadata.plist"
        if let md = try? Data(contentsOf: URL(fileURLWithPath: meta)),
           let raw = try? PropertyListSerialization.propertyList(from: md, options: [], format: nil),
           let dict = raw as? [String: Any],
           let ident = dict["MCMMetadataIdentifier"] as? String,
           ident == bundleID {
            return true
        }
        return false
    }

    /// 所有中国移动容器：[(容器路径, 手机号)]
    static func allContainers() -> [(path: String, phone: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        let dirs = (try? fm.contentsOfDirectory(atPath: appsRoot)) ?? []
        for d in dirs {
            let p = appsRoot + "/" + d
            guard isOurs(p) else { continue }
            out.append((p, phoneFromPrefs(p)))
            let crane = p + "/Library/___Crane_Containers"
            for sub in (try? fm.contentsOfDirectory(atPath: crane)) ?? [] {
                let cp = crane + "/" + sub
                guard isOurs(cp) else { continue }
                out.append((cp, phoneFromPrefs(cp)))
            }
        }
        return out
    }

    // MARK: - 会话

    private static let reSess = try! NSRegularExpression(
        pattern: "JSESSIONID=([0-9a-fA-F-]{36});\\s*UID=([A-Za-z0-9]{20,})")
    private static let reTicket = try! NSRegularExpression(pattern: "ticketID=([A-Za-z]{2,12})")

    /// 读一个容器的三个会话来源（Cache.db-wal / Cache.db / Cookies.binarycookies）
    static func readSessions(container: String, phone: String,
                             log: ((String) -> Void)? = nil) -> [FoundSession] {
        var out: [FoundSession] = []
        var seen = Set<String>()
        let files = [
            container + "/Library/Caches/cn.10086.app/Cache.db-wal",
            container + "/Library/Caches/cn.10086.app/Cache.db",
            container + "/Library/Cookies/Cookies.binarycookies",
        ]
        let label = phone.isEmpty ? String((container as NSString).lastPathComponent.prefix(8)) + "…" : phone
        for f in files {
            let name = (f as NSString).lastPathComponent
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: f))
            } catch {
                log?("   \(label)/\(name)：读不了（\(error.localizedDescription)）")
                continue
            }
            if data.isEmpty {
                log?("   \(label)/\(name)：空文件")
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            let ns = text as NSString
            let matches = reSess.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.numberOfRanges >= 3 else { continue }
                let jid = ns.substring(with: m.range(at: 1))
                let uid = ns.substring(with: m.range(at: 2))
                let tailStart = min(ns.length, m.range.location + m.range.length)
                let tailLen = min(160, ns.length - tailStart)
                let tail = ns.substring(with: NSRange(location: tailStart, length: tailLen))
                var ticket = ""
                if let tm = reTicket.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) {
                    ticket = (tail as NSString).substring(with: tm.range(at: 1))
                }
                let norm = "JSESSIONID=\(jid); UID=\(uid); Comment=SessionServer-unity; "
                    + "Path=/;HTTPOnly; " + (ticket.isEmpty ? "" : "ticketID=\(ticket); ") + "Secure"
                if seen.insert(norm).inserted {
                    out.append(FoundSession(raw: norm, source: name, phone: phone, uid: uid))
                }
            }
            log?("   \(label)/\(name)：\(data.count) 字节，命中 \(matches.count)")
        }
        return out
    }

    /// 全量扫描（带日志，诊断/凭证页都用它）
    static func harvest() -> (sessions: [FoundSession], log: [String]) {
        var log: [String] = []
        func add(_ s: String) { log.append(s); AppLog.w("scan | " + s) }

        let containers = allContainers()
        add("容器：\(containers.count) 个")
        if containers.isEmpty {
            add("⚠️ 一个 cn.10086.app 容器都没找到")
            return ([], log)
        }
        var all: [FoundSession] = []
        var seen = Set<String>()
        for c in containers {
            let got = readSessions(container: c.path, phone: c.phone, log: add)
            add("容器 \(c.phone.isEmpty ? String((c.path as NSString).lastPathComponent.prefix(8)) + "…" : c.phone)：\(got.count) 条")
            for s in got where seen.insert(s.raw).inserted {
                all.append(s)
            }
        }
        add("合计 \(all.count) 条候选会话（已去重）")
        return (all, log)
    }
}
