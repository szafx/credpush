import Foundation

/// 内置 Tailscale（tsnet）：在 App 进程内起一条 tailnet 连接，
/// 再把 `100.98.108.55:8900` 转发到本机 `127.0.0.1:18900`。
///
/// 好处：**不占系统 VPN 通道**，也不经过 Cloudflare。
/// 首次需要授权码（tskey-…），之后身份存 `Documents/tsnet`。
final class Tsnet {
    static let shared = Tsnet()

    static let remoteHost = "100.98.108.55"
    static let remotePort: Int32 = 8900
    static let localPort: Int32 = 18900

    private(set) var ready = false
    private(set) var status = "未启动"
    private var starting = false
    private var waiters: [() -> Void] = []
    private var lastStart = Date.distantPast
    private var waitDeadline = Date.distantPast
    private var hardDeadline = Date.distantPast

    var localBase: String { "http://127.0.0.1:\(Tsnet.localPort)" }

    private func setStatus(_ s: String) {
        status = s
        AppLog.w("tsnet | " + s)
    }

    /// 启动（或复用已有的）。done 在「连上 / 失败 / 等待超时」时回调，
    /// 但**超时之后仍会继续在后台连接**，连上就把 ready 置真。
    func startIfNeeded(timeout: TimeInterval = 6, done: (() -> Void)? = nil) {
        if ready { done?(); return }
        let key = Cfg.tsAuthKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty {
            if status != "未配置授权码" { setStatus("未配置授权码") }
            done?()
            return
        }
        if let done = done { waiters.append(done) }

        if starting {
            // 已经有一次启动在跑：到点就放行调用方
            waitDeadline = min(waitDeadline, Date().addingTimeInterval(timeout))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.flush()
            }
            return
        }
        if Date().timeIntervalSince(lastStart) < 60 && status.hasPrefix("连接失败") {
            flush()
            return
        }

        starting = true
        lastStart = Date()
        waitDeadline = Date().addingTimeInterval(timeout)
        hardDeadline = Date().addingTimeInterval(90)
        setStatus("连接中…")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tsnet").path
        try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)

        let r1 = update_tsnet_auth_key(strdup(key))
        let r2 = tsnet_update_hostname(strdup("credpush-431"))
        let r3 = tsnet_update_state_dir(strdup(docs))
        AppLog.w("tsnet | 配置 keylen=\(key.count) setKey=\(r1) host=\(r2) dir=\(r3) path=\(docs)")
        tsnet_connect_async()

        poll(flushed: false)
    }

    /// 强制重连（改授权码后用）
    func restart() {
        tsnet_cleanup()
        ready = false
        starting = false
        setStatus("已重置")
        lastStart = .distantPast
    }

    private func poll(flushed: Bool) {
        let st = tsnet_get_connect_status()
        if st == 1 {
            let rc = tsnet_start_forward(strdup(Tsnet.remoteHost), Tsnet.remotePort, Tsnet.localPort)
            ready = (rc == 0)
            if ready {
                setStatus("已连接 · 127.0.0.1:\(Tsnet.localPort) → \(Tsnet.remoteHost):\(Tsnet.remotePort)")
            } else {
                setStatus("端口转发失败（rc=\(rc)）")
            }
            starting = false
            flush()
            return
        }
        if st == -1 {
            var msg = "连接失败"
            if let p = tsnet_get_last_error() { msg += "：" + String(cString: p) }
            setStatus(msg)
            starting = false
            flush()
            return
        }
        if !flushed && Date() > waitDeadline {
            setStatus("仍在后台连接…（本次请求先走别的线路）")
            flush()
            // ★ 继续轮询，60 秒硬上限
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.poll(flushed: true)
            }
            return
        }
        if Date() > hardDeadline {
            setStatus("连接超时（90 秒）")
            starting = false
            flush()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.poll(flushed: flushed)
        }
    }

    private func flush() {
        let ws = waiters
        waiters = []
        ws.forEach { $0() }
    }
}
