# scripts

## rebuild.command — 実機への再ビルド＆インストール（ダブルクリック）

無料アカウントでは署名（プロビジョニング）が約7日で切れます。
このスクリプトは、接続中のiPhoneへ **ビルド → 署名更新 → インストール → 起動** を
一括で行い、再デプロイを簡単にします。

### 準備（最初の1回）

1. `scripts/rebuild.command` をエディタで開き、先頭の「設定」を確認・編集します。
   - `PROJECT_DIR` … リポジトリの場所（既定 `/Users/user/safari-yomiage-test`）
   - `BUNDLE_ID` … Xcode で変更した場合は合わせる
   - `TEAM_ID` … 任意。空でもXcode側の設定が使われます
2. デスクトップにコピーして実行権限を付けます:

   ```bash
   cp /Users/user/safari-yomiage-test/scripts/rebuild.command ~/Desktop/YomiagePlayer再ビルド.command
   chmod +x ~/Desktop/YomiagePlayer再ビルド.command
   ```

### 使い方

1. iPhoneをケーブルで接続し、ロック解除（必要なら「信頼」）
2. デスクトップの **`YomiagePlayer再ビルド.command`** をダブルクリック
   - 初回のみ Gatekeeper でブロックされたら、**右クリック > 開く** で許可
3. ターミナルが開き、ビルド〜インストール〜起動まで自動で進みます

### うまくいかないとき

- 「デバイスが見つかりません」→ 接続・ロック解除・「信頼」を確認
- 署名エラー → 一度 Xcode で各ターゲットの **Signing & Capabilities** に Team を設定してから再実行
- `devicectl` が無い → Xcode 15 以降が必要。だめなら Xcode から **Run（⌘R）**

> 前提: Xcode 15 以降（`xcrun devicectl` を使用）。
> このスクリプトは本体アプリ（YomiagePlayer）をビルドします。共有拡張も一緒にビルド・埋め込みされます。
