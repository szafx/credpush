import Foundation

/// 清理中国移动在某个容器里的 **NSURLCache**（Cache.db / -wal / -shm）。
///
/// 为什么是安全的：
///   * NSURLCache 只是 HTTP 缓存，iOS 自己在内存紧张时也会清；
///   * 登录态在 `Library/Cookies/Cookies.binarycookies`（实测里面有 JSESSIONID/UID），不动它；
///   * 每次都先完整备份到 `cn.10086.app.backup-<时间戳>`，删除失败/校验不过会回滚。
///
/// 代价：清完后该容器暂时读不到会话，要等下次打开中国移动重新生成缓存。
enum CacheCleaner {
    static func cacheDir(_ container: String) -> String {
        container + "/Library/Caches/cn.10086.app"
    }

    static func size(_ path: String) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        if let en = fm.enumerator(atPath: path) {
            for case let f as String in en {
                let full = path + "/" + f
                if let a = try? fm.attributesOfItem(atPath: full), let s = a[.size] as? Int64 {
                    total += s
                }
            }
        }
        return total
    }

    static func fmt(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576.0) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }

    /// 清理前必须先满足：服务端已有该号最新会话、中国移动没在运行。
    static func clean(container: String) -> (ok: Bool, msg: String, freed: Int64) {
        if Crane.isChinaMobileRunning() {
            return (false, "中国移动正在运行，先关掉再清理", 0)
        }
        let fm = FileManager.default
        let dir = cacheDir(container)
        guard fm.fileExists(atPath: dir) else {
            return (false, "这个容器没有缓存目录", 0)
        }
        let freed = size(dir)
        if freed == 0 { return (true, "本来就没什么缓存", 0) }

        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        let bak = container + "/Library/Caches/cn.10086.app.backup-" + stamp

        do {
            try fm.copyItem(atPath: dir, toPath: bak)
        } catch {
            return (false, "备份失败：\(error.localizedDescription)", 0)
        }
        do {
            try fm.removeItem(atPath: dir)
        } catch {
            try? fm.removeItem(atPath: bak)
            return (false, "删除失败：\(error.localizedDescription)", 0)
        }
        if fm.fileExists(atPath: dir) {
            return (false, "删除后目录还在（没生效）", 0)
        }
        AppLog.w("clean | \(container.suffix(8)) 释放 \(fmt(freed))，备份 \(bak.suffix(20))")
        return (true, "已清理并备份", freed)
    }

    /// 删掉 3 天前的备份（避免备份本身越堆越多）
    @discardableResult
    static func purgeOldBackups(olderThan days: Int = 3) -> Int {
        let fm = FileManager.default
        var n = 0
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for c in Scanner.allContainers() {
            let base = c.path + "/Library/Caches"
            let list = (try? fm.contentsOfDirectory(atPath: base)) ?? []
            for name in list where name.hasPrefix("cn.10086.app.backup-") {
                let p = base + "/" + name
                if let a = try? fm.attributesOfItem(atPath: p),
                   let d = a[.modificationDate] as? Date, d < cutoff {
                    try? fm.removeItem(atPath: p)
                    n += 1
                }
            }
        }
        if n > 0 { AppLog.w("clean | 删除旧备份 \(n) 个") }
        return n
    }
}
