#!/bin/bash

# RDS暗号化監査システム テスト環境セットアップスクリプト
set -e

echo "🧪 RDSテスト環境のセットアップを開始します"

REGION=${AWS_DEFAULT_REGION:-"ap-northeast-1"}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🌍 リージョン: $REGION"
echo "👤 アカウント: $ACCOUNT_ID"

# VPCの作成または既存VPCの使用
echo -e "\n1. ネットワーク環境の確認"
DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query "Vpcs[0].VpcId" --output text --region $REGION)

if [ "$DEFAULT_VPC" = "None" ] || [ -z "$DEFAULT_VPC" ]; then
    echo "❌ デフォルトVPCが見つかりません。手動でVPCとサブネットを作成してください。"
    exit 1
else
    echo "✅ デフォルトVPCを使用: $DEFAULT_VPC"
fi

# サブネットの取得
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC" --query "Subnets[?AvailabilityZone!=null].SubnetId" --output text --region $REGION)
SUBNET_ARRAY=($SUBNETS)

if [ ${#SUBNET_ARRAY[@]} -lt 2 ]; then
    echo "❌ 最低2つのサブネットが必要です（現在: ${#SUBNET_ARRAY[@]}個）"
    exit 1
fi

echo "✅ 使用可能なサブネット数: ${#SUBNET_ARRAY[@]}個"

# DBサブネットグループの作成
echo -e "\n2. DBサブネットグループの作成"
DB_SUBNET_GROUP_NAME="test-db-subnet-group"

if aws rds describe-db-subnet-groups --db-subnet-group-name $DB_SUBNET_GROUP_NAME --region $REGION &>/dev/null; then
    echo "✅ DBサブネットグループ既存: $DB_SUBNET_GROUP_NAME"
else
    echo "📡 DBサブネットグループを作成中: $DB_SUBNET_GROUP_NAME"
    aws rds create-db-subnet-group \
        --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
        --db-subnet-group-description "RDS暗号化監査テスト用サブネットグループ" \
        --subnet-ids ${SUBNET_ARRAY[0]} ${SUBNET_ARRAY[1]} \
        --tags Key=created-by,Value=setup-test-env \
        --region $REGION
    echo "✅ DBサブネットグループ作成完了"
fi

# セキュリティグループの作成
echo -e "\n3. セキュリティグループの作成"
SECURITY_GROUP_NAME="test-rds-sg"

# 既存のセキュリティグループを確認
EXISTING_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$DEFAULT_VPC" --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>/dev/null)

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
    echo "✅ セキュリティグループ既存: $EXISTING_SG"
    SECURITY_GROUP_ID=$EXISTING_SG
else
    echo "🔒 セキュリティグループを作成中: $SECURITY_GROUP_NAME"
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP_NAME \
        --description "RDS暗号化監査テスト用セキュリティグループ" \
        --vpc-id $DEFAULT_VPC \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=created-by,Value=setup-test-env},{Key=Name,Value=$SECURITY_GROUP_NAME}]" \
        --query 'GroupId' \
        --output text \
        --region $REGION)
    
    # MySQL/PostgreSQLアクセスルールを追加
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 3306 \
        --cidr 10.0.0.0/8 \
        --region $REGION
        
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 5432 \
        --cidr 10.0.0.0/8 \
        --region $REGION
    
    echo "✅ セキュリティグループ作成完了: $SECURITY_GROUP_ID"
fi

# パラメーターグループの作成
echo -e "\n4. パラメーターグループの作成"

# MySQLパラメーターグループ
MYSQL_PG_NAME="test-mysql-params"
if aws rds describe-db-parameter-groups --db-parameter-group-name $MYSQL_PG_NAME --region $REGION &>/dev/null; then
    echo "✅ MySQLパラメーターグループ既存: $MYSQL_PG_NAME"
else
    echo "⚙️ MySQLパラメーターグループを作成中: $MYSQL_PG_NAME"
    aws rds create-db-parameter-group \
        --db-parameter-group-name $MYSQL_PG_NAME \
        --db-parameter-group-family mysql8.0 \
        --description "RDS暗号化監査テスト用MySQLパラメーターグループ" \
        --tags Key=created-by,Value=setup-test-env \
        --region $REGION
        
    # セキュリティに関するパラメーターを設定（意図的に非推奨設定）
    aws rds modify-db-parameter-group \
        --db-parameter-group-name $MYSQL_PG_NAME \
        --parameters "ParameterName=require_secure_transport,ParameterValue=OFF,ApplyMethod=immediate" \
        --parameters "ParameterName=general_log,ParameterValue=0,ApplyMethod=immediate" \
        --parameters "ParameterName=slow_query_log,ParameterValue=0,ApplyMethod=immediate" \
        --region $REGION
    
    echo "✅ MySQLパラメーターグループ作成完了"
fi

# PostgreSQLパラメーターグループ
POSTGRES_PG_NAME="test-postgres-params"
if aws rds describe-db-parameter-groups --db-parameter-group-name $POSTGRES_PG_NAME --region $REGION &>/dev/null; then
    echo "✅ PostgreSQLパラメーターグループ既存: $POSTGRES_PG_NAME"
else
    echo "⚙️ PostgreSQLパラメーターグループを作成中: $POSTGRES_PG_NAME"
    aws rds create-db-parameter-group \
        --db-parameter-group-name $POSTGRES_PG_NAME \
        --db-parameter-group-family postgres15 \
        --description "RDS暗号化監査テスト用PostgreSQLパラメーターグループ" \
        --tags Key=created-by,Value=setup-test-env \
        --region $REGION
        
    # セキュリティに関するパラメーターを設定（意図的に非推奨設定）
    aws rds modify-db-parameter-group \
        --db-parameter-group-name $POSTGRES_PG_NAME \
        --parameters "ParameterName=ssl,ParameterValue=off,ApplyMethod=pending-reboot" \
        --parameters "ParameterName=log_statement,ParameterValue=none,ApplyMethod=immediate" \
        --parameters "ParameterName=log_connections,ParameterValue=off,ApplyMethod=immediate" \
        --region $REGION
    
    echo "✅ PostgreSQLパラメーターグループ作成完了"
fi

# テスト用RDSインスタンスの作成
echo -e "\n5. テスト用RDSインスタンスの作成"

# 暗号化無効のMySQLインスタンス
MYSQL_INSTANCE_ID="test-mysql-unencrypted"
if aws rds describe-db-instances --db-instance-identifier $MYSQL_INSTANCE_ID --region $REGION &>/dev/null; then
    echo "✅ MySQLテストインスタンス既存: $MYSQL_INSTANCE_ID"
else
    echo "🗄️ 暗号化無効のMySQLインスタンスを作成中: $MYSQL_INSTANCE_ID"
    aws rds create-db-instance \
        --db-instance-identifier $MYSQL_INSTANCE_ID \
        --db-instance-class db.t3.micro \
        --engine mysql \
        --engine-version 8.0.35 \
        --master-username testuser \
        --master-user-password 'TempPassword123!' \
        --allocated-storage 20 \
        --storage-type gp2 \
        --no-storage-encrypted \
        --vpc-security-group-ids $SECURITY_GROUP_ID \
        --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
        --db-parameter-group-name $MYSQL_PG_NAME \
        --backup-retention-period 1 \
        --no-multi-az \
        --no-publicly-accessible \
        --no-auto-minor-version-upgrade \
        --no-deletion-protection \
        --tags Key=created-by,Value=setup-test-env Key=test-purpose,Value=encryption-audit \
        --region $REGION
    
    echo "✅ MySQLテストインスタンス作成開始"
fi

# 暗号化有効のPostgreSQLインスタンス（比較用）
POSTGRES_INSTANCE_ID="test-postgres-encrypted"
if aws rds describe-db-instances --db-instance-identifier $POSTGRES_INSTANCE_ID --region $REGION &>/dev/null; then
    echo "✅ PostgreSQLテストインスタンス既存: $POSTGRES_INSTANCE_ID"
else
    echo "🗄️ 暗号化有効のPostgreSQLインスタンスを作成中: $POSTGRES_INSTANCE_ID"
    aws rds create-db-instance \
        --db-instance-identifier $POSTGRES_INSTANCE_ID \
        --db-instance-class db.t3.micro \
        --engine postgres \
        --engine-version 15.4 \
        --master-username testuser \
        --master-user-password 'TempPassword123!' \
        --allocated-storage 20 \
        --storage-type gp2 \
        --storage-encrypted \
        --vpc-security-group-ids $SECURITY_GROUP_ID \
        --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
        --db-parameter-group-name $POSTGRES_PG_NAME \
        --backup-retention-period 1 \
        --no-multi-az \
        --no-publicly-accessible \
        --no-auto-minor-version-upgrade \
        --no-deletion-protection \
        --tags Key=created-by,Value=setup-test-env Key=test-purpose,Value=encryption-audit \
        --region $REGION
    
    echo "✅ PostgreSQLテストインスタンス作成開始"
fi

echo -e "\n✅ テスト環境のセットアップが完了しました！"
echo ""
echo "📋 作成されたリソース:"
echo "  - DBサブネットグループ: $DB_SUBNET_GROUP_NAME"
echo "  - セキュリティグループ: $SECURITY_GROUP_ID"
echo "  - MySQLパラメーターグループ: $MYSQL_PG_NAME (セキュリティ設定無効)"
echo "  - PostgreSQLパラメーターグループ: $POSTGRES_PG_NAME (セキュリティ設定無効)"
echo "  - MySQLテストインスタンス: $MYSQL_INSTANCE_ID (暗号化無効)"
echo "  - PostgreSQLテストインスタンス: $POSTGRES_INSTANCE_ID (暗号化有効)"
echo ""
echo "⏳ RDSインスタンスの作成には10-15分程度かかります"
echo "   作成状況はAWSコンソールで確認できます:"
echo "   https://console.aws.amazon.com/rds/home?region=$REGION"
echo ""
echo "🧹 テスト環境の削除方法:"
echo "   ./scripts/cleanup-test-env.sh を実行してください"
echo ""
echo "⚠️ 注意: これらのリソースは課金対象です。テスト完了後は必ず削除してください。"
