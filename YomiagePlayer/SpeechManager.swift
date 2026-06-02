import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// 読み上げ全体を管理するクラス。
///
/// `AVSpeechSynthesizer` をベースに、以下を実現する:
///  - 文単位に分割して読み上げ（途中からの再開＝シークを可能にするため）
///  - `AVAudioSession`（.playback / .spokenAudio）でバックグラウンド再生
///  - `MPNowPlayingInfoCenter` でロック画面・コントロールセンターへ情報表示
///  - `MPRemoteCommandCenter` で再生/一時停止/スキップ/シークバー操作
final class SpeechManager: NSObject, ObservableObject {

    // MARK: - 公開状態（UIバインド用）

    /// 再生中かどうか。
    @Published private(set) var isPlaying = false
    /// 読み上げ進捗（0.0〜1.0）。シークバーにバインドする。
    @Published private(set) var progress: Double = 0
    /// 現在読み上げ対象のテキスト。
    @Published private(set) var fullText: String = ""
    /// 読み上げ速度（AVSpeechUtterance.rate と同じ 0.0〜1.0 のスケール）。
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// 端末で利用できる音声の一覧（日本語・高品質を優先して並べ替え済み）。
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    /// 選択中の音声の識別子。nil の場合は日本語の既定音声を使う。
    @Published var selectedVoiceIdentifier: String?

    // MARK: - 内部状態

    private let synthesizer = AVSpeechSynthesizer()

    /// 文（区切り文字を含む）の配列。連結すると元テキストと一致する。
    private var sentences: [String] = []
    /// 各文の先頭が、テキスト全体の何文字目（UTF-16）から始まるか。
    private var startOffsets: [Int] = []
    /// テキスト全体の長さ（UTF-16 単位）。
    private var totalChars = 0

    /// 現在読み上げ中の文インデックス。
    private var currentSentenceIndex = 0
    /// 現在の発話（utterance）の先頭が、テキスト全体の何文字目から始まるか。
    private var currentUtteranceBaseOffset = 0
    /// これまでに読み上げた位置（テキスト全体での UTF-16 オフセット）。
    private var spokenGlobalOffset = 0
    /// stop 後の処理を決める保留値。
    /// nil = 保留なし（自然終了として次の文へ）, -1 = 停止のみ, 0以上 = その位置から再開。
    private var pendingRestartOffset: Int?

    /// 1文字あたりの想定秒数。Now Playing の擬似的な総時間・経過時間に使う。
    private let secondsPerChar: Double = 0.13

    /// 擬似的な総再生時間（秒）。
    var duration: Double { Double(totalChars) * secondsPerChar }
    /// 擬似的な経過時間（秒）。
    var elapsedTime: Double { progress * duration }

    // MARK: - 初期化

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        setupRemoteCommands()
        loadVoices()
    }

    // MARK: - 音声（ボイス）

    /// 端末にある音声を読み込む。日本語・高品質を上位に並べ、未選択なら最良の日本語音声を既定にする。
    func loadVoices() {
        let all = AVSpeechSynthesisVoice.speechVoices()
        availableVoices = all.sorted { a, b in
            let aJa = a.language.hasPrefix("ja")
            let bJa = b.language.hasPrefix("ja")
            if aJa != bJa { return aJa }                       // 日本語を先頭へ
            if a.language != b.language { return a.language < b.language }
            if a.quality.rawValue != b.quality.rawValue {
                return a.quality.rawValue > b.quality.rawValue  // 高品質を先に
            }
            return a.name < b.name
        }
        if selectedVoiceIdentifier == nil {
            selectedVoiceIdentifier = bestJapaneseVoice()?.identifier
        }
    }

    /// 日本語で最も高品質な音声を返す（Premium > Enhanced > Default）。
    private func bestJapaneseVoice() -> AVSpeechSynthesisVoice? {
        availableVoices
            .filter { $0.language.hasPrefix("ja") }
            .max(by: { $0.quality.rawValue < $1.quality.rawValue })
    }

    /// 再生中に音声を切り替えたとき、現在位置で読み直して新しい音声を反映する。
    func applyVoiceChange() {
        if isPlaying {
            seek(toFraction: progress)
        }
    }

    /// 現在選択中の音声（なければ日本語の既定音声）。
    private var currentVoice: AVSpeechSynthesisVoice? {
        if let id = selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "ja-JP")
    }

    // MARK: - テキスト読み込み

    /// 読み上げるテキストを設定する。
    func load(text: String) {
        // 進行中の読み上げがあれば止める。
        pendingRestartOffset = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            // 停止コールバックで次の文へ進んでしまわないよう「停止のみ」を指示。
            pendingRestartOffset = -1
            synthesizer.stopSpeaking(at: .immediate)
        }

        fullText = text
        sentences = Self.splitIntoSentences(text)
        startOffsets = []
        var acc = 0
        for s in sentences {
            startOffsets.append(acc)
            acc += (s as NSString).length
        }
        totalChars = acc

        currentSentenceIndex = 0
        currentUtteranceBaseOffset = 0
        spokenGlobalOffset = 0
        isPlaying = false
        progress = 0
        updateNowPlaying()
    }

    // MARK: - 再生コントロール

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard totalChars > 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(true)

        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        } else if !synthesizer.isSpeaking {
            // 最後まで読み終わっている場合は先頭から。
            let from = spokenGlobalOffset >= totalChars ? 0 : spokenGlobalOffset
            beginSpeaking(fromGlobalOffset: from)
        }
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        }
        isPlaying = false
        updateNowPlaying()
    }

    /// 指定の割合（0.0〜1.0）へシークする。シークバー・ロック画面スクラブ共通の入口。
    func seek(toFraction fraction: Double) {
        guard totalChars > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        let target = Int((clamped * Double(totalChars)).rounded())

        spokenGlobalOffset = target
        progress = clamped

        let shouldResume = isPlaying
        if synthesizer.isSpeaking || synthesizer.isPaused {
            // stop は非同期に didCancel または didFinish を呼ぶ。
            // どちらが呼ばれても確実にシーク先から再開できるよう保留値で制御する。
            pendingRestartOffset = shouldResume ? target : -1
            synthesizer.stopSpeaking(at: .immediate)
        } else if shouldResume {
            beginSpeaking(fromGlobalOffset: target)
        }
        updateNowPlaying()
    }

    /// 秒数ぶんスキップ（ロック画面の早送り/巻き戻し用）。
    func skip(by seconds: Double) {
        guard duration > 0 else { return }
        let newElapsed = min(max(elapsedTime + seconds, 0), duration)
        seek(toFraction: newElapsed / duration)
    }

    // MARK: - 内部: 発話の開始

    private func beginSpeaking(fromGlobalOffset offset: Int) {
        guard totalChars > 0 else { return }
        let clamped = min(max(offset, 0), totalChars)
        let idx = sentenceIndex(forGlobalOffset: clamped)
        currentSentenceIndex = idx
        let local = clamped - startOffsets[idx]
        isPlaying = true
        enqueueSentence(idx, fromLocalOffset: local)
        updateNowPlaying()
    }

    private func enqueueSentence(_ index: Int, fromLocalOffset local: Int) {
        guard index >= 0, index < sentences.count else {
            finishPlayback()
            return
        }
        let ns = sentences[index] as NSString
        let safeLocal = min(max(local, 0), ns.length)
        let sub = safeLocal < ns.length ? ns.substring(from: safeLocal) : ""

        currentUtteranceBaseOffset = startOffsets[index] + safeLocal

        // 空文字だと発話が完了しないことがあるので半角スペースで代替。
        let utterance = AVSpeechUtterance(string: sub.isEmpty ? " " : sub)
        utterance.voice = currentVoice
        utterance.rate = rate
        synthesizer.speak(utterance)
    }

    private func finishPlayback() {
        isPlaying = false
        spokenGlobalOffset = totalChars
        progress = 1
        updateNowPlaying()
    }

    /// グローバルオフセットを含む文のインデックスを返す。
    private func sentenceIndex(forGlobalOffset offset: Int) -> Int {
        guard !startOffsets.isEmpty else { return 0 }
        if offset >= totalChars { return sentences.count - 1 }
        var lo = 0
        var hi = startOffsets.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if startOffsets[mid] <= offset {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    // MARK: - オーディオセッション

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback でロック・バックグラウンドでも音を出す。.spokenAudio は読み上げ向け。
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
    }

    // MARK: - リモートコマンド（ロック画面 / コントロールセンター）

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 15); return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15); return .success
        }

        // ★ ロック画面のシークバー（スクラブ）を有効化する。
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let e = event as? MPChangePlaybackPositionCommandEvent,
                  self.duration > 0 else { return .commandFailed }
            self.seek(toFraction: e.positionTime / self.duration)
            return .success
        }
    }

    // MARK: - Now Playing 情報の更新

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "ページの読み上げ"
        info[MPMediaItemPropertyArtist] = "Yomiage Player"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 文分割

    /// テキストを文（区切り文字を含む）に分割する。連結すると元テキストに一致する。
    static func splitIntoSentences(_ text: String) -> [String] {
        let delimiters: Set<Character> = ["。", "！", "？", "!", "?", "\n", "．", "."]
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if delimiters.contains(ch) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechManager: AVSpeechSynthesizerDelegate {

    /// 読み上げ位置が進むたびに呼ばれる。進捗の追従に使う。
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        spokenGlobalOffset = currentUtteranceBaseOffset + characterRange.location + characterRange.length
        progress = totalChars > 0
            ? min(1, Double(spokenGlobalOffset) / Double(totalChars))
            : 0
        updateNowPlaying()
    }

    /// 発話が終了したとき（自然終了）に呼ばれる。
    /// stop による中断でも環境によってはこちらが呼ばれるため、保留値を最優先で処理する。
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        if consumePendingRestart() { return }
        // 自然終了 → 次の文へ。
        let next = currentSentenceIndex + 1
        if next < sentences.count {
            currentSentenceIndex = next
            enqueueSentence(next, fromLocalOffset: 0)
        } else {
            finishPlayback()
        }
    }

    /// stop（シーク・読み込み直し）でキャンセルされたとき。
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        consumePendingRestart()
    }

    /// 保留中の停止／再開要求を処理する。処理したら true を返す。
    /// stopSpeaking 直後に speak すると無視されることがあるため、次のループで再開する。
    @discardableResult
    private func consumePendingRestart() -> Bool {
        guard let pending = pendingRestartOffset else { return false }
        pendingRestartOffset = nil
        if pending >= 0 {
            DispatchQueue.main.async { [weak self] in
                self?.beginSpeaking(fromGlobalOffset: pending)
            }
        }
        return true
    }
}
