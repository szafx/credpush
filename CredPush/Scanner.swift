import Foundation

struct FoundSession {
    let raw: String
    let source: String
    /// 容器对应的手机号（来自容器自己的 UserPhone）
    let phone: String
    /// 会话里的 UID：用来判断「服务端那份」和「容器里的」是不是同一条
    let uid: String
    /// 在 Cache.db-wal 里**最后一次出现**的字节偏移（越大越新）；非 WAL 来源为 -1。
    /// ★ 一定要「单独推最新那条」：整批一起推时，前面几条失效的会先把服务端打到
    ///   「登录状态已过期」，同一批里真正有效的那条也被连坐（2026-11-12 实测）。
    let recency: Int
    /// 会话的**创建时间**（来自 Cookies.binarycookies 里 JSESSIONID 那组 cookie 的创建时间）。
    /// ★ 比 WAL 偏移可靠：2026-11-13 23:48 那次冷启动的新会话，App 只把它写进了
    ///   Cookies.binarycookies，WAL 里没有位置（recency=-1）—— 只按偏移排序会挑中旧会话，
    ///   推上去就是「APP登录状态已过期」（事故 B）。有创建时间就以它为准。
    let createdAt: Date?
}

/// 扫「中国移动」App 的容器（主容器 + Crane 分身），挖出 App 会话。
enum Scanner {
    static let bundleID = "cn.10086.app"
    static let appsRoot = "/var/mobile/Containers/Data/Application"
    static let cranePrefs = "/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"

    // MARK: - 容器

    /// 按 Crane 的容器 id（= `Library/___Crane_Containers/<id>` 的目录名）找路径。
    ///
    /// ★ 新建的容器在**登录完成前 `UserPhone` 是空的**，`allContainers()` 里虽然能看到
    ///   目录，但 `phone` 字段为空 → 按手机号永远匹配不到。所以新增账号流程必须按
    ///   「Crane 名字 → id → 目录」认人（2026-11-11 视频里就是这么卡的）。
    static func path(forCraneID id: String) -> String? {
        guard !id.isEmpty else { return nil }
        for c in allContainers() where (c.path as NSString).lastPathComponent == id {
            return c.path
        }
        // 还没被 allContainers() 认出来（少了标记文件）时，直接按目录拼
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: appsRoot)) ?? []
        for d in dirs {
            let cand = appsRoot + "/" + d + "/Library/___Crane_Containers/" + id
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: cand, isDirectory: &isDir), isDir.boolValue {
                return cand
            }
        }
        return nil
    }

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
        // norm -> (来源、UID、WAL 偏移、cookie 创建时间)
        var order: [String] = []
        var byNorm: [String: (source: String, uid: String, recency: Int, created: Date?)] = [:]
        let files = [
            container + "/Library/Caches/cn.10086.app/Cache.db-wal",
            container + "/Library/Caches/cn.10086.app/Cache.db",
            // ★ binarycookies 是**结构化二进制**，用正则 grep 请求头文本永远命中 0 次，
            //   所以这一份下面单独解析（cookieSessions）。
        ]
        let label = phone.isEmpty ? String((container as NSString).lastPathComponent.prefix(8)) + "…" : phone
        for (idx, f) in files.enumerated() {
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
                if byNorm[norm] == nil { order.append(norm) }
                var e = byNorm[norm] ?? (source: name, uid: uid, recency: -1, created: nil)
                if idx == 0 {   // 只有 WAL 里的位置能代表「新旧」
                    e.recency = max(e.recency, m.range.location)
                }
                byNorm[norm] = e
            }
            log?("   \(label)/\(name)：\(data.count) 字节，命中 \(matches.count)")
        }

        // ★ 结构化解析 Cookies.binarycookies —— 拿 JSESSIONID/UID/ticketID 四件套 + **创建时间**。
        //   新会话可能只在这里（WAL 里一条记录都没有），漏了它就会推旧会话（事故 B）。
        let cookieSess = cookieSessions(container: container, phone: phone)
        for s in cookieSess {
            if var e = byNorm[s.raw] {
                if e.created == nil { e.created = s.createdAt; byNorm[s.raw] = e }
                continue
            }
            // 同一 UID 但 norm 字符串对不齐（ticketID 截断等）→ 合并到已有那条上
            if let k = byNorm.first(where: { $0.value.uid == s.uid })?.key, var e = byNorm[k] {
                if e.created == nil { e.created = s.createdAt; byNorm[k] = e }
                continue
            }
            order.append(s.raw)
            byNorm[s.raw] = (source: s.source, uid: s.uid, recency: -1, created: s.createdAt)
        }
        if !cookieSess.isEmpty {
            log?("   \(label)/Cookies.binarycookies：解析出 \(cookieSess.count) 组会话")
        }

        return order.compactMap { k in
            guard let e = byNorm[k] else { return nil }
            return FoundSession(raw: k, source: e.source, phone: phone, uid: e.uid,
                                recency: e.recency, createdAt: e.created)
        }
    }

    // MARK: - Cookies.binarycookies

    /// 一条 cookie 记录
    struct CookieRec {
        let domain: String
        let name: String
        let value: String
        let created: Date?
    }

    /// 解析 Apple 的 `.binarycookies`（`cook` 魔数 + N 个 page + 每 page 若干记录）。
    /// 结构（实测 iPhone iOS 16 / Darwin 22.2）：
    ///   header: "cook" + 大端 page 数 + 每个 page 的**大端**长度
    ///   page:   4B 头 + **小端**记录数 + 记录偏移数组（小端）
    ///   record: 4B 长度 + 若干 4B 偏移（相对**记录起点**）+ 两个 double（expiry / creation，Apple 纪元）
    static func parseBinaryCookies(_ data: Data) -> [CookieRec] {
        let b = [UInt8](data)
        func be32(_ arr: [UInt8], _ o: Int) -> Int? {
            guard o >= 0, o + 4 <= arr.count else { return nil }
            return (Int(arr[o]) << 24) | (Int(arr[o + 1]) << 16) | (Int(arr[o + 2]) << 8) | Int(arr[o + 3])
        }
        func le32(_ arr: [UInt8], _ o: Int) -> Int? {
            guard o >= 0, o + 4 <= arr.count else { return nil }
            return (Int(arr[o + 3]) << 24) | (Int(arr[o + 2]) << 16) | (Int(arr[o + 1]) << 8) | Int(arr[o])
        }
        func f64le(_ arr: [UInt8], _ o: Int) -> Double? {
            guard o >= 0, o + 8 <= arr.count else { return nil }
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(arr[o + i]) }
            return Double(bitPattern: v)
        }
        func cstr(_ arr: [UInt8], _ at: Int) -> String {
            guard at >= 0, at < arr.count else { return "" }
            var e = at
            while e < arr.count && arr[e] != 0 { e += 1 }
            return String(decoding: arr[at..<e], as: UTF8.self)
        }
        guard be32(b, 0) == 0x636F_6F6B, let pages = be32(b, 4), pages > 0, pages < 256 else { return [] }
        var off = 8 + 4 * pages
        var out: [CookieRec] = []
        for p in 0..<pages {
            guard let sz = be32(b, 8 + 4 * p), sz > 8, off + sz <= b.count else { break }
            let page = Array(b[off..<(off + sz)])
            off += sz
            guard let n = le32(page, 4), n >= 0, n < 4096 else { continue }
            for i in 0..<n {
                guard let ro = le32(page, 8 + 4 * i), ro >= 0, ro + 48 <= page.count else { continue }
                guard let domainOff = le32(page, ro + 16), let nameOff = le32(page, ro + 20),
                      let valueOff = le32(page, ro + 28) else { continue }
                let created = f64le(page, ro + 40).map { Date(timeIntervalSinceReferenceDate: $0) }
                // ★ 三个字符串偏移都是**相对记录起点**（实测真机 cookie 文件；不是相对 page）
                let rec = CookieRec(domain: cstr(page, ro + domainOff),
                                    name: cstr(page, ro + nameOff),
                                    value: cstr(page, ro + valueOff), created: created)
                if !rec.name.isEmpty { out.append(rec) }
            }
        }
        return out
    }

    /// 从 Cookies.binarycookies 里成组取出会话（JSESSIONID + UID + ticketID）。
    /// ⚠️ iOS 会**延迟落盘** cookie：中国移动还在前台时，文件里可能还是上一次的内容 ——
    ///    所以它只能和 WAL/DB 互为补充，不能当成唯一来源。
    static func cookieSessions(container: String, phone: String) -> [FoundSession] {
        let p = container + "/Library/Cookies/Cookies.binarycookies"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)), !d.isEmpty else { return [] }
        let recs = parseBinaryCookies(d)
        guard !recs.isEmpty else { return [] }
        var byDomain: [String: [CookieRec]] = [:]
        for r in recs where !r.domain.isEmpty { byDomain[r.domain, default: []].append(r) }
        var out: [FoundSession] = []
        for (_, list) in byDomain {
            guard let j = list.first(where: { $0.name == "JSESSIONID" }), j.value.count >= 32,
                  let u = list.first(where: { $0.name == "UID" }), u.value.count >= 10 else { continue }
            let ticket = list.first(where: { $0.name == "ticketID" })?.value
            let group: Set<String> = ["JSESSIONID", "UID", "Comment", "ticketID"]
            let created = list.filter { group.contains($0.name) }.compactMap { $0.created }.max()
            let norm = "JSESSIONID=\(j.value); UID=\(u.value); Comment=SessionServer-unity; "
                + "Path=/;HTTPOnly; " + (ticket.map { "ticketID=\($0); " } ?? "") + "Secure"
            out.append(FoundSession(raw: norm, source: "Cookies.binarycookies", phone: phone,
                                    uid: u.value, recency: -1, createdAt: created))
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
