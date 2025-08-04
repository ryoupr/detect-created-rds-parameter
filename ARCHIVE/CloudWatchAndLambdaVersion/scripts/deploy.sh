#!/bin/bash

# RDS Parameter Group Encryption Monitor デプロイスクリプト

set -e

echo "🚀 RDS Parameter Group Encryption Monitor のデプロイを開始します..."

# 環境変数の確認
if [ -z "$ALERT_EMAIL" ]; then
    echo "⚠️  警告: ALERT_EMAIL環境変数が設定されていません。"
    echo "   デフォルトのメールアドレス (admin@example.com) を使用します。"
    echo "   実際のメールアドレスを設定するには:"
    echo "   export ALERT_EMAIL=your-email@example.com"
    ALERT_EMAIL="admin@example.com"
fi

echo "📧 通知先メールアドレス: $ALERT_EMAIL"

# Lambda関数のビルド
echo "🔨 Lambda関数をビルドしています..."
cd lambda
npm install
npm run build
cd ..

echo "📦 CDKのビルド..."
npm run build

# CDKブートストラップの確認
echo "🥾 CDKブートストラップの確認..."
if ! npx cdk bootstrap 2>/dev/null; then
    echo "⚠️  CDKブートストラップが必要です。実行中..."
    npx cdk bootstrap
fi

# CDKテンプレートの差分チェック
echo "📋 デプロイ前の差分確認..."
npx cdk diff --context alertEmail="$ALERT_EMAIL"

# デプロイの確認
echo ""
echo "❓ デプロイを実行しますか? (y/N)"
read -r CONFIRM

if [[ $CONFIRM =~ ^[Yy]$ ]]; then
    echo "🚀 デプロイを実行しています..."
    npx cdk deploy --context alertEmail="$ALERT_EMAIL" --require-approval never
    
    echo ""
    echo "✅ デプロイが完了しました！"
    echo ""
    echo "📧 次の手順:"
    echo "1. SNSサブスクリプション確認メールを受信したら、確認リンクをクリックしてください"
    echo "2. テスト用RDSインスタンスを作成して動作確認を行ってください"
    echo ""
    echo "📊 CloudWatchログの確認:"
    echo "   - RDS Parameter Audit Function: /aws/lambda/DetectCreatedRdsParameterStack-RDSParameterAuditFunction*"
    echo "   - Scheduled Audit Function: /aws/lambda/DetectCreatedRdsParameterStack-ScheduledRDSParameterAuditFunction*"
    echo ""
    echo "🔧 手動実行でのテスト:"
    echo "   aws lambda invoke --function-name DetectCreatedRdsParameterStack-ScheduledRDSParameterAuditFunction* response.json"
    
else
    echo "❌ デプロイがキャンセルされました。"
fi
