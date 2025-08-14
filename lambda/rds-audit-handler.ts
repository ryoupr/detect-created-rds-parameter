import { Handler, Context } from 'aws-lambda';
import { RDSClient, DescribeDBInstancesCommand, DescribeDBParametersCommand } from '@aws-sdk/client-rds';
import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';

// イベントの型定義
interface ConfigRuleComplianceChangeEvent {
  version: string;
  id: string;
  'detail-type': 'Config Rules Compliance Change';
  source: 'aws.config';
  account: string;
  time: string;
  region: string;
  detail: {
    resourceId: string;
    resourceType: string;
    configRuleName: string;
    newEvaluationResult: {
      evaluationResultIdentifier: {
        evaluationResultQualifier: {
          configRuleName: string;
          resourceType: string;
          resourceId: string;
        };
        orderingTimestamp: string;
      };
      complianceType: 'COMPLIANT' | 'NON_COMPLIANT' | 'NOT_APPLICABLE';
      resultRecordedTime: string;
      configRuleInvokeTime: string;
    };
  };
}

// 環境変数
const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN!;
const LOG_LEVEL = process.env.LOG_LEVEL || 'INFO';

// クライアントの初期化
const rdsClient = new RDSClient({});
const snsClient = new SNSClient({});

// ログ機能
const log = {
  info: (message: string, data?: any) => {
    if (LOG_LEVEL === 'INFO' || LOG_LEVEL === 'DEBUG') {
      console.log(`[INFO] ${message}`, data ? JSON.stringify(data, null, 2) : '');
    }
  },
  debug: (message: string, data?: any) => {
    if (LOG_LEVEL === 'DEBUG') {
      console.log(`[DEBUG] ${message}`, data ? JSON.stringify(data, null, 2) : '');
    }
  },
  error: (message: string, error?: any) => {
    console.error(`[ERROR] ${message}`, error);
  },
};

// パラメーターグループのセキュリティチェック
const PARAMETER_SECURITY_RULES = {
  mysql: {
    require_secure_transport: (value: string) => 
      value === 'OFF' ? 'SSL/TLS通信が強制されていません (require_secure_transport=OFF)' : null,
    general_log: (value: string) => 
      value === '0' ? '一般ログが無効化されています (general_log=0)' : null,
    slow_query_log: (value: string) => 
      value === '0' ? 'スロークエリログが無効化されています (slow_query_log=0)' : null,
    log_bin_trust_function_creators: (value: string) => 
      value === '1' ? 'バイナリログの関数作成者制限が無効化されています (log_bin_trust_function_creators=1)' : null,
  },
  postgres: {
    ssl: (value: string) => 
      value === 'off' ? 'SSLが無効化されています (ssl=off)' : null,
    log_statement: (value: string) => 
      value === 'none' ? 'SQL文のログが無効化されています (log_statement=none)' : null,
    log_connections: (value: string) => 
      value === 'off' ? '接続ログが無効化されています (log_connections=off)' : null,
    log_disconnections: (value: string) => 
      value === 'off' ? '切断ログが無効化されています (log_disconnections=off)' : null,
  },
  'aurora-mysql': {
    require_secure_transport: (value: string) => 
      value === 'OFF' ? 'SSL/TLS通信が強制されていません (require_secure_transport=OFF)' : null,
    general_log: (value: string) => 
      value === '0' ? '一般ログが無効化されています (general_log=0)' : null,
    slow_query_log: (value: string) => 
      value === '0' ? 'スロークエリログが無効化されています (slow_query_log=0)' : null,
  },
  'aurora-postgresql': {
    ssl: (value: string) => 
      value === 'off' ? 'SSLが無効化されています (ssl=off)' : null,
    log_statement: (value: string) => 
      value === 'none' ? 'SQL文のログが無効化されています (log_statement=none)' : null,
    log_connections: (value: string) => 
      value === 'off' ? '接続ログが無効化されています (log_connections=off)' : null,
  },
};

// RDSインスタンスの詳細チェック
async function checkRdsInstanceDetails(resourceId: string): Promise<string[]> {
  const issues: string[] = [];
  
  try {
    log.info(`RDSインスタンスの詳細を取得中: ${resourceId}`);
    
    const response = await rdsClient.send(
      new DescribeDBInstancesCommand({
        DBInstanceIdentifier: resourceId,
      })
    );

    const instance = response.DBInstances?.[0];
    if (!instance) {
      throw new Error(`インスタンス ${resourceId} が見つかりません`);
    }

    log.debug('RDSインスタンス詳細', {
      instanceId: instance.DBInstanceIdentifier,
      engine: instance.Engine,
      encrypted: instance.StorageEncrypted,
      kmsKeyId: instance.KmsKeyId,
      deletionProtection: instance.DeletionProtection,
    });

    // ストレージ暗号化チェック
    if (!instance.StorageEncrypted) {
      issues.push('❌ ストレージ暗号化が無効化されています');
    } else {
      issues.push('✅ ストレージ暗号化が有効化されています');
      
      // KMSキーチェック
      if (!instance.KmsKeyId || instance.KmsKeyId.includes('alias/aws/rds')) {
        issues.push('⚠️ デフォルトのAWS管理キーを使用しています（お客様管理キーの使用を推奨）');
      } else {
        issues.push('✅ お客様管理のKMSキーを使用しています');
      }
    }

    // 削除保護チェック
    if (!instance.DeletionProtection) {
      issues.push('⚠️ 削除保護が無効化されています');
    } else {
      issues.push('✅ 削除保護が有効化されています');
    }

    // パラメーターグループのチェック
    if (instance.DBParameterGroups && instance.Engine) {
      for (const pgInfo of instance.DBParameterGroups) {
        if (pgInfo.DBParameterGroupName) {
          const pgIssues = await checkParameterGroup(pgInfo.DBParameterGroupName, instance.Engine);
          issues.push(...pgIssues);
        }
      }
    }

  } catch (error: any) {
    log.error(`RDSインスタンス詳細の取得エラー: ${resourceId}`, error);
    issues.push(`❌ インスタンス詳細の取得に失敗しました: ${error?.message || 'Unknown error'}`);
  }

  return issues;
}

// パラメーターグループのセキュリティチェック
async function checkParameterGroup(parameterGroupName: string, engine: string): Promise<string[]> {
  const issues: string[] = [];
  
  try {
    log.info(`パラメーターグループをチェック中: ${parameterGroupName} (${engine})`);
    
    const engineType = engine.toLowerCase();
    const rules = PARAMETER_SECURITY_RULES[engineType as keyof typeof PARAMETER_SECURITY_RULES];
    
    if (!rules) {
      log.info(`エンジン ${engine} の監査ルールが定義されていません`);
      return issues;
    }

    // パラメーターを取得（ユーザー設定値のみ）
    const response = await rdsClient.send(
      new DescribeDBParametersCommand({
        DBParameterGroupName: parameterGroupName,
        Source: 'user',
        MaxRecords: 100,
      })
    );

    const parameters = response.Parameters || [];
    log.debug(`取得したパラメーター数: ${parameters.length}`);

    // 各ルールを適用
    for (const [paramName, checkFunction] of Object.entries(rules)) {
      const param = parameters.find((p: any) => p.ParameterName === paramName);
      const paramValue = param?.ParameterValue || 'default';
      
      const issue = checkFunction(paramValue);
      if (issue) {
        issues.push(`⚠️ ${parameterGroupName}: ${issue}`);
      } else {
        issues.push(`✅ ${parameterGroupName}: ${paramName} = ${paramValue} (OK)`);
      }
    }

  } catch (error: any) {
    log.error(`パラメーターグループのチェックエラー: ${parameterGroupName}`, error);
    issues.push(`❌ パラメーターグループ ${parameterGroupName} のチェックに失敗しました: ${error?.message || 'Unknown error'}`);
  }

  return issues;
}

// SNS通知の送信
async function sendNotification(resourceId: string, configRuleName: string, issues: string[]): Promise<void> {
  const timestamp = new Date().toISOString();
  const region = process.env.AWS_REGION || 'ap-northeast-1';
  
  const subject = `🔐 RDS暗号化監査アラート - ${resourceId}`;
  
  const message = `
RDS暗号化設定の監査で問題が検出されました

📋 詳細情報:
  リソース: ${resourceId}
  ルール: ${configRuleName}
  タイムスタンプ: ${timestamp}
  リージョン: ${region}

🔍 検出された問題:
${issues.map(issue => `  ${issue}`).join('\n')}

🔗 対応方法:
1. AWSコンソールでRDSインスタンスを確認
   https://console.aws.amazon.com/rds/home?region=${region}#dbinstance:id=${resourceId}

2. 暗号化の有効化:
   - 新しいインスタンス: 作成時に暗号化を有効化
   - 既存インスタンス: スナップショットから暗号化インスタンスを再作成

3. パラメーターグループの修正:
   - 該当パラメーターを適切な値に設定
   - インスタンスの再起動が必要な場合があります

4. 削除保護の有効化:
   aws rds modify-db-instance --db-instance-identifier ${resourceId} --deletion-protection

本通知は自動生成されました。詳細についてはセキュリティチームまでお問い合わせください。
`.trim();

  try {
    await snsClient.send(
      new PublishCommand({
        TopicArn: SNS_TOPIC_ARN,
        Subject: subject,
        Message: message,
      })
    );
    
    log.info(`SNS通知を送信しました: ${resourceId}`);
  } catch (error) {
    log.error('SNS通知の送信に失敗しました', error);
    throw error;
  }
}

// メインハンドラー
export const handler: Handler<ConfigRuleComplianceChangeEvent> = async (event: ConfigRuleComplianceChangeEvent, context: Context) => {
  log.info('Lambda関数が開始されました', { eventId: event.id, requestId: context.awsRequestId });
  log.debug('受信イベント', event);

  try {
    // 非準拠の場合のみ処理
    if (event.detail.newEvaluationResult.complianceType !== 'NON_COMPLIANT') {
      log.info('準拠状態のため処理をスキップします', {
        complianceType: event.detail.newEvaluationResult.complianceType,
      });
      return;
    }

    const resourceId = event.detail.resourceId;
    const resourceType = event.detail.resourceType;
    const configRuleName = event.detail.configRuleName;

    log.info('非準拠リソースを処理中', {
      resourceId,
      resourceType,
      configRuleName,
    });

    let issues: string[] = [];

    // リソースタイプに応じた詳細チェック
    if (resourceType === 'AWS::RDS::DBInstance') {
      issues = await checkRdsInstanceDetails(resourceId);
    } else if (resourceType === 'AWS::RDS::DBCluster') {
      // クラスターの場合は簡単な情報のみ
      issues = [`RDSクラスター ${resourceId} がConfig Rule ${configRuleName} に準拠していません`];
    } else {
      // その他のリソースタイプ
      issues = [`リソース ${resourceId} (${resourceType}) がConfig Rule ${configRuleName} に準拠していません`];
    }

    // 問題が検出された場合はSNS通知を送信
    if (issues.length > 0) {
      await sendNotification(resourceId, configRuleName, issues);
    }

    log.info('Lambda関数が正常に完了しました', {
      resourceId,
      issuesCount: issues.length,
    });

  } catch (error) {
    log.error('Lambda関数でエラーが発生しました', error);
    throw error; // DLQに送信するためエラーを再スロー
  }
};

// カスタムConfig Ruleのハンドラー（パラメーターグループ用）
export const customRuleHandler: Handler = async (event: any, context: Context) => {
  log.info('カスタムConfig Ruleが開始されました', { eventId: event.configRuleInvokingEvent?.configurationItem?.resourceId });
  log.debug('受信イベント', event);

  // Config Rules評価ロジックをここに実装
  // このサンプルでは詳細実装は省略
  
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: 'Custom Config Rule executed successfully',
    }),
  };
};
