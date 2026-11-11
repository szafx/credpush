import Foundation

/// Crane 集成：调 `/usr/local/bin/cranectl` 读/切容器，拉起/关闭中国移动。
///
/// 前提：越狱设备 + Crane（rootless）。非越狱（只有 TrollStore）设备上这些工具不存在，
/// `available()` 会返回 false，界面自动退回「手动」提示。
enum Crane {
    static let appBundle = "cn.10086.app"

    /// ★ 这台是 **roothide** 越狱：越狱文件不在固定的 /usr/local，
    ///   而在随机命名的 jbroot 目录（/var/containers/Bundle/Application/.jbroot-XXXX/）。
    ///   这里动态找出来，找不到就退回真实路径。
    static var jbrootPath: String {
        if let env = ProcessInfo.processInfo.environment["JBROOT"], !env.isEmpty { return env }
        let fm = FileManager.default
        for base in ["/var/containers/Bundle/Application",
                     "/private/var/containers/Bundle/Application"] {
            if let items = try? fm.contentsOfDirectory(atPath: base) {
                let jbs = items.filter { $0.hasPrefix(".jbroot-") }.sorted()
                if let last = jbs.last { return base + "/" + last }
            }
        }
        return ""
    }

    static func jb(_ p: String) -> String {
        let r = jbrootPath
        return r.isEmpty ? p : r + p
    }

    static var cranectl: String { jb("/usr/local/bin/cranectl") }
    static var uiopen: String { jb("/usr/bin/uiopen") }
    static var launchctl: String { jb("/usr/bin/launchctl") }
    static var defaultsBin: String { jb("/usr/bin/defaults") }

    static func exists(_ p: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: p)
    }

    static func available() -> Bool {
        return exists(cranectl) && exists(uiopen)
    }

    // MARK: - 跑外部命令（posix_spawn + 超时）

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 12) -> (Int32, String) {
        guard exists(path) else { return (-1, "找不到 \(path)") }

        var fds: [Int32] = [-1, -1]
        let pipeRC = fds.withUnsafeMutableBufferPointer { buf in
            pipe(buf.baseAddress!)
        }
        guard pipeRC == 0 else { return (-1, "pipe 失败") }

        let actions = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
        actions.initialize(to: nil)
        posix_spawn_file_actions_init(actions)
        posix_spawn_file_actions_adddup2(actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(actions, fds[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(actions, fds[0])
        posix_spawn_file_actions_addclose(actions, fds[1])

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map {
            strdup("\($0.key)=\($0.value)")
        }
        envp.append(nil)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, actions, nil, argv, envp)
        posix_spawn_file_actions_destroy(actions)
        actions.deallocate()
        close(fds[1])
        for p in argv where p != nil { free(p) }
        for p in envp where p != nil { free(p) }
        guard rc == 0 else {
            close(fds[0])
            return (-1, "spawn 失败 rc=\(rc)")
        }

        let lock = NSLock()
        var box = Data()
        let sem = DispatchSemaphore(value: 0)
        let fh = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        DispatchQueue.global().async {
            let d = fh.readDataToEndOfFile()
            lock.lock(); box = d; lock.unlock()
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            kill(pid, SIGKILL)
            _ = sem.wait(timeout: .now() + 2)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        lock.lock()
        let text = String(data: box, encoding: .utf8) ?? ""
        lock.unlock()
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        return (code, text)
    }

    // MARK: - 容器

    struct Container {
        let id: String
        let name: String        // 用户起的名字（手机号）；DEFAULT 时是「默认」
    }

    static func list() -> [Container] {
        let (rc, out) = run(cranectl, ["--list", appBundle])
        guard rc == 0 else { return [] }
        var rows: [Container] = []
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            guard let l = line.firstIndex(of: "("), let r = line.lastIndex(of: ")"), l < r else { continue }
            let name = line[..<l].trimmingCharacters(in: .whitespaces)
            let id = String(line[line.index(after: l)..<r])
            if id.isEmpty { continue }
            rows.append(Container(id: id, name: name))
        }
        return rows
    }

    /// 当前默认容器 id（读 Crane 的偏好；读不到返回空）
    static func activeContainerID() -> String {
        let (rc, out) = run(defaultsBin,
                            ["read", "com.opa334.craneprefs", "appSettings_" + appBundle])
        guard rc == 0 else { return "" }
        for line in out.split(separator: "\n") where line.contains("activeContainer") {
            if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b {
                return String(line[line.index(after: a)..<b])
            }
        }
        return ""
    }

    /// 按容器名（手机号）切换；name 传「默认」时用 DEFAULT
    static func switchTo(name: String) -> Bool {
        let target = (name == "默认" || name.isEmpty) ? "DEFAULT" : name
        let (rc, out) = run(cranectl, ["--switch", appBundle, "name:" + target])
        AppLog.w("crane | switch \(target) rc=\(rc) \(out.prefix(80))")
        return rc == 0
    }

    // MARK: - 中国移动进程

    /// 正在运行的 pid（没运行返回 0）
    static func chinaMobilePid() -> Int32 {
        let (rc, out) = run(launchctl, ["list"])
        guard rc == 0 else { return 0 }
        for line in out.split(separator: "\n") {
            guard line.contains("UIKitApplication:\(appBundle)") else { continue }
            let parts = line.split(separator: "\t")
            if let first = parts.first, let pid = Int32(first.trimmingCharacters(in: .whitespaces)) {
                return pid
            }
        }
        return 0
    }

    static func isChinaMobileRunning() -> Bool { return chinaMobilePid() > 0 }

    @discardableResult
    static func killChinaMobile() -> Bool {
        let pid = chinaMobilePid()
        guard pid > 0 else { return true }
        let r = kill(pid, SIGKILL)
        AppLog.w("crane | kill \(appBundle) pid=\(pid) rc=\(r)")
        return r == 0
    }

    @discardableResult
    static func launchChinaMobile() -> Bool {
        let (rc, _) = run(uiopen, ["--bundleid", appBundle], timeout: 8)
        AppLog.w("crane | launch uiopen rc=\(rc)")
        return rc == 0
    }
}
