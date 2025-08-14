#!/bin/bash

# RDS暗号化監査システム テスト環境クリーンアップスクリプト
set -e

echo "🧹 RDSテスト環境のクリーンアップを開始します"

REGION=${AWS_DEFAULT_REGION:-"ap-northeast-1"}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🌍 リージョン: $REGION"
echo "👤 アカウント: $ACCOUNT_ID"

# 1. RDSインスタンスの削除
echo -e "\n1. RDSテストインスタンスの削除"

TEST_INSTANCES=("test-mysql-unencrypted" "test-postgres-encrypted")
for INSTANCE_ID in "${TEST_INSTANCES[@]}"; do
    if aws rds describe-db-instances --db-instance-identifier $INSTANCE_ID --region $REGION &>/dev/null; then
        echo "🗑️ RDSインスタンスを削除中: $INSTANCE_ID"
        
        # 削除保護の無効化
        aws rds modify-db-instance \
            --db-instance-identifier $INSTANCE_ID \
            --no-deletion-protection \
            --apply-immediately \
            --region $REGION &>/dev/null
            
        # インスタンス削除
        aws rds delete-db-instance \
            --db-instance-identifier $INSTANCE_ID \
            --skip-final-snapshot \
            --delete-automated-backups \
            --region $REGION
        
        echo "✅ $INSTANCE_ID の削除を開始しました"
    else
        echo "ℹ️ RDSインスタンス $INSTANCE_ID は存在しません"
    fi
done

# インスタンス削除の完了を待機
echo -e "\n⏳ RDSインスタンスの削除完了を待機中..."
for INSTANCE_ID in "${TEST_INSTANCES[@]}"; do
    if aws rds describe-db-instances --db-instance-identifier $INSTANCE_ID --region $REGION &>/dev/null; then
        echo "  - $INSTANCE_ID の削除完了待機..."
        aws rds wait db-instance-deleted --db-instance-identifier $INSTANCE_ID --region $REGION || echo "⚠️ $INSTANCE_ID の削除待機中にエラーが発生しました"
    fi
done
echo "✅ RDSインスタンスの削除が完了しました"

# 2. パラメーターグループの削除
echo -e "\n2. テスト用パラメーターグループの削除"

PARAMETER_GROUPS=("test-mysql-params" "test-postgres-params")
for PG_NAME in "${PARAMETER_GROUPS[@]}"; do
    if aws rds describe-db-parameter-groups --db-parameter-group-name $PG_NAME --region $REGION &>/dev/null; then
        echo "🗑️ パラメーターグループを削除中: $PG_NAME"
        aws rds delete-db-parameter-group --db-parameter-group-name $PG_NAME --region $REGION
        echo "✅ $PG_NAME の削除完了"
    else
        echo "ℹ️ パラメーターグループ $PG_NAME は存在しません"
    fi
done

# 3. DBサブネットグループの削除
echo -e "\n3. DBサブネットグループの削除"

DB_SUBNET_GROUP_NAME="test-db-subnet-group"
if aws rds describe-db-subnet-groups --db-subnet-group-name $DB_SUBNET_GROUP_NAME --region $REGION &>/dev/null; then
    echo "🗑️ DBサブネットグループを削除中: $DB_SUBNET_GROUP_NAME"
    aws rds delete-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP_NAME --region $REGION
    echo "✅ DBサブネットグループの削除完了"
else
    echo "ℹ️ DBサブネットグループ $DB_SUBNET_GROUP_NAME は存在しません"
fi

# 4. セキュリティグループの削除
echo -e "\n4. テスト用セキュリティグループの削除"

SECURITY_GROUP_NAME="test-rds-sg"
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>/dev/null)

if [ "$SECURITY_GROUP_ID" != "None" ] && [ -n "$SECURITY_GROUP_ID" ]; then
    echo "🗑️ セキュリティグループを削除中: $SECURITY_GROUP_ID"
    aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION
    echo "✅ セキュリティグループの削除完了"
else
    echo "ℹ️ セキュリティグループ $SECURITY_GROUP_NAME は存在しません"
fi

echo -e "\n✅ テスト環境のクリーンアップが完了しました！"
echo ""
echo "📋 削除されたリソース:"
echo "  - RDSインスタンス: ${TEST_INSTANCES[*]}"
echo "  - パラメーターグループ: ${PARAMETER_GROUPS[*]}"
echo "  - DBサブネットグループ: $DB_SUBNET_GROUP_NAME"
echo "  - セキュリティグループ: $SECURITY_GROUP_NAME"
echo ""
echo "💡 本スクリプトではVPCやサブネットは削除されません"
echo "   （他のリソースでも使用されている可能性があるため）"
echo ""
echo "🔍 削除が正常に完了したかどうかは、AWSコンソールで確認してください："
echo "   https://console.aws.amazon.com/rds/home?region=$REGION"
