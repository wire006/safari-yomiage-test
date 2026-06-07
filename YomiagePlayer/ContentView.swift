import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var speech: SpeechManager

    @State private var inputText = """
    これは読み上げのサンプルです。シークバーをドラッグすると、好きな位置から読み上げを再開できます。
    画面をロックしても再生は続き、ロック画面のシークバーからも位置を変更できます。
    速度スライダーで読み上げの速さを調整できます。お好みに合わせて使ってみてください。
    """

    // スライダーをユーザーが操作している間は、再生側の進捗で値を上書きしない。
    @State private var isEditingSlider = false
    @State private var sliderValue: Double = 0
    // ファイル取り込み（書類ピッカー）の表示状態。
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TextEditor(text: $inputText)
                        .font(.body)
                        .frame(height: 160)
                        .scrollContentBackground(.hidden)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3))
                        )

                Button {
                    speech.load(text: inputText)
                    sliderValue = 0
                } label: {
                    Label("このテキストを読み込む", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                // テキストの取り込み（A: クリップボード / C: ファイル）
                HStack(spacing: 12) {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("ペーストして読み込む", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showingImporter = true
                    } label: {
                        Label("ファイルから読み込む", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: importContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        loadFromFile(url)
                    }
                }

                // シークバー
                VStack(spacing: 4) {
                    Slider(
                        value: $sliderValue,
                        in: 0...1,
                        onEditingChanged: { editing in
                            isEditingSlider = editing
                            if !editing {
                                speech.seek(toFraction: sliderValue)
                            }
                        }
                    )
                    HStack {
                        Text(timeString(speech.elapsedTime))
                        Spacer()
                        Text(timeString(speech.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                // 再生コントロール
                HStack(spacing: 40) {
                    Button {
                        speech.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15").font(.title)
                    }

                    Button {
                        speech.togglePlayPause()
                    } label: {
                        Image(systemName: speech.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }

                    Button {
                        speech.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15").font(.title)
                    }
                }
                .padding(.top, 4)

                // 速度調整（1.0×〜1.4×、1.0×＝標準100%）
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $speech.speedMultiplier, in: 1.0...1.4, step: 0.02)
                            .onChange(of: speech.speedMultiplier) { _ in
                                speech.applySpeedChange()
                            }
                        Image(systemName: "hare")
                    }
                    Text(speedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)

                // 音声（ボイス）選択
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("音声（\(speech.availableVoices.count)件）")
                            .font(.subheadline.bold())
                        Spacer()
                        Picker("音声", selection: $speech.selectedVoiceIdentifier) {
                            ForEach(speech.availableVoices, id: \.identifier) { voice in
                                Text(voiceLabel(voice)).tag(Optional(voice.identifier))
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: speech.selectedVoiceIdentifier) { _ in
                            speech.applyVoiceChange()
                        }
                    }
                    Text("Safariと同じ音声にするには、設定 > アクセシビリティ > 読み上げコンテンツ > 声 で使っている音声をダウンロードしてから、ここで同じ音声を選んでください。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.5))
                )
                }
                .padding()
            }
            .navigationTitle("読み上げプレイヤー")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                speech.load(text: inputText)
            }
            // 再生側の進捗をスライダーへ反映（ドラッグ中は除く）。
            .onReceive(speech.$progress) { p in
                if !isEditingSlider { sliderValue = p }
            }
        }
    }

    /// 速度ラベル（倍率と、標準を100%とした目安の％）。
    private var speedLabel: String {
        let percent = Int((speech.speedMultiplier * 100).rounded())
        return String(format: "読み上げ速度  %.2f×（約%d%%）", speech.speedMultiplier, percent)
    }

    /// A: クリップボードの文字列を読み込む。
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        inputText = text
        speech.load(text: text)
        sliderValue = 0
    }

    /// 取り込み可能なファイル形式（PDF / DOCX / テキスト / RTF）。
    private var importContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .utf8PlainText, .rtf]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        return types
    }

    /// C: 選択したファイル（PDF / DOCX / テキスト / RTF）からテキストを取り込む。
    private func loadFromFile(_ url: URL) {
        // 他アプリ由来のURLはセキュリティスコープのアクセス開始が必要。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let text = DocumentTextExtractor.text(from: url), !text.isEmpty else { return }
        inputText = text
        speech.load(text: text)
        sliderValue = 0
    }

    /// 音声の表示名（名前・品質、Siri音声なら「Siri」表示）。
    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium:  quality = "プレミアム"
        case .enhanced: quality = "高品質"
        default:        quality = "標準"
        }
        let siri = voice.identifier.lowercased().contains("siri") ? "・Siri" : ""
        return "\(voice.name)（\(quality)\(siri)）"
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    ContentView()
        .environmentObject(SpeechManager())
}
