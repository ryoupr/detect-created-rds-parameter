#!/bin/bash

# 指定されたタグが付与されているAWSリソースを一覧表示するスクリプト

set -e

echo "🏷️  タグ付きリソースの検索を開始します"

# --- 設定 ---
# 検索対象のタグを指定します
TAG_KEY="created-by"
TAG_VALUE="setup-test-env"
# ---

# jqコマンドの存在確認
if ! command -v jq &> /dev/null; then
    echo "❌ エラー: このスクリリプトの実行には 'jq' が必要です。"
    echo "ℹ️ 'sudo apt-get install jq' や 'sudo yum install jq' などでインストールしてください。"
    exit 1
fi

# AWSリージョンの設定
REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
    REGION="ap-northeast-1"
    echo "⚠️  AWSリージョンが設定されていません。デフォルトで ${REGION} を使用します"
fi

echo "🌍 使用するリージョン: $REGION"
echo "🔍 検索するタグ: Key=${TAG_KEY}, Value=${TAG_VALUE}"
echo ""

# AWS Resource Groups Tagging API を使用してリソースを検索
echo "🚀 リソースを検索中..."
RESOURCES=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=${TAG_KEY},Values=${TAG_VALUE}" \
    --region "$REGION" \
    --output json)

# 結果の確認
if [ -z "$RESOURCES" ] || [ "$(echo "$RESOURCES" | jq '.ResourceTagMappingList | length')" -eq 0 ]; then
    echo "✅ 指定されたタグを持つリソースは見つかりませんでした。"
    exit 0
fi

echo "📋 見つかったリソース一覧:"
echo "--------------------------------------------------"

# jq を使って結果を整形して出力
# ARNからサービスとリソースタイプを抽出して表示
echo "$RESOURCES" | jq -r '
  .ResourceTagMappingList[] |
  ( .ResourceARN | split(":") | 
    "Service: " + .[2] + "\n" +
    "Resource: " + .[5] 
  ) +
  "\nARN: " + .ResourceARN + "\n--------------------------------------------------"
'

echo "✅ 検索が完了しました。"
