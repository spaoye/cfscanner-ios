import Foundation
import UIKit

/// 目标地区：按连接实测的落点（机房/国家）过滤，不是按 IP 归属——
/// CF 是 anycast，同一个 IP 在不同网络、不同时间可能落到不同机房，只能现测现筛。
enum RegionPreference: String, CaseIterable, Identifiable {
    case carrier, local, any, hongKong, taiwan, singapore, japan, korea, usWest, usEast, europe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .carrier: return "本地（按运营商）"
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

/// 本地运营商：三家运营商到 Cloudflare 各机房的路由质量差别很大，
/// 按运营商给一组优先落点（社区常用优选经验），再用实测落点筛选、按实测速度排名。
enum Carrier: String, CaseIterable, Identifiable {
    case telecom, unicom, mobile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .telecom: return "中国电信"
        case .unicom: return "中国联通"
        case .mobile: return "中国移动"
        }
    }

    /// 上传协议里的运营商短名（中转按 地区+运营商 分池，必须是这三个词）
    var shortLabel: String {
        switch self {
        case .telecom: return "电信"
        case .unicom: return "联通"
        case .mobile: return "移动"
        }
    }

    /// 该运营商的优先机房代码集合
    var colos: Set<String> {
        switch self {
        case .telecom: return ["HKG", "NRT", "KIX", "SIN", "LAX", "SJC"]
        case .unicom: return ["HKG", "TPE", "NRT", "KIX", "SIN", "ICN"]
        case .mobile: return ["HKG", "SIN", "NRT", "TPE", "ICN", "LAX"]
        }
    }

    var coloListText: String {
        switch self {
        case .telecom: return "HKG/NRT/KIX/SIN/LAX/SJC"
        case .unicom: return "HKG/TPE/NRT/KIX/SIN/ICN"
        case .mobile: return "HKG/SIN/NRT/TPE/ICN/LAX"
        }
    }
}

/// 下载测速接口：向候选 IP 请求哪个文件来计速。候选 IP 是 Cloudflare 边缘，
/// 所以测速文件本身也必须挂在 Cloudflare 后面（两个预置都满足）。
enum DownloadSource: String, CaseIterable, Identifiable {
    case parallels, cloudflare, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .parallels: return "Parallels（exe 同款）"
        case .cloudflare: return "Cloudflare 官方"
        case .custom: return "自定义地址"
        }
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
    /// 历轮下载测速的原始成绩（第一轮 + 决赛复测），算上传用的可信度/稳定性
    var speedSamples: [Double] = []
    var lossRate: Double { sent > 0 ? Double(sent - received) / Double(sent) : 1 }
}

@MainActor
final class Scanner: ObservableObject {

    // MARK: 设置（界面直接绑定，默认值对齐 CFST）
    @Published var region: RegionPreference = .carrier {   // 目标地区（按实测落点过滤；默认按本地运营商）
        didSet { UserDefaults.standard.set(region.rawValue, forKey: Self.regionKey) }
    }
    private static let regionKey = "cfscanner.region"
    private static let regionMigratedKey = "cfscanner.regionMigratedV2"
    /// 运营商选择：auto（自动识别）/ telecom / unicom / mobile，仅「本地（按运营商）」模式用
    @Published var carrierChoice: String = "auto" {
        didSet { UserDefaults.standard.set(carrierChoice, forKey: Self.carrierKey) }
    }
    private static let carrierKey = "cfscanner.carrier"
    @Published var maxLatencyMs: Double = 200      // -tl  平均延迟上限
    @Published var lossLimitPct: Double = 25       // -tlr 丢包率上限（%）
    @Published var attempts: Double = 4            // -t   每个 IP 延迟测速次数
    @Published var concurrency: Double = 60        // -n   延迟测速并发
    @Published var candidateTarget: Double = 800   //      候选 IP 总数（手机上别太贪）
    @Published var doDownload: Bool = true         // -dd  的反面：是否做下载测速
    @Published var downloadCount: Double = 15      // -dn  下载测速数量
    @Published var downloadSeconds: Double = 8     // -dt  单个 IP 下载测速时长
    @Published var downloadSource: DownloadSource = .parallels {   // 下载测速接口（默认 exe 同款）
        didSet { UserDefaults.standard.set(downloadSource.rawValue, forKey: Self.downloadSourceKey) }
    }
    @Published var customDownloadURL: String = "" {                // downloadSource == .custom 时用
        didSet { UserDefaults.standard.set(customDownloadURL, forKey: Self.customDownloadURLKey) }
    }
    private static let downloadSourceKey = "cfscanner.downloadSource"
    private static let customDownloadURLKey = "cfscanner.customDownloadURL"

    /// 当前测速接口的 (域名, 路径)：连接打到候选 IP，SNI/Host 用这个域名
    var downloadEndpoint: (host: String, path: String) {
        switch downloadSource {
        case .cloudflare:
            // 官方 /__down：bytes 必须 < 100000000，否则 403（构建 1 的坑）
            return ("speed.cloudflare.com", "/__down?bytes=90000000")
        case .parallels:
            // exe 内置 cfstd 配置同款：download.parallels.com 本身在 Cloudflare 后面，333MB dmg
            return ("download.parallels.com", "/desktop/v17/17.1.1-51537/ParallelsDesktop-17.1.1-51537.dmg")
        case .custom:
            let text = customDownloadURL.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: text), let h = url.host, !h.isEmpty {
                var path = url.path.isEmpty ? "/" : url.path
                if let q = url.query, !q.isEmpty { path += "?" + q }
                return (h, path)
            }
            return ("download.parallels.com", "/desktop/v17/17.1.1-51537/ParallelsDesktop-17.1.1-51537.dmg")
        }
    }

    // MARK: 结果上传设置（总开关默认关；关时就是普通优选 App，不发出任何上传请求）
    @Published var uploadEnabled: Bool = false {
        didSet { UserDefaults.standard.set(uploadEnabled, forKey: Self.uploadEnabledKey) }
    }
    @Published var uploadAPIURL: String = "https://api.8888345.xyz/api/client/uploadResult" {
        didSet { UserDefaults.standard.set(uploadAPIURL, forKey: Self.uploadAPIKey) }
    }
    @Published var uploadToken: String = "" {
        didSet { UserDefaults.standard.set(uploadToken, forKey: Self.uploadTokenKey) }
    }
    @Published var uploadRegion: String = "北京" {
        didSet { UserDefaults.standard.set(uploadRegion, forKey: Self.uploadRegionKey) }
    }
    @Published var uploadMinSpeed: Double = 10 {   // 上传门槛 MB/s（0 = 不设门槛）
        didSet { UserDefaults.standard.set(uploadMinSpeed, forKey: Self.uploadMinSpeedKey) }
    }
    @Published var autoUpload: Bool = false {       // 测完自动上传（仅总开关打开时生效）
        didSet { UserDefaults.standard.set(autoUpload, forKey: Self.autoUploadKey) }
    }
    private static let uploadEnabledKey = "cfscanner.uploadEnabled"
    private static let uploadAPIKey = "cfscanner.uploadAPIURL"
    private static let uploadTokenKey = "cfscanner.uploadToken"
    private static let uploadRegionKey = "cfscanner.uploadRegion"
    private static let uploadMinSpeedKey = "cfscanner.uploadMinSpeed"
    private static let autoUploadKey = "cfscanner.autoUpload"

    // 上传状态（界面显示；与测速状态分开，免得互相覆盖）
    @Published private(set) var uploadStatus: String = ""
    @Published private(set) var isUploading = false
    /// 最近一轮测速定下的运营商与完成时间（上传时标注 地区/运营商 用）
    private var lastCarrier: Carrier?
    private var lastFinishedAt: Date?

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
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.regionKey),
           let saved = RegionPreference(rawValue: raw) {
            // 一次性迁移：老默认「本地（自动探测）」升到「本地（按运营商）」（用户明确要求按运营商优选）；
            // 之后用户再手动改回去，不会被二次迁移
            if saved == .local && !defaults.bool(forKey: Self.regionMigratedKey) {
                region = .carrier
                defaults.set(true, forKey: Self.regionMigratedKey)
                defaults.set(RegionPreference.carrier.rawValue, forKey: Self.regionKey)
            } else {
                region = saved
            }
        }
        if let c = defaults.string(forKey: Self.carrierKey) {
            carrierChoice = c
        }
        uploadEnabled = defaults.bool(forKey: Self.uploadEnabledKey)
        if let u = defaults.string(forKey: Self.uploadAPIKey), !u.isEmpty { uploadAPIURL = u }
        uploadToken = defaults.string(forKey: Self.uploadTokenKey) ?? ""
        if let r = defaults.string(forKey: Self.uploadRegionKey), !r.isEmpty { uploadRegion = r }
        if defaults.object(forKey: Self.uploadMinSpeedKey) != nil {
            uploadMinSpeed = defaults.double(forKey: Self.uploadMinSpeedKey)
        }
        autoUpload = defaults.bool(forKey: Self.autoUploadKey)
        if let raw = defaults.string(forKey: Self.downloadSourceKey),
           let src = DownloadSource(rawValue: raw) {
            downloadSource = src
        }
        customDownloadURL = defaults.string(forKey: Self.customDownloadURLKey) ?? ""
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
            statusText = "导入失败：\(name) 里没找到有效的 IP。支持纯 IP、IP:端口、https://IP、104.16.0.0/24 网段；纯域名的行会被跳过。"
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

    // MARK: 屏幕常亮（测速/上传期间不黑屏，结束或停止后恢复系统自动锁屏）
    private func setRunning(_ value: Bool) {
        isRunning = value
        updateIdleTimer()
    }

    private func setUploading(_ value: Bool) {
        isUploading = value
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isRunning || isUploading
    }

    private func run() async {
        setRunning(true)
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
        let carrierChoiceSnap = carrierChoice
        let dlEndpoint = downloadEndpoint
        let latencyShare = regionPref == .any ? (doDownload ? 0.8 : 1.0) : 0.7

        // 运营商模式：先定运营商（手动选择优先，其次自动识别当前网络出口的运营商）
        var activeCarrier: Carrier? = nil
        var carrierSource = ""
        if regionPref == .carrier {
            if let manual = Carrier(rawValue: carrierChoiceSnap) {
                activeCarrier = manual
                carrierSource = "手动选择"
            } else {
                statusText = "正在识别本地运营商…"
                if let detected = await NetTest.detectCarrier() {
                    activeCarrier = detected
                    carrierSource = "自动识别"
                }
            }
            if let c = activeCarrier {
                statusText = "运营商：\(c.label)（\(carrierSource)），优先落点 \(c.coloListText)，开始测速"
            } else {
                statusText = "运营商识别失败，已改用自动探测主落点（也可以在参数里手动选运营商）"
            }
            lastCarrier = activeCarrier
        }

        let candidates: [String]
        if let custom = customIPs, !custom.isEmpty {
            // 自选列表优先；太多时随机抽 8000 个（手机上跑完一轮的时间上限）
            candidates = custom.count > 8000 ? Array(custom.shuffled().prefix(8000)) : custom
        } else {
            candidates = IPRanges.candidates(targetCount: Int(candidateTarget))
        }
        guard !candidates.isEmpty else {
            statusText = "候选 IP 生成失败"
            setRunning(false)
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
            setRunning(false)
            return
        }
        guard !filtered.isEmpty else {
            statusText = "没有符合条件的 IP（延迟 ≤ \(Int(latencyLimit))ms、丢包 ≤ \(Int(lossLimitPct))%）。可以放宽上限再试。"
            results = []
            setRunning(false)
            return
        }

        // ---------- 地区筛选：从最低延迟开始逐批探测落点，只留目标地区的 ----------
        // 「本地（自动探测）」：先探测最快的一批 IP 实际落到哪个机房，出现最多的那个就是
        // 当前网络的本地落点，之后按它过滤。
        // 「本地（按运营商）」：只留落到该运营商优先机房的 IP；优先机房一个都没命中时，
        // 退回按实际主落点筛选并在状态栏说明，不让用户空手而归。
        if regionPref != .any {
            let isCarrier = regionPref == .carrier && activeCarrier != nil
            let isLocal = regionPref == .local || (regionPref == .carrier && activeCarrier == nil)
            let probeCap = isCarrier ? 400 : 200
            let want = doDownload ? max(nDownload, 1) : Int.max
            var matched: [ScanResult] = []
            var probed = Set<String>()
            var idx = 0
            let batchSize = 20
            var detectedColo: String?
            var detectedCountry: String?
            var coloCounts: [String: Int] = [:]
            while idx < filtered.count && matched.count < want && probed.count < probeCap {
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
                for r in batch {
                    if let j = filtered.firstIndex(where: { $0.ip == r.ip }),
                       let c = filtered[j].colo {
                        coloCounts[c, default: 0] += 1
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
                    let hit: Bool
                    if isCarrier {
                        hit = filtered[j].colo.map { activeCarrier!.colos.contains($0) } ?? false
                    } else if isLocal {
                        hit = detectedColo != nil && filtered[j].colo == detectedColo
                    } else {
                        hit = regionPref.matches(colo: filtered[j].colo, country: filtered[j].country)
                    }
                    if hit && !matched.contains(where: { $0.ip == r.ip }) {
                        matched.append(filtered[j])
                    }
                }
                let label = isCarrier ? "\(activeCarrier!.label)·优选落点"
                    : isLocal ? "本地·\(detectedColo ?? "探测中")" : regionPref.label
                statusText = "地区筛选中（\(label)）：已探测 \(probed.count) 个，命中 \(matched.count) 个"
                progress = 0.7 + 0.15 * Double(probed.count) / Double(max(filtered.count, 1))
                results = Self.displaySorted(filtered.filter { probed.contains($0.ip) })
            }
            if cancelled {
                let label = isCarrier ? "\(activeCarrier!.label)·优选落点"
                    : isLocal ? "本地·\(detectedColo ?? "未定")" : regionPref.label
                statusText = "已停止。地区筛选（\(label)）命中 \(matched.count) 个"
                results = matched
                progress = 1
                setRunning(false)
                return
            }
            // 运营商模式兜底：优先机房零命中时改按实际主落点筛
            var fellBackNote: String? = nil
            if isCarrier && matched.isEmpty,
               let dom = coloCounts.max(by: { $0.value < $1.value })?.key {
                matched = filtered.filter { probed.contains($0.ip) && $0.colo == dom }
                let country = filtered.first(where: { $0.colo == dom })?.country
                fellBackNote = "没有 IP 落到\(activeCarrier!.label)的优先机房（\(activeCarrier!.coloListText)），已按实际主落点 \(dom)（\(Self.countryName(country))）筛选，命中 \(matched.count) 个"
            }
            if isLocal && detectedColo == nil {
                // 一个落点都没探到（网络异常等）：不硬筛，按不限地区继续后面的流程
                statusText = "落点探测失败（探测了 \(probed.count) 个都没拿到机房信息），已按不限地区继续。"
            } else if matched.isEmpty {
                statusText = "探测了 \(probed.count) 个低延迟 IP，没有实际落到\(regionPref.label)的（它们的真实落点见列表中的地区码）。可以换个地区，或选不限。"
                results = filtered.filter { probed.contains($0.ip) }
                progress = 1
                setRunning(false)
                return
            } else {
                filtered = matched
                statusText = fellBackNote ?? (isLocal
                    ? "本地筛选完成：你的网络主要落到 \(detectedColo!)（\(Self.countryName(detectedCountry))），命中 \(matched.count) 个 IP"
                    : isCarrier
                    ? "运营商筛选完成：\(activeCarrier!.label)优先落点命中 \(matched.count) 个 IP"
                    : "地区筛选完成：\(matched.count) 个 IP 落在\(regionPref.label)")
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
                    NetTest.downloadTest(ip: ip, host: dlEndpoint.host, path: dlEndpoint.path, seconds: dlSeconds)
                }.value
                filtered[i].downloadMBps = outcome.mbps
                filtered[i].speedSamples = [outcome.mbps]
                if let c = outcome.colo { filtered[i].colo = c }
                filtered[i].note = outcome.note
                results = Self.displaySorted(filtered)
                progress = (regionPref == .any ? 0.8 : 0.85) + (regionPref == .any ? 0.2 : 0.15) * Double(i + 1) / Double(queueCount)
            }
            // 决赛复测：第一轮前 5 名再测一轮、取两次里的更好成绩——
            // 避免某个 IP 只因测速那几秒的瞬时拥塞被埋没，或靠运气冲到第一
            var retested = false
            if !cancelled {
                let ranked = filtered.indices
                    .filter { (filtered[$0].downloadMBps ?? 0) > 0 }
                    .sorted { (filtered[$0].downloadMBps ?? 0) > (filtered[$1].downloadMBps ?? 0) }
                let finalists = Array(ranked.prefix(5))
                retested = !finalists.isEmpty
                for (k, i) in finalists.enumerated() {
                    if cancelled { break }
                    statusText = "决赛复测 \(k + 1)/\(finalists.count)：\(filtered[i].ip)"
                    let ip = filtered[i].ip
                    let outcome = await Task.detached {
                        NetTest.downloadTest(ip: ip, host: dlEndpoint.host, path: dlEndpoint.path, seconds: dlSeconds)
                    }.value
                    if outcome.mbps > (filtered[i].downloadMBps ?? 0) {
                        filtered[i].downloadMBps = outcome.mbps
                        if let c = outcome.colo { filtered[i].colo = c }
                        filtered[i].note = outcome.note
                    }
                    filtered[i].speedSamples.append(outcome.mbps)
                    results = Self.displaySorted(filtered)
                }
            }
            filtered = Self.displaySorted(filtered)
            statusText = cancelled
                ? "已停止，已测 \(filtered.filter { $0.downloadMBps != nil }.count) 个下载速度"
                : "完成：\(filtered.count) 个 IP 通过筛选\(retested ? "（前 5 名经复测取最佳）" : "")，第一名就是速度最快、延迟也低的那个"
        } else {
            statusText = "完成（已禁用下载测速，按延迟排序）：共 \(filtered.count) 个可用 IP"
        }

        results = filtered
        progress = 1
        setRunning(false)
        lastFinishedAt = Date()

        // 测完自动上传：仅当总开关与自动上传都开、且本轮没被手动停止时
        if uploadEnabled && autoUpload && !cancelled {
            await uploadResults()
        }
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

    // MARK: 结果上传（总开关关闭时以下方法不会被调用）

    /// 把本轮结果按 exe 3.0 协议上传到中转。
    /// 自动上传（manual=false）：只传达标（≥ 门槛）的前 10 名。
    /// 手动上传（manual=true）：不限门槛，传速度最快的前 5 名——没达到上传要求时也能手动传。
    func uploadResults(manual: Bool = false) async {
        guard uploadEnabled else { return }
        guard !isUploading else { return }
        let token = uploadToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            uploadStatus = "上传失败：请先在「结果上传」里填上传令牌"
            return
        }
        let regionText = uploadRegion.trimmingCharacters(in: .whitespaces)
        guard !regionText.isEmpty else {
            uploadStatus = "上传失败：地区不能为空（要和面板里 broker 地区一致）"
            return
        }
        // 候选：有下载成绩的按速度降序；自动上传要过门槛取前 10，手动上传不限门槛取前 5
        let bySpeed = results
            .filter { ($0.downloadMBps ?? 0) > 0 }
            .sorted { ($0.downloadMBps ?? 0) > ($1.downloadMBps ?? 0) }
        let items: [ScanResult]
        if manual {
            items = Array(bySpeed.prefix(5))
            guard !items.isEmpty else {
                uploadStatus = "没有带下载速度的结果可上传（先跑完一轮下载测速）"
                return
            }
        } else {
            let minSpeed = uploadMinSpeed
            items = Array(bySpeed.filter { ($0.downloadMBps ?? 0) >= max(minSpeed, 0.01) }.prefix(10))
            guard !items.isEmpty else {
                uploadStatus = "没有达到 \(Int(minSpeed)) MB/s 门槛的结果，未上传（共 \(results.count) 条结果）"
                return
            }
        }
        // 运营商：优先用本轮测速定下的，其次参数里的手动选择，最后现场识别一次
        var carrier = lastCarrier ?? Carrier(rawValue: carrierChoice)
        if carrier == nil {
            carrier = await NetTest.detectCarrier()
        }
        guard let isp = carrier else {
            uploadStatus = "上传失败：无法确定运营商（在参数里手动选一次运营商再测，或检查网络）"
            return
        }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let testedAt = fmt.string(from: lastFinishedAt ?? Date())
        let coloSet = Array(Set(items.compactMap { $0.colo })).sorted().joined(separator: ",")

        let bodyItems: [[String: Any]] = items.map { r in
            let speed = r.downloadMBps ?? 0
            // 可信度：复测过的看两轮接近程度（越接近越可信）；只测一轮的给中间值
            let trust: Double
            let notes: String
            if r.speedSamples.count >= 2, let a = r.speedSamples.first, let b = r.speedSamples.last {
                let hi = max(a, b)
                let spread = hi > 0 ? (hi - min(a, b)) / hi : 0
                trust = min(1, max(0, 1 - spread))
                notes = spread <= 0.1 ? "两轮测速稳定" : spread <= 0.25 ? "两轮测速基本稳定" : "两轮测速波动较大"
            } else {
                trust = 0.5
                notes = "单轮测速"
            }
            let score = (speed * trust * (1 - r.lossRate) * 100).rounded() / 100
            return [
                "ip": r.ip,
                "sent": r.sent,
                "recv": r.received,
                "loss": (r.lossRate * 10000).rounded() / 10000,
                "latency": (r.avgLatencyMs * 100).rounded() / 100,
                "speed": (speed * 100).rounded() / 100,
                "colo": r.colo ?? "",
                "score": score,
                "trust": (trust * 100).rounded() / 100,
                "reliability_notes": notes,
                "strategy": "cfscanner-ios",
                "scan_mode": "tcping",
                "cfcolo": coloSet,
                "tested_at": testedAt
            ]
        }
        let body: [String: Any] = [
            "client_version": "3.0",
            "type": "v4",
            "region": regionText,
            "isp": isp.shortLabel,
            "items": bodyItems
        ]

        setUploading(true)
        uploadStatus = manual
            ? "正在手动上传 \(items.count) 条（速度前 \(items.count)，不限门槛 / \(regionText) / \(isp.shortLabel)）…"
            : "正在上传 \(items.count) 条（\(regionText) / \(isp.shortLabel)）…"
        let outcome = await Uploader.upload(
            apiURL: uploadAPIURL.trimmingCharacters(in: .whitespaces),
            token: token,
            body: body
        )
        setUploading(false)
        switch outcome {
        case .success(let saved):
            uploadStatus = saved >= 0
                ? "上传完成：中转已确认保存 \(saved) 条（\(regionText) / \(isp.shortLabel)）"
                : "上传完成：已提交 \(items.count) 条（\(regionText) / \(isp.shortLabel)）"
        case .failure(let err):
            uploadStatus = "上传失败：\(err.message)"
        }
    }

    /// 验证上传令牌（设置时用）：成功会显示中转登记的客户端名
    func verifyUploadToken() async {
        let token = uploadToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            uploadStatus = "请先填上传令牌"
            return
        }
        guard !isUploading else { return }
        setUploading(true)
        uploadStatus = "正在验证令牌…"
        let outcome = await Uploader.verifyToken(
            apiURL: uploadAPIURL.trimmingCharacters(in: .whitespaces),
            token: token
        )
        setUploading(false)
        switch outcome {
        case .success(let name):
            uploadStatus = name.isEmpty ? "令牌验证通过" : "令牌验证通过：\(name)"
        case .failure(let err):
            uploadStatus = err.message
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
