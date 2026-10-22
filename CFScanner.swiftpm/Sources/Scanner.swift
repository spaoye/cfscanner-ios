import Foundation

struct ScanResult: Identifiable {
    let id = UUID()
    let ip: String
    var sent: Int
    var received: Int
    var avgLatencyMs: Double
    var downloadMBps: Double?
    var colo: String?
    var lossRate: Double { sent > 0 ? Double(sent - received) / Double(sent) : 1 }
}

@MainActor
final class Scanner: ObservableObject {

    // MARK: 设置（界面直接绑定，默认值对齐 CFST）
    @Published var maxLatencyMs: Double = 200      // -tl  平均延迟上限
    @Published var lossLimitPct: Double = 25       // -tlr 丢包率上限（%）
    @Published var attempts: Double = 4            // -t   每个 IP 延迟测速次数
    @Published var concurrency: Double = 60        // -n   延迟测速并发
    @Published var candidateTarget: Double = 800   //      候选 IP 总数（手机上别太贪）
    @Published var doDownload: Bool = true         // -dd  的反面：是否做下载测速
    @Published var downloadCount: Double = 10      // -dn  下载测速数量
    @Published var downloadSeconds: Double = 8     // -dt  单个 IP 下载测速时长

    // MARK: 状态
    @Published private(set) var results: [ScanResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "待开始。测速前请先关掉代理（Loon/Egern），否则测的是代理出口。"
    @Published private(set) var progress: Double = 0

    private var cancelled = false
    let testHost = "speed.cloudflare.com"

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        Task { await run() }
    }

    func stop() {
        cancelled = true
        statusText = "正在停止…"
    }

    private func run() async {
        isRunning = true
        cancelled = false
        results = []
        progress = 0

        // 先把设置快照下来，避免测速中途改设置影响本次结果
        let nAttempts = Int(attempts)
        let chunkSize = max(1, Int(concurrency))
        let latencyLimit = maxLatencyMs
        let lossLimit = lossLimitPct / 100
        let nDownload = Int(downloadCount)
        let dlSeconds = downloadSeconds
        let host = testHost

        let candidates = IPRanges.candidates(targetCount: Int(candidateTarget))
        guard !candidates.isEmpty else {
            statusText = "候选 IP 生成失败"
            isRunning = false
            return
        }

        // ---------- 第一阶段：延迟测速（分块并发） ----------
        statusText = "延迟测速中：0/\(candidates.count)"
        var tested: [ScanResult] = []
        var doneCount = 0
        var startIndex = 0
        while startIndex < candidates.count {
            if cancelled { break }
            let chunk = Array(candidates[startIndex..<min(startIndex + chunkSize, candidates.count)])
            let partial = await withTaskGroup(of: ScanResult?.self) { group in
                for ip in chunk {
                    group.addTask {
                        var samples: [Double] = []
                        for _ in 0..<nAttempts {
                            if let ms = await NetTest.tcpPing(ip: ip) {
                                samples.append(ms)
                            }
                        }
                        guard !samples.isEmpty else { return nil }
                        return ScanResult(
                            ip: ip,
                            sent: nAttempts,
                            received: samples.count,
                            avgLatencyMs: samples.reduce(0, +) / Double(samples.count),
                            downloadMBps: nil,
                            colo: nil
                        )
                    }
                }
                var acc: [ScanResult] = []
                for await r in group {
                    if let r { acc.append(r) }
                }
                return acc
            }
            tested.append(contentsOf: partial)
            doneCount += chunk.count
            progress = Double(doneCount) / Double(candidates.count) * (doDownload ? 0.8 : 1.0)
            statusText = "延迟测速中：\(doneCount)/\(candidates.count)，可用 \(tested.count)"
            startIndex += chunkSize
        }

        // ---------- 过滤 + 排序（丢包优先分组，其次延迟，和 CFST 一致） ----------
        var filtered = tested.filter { $0.avgLatencyMs <= latencyLimit && $0.lossRate <= lossLimit }
        filtered.sort {
            if $0.lossRate != $1.lossRate { return $0.lossRate < $1.lossRate }
            return $0.avgLatencyMs < $1.avgLatencyMs
        }

        if cancelled {
            statusText = "已停止。延迟阶段完成 \(doneCount)/\(candidates.count)，可用 \(filtered.count) 个"
            results = filtered
            isRunning = false
            return
        }
        guard !filtered.isEmpty else {
            statusText = "没有符合条件的 IP（延迟 ≤ \(Int(latencyLimit))ms、丢包 ≤ \(Int(lossLimitPct))%）。可以放宽上限再试。"
            results = []
            isRunning = false
            return
        }

        // ---------- 第二阶段：下载测速（从低延迟开始逐个测，和 CFST 一样） ----------
        if doDownload {
            let queueCount = min(nDownload, filtered.count)
            for i in 0..<queueCount {
                if cancelled { break }
                statusText = "下载测速 \(i + 1)/\(queueCount)：\(filtered[i].ip)"
                let ip = filtered[i].ip
                let outcome = await Task.detached {
                    NetTest.downloadTest(ip: ip, testHost: host, seconds: dlSeconds)
                }.value
                filtered[i].downloadMBps = outcome.mbps
                filtered[i].colo = outcome.colo
                results = Self.displaySorted(filtered)
                progress = 0.8 + 0.2 * Double(i + 1) / Double(queueCount)
            }
            filtered = Self.displaySorted(filtered)
            statusText = cancelled
                ? "已停止，已测 \(filtered.filter { $0.downloadMBps != nil }.count) 个下载速度"
                : "完成：\(filtered.count) 个 IP 通过筛选，第一名就是速度最快、延迟也低的那个"
        } else {
            statusText = "完成（已禁用下载测速，按延迟排序）：共 \(filtered.count) 个可用 IP"
        }

        results = filtered
        progress = 1
        isRunning = false
    }

    /// 有下载速度的按速度降序在前，其余按延迟升序排后面
    static func displaySorted(_ list: [ScanResult]) -> [ScanResult] {
        list.sorted {
            switch ($0.downloadMBps, $1.downloadMBps) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                if $0.lossRate != $1.lossRate { return $0.lossRate < $1.lossRate }
                return $0.avgLatencyMs < $1.avgLatencyMs
            }
        }
    }

    /// 导出的 CSV，格式与 CFST 的 result.csv 对齐
    var csvText: String {
        var lines = ["IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码"]
        for r in results {
            let speed = r.downloadMBps.map { String(format: "%.2f", $0) } ?? ""
            lines.append("\(r.ip),\(r.sent),\(r.received),\(String(format: "%.2f", r.lossRate)),\(String(format: "%.2f", r.avgLatencyMs)),\(speed),\(r.colo ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
