#!/bin/bash

# RDS テスト環境セットアップスクリプト
set -e

echo "🔧 RDS テスト環境のセットアップ開始"

REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
    REGION="ap-northeast-1"
    echo "⚠️ AWS リージョンが設定されていません。デフォルトで ${REGION} を使用します"
fi

echo "🌍 使用するリージョン: $REGION"

# 1. VPCとサブネットの確認・作成
echo -e "\n1. VPC設定の確認"


# 既存のタグ付きVPCを優先利用
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:created-by,Values=setup-test-env" --query 'Vpcs[0].VpcId' --output text --region $REGION)
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
    # デフォルトVPCを利用
    DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $REGION)
    if [ "$DEFAULT_VPC" = "None" ] || [ -z "$DEFAULT_VPC" ]; then
        echo "❌ デフォルトVPCも見つかりません。VPCを作成します。"
        VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text --region $REGION)
        aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=test-rds-vpc Key=created-by,Value=setup-test-env --region $REGION
        echo "✅ VPC作成: $VPC_ID (タグ付き)"
    else
        VPC_ID=$DEFAULT_VPC
        echo "✅ デフォルトVPCを利用: $VPC_ID"
    fi
else
    echo "✅ タグ付きVPCを利用: $VPC_ID"
fi

# 既存のタグ付きサブネットを優先利用
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:created-by,Values=setup-test-env" --query 'Subnets[].SubnetId' --output text --region $REGION)
if [ -z "$SUBNETS" ]; then
    # VPC内のサブネットがなければ新規作成
    echo "❌ タグ付きサブネットが見つかりません。サブネットを作成します。"
    AZ1=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text --region $REGION)
    AZ2=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text --region $REGION)
    SUBNET1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone $AZ1 --query 'Subnet.SubnetId' --output text --region $REGION)
    SUBNET2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone $AZ2 --query 'Subnet.SubnetId' --output text --region $REGION)
    aws ec2 create-tags --resources $SUBNET1_ID --tags Key=Name,Value=test-rds-subnet-1 Key=created-by,Value=setup-test-env --region $REGION
    aws ec2 create-tags --resources $SUBNET2_ID --tags Key=Name,Value=test-rds-subnet-2 Key=created-by,Value=setup-test-env --region $REGION
    echo "✅ サブネット作成: $SUBNET1_ID, $SUBNET2_ID (タグ付き)"
    SUBNETS="$SUBNET1_ID $SUBNET2_ID"
else
    echo "✅ タグ付きサブネットを利用: $SUBNETS"
fi

# 2. DBサブネットグループの作成
echo -e "\n2. DBサブネットグループの作成"

# サブネットIDを配列に変換
SUBNET_ARRAY=($SUBNETS)
if [ ${#SUBNET_ARRAY[@]} -lt 2 ]; then
    echo "❌ 最低2つのサブネットが必要です。現在: ${#SUBNET_ARRAY[@]}個"
    exit 1
fi


# タグ付きDBサブネットグループを再利用、なければ作成
DB_SUBNET_GROUP_NAME=""
EXISTING_SUBNET_GROUPS=$(aws rds describe-db-subnet-groups --region $REGION --query 'DBSubnetGroups[].DBSubnetGroupName' --output text)
for GROUP in $EXISTING_SUBNET_GROUPS; do
    TAGS=$(aws rds list-tags-for-resource --resource-name arn:aws:rds:$REGION:$(aws sts get-caller-identity --query 'Account' --output text):subgrp:$GROUP --region $REGION --query 'TagList' --output json)
    if echo "$TAGS" | grep -q '"Key": *"created-by"' && echo "$TAGS" | grep -q '"Value": *"setup-test-env"'; then
        DB_SUBNET_GROUP_NAME="$GROUP"
        echo "✅ タグ付きDBサブネットグループを利用: $DB_SUBNET_GROUP_NAME"
        break
    fi
done

if [ -z "$DB_SUBNET_GROUP_NAME" ]; then
    DB_SUBNET_GROUP_NAME="test-db-subnet-group"
    echo "📦 DBサブネットグループを作成: $DB_SUBNET_GROUP_NAME"
    aws rds create-db-subnet-group \
        --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
        --db-subnet-group-description "Test DB subnet group for RDS encryption monitoring" \
        --subnet-ids ${SUBNET_ARRAY[0]} ${SUBNET_ARRAY[1]} \
        --tags Key=Name,Value=$DB_SUBNET_GROUP_NAME Key=created-by,Value=setup-test-env \
        --region $REGION
    echo "✅ DBサブネットグループ作成完了"
    echo "🏷️ DBサブネットグループにタグを付与"
fi

# 3. セキュリティグループの作成
echo -e "\n3. セキュリティグループの作成"

SECURITY_GROUP_NAME="test-rds-sg"

# 既存のセキュリティグループを確認
EXISTING_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)

if [ "$EXISTING_SG" = "None" ] || [ -z "$EXISTING_SG" ]; then
    echo "📡 セキュリティグループを作成: $SECURITY_GROUP_NAME"
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP_NAME \
        --description "Test security group for RDS instances" \
        --vpc-id $VPC_ID \
        --query 'GroupId' \
        --output text \
        --region $REGION)
    
    # セキュリティグループにタグを付与
    aws ec2 create-tags --resources $SECURITY_GROUP_ID --tags Key=Name,Value=$SECURITY_GROUP_NAME Key=created-by,Value=setup-test-env --region $REGION
    
    # MySQLポート (3306) を開放
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 3306 \
        --cidr 10.0.0.0/16 \
        --region $REGION
    
    # SQL Serverポート (1433) を開放
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 1433 \
        --cidr 10.0.0.0/16 \
        --region $REGION
    
    echo "✅ セキュリティグループ作成完了: $SECURITY_GROUP_ID"
    echo "🏷️ セキュリティグループにタグを付与"
else
    echo "✅ 既存のセキュリティグループを使用: $EXISTING_SG"
    SECURITY_GROUP_ID=$EXISTING_SG
fi

# 4. パラメーターグループの作成（修正版）
echo -e "\n4. パラメーターグループの作成"


# タグ付きMySQLパラメーターグループを再利用、なければ作成
MYSQL_PARAMETER_GROUP_NAME=""
EXISTING_MYSQL_PGS=$(aws rds describe-db-parameter-groups --region $REGION --query 'DBParameterGroups[?DBParameterGroupFamily==`mysql8.0`].[DBParameterGroupName]' --output text)
for PG in $EXISTING_MYSQL_PGS; do
    TAGS=$(aws rds list-tags-for-resource --resource-name arn:aws:rds:$REGION:$(aws sts get-caller-identity --query 'Account' --output text):pg:$PG --region $REGION --query 'TagList' --output json)
    if echo "$TAGS" | grep -q '"Key": *"created-by"' && echo "$TAGS" | grep -q '"Value": *"setup-test-env"'; then
        MYSQL_PARAMETER_GROUP_NAME="$PG"
        echo "✅ タグ付きMySQLパラメーターグループを利用: $MYSQL_PARAMETER_GROUP_NAME"
        break
    fi
done

if [ -z "$MYSQL_PARAMETER_GROUP_NAME" ]; then
    MYSQL_PARAMETER_GROUP_NAME="test-mysql-params"
    echo "📋 MySQLパラメーターグループを作成: $MYSQL_PARAMETER_GROUP_NAME"
    aws rds create-db-parameter-group \
        --db-parameter-group-name $MYSQL_PARAMETER_GROUP_NAME \
        --db-parameter-group-family mysql8.0 \
        --description 'Test MySQL parameter group' \
        --tags Key=Name,Value=$MYSQL_PARAMETER_GROUP_NAME Key=created-by,Value=setup-test-env \
        --region $REGION
fi

# 実際に利用可能なパラメーターを設定
echo "⚙️ MySQLパラメーターを設定"
aws rds modify-db-parameter-group \
    --db-parameter-group-name $MYSQL_PARAMETER_GROUP_NAME \
    --parameters 'ParameterName=general_log,ParameterValue=0,ApplyMethod=immediate' \
    --region $REGION

aws rds modify-db-parameter-group \
    --db-parameter-group-name $MYSQL_PARAMETER_GROUP_NAME \
    --parameters 'ParameterName=slow_query_log,ParameterValue=0,ApplyMethod=immediate' \
    --region $REGION

echo "✅ MySQLパラメーターグループ設定完了"
echo "🏷️ MySQLパラメーターグループにタグを付与"


# タグ付きSQL Serverパラメーターグループを再利用、なければ作成
SQLSERVER_PARAMETER_GROUP_NAME=""
EXISTING_SQLSERVER_PGS=$(aws rds describe-db-parameter-groups --region $REGION --query 'DBParameterGroups[?DBParameterGroupFamily==`sqlserver-se-15.0`].[DBParameterGroupName]' --output text)
for PG in $EXISTING_SQLSERVER_PGS; do
    TAGS=$(aws rds list-tags-for-resource --resource-name arn:aws:rds:$REGION:$(aws sts get-caller-identity --query 'Account' --output text):pg:$PG --region $REGION --query 'TagList' --output json)
    if echo "$TAGS" | grep -q '"Key": *"created-by"' && echo "$TAGS" | grep -q '"Value": *"setup-test-env"'; then
        SQLSERVER_PARAMETER_GROUP_NAME="$PG"
        echo "✅ タグ付きSQL Serverパラメーターグループを利用: $SQLSERVER_PARAMETER_GROUP_NAME"
        break
    fi
done

if [ -z "$SQLSERVER_PARAMETER_GROUP_NAME" ]; then
    SQLSERVER_PARAMETER_GROUP_NAME="test-sqlserver-params"
    echo "📋 SQL Serverパラメーターグループを作成: $SQLSERVER_PARAMETER_GROUP_NAME"
    aws rds create-db-parameter-group \
        --db-parameter-group-name $SQLSERVER_PARAMETER_GROUP_NAME \
        --db-parameter-group-family sqlserver-se-15.0 \
        --description 'Test SQL Server parameter group' \
        --tags Key=Name,Value=$SQLSERVER_PARAMETER_GROUP_NAME Key=created-by,Value=setup-test-env \
        --region $REGION
fi

echo "⚙️ SQL Serverパラメーターを設定"
aws rds modify-db-parameter-group \
    --db-parameter-group-name $SQLSERVER_PARAMETER_GROUP_NAME \
    --parameters 'ParameterName=contained database authentication,ParameterValue=1,ApplyMethod=immediate' \
    --region $REGION

echo "✅ SQL Serverパラメーターグループ設定完了"
echo "🏷️ SQL Serverパラメーターグループにタグを付与"


# 5. RDSインスタンスの自動作成
echo -e "\n5. RDSインスタンスの自動作成"

# 暗号化無効のMySQLインスタンス
if aws rds describe-db-instances --db-instance-identifier test-mysql-unencrypted --region $REGION > /dev/null 2>&1; then
    echo "🟡 test-mysql-unencrypted は既に存在します。スキップ"
else
    echo "🔴 暗号化無効のMySQLインスタンスを作成"
    aws rds create-db-instance \
      --db-instance-identifier test-mysql-unencrypted \
      --db-instance-class db.t3.micro \
      --engine mysql \
      --master-username admin \
      --master-user-password TestPassword123 \
      --db-parameter-group-name $MYSQL_PARAMETER_GROUP_NAME \
      --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
      --vpc-security-group-ids $SECURITY_GROUP_ID \
      --allocated-storage 20 \
      --no-storage-encrypted \
      --tags Key=Name,Value=test-mysql-unencrypted Key=created-by,Value=setup-test-env \
      --region $REGION
fi

# 暗号化有効のMySQLインスタンス
if aws rds describe-db-instances --db-instance-identifier test-mysql-encrypted --region $REGION > /dev/null 2>&1; then
    echo "🟡 test-mysql-encrypted は既に存在します。スキップ"
else
    echo "🟢 暗号化有効のMySQLインスタンスを作成"
    aws rds create-db-instance \
      --db-instance-identifier test-mysql-encrypted \
      --db-instance-class db.t3.micro \
      --engine mysql \
      --master-username admin \
      --master-user-password TestPassword123 \
      --db-parameter-group-name $MYSQL_PARAMETER_GROUP_NAME \
      --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
      --vpc-security-group-ids $SECURITY_GROUP_ID \
      --allocated-storage 20 \
      --storage-encrypted \
      --tags Key=Name,Value=test-mysql-encrypted Key=created-by,Value=setup-test-env \
      --region $REGION
fi

# 問題のあるSQL Serverインスタンス
if aws rds describe-db-instances --db-instance-identifier test-sqlserver-insecure --region $REGION > /dev/null 2>&1; then
    echo "🟡 test-sqlserver-insecure は既に存在します。スキップ"
else
    echo "🔴 問題のあるSQL Serverインスタンスを作成"
    aws rds create-db-instance \
      --db-instance-identifier test-sqlserver-insecure \
      --db-instance-class db.m5.large \
      --engine sqlserver-se \
      --master-username admin \
      --master-user-password TestPassword123 \
      --db-parameter-group-name $SQLSERVER_PARAMETER_GROUP_NAME \
      --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
      --vpc-security-group-ids $SECURITY_GROUP_ID \
      --allocated-storage 20 \
      --no-storage-encrypted \
      --license-model license-included \
      --tags Key=Name,Value=test-sqlserver-insecure Key=created-by,Value=setup-test-env \
      --region $REGION
fi

