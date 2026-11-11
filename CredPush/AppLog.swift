import Foundation

/// 极简文件日志：写到 App 自己的 Documents/credpush.log
/// （越狱机上可以直接 SSH 读，排查「扫不到容器」这类问题全靠它）
enum AppLog {
    static let path: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return docs + "/credpush.log"
    }()

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func w(_ s: String) {
        let line = "\(df.string(from: Date()))  \(s)\n"
        NSLog("CredPush: %@", s)
        let fm = FileManager.default
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // 太大就砍掉前一半
        if let sz = try? fm.attributesOfItem(atPath: path)[.size] as? Int, sz > 200_000,
           let txt = try? String(contentsOfFile: path, encoding: .utf8) {
            let half = String(txt.suffix(txt.count / 2))
            try? half.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
