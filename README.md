# safari-yomiage-test / YomiagePlayer

iOS の「ページの読み上げ」相当を**自前**で実装したサンプルアプリです。
Safari 純正の読み上げではシークバーで位置指定ができなくなったため、
`AVSpeechSynthesizer` をベースに「**シークバーによる位置指定**」と
「**バックグラウンド再生 / ロック画面コントロール**」を実現する検証用プロジェクトです。

## できること

- テキストを貼り付けて日本語で読み上げ
- アプリ内のシークバーで**好きな位置から読み上げ再開**
- 早送り / 巻き戻し（15秒）・読み上げ速度の調整
- **バックグラウンド再生**（`AVAudioSession` の `.playback` / `.spokenAudio`）
- **ロック画面・コントロールセンター**での再生/一時停止/スキップ
- **ロック画面のシークバー（スクラブ）**での位置指定
  （`MPRemoteCommandCenter.changePlaybackPositionCommand`）

## 仕組みのポイント

- 本文を**文単位**（。！？改行などで区切り）に分割し、1文ずつ読み上げる。
  これにより「途中の任意位置から再開」＝シークが可能になります。
- `willSpeakRangeOfSpeechString` で読み上げ位置を追従し、進捗（0〜1）を更新。
- TTS は本来「尺」を持たないため、文字数 × 想定秒数で**擬似的な総時間・経過時間**を
  作り、Now Playing（ロック画面）のシークバーへ反映しています。

主要ファイル:

| ファイル | 役割 |
|---|---|
| `YomiagePlayer/SpeechManager.swift` | 読み上げ・オーディオセッション・リモートコマンド・Now Playing |
| `YomiagePlayer/ContentView.swift`   | UI（テキスト入力・シークバー・再生コントロール・速度） |
| `YomiagePlayer/YomiagePlayerApp.swift` | アプリのエントリポイント |
| `Info.plist` | `UIBackgroundModes: audio`（バックグラウンド再生に必須） |

## ビルドと実行（個人検証）

1. `YomiagePlayer.xcodeproj` を Xcode 16 以降で開く
2. ターゲット `YomiagePlayer` を選択
3. **Signing & Capabilities** で自分の Apple ID（Team）を設定
   - `PRODUCT_BUNDLE_IDENTIFIER` が他と重複する場合は
     `com.example.YomiagePlayer` を自分用に変更してください
4. 実機（iPhone）を接続して Run
   - バックグラウンド再生・ロック画面コントロールは**実機**でのみ確認できます
     （シミュレータではロック画面の挙動は確認できません）

> 注意: バックグラウンド再生には `Info.plist` の `UIBackgroundModes = audio` が必須です。
> Xcode の Capabilities から「Background Modes > Audio, AirPlay, and Picture in Picture」を
> 有効にしても同じ設定になります。

## 動作確認の手順

1. アプリを起動 → サンプル文が読み込まれる
2. 再生ボタンで読み上げ開始
3. シークバーをドラッグして離す → その位置から読み上げ再開
4. 端末をロック → ロック画面のメディアコントロールに表示
5. ロック画面のシークバーをドラッグ → 位置が変わることを確認
