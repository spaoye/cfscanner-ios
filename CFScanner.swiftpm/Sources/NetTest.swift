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
    //
    // 注意：speed.cloudflare.com 的 /__down 接口要求 bytes < 100000000，
    // 等于或超过 1 亿会直接返回 HTTP 403（v1 就栽在这：请求了 104857600，
    // 每次只拿到 403 的 1 个字节，测速全是 0）。

    static func downloadTest(ip: String, testHost: String, seconds: TimeInterval) -> (mbps: Double, colo: String?, note: String?) {
        DownloadTester(ip: ip, testHost: testHost, seconds: seconds).run()
    }

    // MARK: - 落点探测：GET /cdn-cgi/trace（同样连候选 IP、SNI 用测速域名），
    // 响应正文带 colo=XXX（机房代码）和 loc=XX（国家），地区筛选就靠它。
    // CF 是 anycast，IP 没有固定归属地，只能逐个连上去看它实际落在哪。

    static func probe(ip: String, testHost: String) async -> (colo: String?, country: String?) {
        await TraceProbe(ip: ip, testHost: testHost).run()
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
    private var statusCode: Int?
    private var colo: String?
    private var startTime: DispatchTime?
    private var connection: NWConnection?
    private var semaphore: DispatchSemaphore?
    private var finalResult: (mbps: Double, colo: String?, note: String?) = (0, nil, nil)

    init(ip: String, testHost: String, seconds: TimeInterval) {
        self.ip = ip
        self.testHost = testHost
        self.seconds = seconds
    }

    func run() -> (mbps: Double, colo: String?, note: String?) {
        let sem = DispatchSemaphore(value: 0)
        semaphore = sem

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
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.startTime = DispatchTime.now()
                // bytes=90000000：留了余量，没碰 1 亿的 403 红线
                let request = "GET /__down?bytes=90000000 HTTP/1.1\r\nHost: \(self.testHost)\r\nUser-Agent: CFScanner/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    self.receiveNext(connection)
                })
                // 到达测速时长就收尾
                self.queue.asyncAfter(deadline: .now() + self.seconds) { [weak self] in
                    self?.finish()
                }
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = sem.wait(timeout: .now() + seconds + 10)
        return finalResult
    }

    /// 统一收尾：算速度、留诊断信息（HTTP 状态不对或没数据时把原因带出去显示）
    private func finish() {
        finishOnce.run {
            let elapsed = startTime.map {
                Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
            } ?? 0
            var note: String? = nil
            if startTime == nil {
                note = "连接失败"
            } else if let code = statusCode, code != 200 {
                note = "HTTP \(code)"
            } else if totalBytes == 0 {
                note = "无数据"
            }
            let mbps = (elapsed > 0.05 && note == nil) ? Double(totalBytes) / elapsed / 1_000_000 : 0
            finalResult = (mbps, colo, note)
            connection?.cancel()
            semaphore?.signal()
        }
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if !self.headerDone {
                    self.headerBuffer.append(data)
                    // 在字节层找响应头结束标记，只把头部转字符串，
                    // 避免 body 的二进制字节干扰头部解析（地区码之前没显示就是这个原因的嫌疑最大）
                    let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
                    if let range = self.headerBuffer.range(of: terminator) {
                        self.headerDone = true
                        let headData = self.headerBuffer.subdata(in: 0..<range.upperBound)
                        let head = String(data: headData, encoding: .utf8) ?? ""
                        self.statusCode = Self.parseStatus(head)
                        self.colo = Self.parseColo(head)
                        self.totalBytes += self.headerBuffer.count - range.upperBound
                        self.headerBuffer = Data()
                    }
                } else {
                    self.totalBytes += data.count
                }
            }
            if isComplete || error != nil {
                // 数据在测速时长内就传完了（快线路）：立刻按实际用时结算，不等满时长
                self.finish()
            } else if data != nil {
                self.receiveNext(connection)
            }
            // data==nil 且未结束的情况等定时器收尾，不会挂死
        }
    }

    /// HTTP/1.1 200 OK -> 200
    static func parseStatus(_ headers: String) -> Int? {
        guard let firstLine = headers.split(separator: "\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    /// 地区码：优先用测速接口自带的 colo 响应头，没有再从 CF-RAY 后缀解析
    static func parseColo(_ headers: String) -> String? {
        var rayFallback: String?
        for line in headers.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("colo:") {
                let value = trimmed.dropFirst("colo:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return String(value) }
            }
            if lower.hasPrefix("cf-ray:") {
                let value = trimmed.dropFirst("cf-ray:".count).trimmingCharacters(in: .whitespaces)
                if let dash = value.lastIndex(of: "-") {
                    rayFallback = String(value[value.index(after: dash)...])
                }
            }
        }
        return rayFallback
    }
}

/// 一次轻量 HTTPS 请求拿落点信息：连候选 IP，SNI/Host 用测速域名，
/// 读 /cdn-cgi/trace 的正文（纯文本 key=value），解析 colo= 和 loc=。
private final class TraceProbe {
    private let ip: String
    private let testHost: String
    private let queue = DispatchQueue(label: "cfscanner.probe")
    private var buffer = Data()
    private var colo: String?
    private var country: String?

    init(ip: String, testHost: String) {
        self.ip = ip
        self.testHost = testHost
    }

    func run() async -> (colo: String?, country: String?) {
        await withCheckedContinuation { continuation in
            let box = OnceBox()
            let tlsOptions = NWProtocolTLS.Options()
            testHost.withCString { ptr in
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, ptr)
            }
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, queue)
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: 443, using: NWParameters(tls: tlsOptions))

            func finish() {
                box.run {
                    conn.cancel()
                    continuation.resume(returning: (self.colo, self.country))
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET /cdn-cgi/trace HTTP/1.1\r\nHost: \(self.testHost)\r\nUser-Agent: CFScanner/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                        self.receiveNext(conn, finish: finish)
                    })
                case .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish() }
        }
    }

    private func receiveNext(_ conn: NWConnection, finish: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { finish(); return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseBuffer()
            }
            if isComplete || error != nil {
                finish()
            } else if data != nil {
                self.receiveNext(conn, finish: finish)
            }
        }
    }

    private func parseBuffer() {
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("colo=") {
                colo = String(t.dropFirst("colo=".count))
            } else if t.hasPrefix("loc=") {
                country = String(t.dropFirst("loc=".count))
            }
        }
        if colo == nil {
            colo = DownloadTester.parseColo(text)
        }
    }
}
