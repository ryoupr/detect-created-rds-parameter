#!/bin/bash

# RDS Parameter Group 監査システムのテストスクリプト

set -e

echo "🧪 RDS Parameter Group 監査システムのテストを開始します..."

STACK_NAME="DetectCreatedRdsParameterStack"

# スタックの存在確認
echo "📋 スタックの存在確認..."
if ! aws cloudformation describe-stacks --stack-name $STACK_NAME --region $(aws configure get region 2>/dev/null || echo "us-east-1") >/dev/null 2>&1; then
    echo "❌ スタック '$STACK_NAME' が見つかりません。先にデプロイを実行してください。"
    exit 1
fi

# スタック出力の取得
echo "📤 スタック出力の取得..."
OUTPUTS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs' --output json)
SNS_TOPIC_ARN=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey == "AlertTopicArn") | .OutputValue')
AUDIT_FUNCTION_NAME=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey == "AuditFunctionName") | .OutputValue')

echo "📧 SNS Topic ARN: $SNS_TOPIC_ARN"
echo "⚡ Audit Function Name: $AUDIT_FUNCTION_NAME"

# Lambda関数の手動実行テスト
echo ""
echo "🔍 スケジュール監査Lambda関数のテスト実行..."
SCHEDULED_FUNCTION_NAME=$(aws lambda list-functions --query "Functions[?contains(FunctionName, 'ScheduledRDSParameterAuditFunction')].FunctionName" --output text)

if [ -n "$SCHEDULED_FUNCTION_NAME" ]; then
    echo "⚡ 実行中: $SCHEDULED_FUNCTION_NAME"
    
    # テストイベントの作成
    TEST_EVENT='{
        "version": "0",
        "id": "test-event-id",
        "detail-type": "Scheduled Event",
        "source": "aws.events",
        "account": "123456789012",
        "time": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
        "region": "'$(aws configure get region 2>/dev/null || echo "us-east-1")'",
        "detail": {}
    }'
    
    # Lambda関数の実行
    aws lambda invoke \
        --function-name "$SCHEDULED_FUNCTION_NAME" \
        --payload "$TEST_EVENT" \
        --cli-binary-format raw-in-base64-out \
        test-response.json
    
    echo "📄 実行結果:"
    cat test-response.json | jq . 2>/dev/null || cat test-response.json
    echo ""
    
    # ログの確認
    echo "📋 最新のログを確認..."
    LOG_GROUP="/aws/lambda/$SCHEDULED_FUNCTION_NAME"
    
    # 最新のログストリームを取得
    LATEST_STREAM=$(aws logs describe-log-streams \
        --log-group-name "$LOG_GROUP" \
        --order-by LastEventTime \
        --descending \
        --max-items 1 \
        --query 'logStreams[0].logStreamName' \
        --output text)
    
    if [ "$LATEST_STREAM" != "None" ] && [ -n "$LATEST_STREAM" ]; then
        echo "📊 ログストリーム: $LATEST_STREAM"
        aws logs get-log-events \
            --log-group-name "$LOG_GROUP" \
            --log-stream-name "$LATEST_STREAM" \
            --start-time $(($(date +%s) * 1000 - 300000)) \
            --query 'events[].message' \
            --output text
    else
        echo "⚠️  ログストリームが見つかりませんでした。"
    fi
    
    # クリーンアップ
    rm -f test-response.json
    
else
    echo "❌ スケジュール監査Lambda関数が見つかりませんでした。"
fi

echo ""
echo "🔗 次のステップ:"
echo "1. MySQL用パラメーターグループを作成:"
echo "   aws rds create-db-parameter-group --db-parameter-group-name test-mysql-params --db-parameter-group-family mysql8.0 --description 'Test MySQL parameter group'"
echo ""
echo "2. MySQL暗号化無効パラメーターを設定:"
echo "   aws rds modify-db-parameter-group --db-parameter-group-name test-mysql-params --parameters 'ParameterName=innodb_encrypt_tables,ParameterValue=OFF,ApplyMethod=immediate'"
echo ""
echo "3. SQL Server用パラメーターグループを作成:"
echo "   aws rds create-db-parameter-group --db-parameter-group-name test-sqlserver-params --db-parameter-group-family sqlserver-se-15.0 --description 'Test SQL Server parameter group'"
echo ""
echo "4. SQL Server危険設定パラメーターを設定:"
echo "   aws rds modify-db-parameter-group --db-parameter-group-name test-sqlserver-params --parameters 'ParameterName=contained database authentication,ParameterValue=1,ApplyMethod=immediate'"
echo ""
echo "5. RDSインスタンスを作成 (MySQL例):"
echo "   aws rds create-db-instance --db-instance-identifier test-mysql-instance --db-instance-class db.t3.micro --engine mysql --master-username admin --master-user-password password123 --db-parameter-group-name test-mysql-params --allocated-storage 20"
echo ""
echo "6. RDSインスタンスを作成 (SQL Server例):"
echo "   aws rds create-db-instance --db-instance-identifier test-sqlserver-instance --db-instance-class db.t3.small --engine sqlserver-se --master-username admin --master-user-password password123 --db-parameter-group-name test-sqlserver-params --allocated-storage 20 --license-model license-included"
echo ""
echo "7. CloudWatchログで監査結果を確認"
echo ""
echo "✅ テスト完了！"
