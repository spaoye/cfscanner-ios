import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var copiedIP: String?
    @State private var showImporter = false
    @State private var paramsExpanded = false
    @State private var uploadExpanded = false
    @State private var importNote: String?
    @State private var showImportEditor = false
    @State private var importText = ""

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
                    if scanner.uploadEnabled && !scanner.results.isEmpty {
                        Button {
                            Task { await scanner.uploadResults(manual: true) }
                        } label: {
                            HStack {
                                Spacer()
                                if scanner.isUploading {
                                    ProgressView()
                                } else {
                                    Text("手动上传速度前 5（不限门槛）")
                                }
                                Spacer()
                            }
                        }
                        .disabled(scanner.isUploading || scanner.isRunning)
                        if !scanner.uploadStatus.isEmpty {
                            Text(scanner.uploadStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                        Button("粘贴导入（从剪贴板）") { importFromClipboard() }
                        Button("手动输入 / 粘贴文本") {
                            importText = ""
                            showImportEditor = true
                        }
                    } else {
                        Button("导入 IP 文件（CSV / TXT）") { showImporter = true }

                        Button("粘贴导入（从剪贴板）") { importFromClipboard() }
                        Button("手动输入 / 粘贴文本") {
                            importText = ""
                            showImportEditor = true
                        }
                        Text("每行一个 IP 或网段（如 104.16.0.0/24），CSV 取第一列；CFST 的 ip.txt 和 result.csv 可直接导入。也支持 https://IP、IP:端口 这类网页导出格式，纯域名的行会跳过。不导入时从 Cloudflare 官方 IP 段随机抽样。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = importNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("测速接口", selection: $scanner.downloadSource) {
                        ForEach(DownloadSource.allCases) { src in
                            Text(src.label).tag(src)
                        }
                    }
                    .pickerStyle(.menu)
                    if scanner.downloadSource == .custom {
                        TextField("自定义测速地址（https://…）", text: $scanner.customDownloadURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))
                    }
                    Text("下载测速时向候选 IP 请求的文件。Parallels 是 333MB 的安装包，Cloudflare 官方是 speed.cloudflare.com 的测速接口；都要求候选 IP 是 Cloudflare 边缘节点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("参数", isExpanded: $paramsExpanded) {
                    if scanner.customListName != nil {
                        Text("自选名单生效中：名单全部测速（超过 8000 个时随机抽 8000），「候选 IP 总数」不生效，其余参数照常生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("目标地区", selection: $scanner.region) {
                        ForEach(RegionPreference.allCases) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                    if scanner.region == .carrier {
                        Picker("运营商", selection: $scanner.carrierChoice) {
                            Text("自动识别").tag("auto")
                            Text("中国电信").tag("telecom")
                            Text("中国联通").tag("unicom")
                            Text("中国移动").tag("mobile")
                        }
                        .pickerStyle(.menu)
                        Text("按运营商筛选优先落点（电信 HKG/NRT/KIX/SIN/LAX/SJC、联通 HKG/TPE/NRT/KIX/SIN/ICN、移动 HKG/SIN/NRT/TPE/ICN/LAX），最后仍按实测速度排名。自动识别查的是当前网络出口的运营商——开着 VPN 时会识别成 VPN 出口那家，请关掉代理测速，或在这里手动选。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    numberRow("平均延迟上限", value: $scanner.maxLatencyMs, range: 50...500, unit: "ms")
                    numberRow("丢包率上限", value: $scanner.lossLimitPct, range: 0...50, unit: "%")
                    numberRow("每个 IP 测速次数", value: $scanner.attempts, range: 1...6, unit: "次")
                    numberRow("延迟测速并发", value: $scanner.concurrency, range: 10...150)
                    numberRow("候选 IP 总数", value: $scanner.candidateTarget, range: 200...3000, unit: "个")
                        .disabled(scanner.customListName != nil)
                        .opacity(scanner.customListName != nil ? 0.45 : 1)
                    if scanner.customListName != nil {
                        Text("已导入自选名单，本项不生效：名单会全部测速。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("下载测速", isOn: $scanner.doDownload)
                    if scanner.doDownload {
                        numberRow("下载测速数量", value: $scanner.downloadCount, range: 1...30, unit: "个")
                        numberRow("单个下载时长", value: $scanner.downloadSeconds, range: 3...15, unit: "秒")
                    }
                    }
                }

                Section {
                    DisclosureGroup("结果上传", isExpanded: $uploadExpanded) {
                    Toggle("启用结果上传", isOn: $scanner.uploadEnabled)
                    if scanner.uploadEnabled {
                        HStack {
                            TextField("https://…/api/client/uploadResult", text: $scanner.uploadAPIURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.footnote, design: .monospaced))
                            Button("粘贴") {
                                if let s = UIPasteboard.general.string {
                                    scanner.uploadAPIURL = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                            .font(.callout)
                        }
                        HStack {
                            TextField("上传令牌", text: $scanner.uploadToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("粘贴") {
                                if let s = UIPasteboard.general.string {
                                    scanner.uploadToken = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                            .font(.callout)
                        }
                        HStack {
                            Text("地区")
                            Spacer()
                            TextField("地区", text: $scanner.uploadRegion)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                        }
                        numberRow("上传门槛", value: $scanner.uploadMinSpeed, range: 0...50, unit: "MB/s")
                        if scanner.uploadMinSpeed <= 0 {
                            Text("门槛为 0：自动上传不设门槛。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("测完自动上传", isOn: $scanner.autoUpload)
                        Button("验证令牌") {
                            Task { await scanner.verifyUploadToken() }
                        }
                        .disabled(scanner.isUploading)
                        if !scanner.uploadStatus.isEmpty {
                            Text(scanner.uploadStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("开启后，测速结果里达标的前 10 名（IP、速度、延迟、丢包、落点）会按地区 + 运营商上传到中转，供 Emby 面板的自动优选拉取使用。地区要和面板里 broker 的地区填一致；运营商用测速时识别/选择的那家。令牌与电脑端工具里填的是同一个，只保存在本机。自动上传按上面的门槛筛前 10 名；结果区的手动上传不限门槛，传速度最快的前 5 名。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("关闭时本 App 就是普通的优选测速工具，不会向任何服务器上传数据。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
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
        .sheet(isPresented: $showImporter) {
            DocumentPicker(onPick: { url in
                showImporter = false
                handlePickedFile(url)
            }, onCancel: {
                showImporter = false
            })
            .ignoresSafeArea()
        }
        .alert("导入结果", isPresented: Binding(
            get: { importNote != nil },
            set: { if !$0 { importNote = nil } }
        )) {
            Button("好") { importNote = nil }
        } message: {
            Text(importNote ?? "")
        }
    }

    /// 处理文件选择器（asCopy 模式）交回的本地文件副本：限大小、解码、导入，全程给反馈
    private func handlePickedFile(_ url: URL) {
        let name = url.lastPathComponent
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if fileSize > 20 * 1024 * 1024 {
            importNote = "「\(name)」有 \(fileSize / 1024 / 1024) MB，太大了。IP 列表应该是几十 KB 的文本文件，是不是选错文件了？"
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            importNote = "读不到「\(name)」的内容，请换个位置存放（比如先存到「我的 iPhone」）再导入，或用粘贴/手动输入。"
            return
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) {
            scanner.importCustomList(text: text, name: name)
            importNote = scanner.statusText
        } else {
            importNote = "「\(name)」不是文本内容，无法导入。请选择一行一个 IP 的 .txt 或 .csv 文件。"
        }
    }

    /// 从剪贴板导入：依次尝试纯文本、文件 URL、原始数据（在「文件」里长按文件选「拷贝」也能粘进来）
    private func importFromClipboard() {
        let pb = UIPasteboard.general
        if let s = pb.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scanner.importCustomList(text: s, name: "剪贴板导入.txt")
            importNote = scanner.statusText
            return
        }
        if let url = pb.url, url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) {
                scanner.importCustomList(text: text, name: url.lastPathComponent)
                importNote = scanner.statusText
                return
            }
        }
        if let data = pb.data(forPasteboardType: UTType.data.identifier),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) {
            scanner.importCustomList(text: text, name: "剪贴板导入.txt")
            importNote = scanner.statusText
            return
        }
        importNote = "剪贴板里没找到可导入的文本或文件。在「文件」App 里长按文件选「拷贝」，或打开文件全选拷贝内容，再回来点粘贴导入；也可以用「手动输入 / 粘贴文本」。"
    }

    /// 数字参数行：名称 + 数字输入框（预填当前值）+ 单位 + 范围小字；输入越界自动收回边界
    private func numberRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "") -> some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .onChange(of: value.wrappedValue) { newValue in
                    let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                    if clamped != newValue { value.wrappedValue = clamped }
                }
            if !unit.isEmpty {
                Text(unit)
                    .foregroundStyle(.secondary)
            }
            Text("\(Int(range.lowerBound))–\(Int(range.upperBound))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
