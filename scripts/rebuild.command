#!/bin/bash
#
# YomiagePlayer 再ビルド＆実機インストール用スクリプト
# ------------------------------------------------------------
# デスクトップに置いてダブルクリックすると、接続中のiPhoneへ
# 自動でビルド・署名更新・インストール・起動まで行います。
# （無料アカウントで約7日ごとに切れる署名を、手早く貼り直す用途）
#
# 使い方:
#   1) 下の「設定」を自分の環境に合わせて編集
#   2) このファイルをデスクトップにコピーしてダブルクリック
#      （初回のみ: 右クリック > 開く で実行を許可）
#
# 前提: Xcode 15 以降（xcrun devicectl を使用）
# ------------------------------------------------------------
set -o pipefail

# ===== 設定（必要に応じて書き換え）=========================
PROJECT_DIR="/Users/user/safari-yomiage-test"   # リポジトリの場所
SCHEME="YomiagePlayer"
CONFIGURATION="Debug"
BUNDLE_ID="com.example.YomiagePlayer"            # Xcodeで変更したら合わせる
TEAM_ID=""   # 任意。空ならpbxproj/Xcodeの設定を使用。例: ABCDE12345
# ===========================================================

pause_exit() { echo; read -n1 -r -p "Enterキーで閉じる..."; exit "${1:-0}"; }

echo "▶ YomiagePlayer 再ビルドを開始します"
cd "$PROJECT_DIR" 2>/dev/null || { echo "✖ プロジェクトが見つかりません: $PROJECT_DIR"; pause_exit 1; }

# --- 接続中の実機（シミュレータ除く）のUDIDを取得 ---
UDID=$(xcrun xctrace list devices 2>/dev/null \
  | awk '/== Simulators ==/{exit} {print}' \
  | grep -Eo '\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})\)' \
  | tr -d '()' | head -1)

if [ -z "$UDID" ]; then
  echo "✖ 接続中のiPhone/iPadが見つかりません。"
  echo "  ケーブル接続・端末のロック解除・「このコンピュータを信頼」を確認してください。"
  pause_exit 1
fi
echo "✔ デバイス: $UDID"

# --- ビルド（自動署名の更新を許可）---
TEAM_ARG=()
[ -n "$TEAM_ID" ] && TEAM_ARG=(DEVELOPMENT_TEAM="$TEAM_ID")

echo "▶ ビルド中...（初回は数分かかります）"
xcodebuild \
  -project YomiagePlayer.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "id=$UDID" \
  -allowProvisioningUpdates \
  "${TEAM_ARG[@]}" \
  build || { echo "✖ ビルドに失敗しました（署名/Team設定を確認してください）"; pause_exit 1; }

# --- 生成された .app の場所を取得 ---
APP_PATH=$(xcodebuild -project YomiagePlayer.xcodeproj -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')

if [ ! -d "$APP_PATH" ]; then
  echo "✖ ビルド成果物が見つかりません: $APP_PATH"
  pause_exit 1
fi
echo "✔ アプリ: $APP_PATH"

# --- インストール ---
echo "▶ インストール中..."
xcrun devicectl device install app --device "$UDID" "$APP_PATH" \
  || { echo "✖ インストールに失敗しました。Xcodeから Run（⌘R）してください"; pause_exit 1; }

# --- 起動（失敗しても無視）---
echo "▶ 起動中..."
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "✅ 完了しました！"
pause_exit 0
