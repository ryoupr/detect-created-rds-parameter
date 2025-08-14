#!/bin/bash

# RDS暗号化監査システムのデプロイスクリプト（既存リソース設定版）

set -e

CONFIG_FILE="${CONFIG_FILE:-config/existing-resources-config.json}"
STACK_NAME="RdsEncryptionAuditStack"

echo "🚀 RDS暗号化監査システムのデプロイを開始します"
echo "設定ファイル: $CONFIG_FILE"

# 設定ファイルの存在確認
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ エラー: 設定ファイル $CONFIG_FILE が見つかりません"
    echo "利用可能な設定例:"
    echo "  - config/default-config.json (全て新規作成)"
    echo "  - config/existing-resources-config.json (既存リソース活用)"
    echo ""
    echo "設定ファイルを作成してから再実行してください。"
    echo "詳細は docs/existing-config-guide.md を参照してください。"
    exit 1
fi

echo "✅ 設定ファイル $CONFIG_FILE を確認しました"

# 依存関係のインストール
echo "📦 依存関係をインストールしています..."
npm install

# TypeScriptのビルド
echo "🔨 TypeScriptをビルドしています..."
npm run build

# CDKスタックの差分確認
echo "🔍 デプロイ内容を確認しています..."
CONFIG_FILE="$CONFIG_FILE" cdk diff "$STACK_NAME" || true

# デプロイ確認
read -p "このままデプロイを続行しますか？ (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ デプロイを中止しました"
    exit 0
fi

# デプロイ実行
echo "🚀 デプロイを実行しています..."
CONFIG_FILE="$CONFIG_FILE" cdk deploy "$STACK_NAME" --require-approval never

echo ""
echo "✅ デプロイが完了しました！"
echo ""
echo "📧 メール通知の設定:"

# 設定ファイルからSNS設定を確認
if grep -q "existingTopicArn" "$CONFIG_FILE"; then
    echo "  - 既存のSNSトピックを使用しています"
    echo "  - メール通知の設定は既存の設定に従います"
else
    echo "  - 新規SNSトピックを作成しました"
    echo "  - 設定したメールアドレスに確認メールが送信されます"
    echo "  - メール内の「Confirm subscription」リンクをクリックしてください"
fi

echo ""
echo "🔍 監査ルールの確認:"
echo "  AWS Consoleで以下を確認してください:"
echo "  - AWS Config > Rules でルールの状態を確認"
echo "  - CloudWatch Logs でLambda関数のログを確認"
echo ""
echo "📚 詳細なドキュメント:"
echo "  - README.md - 基本的な使用方法"
echo "  - docs/existing-config-guide.md - 既存リソース利用ガイド"
