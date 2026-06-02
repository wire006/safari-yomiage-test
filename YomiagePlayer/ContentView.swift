import SwiftUI
import AVFoundation

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $inputText)
                    .font(.body)
                    .frame(minHeight: 160)
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

                // 速度調整
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $speech.rate,
                               in: AVSpeechRateRange.min...AVSpeechRateRange.max)
                        Image(systemName: "hare")
                    }
                    Text("読み上げ速度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)

                // 音声（ボイス）選択
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("音声")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                Spacer()
            }
            .padding()
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

    /// 音声の表示名（名前・言語・品質）。
    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium:  quality = "プレミアム"
        case .enhanced: quality = "高品質"
        default:        quality = "標準"
        }
        return "\(voice.name)（\(voice.language)・\(quality)）"
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// AVSpeechUtterance.rate の有効範囲。
enum AVSpeechRateRange {
    static let min: Float = 0.0   // AVSpeechUtteranceMinimumSpeechRate
    static let max: Float = 1.0   // AVSpeechUtteranceMaximumSpeechRate
}

#Preview {
    ContentView()
        .environmentObject(SpeechManager())
}
