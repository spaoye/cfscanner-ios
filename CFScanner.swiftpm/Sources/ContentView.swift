import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var copiedIP: String?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        scanner.toggle()
                    } label: {
                        HStack {
                            Spacer()
                            Text(scanner.isRunning ? "停止" : "开始优选测速")
                                .font(.headline)
                                .foregroundStyle(scanner.isRunning ? .red : .accentColor)
                            Spacer()
                        }
                    }
                    .disabled(false)

                    ProgressView(value: scanner.progress)
                    Text(scanner.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("结果（点一行复制 IP）") {
                    if scanner.results.isEmpty {
                        Text("暂无结果")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(scanner.results) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.ip)
                                    .font(.system(.body, design: .monospaced))
                                Text("延迟 \(Int(r.avgLatencyMs))ms · 丢包 \(Int(r.lossRate * 100))% · 收到 \(r.received)/\(r.sent)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let mbps = r.downloadMBps {
                                    Text(String(format: "%.2f MB/s", mbps))
                                        .font(.system(.body, design: .monospaced))
                                        .bold()
                                }
                                if let colo = r.colo {
                                    Text(colo)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let note = r.note {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = r.ip
                            copiedIP = r.ip
                        }
                    }
                }

                Section("自选 IP 列表") {
                    if let name = scanner.customListName {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                    .font(.callout)
                                Text("共 \(scanner.customListCount) 个 IP，测速只测这些")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("清除", role: .destructive) {
                                scanner.clearCustomList()
                            }
                        }
                        Button("重新导入") { showImporter = true }
                    } else {
                        Button("导入 IP 文件（CSV / TXT）") { showImporter = true }
                        Text("每行一个 IP 或网段（如 104.16.0.0/24），CSV 取第一列；CFST 的 ip.txt 和 result.csv 可直接导入。不导入时从 Cloudflare 官方 IP 段随机抽样。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("参数") {
                    Picker("目标地区", selection: $scanner.region) {
                        ForEach(RegionPreference.allCases) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                    settingRow("平均延迟上限", value: "\(Int(scanner.maxLatencyMs)) ms") {
                        Slider(value: $scanner.maxLatencyMs, in: 50...500, step: 10)
                    }
                    settingRow("丢包率上限", value: "\(Int(scanner.lossLimitPct)) %") {
                        Slider(value: $scanner.lossLimitPct, in: 0...50, step: 5)
                    }
                    settingRow("每个 IP 测速次数", value: "\(Int(scanner.attempts)) 次") {
                        Slider(value: $scanner.attempts, in: 1...6, step: 1)
                    }
                    settingRow("延迟测速并发", value: "\(Int(scanner.concurrency))") {
                        Slider(value: $scanner.concurrency, in: 10...150, step: 10)
                    }
                    settingRow("候选 IP 总数", value: "\(Int(scanner.candidateTarget))") {
                        Slider(value: $scanner.candidateTarget, in: 200...3000, step: 100)
                    }
                    Toggle("下载测速", isOn: $scanner.doDownload)
                    if scanner.doDownload {
                        settingRow("下载测速数量", value: "\(Int(scanner.downloadCount)) 个") {
                            Slider(value: $scanner.downloadCount, in: 1...30, step: 1)
                        }
                        settingRow("单个下载时长", value: "\(Int(scanner.downloadSeconds)) 秒") {
                            Slider(value: $scanner.downloadSeconds, in: 3...15, step: 1)
                        }
                    }
                }

                Section {
                    Text("测速域名用 speed.cloudflare.com（Cloudflare 官方）。延迟测速是 TCPing（443 端口），和 CFST 默认模式一致；下载测速连到候选 IP 并以该域名做 SNI/Host。地区选择按实测落点过滤：CF 是 anycast，IP 没有固定归属地，App 会逐个连接确认每个 IP 实际落到哪个机房，只保留目标地区的再做下载测速。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("CF 优选测速")
            .toolbar {
                if !scanner.results.isEmpty {
                    ShareLink(item: scanner.csvText) {
                        Label("导出 CSV", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .commaSeparatedText, .text, .data], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                    scanner.importCustomList(text: text, name: url.lastPathComponent)
                }
            }
            .alert("已复制", isPresented: Binding(
                get: { copiedIP != nil },
                set: { if !$0 { copiedIP = nil } }
            )) {
                Button("好") { copiedIP = nil }
            } message: {
                Text(copiedIP ?? "")
            }
        }
    }

    private func settingRow<Control: View>(_ title: String, value: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            control()
        }
    }
}
