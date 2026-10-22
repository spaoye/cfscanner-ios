import Foundation
import Network
import Security

/// 底层测速：TCPing 延迟 + TLS(SNI 伪装) 下载测速，与 CFST 的两段式流程对应。
enum NetTest {

    // MARK: - TCPing：测 TCP 握手耗时（CFST 默认的延迟测速模式），端口固定 443

    static func tcpPing(ip: String, timeout: TimeInterval = 2.0) async -> Double? {
        await withCheckedContinuation { continuation in
            let box = OnceBox()
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: 443, using: .tcp)
            let start = DispatchTime.now()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    box.run {
                        conn.cancel()
                        continuation.resume(returning: ms)
                    }
                case .failed, .cancelled:
                    box.run { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.run {
                    conn.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - 下载测速：连到指定 IP，但 TLS 的 SNI 和 HTTP 的 Host 都用测速域名，
    // 这样任意一个 CF 的 IP 都能当作 speed.cloudflare.com 的边缘来测速；
    // 地区码从响应头 CF-RAY 的后缀解析（和 CFST 显示地区码的方式一致）。

    static func downloadTest(ip: String, testHost: String, seconds: TimeInterval) -> (mbps: Double, colo: String?) {
        DownloadTester(ip: ip, testHost: testHost, seconds: seconds).run()
    }
}

/// 保证闭包只执行一次（超时和完成回调赛跑时用）
private final class OnceBox {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        block()
    }
}

private final class DownloadTester {
    private let ip: String
    private let testHost: String
    private let seconds: TimeInterval
    private let queue = DispatchQueue(label: "cfscanner.download")
    private let finishOnce = OnceBox()
    private var totalBytes = 0
    private var headerBuffer = Data()
    private var headerDone = false
    private var colo: String?
    private var startTime: DispatchTime?

    init(ip: String, testHost: String, seconds: TimeInterval) {
        self.ip = ip
        self.testHost = testHost
        self.seconds = seconds
    }

    func run() -> (mbps: Double, colo: String?) {
        let sem = DispatchSemaphore(value: 0)
        var result: (mbps: Double, colo: String?) = (0, nil)

        let tlsOptions = NWProtocolTLS.Options()
        // 关键一步：连接目标是 IP，但 SNI 写测速域名
        testHost.withCString { ptr in
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, ptr)
        }
        // 证书是签给域名的、连的却是 IP，校验必然过不了；这是测速工具，只测速度，故跳过校验
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)

        let connection = NWConnection(host: NWEndpoint.Host(ip), port: 443, using: NWParameters(tls: tlsOptions))

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.startTime = DispatchTime.now()
                let request = "GET /__down?bytes=104857600 HTTP/1.1\r\nHost: \(self.testHost)\r\nUser-Agent: CFScanner/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    self.receiveNext(connection)
                })
                self.queue.asyncAfter(deadline: .now() + self.seconds) {
                    connection.cancel()
                }
            case .failed, .cancelled:
                self.finishOnce.run {
                    let elapsed = self.startTime.map {
                        Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
                    } ?? 0
                    let mbps = elapsed > 0.2 ? Double(self.totalBytes) / elapsed / 1_000_000 : 0
                    result = (mbps, self.colo)
                    sem.signal()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = sem.wait(timeout: .now() + seconds + 10)
        return result
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                if !self.headerDone {
                    self.headerBuffer.append(data)
                    if let text = String(data: self.headerBuffer, encoding: .utf8),
                       let end = text.range(of: "\r\n\r\n") {
                        self.headerDone = true
                        let head = String(text[..<end.upperBound])
                        self.colo = Self.parseColo(head)
                        self.totalBytes += self.headerBuffer.count - head.utf8.count
                    }
                } else {
                    self.totalBytes += data.count
                }
                if !isComplete {
                    self.receiveNext(connection)
                }
            }
        }
    }

    /// CF-RAY: 8f3a……-LAX -> LAX
    static func parseColo(_ headers: String) -> String? {
        for line in headers.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("cf-ray:") {
                let value = trimmed.dropFirst("cf-ray:".count).trimmingCharacters(in: .whitespaces)
                if let dash = value.lastIndex(of: "-") {
                    return String(value[value.index(after: dash)...])
                }
            }
        }
        return nil
    }
}
