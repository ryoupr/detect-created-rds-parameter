#!/usr/bin/env bash
# SNS トピック状態確認スクリプト
# 用途:
#  1. デプロイ済みスタック出力 or 環境変数で指定された SNS Topic ARN の存在/属性/サブスクリプション状況を確認
#  2. メール購読が PendingConfirmation のまま放置されていないか簡易チェック
#  3. Config: NOTIFY トピックの ARN を安全に取得 (cdk 出力 or 直接指定)
#
# 使い方:
#   bash scripts/check-sns-topic.sh                   # CDK の出力ファイル (cdk synth/diff 時) か describe-stacks から自動判定
#   SNS_TOPIC_ARN=arn:aws:sns:... bash scripts/check-sns-topic.sh
#   STACK_NAME=RdsEncryptionAuditStack bash scripts/check-sns-topic.sh
#
# オプション環境変数:
#   STACK_NAME                (default: RdsEncryptionAuditStack)
#   REGION / AWS_DEFAULT_REGION
#   SNS_TOPIC_ARN             直接 ARN 指定で stack 参照スキップ
#   OUTPUT=json|table         出力フォーマット (属性/購読)
#
# 返り値: 0=成功, 1=トピック未存在, 2=購読取得エラー
set -euo pipefail
command -v aws >/dev/null 2>&1 || { echo "❌ aws CLI 未インストール"; exit 1; }

REGION=${AWS_DEFAULT_REGION:-${REGION:-"ap-northeast-1"}}
STACK_NAME=${STACK_NAME:-RdsEncryptionAuditStack}
OUTPUT=${OUTPUT:-table}
: "${REGION}" >/dev/null

get_stack_output() {
  local key="$1"
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" --output text 2>/dev/null || echo ""
}

if [[ -z ${SNS_TOPIC_ARN:-} || ${SNS_TOPIC_ARN} == NONE ]]; then
  SNS_TOPIC_ARN=$(get_stack_output NotificationTopicArn || true)
fi

if [[ -z $SNS_TOPIC_ARN || $SNS_TOPIC_ARN == None ]]; then
  echo "❌ SNS Topic ARN を特定できません (STACK_NAME=$STACK_NAME REGION=$REGION)"
  echo "   環境変数 SNS_TOPIC_ARN=arn:aws:sns:... を指定してください"
  exit 1
fi

echo "🔎 SNS Topic チェック: $SNS_TOPIC_ARN (region=$REGION)"

# 属性
if ! ATTR_JSON=$(aws sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN" --region "$REGION" --output json 2>/dev/null); then
  echo "❌ トピックが存在しません"; exit 1;
fi

# Attributes 整形
POLICY_MD5=$(echo "$ATTR_JSON" | jq -r '.Attributes.Policy' 2>/dev/null | md5sum | awk '{print $1}') || POLICY_MD5="-"
SUB_PENDING="-"

# サブスクリプション一覧
if SUBS_RAW=$(aws sns list-subscriptions-by-topic --topic-arn "$SNS_TOPIC_ARN" --region "$REGION" --output json 2>/dev/null); then
  PENDING=$(echo "$SUBS_RAW" | jq -r '.Subscriptions[] | select(.SubscriptionArn=="PendingConfirmation") | .Endpoint' | paste -sd, - || true)
  CONFIRMED=$(echo "$SUBS_RAW" | jq -r '.Subscriptions[] | select(.SubscriptionArn!="PendingConfirmation") | .Protocol+":"+.Endpoint' | paste -sd, - || true)
  SUB_PENDING=${PENDING:-none}
  SUB_CONFIRMED=${CONFIRMED:-none}
else
  echo "⚠️ サブスクリプション取得失敗"; SUB_PENDING="(error)"; SUB_CONFIRMED="(error)"; RC=2
fi

if [[ $OUTPUT == json ]]; then
  jq -n --arg topic "$SNS_TOPIC_ARN" \
        --arg policy_md5 "$POLICY_MD5" \
        --arg subs_pending "$SUB_PENDING" \
        --arg subs_confirmed "$SUB_CONFIRMED" \
        '{topic: $topic, policy_md5:$policy_md5, subscriptions:{pending:$subs_pending, confirmed:$subs_confirmed}}'
else
  echo "--- Attributes Digest ---"
  echo "Policy(md5) : $POLICY_MD5"
  echo "Confirmed  : ${SUB_CONFIRMED:-none}"
  echo "Pending    : $SUB_PENDING"
fi

# 推奨アクション
if [[ $SUB_PENDING != none && $SUB_PENDING != "(error)" ]]; then
  echo "💡 PendingConfirmation の購読があります。メール受信者に確認リンククリックを依頼してください。"
fi

exit ${RC:-0}
