# CF 优选测速（iOS 版）

XIU2/CloudflareSpeedTest 的 iOS 复刻，算法和原版一致：

1. 从 Cloudflare 官方 IP 段里按 /24 随机抽样出候选 IP
2. 延迟测速（TCPing，443 端口，就是原版的默认模式）
3. 按丢包率、平均延迟过滤排序
4. 对最快的几个逐个下载测速：连接打到候选 IP，但 TLS 的 SNI 和 HTTP 的 Host 用 `speed.cloudflare.com`（Cloudflare 官方测速域名），地区码从响应头 `CF-RAY` 解析
5. 结果按下载速度排序，第一名就是原版说的「既最快、延迟也低」的那个；点一行复制 IP，也可导出 CSV（格式与原版 result.csv 一致）

## 为什么是源码包而不是现成的 IPA

打包、签名 IPA 必须在 macOS + Xcode 里用你自己的 Apple ID 证书完成，我这边的 Linux 环境签不了。所以交付的是 **Swift Playgrounds App 包（.swiftpm）**，两种打开方式：

### 方式一：iPad 上的 Swift Playgrounds（不用电脑）

1. 把 zip 存到「文件」App 并解压，得到 `CFScanner.swiftpm`
2. 在 Swift Playgrounds 里打开它（或在文件 App 里点它，会跳转过去）
3. 点右上角运行按钮，App 就在这台 iPad 上跑起来了

### 方式二：Mac 上的 Xcode（装到 iPhone 用这个）

1. 解压后双击 `CFScanner.swiftpm`，用 Xcode 打开
2. Xcode 设置里登录你自己的 Apple ID（免费账号就行）
3. 数据线连上 iPhone，顶部设备选你的 iPhone，点运行
4. iPhone 上第一次要开「开发者模式」（设置 → 隐私与安全性 → 开发者模式），并在 设置 → 通用 → VPN与设备管理 里信任你的证书

免费签名的 App **7 天过期**，过期后回 Xcode 重新运行一次即可；付费开发者账号签的是 1 年。

## 使用提醒

- **测速前关掉 Loon/Egern 等代理**，否则测的全是代理出口的速度（原版 CFST 也是这个要求）
- 在哪个网络下测，结果就只代表那个网络；Wi-Fi 和蜂窝要分开测
- 每次测速结果不一样是正常的：每段随机抽的 IP 不同（和原版一样）

## 参数对照（和 CFST 命令行）

| 本 App | CFST 参数 | 说明 |
|---|---|---|
| 平均延迟上限 | `-tl` | 只保留平均延迟低于此值的 IP |
| 丢包率上限 | `-tlr` | 只保留丢包率低于此值的 IP |
| 每个 IP 测速次数 | `-t` | 默认 4 次 |
| 延迟测速并发 | `-n` | 手机上默认 60，别开太高 |
| 下载测速数量 | `-dn` | 默认 10 个 |
| 单个下载时长 | `-dt` | 默认 8 秒 |
| 下载测速开关（关） | `-dd` | 关掉后结果按延迟排序 |
| 候选 IP 总数 | — | 手机端新增的节流项，默认 800；调大更全面但更慢 |

## 与原版的差异（v1）

- 只测 IPv4（IPv6 段后续可加）
- 端口固定 443，测速域名固定 `speed.cloudflare.com`（原版默认用作者的 cf.xiu2.xyz 并建议自建；这里用官方域名更稳）
- 下载测速时因为连的是 IP、证书是域名的，App 内跳过了证书校验——只影响测速本身，不用于任何登录/敏感场景
