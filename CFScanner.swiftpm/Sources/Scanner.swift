import Foundation

/// 目标地区：按连接实测的落点（机房/国家）过滤，不是按 IP 归属——
/// CF 是 anycast，同一个 IP 在不同网络、不同时间可能落到不同机房，只能现测现筛。
enum RegionPreference: String, CaseIterable, Identifiable {
    case local, any, hongKong, taiwan, singapore, japan, korea, usWest, usEast, europe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "本地（自动探测）"
        case .any: return "不限"
        case .hongKong: return "香港"
        case .taiwan: return "台湾"
        case .singapore: return "新加坡"
        case .japan: return "日本"
        case .korea: return "韩国"
        case .usWest: return "美国西部"
        case .usEast: return "美国东部"
        case .europe: return "欧洲"
        }
    }

    /// 按国家匹配的地区（用 trace 响应里的 loc 字段）
    var countries: Set<String>? {
        switch self {
        case .hongKong: return ["HK"]
        case .taiwan: return ["TW"]
        case .singapore: return ["SG"]
        case .japan: return ["JP"]
        case .korea: return ["KR"]
        case .europe: return ["GB", "DE", "FR", "NL", "ES", "IT", "SE", "CH", "AT", "PL", "BE", "DK", "NO", "FI", "IE", "PT", "CZ"]
        default: return nil
        }
    }

    /// 按机房代码匹配的地区（美国东西部同属一个国家，只能按机房分）
    var colos: Set<String>? {
        switch self {
        case .usWest: return ["LAX", "SJC", "SFO", "SEA", "PDX", "SLC", "DEN", "PHX", "LAS", "SAN"]
        case .usEast: return ["IAD", "EWR", "JFK", "LGA", "BOS", "ORD", "DFW", "IAH", "ATL", "MIA", "CLT", "DTW", "MSP", "BNA", "STL", "CMH", "IND"]
        default: return nil
        }
    }

    func matches(colo: String?, country: String?) -> Bool {
        if let colos { return colo.map { colos.contains($0) } ?? false }
        if let countries { return country.map { countries.contains($0) } ?? false }
        return true
    }
}

struct ScanResult: Identifiable {
    let id = UUID()
    let ip: String
    var sent: Int
    var received: Int
    var avgLatencyMs: Double
    var downloadMBps: Double?
    var colo: String?
    var country: String? = nil
    var note: String? = nil
    var lossRate: Double { sent > 0 ? Double(sent - received) / Double(sent) : 1 }
}

@MainActor
final class Scanner: ObservableObject {

    // MARK: 设置（界面直接绑定，默认值对齐 CFST）
    @Published var region: RegionPreference = .local {   // 目标地区（按实测落点过滤；默认本地自动探测）
        didSet { UserDefaults.standard.set(region.rawValue, forKey: Self.regionKey) }
    }
    private static let regionKey = "cfscanner.region"
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

    // MARK: 自选 IP 列表（导入后持久化，优先于官方段随机抽样）
    @Published private(set) var customListName: String?
    @Published private(set) var customListCount: Int = 0
    private var customIPs: [String]?
    private static let customTextKey = "cfscanner.customIPText"
    private static let customNameKey = "cfscanner.customIPName"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.regionKey),
           let saved = RegionPreference(rawValue: raw) {
            region = saved
        }
        if let text = UserDefaults.standard.string(forKey: Self.customTextKey),
           let name = UserDefaults.standard.string(forKey: Self.customNameKey) {
            let ips = IPRanges.parseCustomList(text)
            if !ips.isEmpty {
                customIPs = ips
                customListName = name
                customListCount = ips.count
            }
        }
    }

    /// 导入自选 IP 文件内容；解析不到有效 IP 时不保存并说明原因
    func importCustomList(text: String, name: String) {
        let ips = IPRanges.parseCustomList(text)
        guard !ips.isEmpty else {
            statusText = "导入失败：\(name) 里没找到有效的 IP 或网段（每行一个 IP，或 104.16.0.0/24 这样的网段，CSV 取第一列）。"
            return
        }
        customIPs = ips
        customListName = name
        customListCount = ips.count
        UserDefaults.standard.set(text, forKey: Self.customTextKey)
        UserDefaults.standard.set(name, forKey: Self.customNameKey)
        statusText = "已导入自选列表：\(name)，共 \(ips.count) 个 IP。下次测速只测这些。"
    }

    func clearCustomList() {
        customIPs = nil
        customListName = nil
        customListCount = 0
        UserDefaults.standard.removeObject(forKey: Self.customTextKey)
        UserDefaults.standard.removeObject(forKey: Self.customNameKey)
        statusText = "已清除自选列表，恢复用 Cloudflare 官方 IP 段随机抽样。"
    }

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
        let regionPref = region
        let latencyShare = regionPref == .any ? (doDownload ? 0.8 : 1.0) : 0.7

        let candidates: [String]
        if let custom = customIPs, !custom.isEmpty {
            // 自选列表优先；太多时随机抽 8000 个（手机上跑完一轮的时间上限）
            candidates = custom.count > 8000 ? Array(custom.shuffled().prefix(8000)) : custom
        } else {
            candidates = IPRanges.candidates(targetCount: Int(candidateTarget))
        }
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
            progress = Double(doneCount) / Double(candidates.count) * latencyShare
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

        // ---------- 地区筛选：从最低延迟开始逐批探测落点，只留目标地区的 ----------
        // 「本地」模式：先探测最快的一批 IP 实际落到哪个机房，出现最多的那个就是
        // 当前网络的本地落点，之后按它过滤（换网络/换运营商，落点会自动跟着变）。
        if regionPref != .any {
            let isLocal = regionPref == .local
            let want = doDownload ? max(nDownload, 1) : Int.max
            var matched: [ScanResult] = []
            var probed = Set<String>()
            var idx = 0
            let batchSize = 20
            var detectedColo: String?
            var detectedCountry: String?
            while idx < filtered.count && matched.count < want && probed.count < 200 {
                if cancelled { break }
                let batch = Array(filtered[idx..<min(idx + batchSize, filtered.count)])
                idx += batch.count
                let infos = await withTaskGroup(of: (String, String?, String?).self) { group in
                    for r in batch {
                        group.addTask {
                            let p = await NetTest.probe(ip: r.ip, testHost: host)
                            return (r.ip, p.colo, p.country)
                        }
                    }
                    var acc: [(String, String?, String?)] = []
                    for await v in group { acc.append(v) }
                    return acc
                }
                var byIP: [String: (colo: String?, country: String?)] = [:]
                for (ip, colo, country) in infos { byIP[ip] = (colo, country) }
                for j in filtered.indices {
                    if let info = byIP[filtered[j].ip] {
                        filtered[j].colo = info.colo
                        filtered[j].country = info.country
                    }
                }
                // 本地模式：第一批探测完就定主落点（出现次数最多，同票取先出现的，即延迟更低那批里的）
                if isLocal && detectedColo == nil {
                    var counts: [String: Int] = [:]
                    var order: [String] = []
                    for r in batch {
                        guard let j = filtered.firstIndex(where: { $0.ip == r.ip }),
                              let c = filtered[j].colo else { continue }
                        if counts[c] == nil { order.append(c) }
                        counts[c, default: 0] += 1
                    }
                    var bestCount = -1
                    for c in order where counts[c]! > bestCount {
                        detectedColo = c
                        bestCount = counts[c]!
                    }
                    if let dc = detectedColo,
                       let j = filtered.firstIndex(where: { $0.colo == dc }) {
                        detectedCountry = filtered[j].country
                    }
                }
                for r in batch {
                    probed.insert(r.ip)
                    guard let j = filtered.firstIndex(where: { $0.ip == r.ip }) else { continue }
                    let hit = isLocal
                        ? (detectedColo != nil && filtered[j].colo == detectedColo)
                        : regionPref.matches(colo: filtered[j].colo, country: filtered[j].country)
                    if hit && !matched.contains(where: { $0.ip == r.ip }) {
                        matched.append(filtered[j])
                    }
                }
                let label = isLocal ? "本地·\(detectedColo ?? "探测中")" : regionPref.label
                statusText = "地区筛选中（\(label)）：已探测 \(probed.count) 个，命中 \(matched.count) 个"
                progress = 0.7 + 0.15 * Double(probed.count) / Double(max(filtered.count, 1))
                results = Self.displaySorted(filtered.filter { probed.contains($0.ip) })
            }
            if cancelled {
                let label = isLocal ? "本地·\(detectedColo ?? "未定")" : regionPref.label
                statusText = "已停止。地区筛选（\(label)）命中 \(matched.count) 个"
                results = matched
                progress = 1
                isRunning = false
                return
            }
            if isLocal && detectedColo == nil {
                // 一个落点都没探到（网络异常等）：不硬筛，按不限地区继续后面的流程
                statusText = "落点探测失败（探测了 \(probed.count) 个都没拿到机房信息），已按不限地区继续。"
            } else {
                guard !matched.isEmpty else {
                    statusText = "探测了 \(probed.count) 个低延迟 IP，没有实际落到\(regionPref.label)的（它们的真实落点见列表中的地区码）。可以换个地区，或选不限。"
                    results = filtered.filter { probed.contains($0.ip) }
                    progress = 1
                    isRunning = false
                    return
                }
                filtered = matched
                statusText = isLocal
                    ? "本地筛选完成：你的网络主要落到 \(detectedColo!)（\(Self.countryName(detectedCountry))），命中 \(matched.count) 个 IP"
                    : "地区筛选完成：\(matched.count) 个 IP 落在\(regionPref.label)"
            }
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
                filtered[i].note = outcome.note
                results = Self.displaySorted(filtered)
                progress = (regionPref == .any ? 0.8 : 0.85) + (regionPref == .any ? 0.2 : 0.15) * Double(i + 1) / Double(queueCount)
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

    /// 国家代码转中文名（状态栏显示本地落点时用）
    static func countryName(_ code: String?) -> String {
        switch code {
        case "HK": return "香港"
        case "TW": return "台湾"
        case "SG": return "新加坡"
        case "JP": return "日本"
        case "KR": return "韩国"
        case "US": return "美国"
        case "CN": return "中国大陆"
        case nil: return "未知"
        default: return code!
        }
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
