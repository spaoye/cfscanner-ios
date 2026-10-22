import SwiftUI
import UniformTypeIdentifiers

/// UIKit 原生文件选择器（替代 SwiftUI 的 .fileImporter）。
/// 两个关键点：
/// 1. `asCopy: true`——系统先把选中的文件复制到本 App 的临时目录再交回来，
///    绕开安全作用域与各种文件提供方（iCloud/第三方 App）导致的「点文件没反应/选不动」。
/// 2. 允许类型放最宽（public.item 是所有类型的根），任何文件都可点选，
///    是否是可用的 IP 列表由导入解析决定并给出提示，不在选择器里先卡一道。
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .data, .text, .plainText, .commaSeparatedText],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
