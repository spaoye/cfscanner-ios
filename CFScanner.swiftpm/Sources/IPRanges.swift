import Foundation

/// Cloudflare 官方公布的 IPv4 段（与 CFST 的 ip.txt 同源）。
/// 默认策略与 CFST 一致：每个 /24 随机抽 1 个 IP 测速；
/// 段太多时按步长均匀抽样，把候选总数压到 targetCount 附近（手机上跑得动）。
enum IPRanges {

    static let ipv4CIDRs: [String] = [
        "173.245.48.0/20",
        "103.21.244.0/22",
        "103.22.200.0/22",
        "103.31.4.0/22",
        "141.101.64.0/18",
        "108.162.192.0/18",
        "190.93.240.0/20",
        "188.114.96.0/20",
        "197.234.240.0/22",
        "198.41.128.0/17",
        "162.158.0.0/15",
        "104.16.0.0/13",
        "104.24.0.0/14",
        "172.64.0.0/13",
        "131.0.72.0/22"
    ]

    static func ipToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    static func uint32ToIP(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    /// 生成候选 IP 列表：枚举所有 /24 子网 -> 均匀抽样 -> 每段随机一个主机地址
    static func candidates(targetCount: Int) -> [String] {
        var subnets: [UInt32] = []   // 每个 /24 的网络地址
        for cidr in ipv4CIDRs {
            let pair = cidr.split(separator: "/")
            guard pair.count == 2,
                  let base = ipToUInt32(String(pair[0])),
                  let prefix = Int(pair[1]), prefix <= 24 else { continue }
            let count24 = 1 << (24 - prefix)
            for i in 0..<count24 {
                subnets.append(base + UInt32(i) * 256)
            }
        }
        guard !subnets.isEmpty else { return [] }

        let chosen: [UInt32]
        if subnets.count > targetCount && targetCount > 0 {
            let stride = Double(subnets.count) / Double(targetCount)
            var picked: [UInt32] = []
            var idx = 0.0
            while idx < Double(subnets.count) {
                picked.append(subnets[Int(idx)])
                idx += stride
            }
            chosen = picked
        } else {
            chosen = subnets
        }
        return chosen.map { uint32ToIP($0 + UInt32.random(in: 1...254)) }
    }

    /// 解析自选 IP 列表（兼容 CFST 的 ip.txt 与 result.csv）：
    /// 每行一个 IPv4 或 CIDR 网段，CSV 取第一列，# 开头是注释，空行跳过。
    /// CIDR 段直接展开（单段上限 65536 个，超大段随机抽 8192 个），结果去重、保序。
    static func parseCustomList(_ text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ ip: String) {
            if seen.insert(ip).inserted { result.append(ip) }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let comma = line.firstIndex(of: ",") {
                line = String(line[..<comma]).trimmingCharacters(in: .whitespaces)
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if line.isEmpty { continue }
            if line.contains("/") {
                let pair = line.split(separator: "/")
                guard pair.count == 2,
                      let base = ipToUInt32(String(pair[0])),
                      let prefix = Int(pair[1]), (0...32).contains(prefix) else { continue }
                let hostBits = 32 - prefix
                let total = UInt64(1) << UInt64(hostBits)   // hostBits 最大 32，UInt64 装得下
                let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
                let network = base & mask
                if total <= 65536 {
                    for i in 0..<UInt32(total) { add(uint32ToIP(network &+ i)) }
                } else {
                    for _ in 0..<8192 {
                        add(uint32ToIP(network &+ UInt32(truncatingIfNeeded: UInt64.random(in: 0..<total))))
                    }
                }
            } else if ipToUInt32(line) != nil {
                add(line)
            }
        }
        return result
    }
}
