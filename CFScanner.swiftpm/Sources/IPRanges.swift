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
}
