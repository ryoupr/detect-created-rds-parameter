#!/bin/bash

# RDS暗号化監査システムデプロイスクリプト
set -e

echo "🚀 RDS暗号化監査システムのデプロイを開始します"

# 現在のディレクトリを確認
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 環境変数の確認
echo "📋 環境設定の確認"
AWS_REGION=${CDK_DEFAULT_REGION:-"ap-northeast-1"}
AWS_ACCOUNT=${CDK_DEFAULT_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "未設定")}

echo "  リージョン: $AWS_REGION"
echo "  アカウント: $AWS_ACCOUNT"

if [ "$AWS_ACCOUNT" = "未設定" ]; then
  echo "❌ AWSの認証情報が設定されていません"
  echo "   aws configure を実行するか、適切な認証情報を設定してください"
  exit 1
fi

# 依存関係の確認
echo -e "\n📦 依存関係の確認"
if ! command -v node &> /dev/null; then
  echo "❌ Node.jsがインストールされていません"
  exit 1
fi

if ! command -v cdk &> /dev/null; then
  echo "⚠️ AWS CDK CLIがインストールされていません。インストール中..."
  npm install -g aws-cdk
fi

# 依存関係のインストール
echo -e "\n📥 依存関係のインストール"
npm install

# TypeScriptのビルド
echo -e "\n🔨 TypeScriptのビルド"
npm run build

# CDKのブートストラップ確認
echo -e "\n🏗️ CDKブートストラップの確認"
if ! aws cloudformation describe-stacks --stack-name CDKToolkit --region $AWS_REGION &>/dev/null; then
  echo "   CDKブートストラップを実行中..."
  cdk bootstrap aws://$AWS_ACCOUNT/$AWS_REGION
else
  echo "   ✅ CDKブートストラップ済み"
fi

# デプロイ前の確認
echo -e "\n🔍 デプロイ前の差分確認"
cdk diff

# デプロイの実行確認
echo -e "\n⚠️ デプロイを実行してよろしいですか？"
echo "   以下のリソースが作成されます："
echo "   - AWS Config Rules"
echo "   - Lambda関数"
echo "   - SNSトピック"
echo "   - S3バケット"
echo "   - EventBridge Rule"
echo "   - IAMロール"

read -p "続行しますか？ (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "デプロイをキャンセルしました"
  exit 0
fi

# デプロイの実行
echo -e "\n🚀 デプロイを実行中..."
cdk deploy --require-approval never

# デプロイ後の設定案内
echo -e "\n✅ デプロイが完了しました！"
echo ""
echo "📧 次の手順:"
echo "1. 通知メールアドレスの確認"
echo "   - SNSトピックから購読確認メールが送信されます"
echo "   - メール内の確認リンクをクリックしてください"
echo ""
echo "2. 動作確認"
echo "   - 暗号化無効のRDSインスタンスを作成して通知を確認"
echo ""
echo "3. 設定の確認"
echo "   - AWS Configコンソールでルールの状態を確認"
echo "   - CloudWatch LogsでLambda関数のログを確認"
echo ""
echo "🔗 有用なリンク:"
echo "   AWS Config: https://console.aws.amazon.com/config/home?region=$AWS_REGION"
echo "   Lambda Functions: https://console.aws.amazon.com/lambda/home?region=$AWS_REGION"
echo "   SNS Topics: https://console.aws.amazon.com/sns/v3/home?region=$AWS_REGION"
echo ""
echo "📚 詳細な設定方法はREADME.mdを参照してください"
