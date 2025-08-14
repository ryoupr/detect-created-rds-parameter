#!/usr/bin/env bash

# RDS暗号化監査システム テスト環境クリーンアップスクリプト
# 改良点:
#  - set -euo pipefail で厳格化
#  - 環境変数による対象制御 (SKIP_DB_DELETE など)
#  - 削除待機を並列化 (バックグラウンド) し時間短縮
#  - 既存しないリソースは警告のみ
set -euo pipefail

REGION=${AWS_DEFAULT_REGION:-${REGION:-"ap-northeast-1"}}
APP_TAG_KEY=${APP_TAG_KEY:-Application}
APP_TAG_VALUE=${APPLICATION_TAG_VALUE:-detect-created-rds-parameter-test}
# （完全タグベース削除に移行: 以下の名前指定は互換維持のため残すがロジックでは使用しない）
MYSQL_INSTANCE_ID=${MYSQL_INSTANCE_ID:-""}
POSTGRES_INSTANCE_ID=${POSTGRES_INSTANCE_ID:-""}
DB_SUBNET_GROUP_NAME=${DB_SUBNET_GROUP_NAME:-""}
SECURITY_GROUP_NAME=${SECURITY_GROUP_NAME:-""}
MYSQL_PG_NAME=${MYSQL_PG_NAME:-""}
POSTGRES_PG_NAME=${POSTGRES_PG_NAME:-""}
SKIP_DB_DELETE=${SKIP_DB_DELETE:-"false"}
NO_WAIT=${NO_WAIT:-"false"}
DELETE_TAGGED_VPC=${DELETE_TAGGED_VPC:-"true"}   # false にすると VPC/サブネット温存

echo "🧹 RDSテスト環境のクリーンアップを開始します"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")

echo "🌍 リージョン: $REGION"
echo "👤 アカウント: $ACCOUNT_ID"
echo "🏷️ 削除対象タグ: $APP_TAG_KEY=$APP_TAG_VALUE (完全タグベース)"

echo -e "\n0. タグスキャン"

# --- ヘルパ ---
has_tag() { # arn
    local arn="$1"; local key="$APP_TAG_KEY"; local val="$APP_TAG_VALUE"
    aws rds list-tags-for-resource --resource-name "$arn" --region "$REGION" \
        --query "TagList[?Key=='$key' && Value=='$val'] | length(@)" --output text 2>/dev/null || echo 0
}

# RDSインスタンス (DB / Cluster) 列挙
TAGGED_DB_INSTANCES=()
while read -r dbid; do
    [[ -z $dbid || $dbid == None ]] && continue
    ARN="arn:aws:rds:$REGION:$ACCOUNT_ID:db:$dbid"
    if [[ $(has_tag "$ARN") -gt 0 ]]; then TAGGED_DB_INSTANCES+=("$dbid"); fi
done < <(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null | tr '\t' '\n')

TAGGED_DB_CLUSTERS=()
while read -r cid; do
    [[ -z $cid || $cid == None ]] && continue
    CARN="arn:aws:rds:$REGION:$ACCOUNT_ID:cluster:$cid"
    if [[ $(has_tag "$CARN") -gt 0 ]]; then TAGGED_DB_CLUSTERS+=("$cid"); fi
done < <(aws rds describe-db-clusters --region "$REGION" --query 'DBClusters[].DBClusterIdentifier' --output text 2>/dev/null | tr '\t' '\n')

# パラメータグループ (DB / Cluster 両方)
TAGGED_PGS=()
while read -r pg; do
    [[ -z $pg || $pg == None ]] && continue
    ARN="arn:aws:rds:$REGION:$ACCOUNT_ID:pg:$pg"
    if [[ $(has_tag "$ARN") -gt 0 ]]; then TAGGED_PGS+=("$pg"); fi
done < <(aws rds describe-db-parameter-groups --region "$REGION" --query 'DBParameterGroups[].DBParameterGroupName' --output text 2>/dev/null | tr '\t' '\n')

TAGGED_CLUSTER_PGS=()
while read -r cpg; do
    [[ -z $cpg || $cpg == None ]] && continue
    CPG_ARN="arn:aws:rds:$REGION:$ACCOUNT_ID:cluster-pg:$cpg"
    if [[ $(has_tag "$CPG_ARN") -gt 0 ]]; then TAGGED_CLUSTER_PGS+=("$cpg"); fi
done < <(aws rds describe-db-cluster-parameter-groups --region "$REGION" --query 'DBClusterParameterGroups[].DBClusterParameterGroupName' --output text 2>/dev/null | tr '\t' '\n')

# DB Subnet Group (タグ API 対応)
TAGGED_SUBNET_GROUPS=()
while read -r sg; do
    [[ -z $sg || $sg == None ]] && continue
    ARN="arn:aws:rds:$REGION:$ACCOUNT_ID:subgrp:$sg"
    if [[ $(has_tag "$ARN") -gt 0 ]]; then TAGGED_SUBNET_GROUPS+=("$sg"); fi
done < <(aws rds describe-db-subnet-groups --region "$REGION" --query 'DBSubnetGroups[].DBSubnetGroupName' --output text 2>/dev/null | tr '\t' '\n')

echo "  - Tagged DB Instances       : ${TAGGED_DB_INSTANCES[*]:-(none)}"
echo "  - Tagged DB Clusters        : ${TAGGED_DB_CLUSTERS[*]:-(none)}"
echo "  - Tagged ParameterGroups    : ${TAGGED_PGS[*]:-(none)}"
echo "  - Tagged ClusterParamGroups : ${TAGGED_CLUSTER_PGS[*]:-(none)}"
echo "  - Tagged SubnetGroups       : ${TAGGED_SUBNET_GROUPS[*]:-(none)}"

# フォールバック統合 (無効化済: 完全タグベース)

# 1. RDSインスタンスの削除
echo -e "\n1. RDSテストインスタンスの削除"

TEST_INSTANCES=("${TAGGED_DB_INSTANCES[@]}")
TEST_CLUSTERS=("${TAGGED_DB_CLUSTERS[@]}")
if [[ "$SKIP_DB_DELETE" == "true" ]]; then
    echo "⏭️  SKIP_DB_DELETE=true のため RDS インスタンス削除をスキップします";
else
    for INSTANCE_ID in "${TEST_INSTANCES[@]}"; do
        if aws rds describe-db-instances --db-instance-identifier "$INSTANCE_ID" --region "$REGION" --query 'DBInstance' >/dev/null 2>&1; then
        # 既にタグベースで抽出済
        echo "🗑️ RDSインスタンスを削除中: $INSTANCE_ID"
        
        # 削除保護の無効化
        aws rds modify-db-instance \
                        --db-instance-identifier "$INSTANCE_ID" \
            --no-deletion-protection \
            --apply-immediately \
                        --region "$REGION" &>/dev/null || true
            
        # インスタンス削除
        aws rds delete-db-instance \
                        --db-instance-identifier "$INSTANCE_ID" \
            --skip-final-snapshot \
            --delete-automated-backups \
                        --region "$REGION" || echo "⚠️ 削除コマンド失敗: $INSTANCE_ID"
        
        echo "✅ $INSTANCE_ID の削除を開始しました"
    else
        echo "ℹ️ RDSインスタンス $INSTANCE_ID は存在しません"
    fi
    done
fi

# クラスタ削除 (先にインスタンス削除が進行中であること前提)
if [[ ${#TEST_CLUSTERS[@]} -gt 0 ]]; then
    echo -e "\n1b. RDSクラスタの削除"
    for CID in "${TEST_CLUSTERS[@]}"; do
        if aws rds describe-db-clusters --db-cluster-identifier "$CID" --region "$REGION" &>/dev/null; then
            echo "🗑️ RDSクラスタ削除中: $CID"
            aws rds delete-db-cluster --db-cluster-identifier "$CID" --skip-final-snapshot --region "$REGION" 2>/dev/null || echo "⚠️ 削除失敗: $CID"
        fi
    done
fi

# インスタンス削除の完了を待機
if [[ "$SKIP_DB_DELETE" == "false" && "$NO_WAIT" == "false" ]]; then
    echo -e "\n⏳ RDSインスタンスの削除完了を待機中..."
    for INSTANCE_ID in "${TEST_INSTANCES[@]}"; do
            if aws rds describe-db-instances --db-instance-identifier "$INSTANCE_ID" --region "$REGION" &>/dev/null; then
                    echo "  - $INSTANCE_ID の削除完了待機..."
                    (aws rds wait db-instance-deleted --db-instance-identifier "$INSTANCE_ID" --region "$REGION" && echo "    ✅ $INSTANCE_ID 削除完了") &
            fi
    done
    wait || true
    echo "✅ RDSインスタンスの削除待機処理完了"
fi

# 2. パラメーターグループの削除
echo -e "\n2. テスト用パラメーターグループの削除"

for PG_NAME in "${TAGGED_PGS[@]}"; do
    if aws rds describe-db-parameter-groups --db-parameter-group-name $PG_NAME --region $REGION &>/dev/null; then
        echo "🗑️ パラメーターグループ削除: $PG_NAME"
        aws rds delete-db-parameter-group --db-parameter-group-name $PG_NAME --region $REGION || echo "⚠️ 削除失敗 $PG_NAME"
        echo "✅ $PG_NAME 削除開始"
    fi
done
for CPG_NAME in "${TAGGED_CLUSTER_PGS[@]}"; do
    if aws rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name $CPG_NAME --region $REGION &>/dev/null; then
        echo "🗑️ クラスタパラメーターグループ削除: $CPG_NAME"
        aws rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name $CPG_NAME --region $REGION || echo "⚠️ 削除失敗 $CPG_NAME"
        echo "✅ $CPG_NAME 削除開始"
    fi
done

# 3. DBサブネットグループの削除
echo -e "\n3. DBサブネットグループの削除"
for sg in "${TAGGED_SUBNET_GROUPS[@]}"; do
    if aws rds describe-db-subnet-groups --db-subnet-group-name "$sg" --region "$REGION" &>/dev/null; then
        echo "🗑️ DBサブネットグループ削除: $sg"
        aws rds delete-db-subnet-group --db-subnet-group-name "$sg" --region "$REGION" || echo "⚠️ 削除失敗 $sg"
        echo "✅ $sg 削除開始"
    fi
done
[[ ${#TAGGED_SUBNET_GROUPS[@]} -eq 0 ]] && echo "ℹ️ タグ一致 DBサブネットグループ なし"

# 4. セキュリティグループの削除 (VPC削除前)
echo -e "\n4. テスト用セキュリティグループの削除"
SECURITY_GROUP_IDS=$(aws ec2 describe-security-groups --filters "Name=tag:$APP_TAG_KEY,Values=$APP_TAG_VALUE" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
if [[ -n $SECURITY_GROUP_IDS ]]; then
    for sgid in $SECURITY_GROUP_IDS; do
        echo "🗑️ セキュリティグループ削除: $sgid"; aws ec2 delete-security-group --group-id "$sgid" --region "$REGION" 2>/dev/null || echo "⚠️ 失敗: $sgid"; done
else
    echo "ℹ️ タグ一致セキュリティグループなし"
fi

# 5. タグ付き VPC / サブネットの削除
echo -e "\n5. タグ付き VPC / サブネットの削除"
if [[ $DELETE_TAGGED_VPC == true || $DELETE_TAGGED_VPC == "true" ]]; then
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:$APP_TAG_KEY,Values=$APP_TAG_VALUE" --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo None)
    if [[ $VPC_ID != None ]]; then
        SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:$APP_TAG_KEY,Values=$APP_TAG_VALUE" --query 'Subnets[].SubnetId' --output text --region "$REGION" || true)
        for sn in $SUBNET_IDS; do
            echo "🗑️ Subnet 削除: $sn"; aws ec2 delete-subnet --subnet-id "$sn" --region "$REGION" 2>/dev/null || echo "⚠️ Subnet 削除失敗: $sn"; done
        echo "🗑️ VPC 削除: $VPC_ID"; aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || echo "⚠️ VPC 削除失敗 (依存リソース残存の可能性)"
        VPC_DELETED=$VPC_ID
    else
        echo "ℹ️ タグ一致 VPC なし"
    fi
else
    echo "⏭️ DELETE_TAGGED_VPC=false のため VPC/サブネット削除スキップ"
fi

echo -e "\n✅ テスト環境のクリーンアップが完了しました！"
echo ""
echo "📋 削除されたリソース:"
if [[ "$SKIP_DB_DELETE" == "false" ]]; then
    echo "  - RDSインスタンス: ${TEST_INSTANCES[*]:-(none)}"
else
    echo "  - RDSインスタンス: (削除スキップ)"
fi
echo "  - パラメーターグループ: ${TAGGED_PGS[*]:-(none)}"
echo "  - クラスタPG: ${TAGGED_CLUSTER_PGS[*]:-(none)}"
echo "  - DBサブネットグループ: ${TAGGED_SUBNET_GROUPS[*]:-(none)}"
echo "  - セキュリティグループ: ${SECURITY_GROUP_IDS:-none}"
if [[ ${VPC_DELETED:-} ]]; then
    echo "  - VPC: $VPC_DELETED (関連サブネット含む)"
else
    if [[ $DELETE_TAGGED_VPC == true || $DELETE_TAGGED_VPC == "true" ]]; then
        echo "  - VPC: (対象なし or 削除失敗)"
    else
        echo "  - VPC: (削除スキップ)"
    fi
fi
echo ""
echo "💡 任意: DELETE_TAGGED_VPC=false で VPC 保持可能"
echo ""
echo "🔍 削除が正常に完了したかどうかは、AWSコンソールで確認してください："
echo "   https://console.aws.amazon.com/rds/home?region=$REGION"
