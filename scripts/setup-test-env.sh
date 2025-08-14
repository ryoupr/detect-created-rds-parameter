#!/usr/bin/env bash

# RDS暗号化監査システム テスト環境セットアップ (ネットワーク自動生成 & Application タグ付与)
# 要件:
#  - デフォルトVPCが無ければ検証用VPC＋2サブネット作成
#  - 生成した全リソースに Application=<VALUE> タグ付与
#  - RDS(MySQL(暗号化無効→失敗時暗号化), Postgres(暗号化有効)) インスタンス作成
#  - クリーンアップでタグ一致のみ削除可能なように manifest を出力
set -euo pipefail
command -v aws >/dev/null 2>&1 || { echo "❌ aws CLI 未インストール"; exit 1; }

# -------- 設定 --------
REGION=${AWS_DEFAULT_REGION:-${REGION:-"ap-northeast-1"}}
APP_TAG_KEY=Application
APP_TAG_VALUE=${APPLICATION_TAG_VALUE:-detect-created-rds-parameter-test}
VPC_CIDR=${VPC_CIDR:-"10.42.0.0/16"}
SUBNET1_CIDR=${SUBNET1_CIDR:-"10.42.1.0/24"}
SUBNET2_CIDR=${SUBNET2_CIDR:-"10.42.2.0/24"}
MYSQL_INSTANCE_ID=${MYSQL_INSTANCE_ID:-"test-mysql-unencrypted"}
POSTGRES_INSTANCE_ID=${POSTGRES_INSTANCE_ID:-"test-postgres-encrypted"}
DB_SUBNET_GROUP_NAME=${DB_SUBNET_GROUP_NAME:-"test-db-subnet-group"}
SECURITY_GROUP_NAME=${SECURITY_GROUP_NAME:-"test-rds-sg"}
MYSQL_PG_NAME=${MYSQL_PG_NAME:-"test-mysql-params"}
POSTGRES_PG_NAME=${POSTGRES_PG_NAME:-"test-postgres-params"}
INSTANCE_CLASS=${INSTANCE_CLASS:-"db.t3.micro"}
MASTER_USERNAME=${MASTER_USERNAME:-"testuser"}
MASTER_PASSWORD=${MASTER_PASSWORD:-"TempPassword123!"}
MYSQL_ENGINE_VERSION=${MYSQL_ENGINE_VERSION:-""}
POSTGRES_ENGINE_VERSION=${POSTGRES_ENGINE_VERSION:-""}
SKIP_DB_CREATE=${SKIP_DB_CREATE:-"false"}
TAGS_COMMON="Key=$APP_TAG_KEY,Value=$APP_TAG_VALUE Key=created-by,Value=setup-test-env Key=test-purpose,Value=encryption-audit"
SHOW_STATUS=${SHOW_STATUS:-"true"}
WAIT_UNTIL_AVAILABLE=${WAIT_UNTIL_AVAILABLE:-"false"}
STATUS_POLL_INTERVAL=${STATUS_POLL_INTERVAL:-30}
[[ ${#MASTER_PASSWORD} -ge 8 ]] || { echo "❌ MASTER_PASSWORD が短すぎます"; exit 1; }

echo "🧪 セットアップ開始 REGION=$REGION TAG=$APP_TAG_KEY=$APP_TAG_VALUE"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo "👤 ACCOUNT=$ACCOUNT_ID"

# -------- 事前: 既存 DB Subnet Group 由来の VPC 再利用判定 --------
REUSED_VPC_FROM_SUBNET_GROUP=false
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --region "$REGION" &>/dev/null; then
    EXISTING_SUBNET_GROUP_VPC_ID=$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --region "$REGION" --query 'DBSubnetGroups[0].VpcId' --output text 2>/dev/null || echo "")
    if [[ -n $EXISTING_SUBNET_GROUP_VPC_ID && $EXISTING_SUBNET_GROUP_VPC_ID != None ]]; then
        VPC_ID=$EXISTING_SUBNET_GROUP_VPC_ID
        REUSED_VPC_FROM_SUBNET_GROUP=true
        echo "ℹ️ 既存 Subnet Group ($DB_SUBNET_GROUP_NAME) の VPC を優先再利用: $VPC_ID"
    fi
fi

# -------- VPC / Subnets --------
echo -e "\n1. VPC/サブネット"
CUSTOM_VPC_CREATED=false
if [[ ${REUSED_VPC_FROM_SUBNET_GROUP} == true ]]; then
    echo "🔁 Subnet Group 由来の VPC 再利用: $VPC_ID"
else
    DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo None)
    if [[ $DEFAULT_VPC == None || -z $DEFAULT_VPC ]]; then
        echo "🔧 デフォルトVPCなし → テスト用VPC作成"
        VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "ResourceType=vpc,Tags=[{Key=$APP_TAG_KEY,Value=$APP_TAG_VALUE},{Key=Name,Value=$APP_TAG_VALUE-vpc}]" --query 'Vpc.VpcId' --output text --region "$REGION")
        aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION" || true
        CUSTOM_VPC_CREATED=true
    else
        VPC_ID=$DEFAULT_VPC
        echo "✅ デフォルトVPC使用: $VPC_ID"
    fi
fi

# 既存タグ付きサブネットが2つ未満なら作成 (custom VPC のみ)
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text --region "$REGION")
read -r -a SUBNET_ARRAY <<< "$SUBNET_IDS"
if [[ $CUSTOM_VPC_CREATED == true ]]; then
    TAGGED_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:$APP_TAG_KEY,Values=$APP_TAG_VALUE" --query 'Subnets[].SubnetId' --output text --region "$REGION")
    read -r -a TAGGED_ARRAY <<< "$TAGGED_SUBNETS"
    if [[ ${#TAGGED_ARRAY[@]} -lt 2 ]]; then
        AZS=($(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[?State==`available`].ZoneName' --output text))
        S1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET1_CIDR" --availability-zone "${AZS[0]}" --tag-specifications "ResourceType=subnet,Tags=[{Key=$APP_TAG_KEY,Value=$APP_TAG_VALUE},{Key=Name,Value=$APP_TAG_VALUE-subnet-a}]" --query 'Subnet.SubnetId' --output text --region "$REGION")
        S2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET2_CIDR" --availability-zone "${AZS[1]}" --tag-specifications "ResourceType=subnet,Tags=[{Key=$APP_TAG_KEY,Value=$APP_TAG_VALUE},{Key=Name,Value=$APP_TAG_VALUE-subnet-b}]" --query 'Subnet.SubnetId' --output text --region "$REGION")
        SUBNET_ARRAY=($S1 $S2)
    else
        SUBNET_ARRAY=(${TAGGED_ARRAY[@]})
    fi
fi
echo "✅ Subnets: ${SUBNET_ARRAY[*]}"

# -------- DB Subnet Group --------
echo -e "\n2. DB Subnet Group"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --region "$REGION" &>/dev/null; then
    # 既存を利用 (VPC は事前ステップで揃えてある)
    echo "✅ 既存: $DB_SUBNET_GROUP_NAME"
else
    aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --db-subnet-group-description "Test Subnet Group" --subnet-ids ${SUBNET_ARRAY[0]} ${SUBNET_ARRAY[1]} --tags $TAGS_COMMON --region "$REGION"
    echo "✅ 作成: $DB_SUBNET_GROUP_NAME"
fi

# -------- Security Group --------
echo -e "\n3. Security Group"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo None)
if [[ $SG_ID == None ]]; then
    SG_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" --description "RDS Test SG" --vpc-id "$VPC_ID" --tag-specifications "ResourceType=security-group,Tags=[{Key=$APP_TAG_KEY,Value=$APP_TAG_VALUE},{Key=Name,Value=$SECURITY_GROUP_NAME}]" --query 'GroupId' --output text --region "$REGION")
    for p in 3306 5432; do aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port $p --cidr 10.0.0.0/8 --region "$REGION" 2>/dev/null || true; done
    echo "✅ 作成: $SG_ID"
else
    echo "✅ 既存: $SG_ID"
fi

# -------- Parameter Groups --------
echo -e "\n4. Parameter Groups"
if ! aws rds describe-db-parameter-groups --db-parameter-group-name "$MYSQL_PG_NAME" --region "$REGION" &>/dev/null; then
    aws rds create-db-parameter-group --db-parameter-group-name "$MYSQL_PG_NAME" --db-parameter-group-family mysql8.0 --description "Test MySQL PG" --tags $TAGS_COMMON --region "$REGION"
    aws rds modify-db-parameter-group --db-parameter-group-name "$MYSQL_PG_NAME" --parameters \
        "ParameterName=require_secure_transport,ParameterValue=OFF,ApplyMethod=immediate" \
        "ParameterName=general_log,ParameterValue=0,ApplyMethod=immediate" \
        "ParameterName=slow_query_log,ParameterValue=0,ApplyMethod=immediate" --region "$REGION" || true
    echo "✅ 作成: $MYSQL_PG_NAME"
else echo "✅ 既存: $MYSQL_PG_NAME"; fi

# --- PostgreSQL Engine Version / Family 判定 ---
if [[ -z $POSTGRES_ENGINE_VERSION ]]; then
    # デフォルトエンジン情報取得
    POSTGRES_ENGINE_VERSION=$(aws rds describe-db-engine-versions --engine postgres --default-only --region "$REGION" --query 'DBEngineVersions[0].EngineVersion' --output text)
    POSTGRES_PG_FAMILY=$(aws rds describe-db-engine-versions --engine postgres --default-only --region "$REGION" --query 'DBEngineVersions[0].DBParameterGroupFamily' --output text)
else
    POSTGRES_PG_FAMILY=$(aws rds describe-db-engine-versions --engine postgres --engine-version "$POSTGRES_ENGINE_VERSION" --region "$REGION" --query 'DBEngineVersions[0].DBParameterGroupFamily' --output text)
fi
echo "ℹ️ PostgreSQL EngineVersion=$POSTGRES_ENGINE_VERSION Family=$POSTGRES_PG_FAMILY"

# 既存 PG の family 不一致なら再作成 (インスタンス未作成前提)
if aws rds describe-db-parameter-groups --db-parameter-group-name "$POSTGRES_PG_NAME" --region "$REGION" &>/dev/null; then
    EXISTING_FAMILY=$(aws rds describe-db-parameter-groups --db-parameter-group-name "$POSTGRES_PG_NAME" --region "$REGION" --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text || echo unknown)
    if [[ "$EXISTING_FAMILY" != "$POSTGRES_PG_FAMILY" ]]; then
        echo "🔄 Family 不一致: existing=$EXISTING_FAMILY required=$POSTGRES_PG_FAMILY → 再作成"
        aws rds delete-db-parameter-group --db-parameter-group-name "$POSTGRES_PG_NAME" --region "$REGION" || true
        # 削除完了待機 (API の eventual consistency を軽減)
        sleep 3
    else
        PG_OK=true
    fi
fi

if ! aws rds describe-db-parameter-groups --db-parameter-group-name "$POSTGRES_PG_NAME" --region "$REGION" &>/dev/null; then
    aws rds create-db-parameter-group --db-parameter-group-name "$POSTGRES_PG_NAME" --db-parameter-group-family "$POSTGRES_PG_FAMILY" --description "Test Postgres PG" --tags $TAGS_COMMON --region "$REGION"
    # 変更できない param (ssl 等) はサイレント失敗許容
    aws rds modify-db-parameter-group --db-parameter-group-name "$POSTGRES_PG_NAME" --parameters \
        "ParameterName=log_statement,ParameterValue=none,ApplyMethod=immediate" \
        "ParameterName=log_connections,ParameterValue=off,ApplyMethod=immediate" --region "$REGION" || true
    echo "✅ 作成: $POSTGRES_PG_NAME ($POSTGRES_PG_FAMILY)"
else
    echo "✅ 既存: $POSTGRES_PG_NAME ($POSTGRES_PG_FAMILY)"
fi

# -------- RDS Instances --------
echo -e "\n5. RDS Instances"
if [[ $SKIP_DB_CREATE == false || $SKIP_DB_CREATE == "false" ]]; then
    # MySQL (unencrypted fallback)
    if ! aws rds describe-db-instances --db-instance-identifier "$MYSQL_INSTANCE_ID" --region "$REGION" &>/dev/null; then
        echo "🗄️ MySQL 作成 (unencrypted→fallback encrypted)"
        set +e
        BASE_ARGS=(--db-instance-identifier "$MYSQL_INSTANCE_ID" --db-instance-class "$INSTANCE_CLASS" --engine mysql --master-username "$MASTER_USERNAME" --master-user-password "$MASTER_PASSWORD" --allocated-storage 20 --storage-type gp2 --vpc-security-group-ids "$SG_ID" --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --db-parameter-group-name "$MYSQL_PG_NAME" --backup-retention-period 1 --no-multi-az --no-publicly-accessible --no-auto-minor-version-upgrade --no-deletion-protection --tags $TAGS_COMMON --region "$REGION")
        [[ -n $MYSQL_ENGINE_VERSION ]] && BASE_ARGS+=(--engine-version "$MYSQL_ENGINE_VERSION")
        if aws rds create-db-instance "${BASE_ARGS[@]}" --no-storage-encrypted 2>/dev/null; then
            echo "✅ MySQL unencrypted 作成開始"
        else
            echo "⚠️ unencrypted 失敗 → encrypted"
            aws rds create-db-instance "${BASE_ARGS[@]}" --storage-encrypted || { echo "❌ MySQL 作成失敗"; exit 1; }
        fi
        set -e
    else echo "✅ 既存 MySQL: $MYSQL_INSTANCE_ID"; fi

    # PostgreSQL (encrypted)
    if ! aws rds describe-db-instances --db-instance-identifier "$POSTGRES_INSTANCE_ID" --region "$REGION" &>/dev/null; then
        POST_ARGS=(--db-instance-identifier "$POSTGRES_INSTANCE_ID" --db-instance-class "$INSTANCE_CLASS" --engine postgres --master-username "$MASTER_USERNAME" --master-user-password "$MASTER_PASSWORD" --allocated-storage 20 --storage-type gp2 --storage-encrypted --vpc-security-group-ids "$SG_ID" --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --db-parameter-group-name "$POSTGRES_PG_NAME" --backup-retention-period 1 --no-multi-az --no-publicly-accessible --no-auto-minor-version-upgrade --no-deletion-protection --tags $TAGS_COMMON --region "$REGION")
        [[ -n $POSTGRES_ENGINE_VERSION ]] && POST_ARGS+=(--engine-version "$POSTGRES_ENGINE_VERSION")
        aws rds create-db-instance "${POST_ARGS[@]}" || { echo "❌ PostgreSQL 作成失敗"; exit 1; }
        echo "✅ PostgreSQL 作成開始"
    else echo "✅ 既存 PostgreSQL: $POSTGRES_INSTANCE_ID"; fi
else
    echo "⏭️ SKIP_DB_CREATE=true: RDS インスタンス作成スキップ"
fi

# -------- Status Functions --------
describe_instance() {
    local id="$1"
    aws rds describe-db-instances --db-instance-identifier "$id" --region "$REGION" --query 'DBInstances[0].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Enc:StorageEncrypted,Class:DBInstanceClass,Endpoint:Endpoint.Address,PG:DBParameterGroups[0].DBParameterGroupName}' --output json 2>/dev/null || true
}

print_status() {
    echo "\n🛰️ インスタンスステータス (timestamp=$(date -Iseconds))"
    for id in "$MYSQL_INSTANCE_ID" "$POSTGRES_INSTANCE_ID"; do
        if aws rds describe-db-instances --db-instance-identifier "$id" --region "$REGION" &>/dev/null; then
            local row
            row=$(aws rds describe-db-instances --db-instance-identifier "$id" --region "$REGION" --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Engine,StorageEncrypted,DBInstanceClass]' --output text 2>/dev/null || echo "-")
            printf "  %-25s %-15s %-10s enc=%-5s class=%s\n" $row
        else
            printf "  %-25s %-15s\n" "$id" "(not found)"
        fi
    done
}

if [[ $SHOW_STATUS == true || $SHOW_STATUS == "true" ]]; then
    print_status
fi

if [[ $WAIT_UNTIL_AVAILABLE == true || $WAIT_UNTIL_AVAILABLE == "true" ]]; then
    echo "⏳ available になるまで待機 (interval=${STATUS_POLL_INTERVAL}s)"
    for id in "$MYSQL_INSTANCE_ID" "$POSTGRES_INSTANCE_ID"; do
        if aws rds describe-db-instances --db-instance-identifier "$id" --region "$REGION" &>/dev/null; then
            while true; do
                status=$(aws rds describe-db-instances --db-instance-identifier "$id" --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo unknown)
                echo "  $id -> $status"
                [[ $status == available || $status == failed || $status == stopped ]] && break
                sleep "$STATUS_POLL_INTERVAL"
            done
        fi
    done
    echo "✅ 待機完了"
    print_status
fi

# -------- Manifest --------
MANIFEST="scripts/.test-env-manifest.env"
cat > "$MANIFEST" <<EOF
APP_TAG_KEY=$APP_TAG_KEY
APP_TAG_VALUE=$APP_TAG_VALUE
REGION=$REGION
VPC_ID=$VPC_ID
CUSTOM_VPC_CREATED=$CUSTOM_VPC_CREATED
SUBNET_IDS=${SUBNET_ARRAY[*]}
SECURITY_GROUP_ID=$SG_ID
DB_SUBNET_GROUP_NAME=$DB_SUBNET_GROUP_NAME
MYSQL_INSTANCE_ID=$MYSQL_INSTANCE_ID
POSTGRES_INSTANCE_ID=$POSTGRES_INSTANCE_ID
MYSQL_PG_NAME=$MYSQL_PG_NAME
POSTGRES_PG_NAME=$POSTGRES_PG_NAME
POSTGRES_ENGINE_VERSION=$POSTGRES_ENGINE_VERSION
POSTGRES_PG_FAMILY=$POSTGRES_PG_FAMILY
EOF

echo -e "\n✅ セットアップ完了 (DB 作成には数分〜)"
echo "📄 Manifest: $MANIFEST"
echo "🏷️ Tag: $APP_TAG_KEY=$APP_TAG_VALUE"
echo "🧹 後片付け: bash scripts/cleanup-test-env.sh (同タグのみ削除)"
