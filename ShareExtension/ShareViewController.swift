import UIKit
import Social
import UniformTypeIdentifiers

/// 共有シートから受け取ったテキストをクリップボードへ格納する共有拡張。
///
/// App Group を使わない簡易版のため、本体アプリへは「クリップボード経由」で渡す。
/// 共有後、本体アプリを開いて「ペーストして読み込む」を押すと読み上げできる。
class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool { true }

    /// 「投稿」を押したとき。共有テキストを取り出してクリップボードへ。
    override func didSelectPost() {
        extractSharedText { [weak self] text in
            if let text, !text.isEmpty {
                UIPasteboard.general.string = text
            }
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    override func configurationItems() -> [Any]! { [] }

    // MARK: - 共有テキストの取り出し

    private func extractSharedText(completion: @escaping (String?) -> Void) {
        // コンポーズ画面に表示・編集されている本文を最優先で使う。
        let typed = contentText ?? ""

        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments, !attachments.isEmpty else {
            completion(typed.isEmpty ? nil : typed)
            return
        }

        let textType = UTType.plainText.identifier
        let urlType = UTType.url.identifier

        // 1) プレーンテキストの添付を探す。
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { data, _ in
                let result = (data as? String) ?? (typed.isEmpty ? nil : typed)
                DispatchQueue.main.async { completion(result) }
            }
            return
        }

        // 2) URL（Webページ共有など）はURL文字列を渡す。
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { data, _ in
                let result = (data as? URL)?.absoluteString ?? (typed.isEmpty ? nil : typed)
                DispatchQueue.main.async { completion(result) }
            }
            return
        }

        completion(typed.isEmpty ? nil : typed)
    }
}
