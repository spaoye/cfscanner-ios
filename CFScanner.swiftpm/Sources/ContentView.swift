import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var copiedIP: String?

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

                Section("参数") {
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
                    Text("测速域名用 speed.cloudflare.com（Cloudflare 官方）。延迟测速是 TCPing（443 端口），和 CFST 默认模式一致；下载测速连到候选 IP 并以该域名做 SNI/Host，地区码取自 CF-RAY 响应头。")
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
