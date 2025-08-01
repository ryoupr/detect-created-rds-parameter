#!/bin/bash

# RDS テスト環境クリーンアップスクリプト
set -e

echo "🧹 RDS テスト環境のクリーンアップ開始"

REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
    REGION="ap-northeast-1"
    echo "⚠️ AWS リージョンが設定されていません。デフォルトで ${REGION} を使用します"
fi

echo "🌍 使用するリージョン: $REGION"

# 1. RDSインスタンスの削除（タグベース + 名前ベース）
echo -e "\n1. RDSインスタンスの削除"

# 削除対象のインスタンスを収集する配列
declare -a INSTANCES_TO_DELETE

# まずタグベースで検索
echo "🔍 タグ 'created-by:setup-test-env' でRDSインスタンスを検索"
TAGGED_INSTANCES=$(aws rds describe-db-instances --query 'DBInstances[?starts_with(DBInstanceIdentifier, `test-`)].DBInstanceIdentifier' --output text --region $REGION)

for INSTANCE_ID in $TAGGED_INSTANCES; do
    if [ -n "$INSTANCE_ID" ]; then
        echo "🔍 RDSインスタンス $INSTANCE_ID のタグ確認"
        TAGS=$(aws rds list-tags-for-resource --resource-name "arn:aws:rds:$REGION:$(aws sts get-caller-identity --query Account --output text):db:$INSTANCE_ID" --query 'TagList[?Key==`created-by`].Value' --output text --region $REGION 2>/dev/null)
        
        if [ "$TAGS" = "setup-test-env" ]; then
            INSTANCES_TO_DELETE+=("$INSTANCE_ID")
        else
            echo "ℹ️ RDSインスタンス $INSTANCE_ID はsetup-test-envで作成されていません"
        fi
    fi
done

# 従来の名前ベースでのフォールバック
echo "🔍 名前ベースでのフォールバック検索"
TEST_INSTANCES=("test-mysql-unencrypted" "test-mysql-encrypted" "test-sqlserver-insecure")
for INSTANCE_ID in "${TEST_INSTANCES[@]}"; do
    if aws rds describe-db-instances --db-instance-identifier $INSTANCE_ID --region $REGION > /dev/null 2>&1; then
        INSTANCES_TO_DELETE+=("$INSTANCE_ID")
    fi
done

# 重複を排除して削除処理を実行
UNIQUE_INSTANCES_TO_DELETE=($(printf "%s\n" "${INSTANCES_TO_DELETE[@]}" | sort -u))

if [ ${#UNIQUE_INSTANCES_TO_DELETE[@]} -gt 0 ]; then
    echo "�️ 以下のRDSインスタンスを削除します: ${UNIQUE_INSTANCES_TO_DELETE[*]}"
    for INSTANCE_ID in "${UNIQUE_INSTANCES_TO_DELETE[@]}"; do
        echo "  - 削除処理開始: $INSTANCE_ID"
        # 削除保護の無効化
        aws rds modify-db-instance \
            --db-instance-identifier $INSTANCE_ID \
            --no-deletion-protection \
            --apply-immediately \
            --region $REGION > /dev/null 2>&1 || true
        
        # インスタンス削除
        if ! aws rds delete-db-instance \
            --db-instance-identifier $INSTANCE_ID \
            --skip-final-snapshot \
            --delete-automated-backups \
            --region $REGION; then
            echo "⚠️ $INSTANCE_ID の削除開始に失敗しました。すでに削除処理中かもしれません。"
        else
            echo "✅ $INSTANCE_ID の削除を開始しました"
        fi
    done

    # すべてのインスタンスの削除完了を待機
    echo "⏳ すべてのRDSインスタンスの削除完了を待機中..."
    for INSTANCE_ID in "${UNIQUE_INSTANCES_TO_DELETE[@]}"; do
        echo "  - $INSTANCE_ID の削除完了待機..."
        if ! aws rds wait db-instance-deleted --db-instance-identifier $INSTANCE_ID --region $REGION; then
            echo "⚠️ $INSTANCE_ID の削除待機中にエラーが発生しましたが、処理を続行します。"
        else
            echo "✅ $INSTANCE_ID の削除が完了しました"
        fi
    done
    echo "✅ すべてのRDSインスタンスが削除されました"
else
    echo "✅ 削除対象のRDSインスタンスは見つかりませんでした"
fi


# 2. パラメーターグループの削除（タグベース + 名前ベース）
echo -e "\n2. パラメーターグループの削除"

# 削除対象のパラメーターグループを収集
declare -a PGS_TO_DELETE

# タグでパラメーターグループを検索
echo "🔍 タグ 'created-by:setup-test-env' でパラメーターグループを検索"
PARAMETER_GROUPS_TAGGED=$(aws rds describe-db-parameter-groups --query 'DBParameterGroups[?starts_with(DBParameterGroupName, `test-`)].DBParameterGroupName' --output text --region $REGION)
for PG_NAME in $PARAMETER_GROUPS_TAGGED; do
    if [ -n "$PG_NAME" ]; then
        TAGS=$(aws rds list-tags-for-resource --resource-name "arn:aws:rds:$REGION:$(aws sts get-caller-identity --query Account --output text):pg:$PG_NAME" --query 'TagList[?Key==`created-by`].Value' --output text --region $REGION 2>/dev/null)
        if [ "$TAGS" = "setup-test-env" ]; then
            PGS_TO_DELETE+=("$PG_NAME")
        fi
    fi
done

# 従来の名前ベースでのフォールバック
PARAMETER_GROUPS_FALLBACK=("test-mysql-params" "test-sqlserver-params")
for PG_NAME in "${PARAMETER_GROUPS_FALLBACK[@]}"; do
    if aws rds describe-db-parameter-groups --db-parameter-group-name $PG_NAME --region $REGION > /dev/null 2>&1; then
        PGS_TO_DELETE+=("$PG_NAME")
    fi
done

# 重複を排除して削除処理を実行
UNIQUE_PGS_TO_DELETE=($(printf "%s\n" "${PGS_TO_DELETE[@]}" | sort -u))
if [ ${#UNIQUE_PGS_TO_DELETE[@]} -gt 0 ]; then
    echo "🗑️ 以下のパラメーターグループを削除します: ${UNIQUE_PGS_TO_DELETE[*]}"
    for PG_NAME in "${UNIQUE_PGS_TO_DELETE[@]}"; do
        if ! aws rds delete-db-parameter-group --db-parameter-group-name "$PG_NAME" --region $REGION; then
            echo "⚠️ $PG_NAME の削除に失敗しました。手動での確認が必要な場合があります。"
        else
            echo "✅ パラメーターグループ削除完了: $PG_NAME"
        fi
    done
else
    echo "✅ 削除対象のパラメーターグループは見つかりませんでした"
fi


# 3. DBサブネットグループの削除（タグベース）
echo -e "\n3. DBサブネットグループの削除"

DB_SUBNET_GROUP_NAME="test-db-subnet-group"

echo "🔍 DBサブネットグループ $DB_SUBNET_GROUP_NAME の確認"
if aws rds describe-db-subnet-groups --db-subnet-group-name $DB_SUBNET_GROUP_NAME --region $REGION > /dev/null 2>&1; then
    TAGS=$(aws rds list-tags-for-resource --resource-name "arn:aws:rds:$REGION:$(aws sts get-caller-identity --query Account --output text):subgrp:$DB_SUBNET_GROUP_NAME" --query 'TagList[?Key==`created-by`].Value' --output text --region $REGION 2>/dev/null)
    
    if [ "$TAGS" = "setup-test-env" ] || [ -z "$TAGS" ]; then
        echo "🗑️ DBサブネットグループを削除: $DB_SUBNET_GROUP_NAME"
        if ! aws rds delete-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP_NAME --region $REGION; then
             echo "⚠️ $DB_SUBNET_GROUP_NAME の削除に失敗しました。手動での確認が必要な場合があります。"
        else
            echo "✅ DBサブネットグループ削除完了"
        fi
    else
        echo "ℹ️ DBサブネットグループ $DB_SUBNET_GROUP_NAME はsetup-test-envで作成されていません"
    fi
else
    echo "✅ DBサブネットグループ $DB_SUBNET_GROUP_NAME は存在しません"
fi

# 4. セキュリティグループの削除
echo -e "\n4. セキュリティグループの削除"

SECURITY_GROUP_NAME="test-rds-sg"

# タグでセキュリティグループを検索
echo "🔍 タグ 'created-by:setup-test-env' でセキュリティグループを検索"
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=tag:created-by,Values=setup-test-env" "Name=group-name,Values=$SECURITY_GROUP_NAME" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)

if [ "$SECURITY_GROUP_ID" != "None" ] && [ -n "$SECURITY_GROUP_ID" ]; then
    echo "🗑️ セキュリティグループを削除: $SECURITY_GROUP_ID"
    aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION
    echo "✅ セキュリティグループ削除完了"
else
    echo "✅ setup-test-envで作成されたセキュリティグループは存在しません"
fi

# 5. VPCとサブネットの削除（タグベース）
echo -e "\n5. VPC関連リソースの削除確認"

# タグでVPCを検索
echo "🔍 タグ 'created-by:setup-test-env' でVPCを検索"
CREATED_VPC=$(aws ec2 describe-vpcs --filters "Name=tag:created-by,Values=setup-test-env" --query 'Vpcs[0].VpcId' --output text --region $REGION 2>/dev/null)

if [ "$CREATED_VPC" != "None" ] && [ -n "$CREATED_VPC" ]; then
    echo "🔍 setup-test-envで作成されたVPCを確認: $CREATED_VPC"
    
    read -p "⚠️ VPC $CREATED_VPC とその関連リソース（サブネット、ルートテーブル、IGW）を削除しますか？ (y/N): " REPLY
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🗑️ VPC関連リソースを削除します"
        
        # タグでサブネットを検索・削除
        echo "📡 setup-test-envで作成されたサブネットを削除中..."
        SUBNETS=$(aws ec2 describe-subnets --filters "Name=tag:created-by,Values=setup-test-env" "Name=vpc-id,Values=$CREATED_VPC" --query 'Subnets[].SubnetId' --output text --region $REGION)
        for SUBNET_ID in $SUBNETS; do
            if [ -n "$SUBNET_ID" ]; then
                echo "  - サブネット削除: $SUBNET_ID"
                aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION
            fi
        done
        
        # タグでインターネットゲートウェイを検索・削除
        echo "🌐 setup-test-envで作成されたインターネットゲートウェイを削除中..."
        IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=tag:created-by,Values=setup-test-env" "Name=attachment.vpc-id,Values=$CREATED_VPC" --query 'InternetGateways[0].InternetGatewayId' --output text --region $REGION)
        if [ "$IGW_ID" != "None" ] && [ -n "$IGW_ID" ]; then
            echo "  - IGWデタッチ: $IGW_ID"
            aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $CREATED_VPC --region $REGION
            echo "  - IGW削除: $IGW_ID"
            aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
        fi
        
        # VPCの削除
        echo "🏠 VPCを削除中..."
        aws ec2 delete-vpc --vpc-id $CREATED_VPC --region $REGION
        echo "✅ VPC削除完了: $CREATED_VPC"
    else
        echo "ℹ️ VPCの削除をスキップしました"
    fi
else
    echo "✅ setup-test-envで作成されたVPCが見つかりません"
fi

echo -e "\n✅ RDS テスト環境のクリーンアップ完了"
echo ""
echo "📋 削除処理の詳細:"
echo "  - RDSインスタンス: タグ 'created-by:setup-test-env' でフィルタリング + フォールバック"
echo "  - パラメーターグループ: タグ 'created-by:setup-test-env' でフィルタリング + フォールバック"
echo "  - DBサブネットグループ: タグ 'created-by:setup-test-env' でフィルタリング"
echo "  - セキュリティグループ: タグ 'created-by:setup-test-env' でフィルタリング"
echo "  - VPC関連リソース: タグ 'created-by:setup-test-env' でフィルタリング"
echo ""
echo "💡 削除が正常に完了したかどうかは、AWSコンソールで確認してください。"
