import Foundation
import UIKit
import PDFKit
import Compression

/// 取り込んだファイルから読み上げ用のテキストを抽出するユーティリティ。
///
/// 対応形式:
///  - PDF  : PDFKit でページごとのテキストを連結
///  - DOCX : zip を展開して word/document.xml から本文を抽出（自作・ベストエフォート）
///  - RTF  : NSAttributedString で読み込み
///  - その他: プレーンテキストとして読み込み
enum DocumentTextExtractor {

    static func text(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return textFromPDF(url)
        case "docx":
            return textFromDOCX(url)
        case "rtf":
            if let data = try? Data(contentsOf: url),
               let attr = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtf],
                   documentAttributes: nil) {
                return nonEmpty(attr.string)
            }
            return nonEmpty((try? String(contentsOf: url)) ?? "")
        default:
            if let s = try? String(contentsOf: url, encoding: .utf8) { return nonEmpty(s) }
            return nonEmpty((try? String(contentsOf: url)) ?? "")
        }
    }

    // MARK: - PDF

    private static func textFromPDF(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                parts.append(s)
            }
        }
        return nonEmpty(parts.joined(separator: "\n"))
    }

    // MARK: - DOCX

    private static func textFromDOCX(_ url: URL) -> String? {
        guard let zip = try? Data(contentsOf: url),
              let xml = entryData(in: zip, named: "word/document.xml"),
              let xmlString = String(data: xml, encoding: .utf8) else {
            return nil
        }
        return nonEmpty(plainText(fromWordML: xmlString))
    }

    /// WordML（document.xml）から本文テキストを取り出す。
    private static func plainText(fromWordML xml: String) -> String {
        var s = xml
        // 段落・改行・タブを対応する文字へ。
        s = s.replacingOccurrences(of: "</w:p>", with: "\n")
        s = s.replacingOccurrences(of: "<w:br/>", with: "\n")
        s = s.replacingOccurrences(of: "<w:br />", with: "\n")
        s = s.replacingOccurrences(of: "<w:tab/>", with: "\t")
        s = s.replacingOccurrences(of: "<w:tab />", with: "\t")
        // 残りのタグをすべて除去（本文テキストは <w:t> 内のみに存在する）。
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // XML エンティティを復号。
        s = s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return s
    }

    // MARK: - 最小限の ZIP 読み取り

    /// ZIP データから指定名のエントリを取り出して展開する（store / deflate のみ対応）。
    private static func entryData(in zip: Data, named name: String) -> Data? {
        let bytes = [UInt8](zip)
        let n = bytes.count
        guard n > 22 else { return nil }

        func u16(_ i: Int) -> Int { Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
        func u32(_ i: Int) -> Int {
            Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
        }

        // End Of Central Directory（signature 0x06054b50）を末尾から探す。
        var eocd = -1
        let minPos = max(0, n - 22 - 65_535)
        var i = n - 22
        while i >= minPos {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let cdCount = u16(eocd + 10)
        let cdOffset = u32(eocd + 16)

        // Central Directory を走査（signature 0x02014b50）。
        var p = cdOffset
        for _ in 0..<cdCount {
            guard p + 46 <= n,
                  bytes[p] == 0x50, bytes[p + 1] == 0x4b, bytes[p + 2] == 0x01, bytes[p + 3] == 0x02 else {
                break
            }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let uncompSize = u32(p + 24)
            let nameLen = u16(p + 28)
            let extraLen = u16(p + 30)
            let commentLen = u16(p + 32)
            let localOffset = u32(p + 42)
            let nameStart = p + 46
            guard nameStart + nameLen <= n else { return nil }
            let entryName = String(bytes: bytes[nameStart..<nameStart + nameLen], encoding: .utf8) ?? ""

            if entryName == name {
                // Local File Header（signature 0x04034b50）からデータ位置を割り出す。
                guard localOffset + 30 <= n,
                      bytes[localOffset] == 0x50, bytes[localOffset + 1] == 0x4b,
                      bytes[localOffset + 2] == 0x03, bytes[localOffset + 3] == 0x04 else {
                    return nil
                }
                let lNameLen = u16(localOffset + 26)
                let lExtraLen = u16(localOffset + 28)
                let dataStart = localOffset + 30 + lNameLen + lExtraLen
                guard dataStart + compSize <= n else { return nil }
                let comp = Data(bytes[dataStart..<dataStart + compSize])
                switch method {
                case 0:  return comp                            // 無圧縮
                case 8:  return inflateRaw(comp, expected: uncompSize)  // raw deflate
                default: return nil
                }
            }
            p = nameStart + nameLen + extraLen + commentLen
        }
        return nil
    }

    /// raw DEFLATE を展開する（Apple の COMPRESSION_ZLIB はヘッダ無しの raw deflate を扱う）。
    private static func inflateRaw(_ data: Data, expected: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = expected > 0 ? expected + 64 : max(data.count * 8, 64 * 1024)
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, capacity, srcPtr, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    // MARK: - ヘルパ

    private static func nonEmpty(_ s: String) -> String? {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}
