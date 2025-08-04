import { EventBridgeEvent, Context } from 'aws-lambda';
import { RDSClient, DescribeDBParameterGroupsCommand, DescribeDBParametersCommand, DescribeDBInstancesCommand } from '@aws-sdk/client-rds';
import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';

interface RDSEventDetail {
  EventCategories: string[];
  EventID?: string;
  SourceIdentifier: string;
  SourceType: string;
  Date: string;
  Message: string;
  SourceArn: string;
}

interface RDSEvent {
  version: string;
  id: string;
  'detail-type': string;
  source: string;
  account: string;
  time: string;
  region: string;
  detail: RDSEventDetail;
}

const rdsClient = new RDSClient({ region: process.env.AWS_REGION });
const snsClient = new SNSClient({ region: process.env.AWS_REGION });

export const handler = async (event: EventBridgeEvent<string, RDSEventDetail>, context: Context): Promise<void> => {
  console.log('Received event:', JSON.stringify(event, null, 2));

  try {
    const rdsEvent = event.detail;

    if (!rdsEvent) {
      console.log('Event detail is missing. Skipping.');
      return;
    }
    
    const sourceType = rdsEvent.SourceType;
    const sourceIdentifier = rdsEvent.SourceIdentifier;
    
    console.log(`Event SourceType: '${sourceType}', SourceIdentifier: '${sourceIdentifier}'`);

    if (!sourceType || !sourceIdentifier) {
      console.log('SourceType or SourceIdentifier is missing. Skipping.');
      return;
    }

    // SourceTypeの処理を分岐
    if (sourceType === 'DB_INSTANCE') {
      console.log(`Processing RDS instance: ${sourceIdentifier}`);
      const encryptionIssues = await checkRDSEncryption(sourceIdentifier);
      
      if (encryptionIssues.length > 0) {
        await sendNotification(encryptionIssues, `RDS Instance: ${sourceIdentifier}`);
        console.log(`Sent notification for ${encryptionIssues.length} issues found in instance: ${sourceIdentifier}`);
      } else {
        console.log(`No encryption issues found for instance: ${sourceIdentifier}`);
      }
    } else if (sourceType === 'DB_PARAMETER_GROUP') {
      console.log(`Processing RDS parameter group: ${sourceIdentifier}`);
      const encryptionIssues = await checkParameterGroupEncryption(sourceIdentifier);
      
      if (encryptionIssues.length > 0) {
        await sendNotification(encryptionIssues, `RDS Parameter Group: ${sourceIdentifier}`);
        console.log(`Sent notification for ${encryptionIssues.length} issues found in parameter group: ${sourceIdentifier}`);
      } else {
        console.log(`No encryption issues found for parameter group: ${sourceIdentifier}`);
      }
    } else {
      console.log(`Unsupported SourceType: '${sourceType}'. Skipping.`);
    }
  } catch (error) {
    console.error('Error processing RDS event:', error);
    throw error;
  }
};

async function checkRDSEncryption(dbInstanceId: string): Promise<string[]> {
  const issues: string[] = [];
  
  try {
    // RDSインスタンスの詳細を取得
    const instanceCommand = new DescribeDBInstancesCommand({
      DBInstanceIdentifier: dbInstanceId
    });
    
    const instanceResponse = await rdsClient.send(instanceCommand);
    
    if (!instanceResponse.DBInstances || instanceResponse.DBInstances.length === 0) {
      console.log('RDS instance not found');
      return issues;
    }
    
    const instance = instanceResponse.DBInstances[0];
    
    // EBS暗号化状態をチェック
    if (!instance.StorageEncrypted) {
      issues.push('RDS instance storage encryption is disabled');
      console.log('⚠️ RDS instance storage encryption is disabled');
    } else {
      console.log('✅ RDS instance storage encryption is enabled');
    }
    
    // パラメーターグループの暗号化設定もチェック
    if (instance.DBParameterGroups && instance.DBParameterGroups.length > 0) {
      for (const paramGroup of instance.DBParameterGroups) {
        if (paramGroup.DBParameterGroupName) {
          console.log(`Checking parameter group: ${paramGroup.DBParameterGroupName}`);
          const parameterIssues = await checkParameterGroupEncryption(paramGroup.DBParameterGroupName, instance.Engine);
          issues.push(...parameterIssues);
        }
      }
    }
    
    // バックアップ暗号化状態をチェック
    if (instance.DBInstanceArn) {
      if (!instance.KmsKeyId && instance.StorageEncrypted) {
        issues.push('RDS instance is using default KMS key instead of customer-managed key');
        console.log('⚠️ RDS instance is using default KMS key');
      }
    }
    
  } catch (error) {
    console.error('Error checking RDS encryption:', error);
    issues.push(`Error checking RDS encryption: ${error}`);
  }
  
  return issues;
}

async function checkParameterGroupEncryption(parameterGroupName: string, engine?: string): Promise<string[]> {
  const issues: string[] = [];
  
  try {
    const command = new DescribeDBParametersCommand({
      DBParameterGroupName: parameterGroupName,
      Source: 'user'
    });
    
    const response = await rdsClient.send(command);
    
    if (!response.Parameters) {
      console.log('No parameters found in the parameter group');
      return issues;
    }

    // エンジン固有の暗号化パラメーターを確認
    const encryptionParameters = getEncryptionParametersByEngine(engine || 'unknown');
    
    for (const param of response.Parameters) {
      if (param.ParameterName && encryptionParameters.includes(param.ParameterName)) {
        console.log(`Found security parameter: ${param.ParameterName} = ${param.ParameterValue}`);
        
        // MySQL/MariaDB のセキュリティパラメーターチェック
        if (param.ParameterName === 'require_secure_transport' && param.ParameterValue === 'OFF') {
          issues.push(`MySQL secure transport is disabled (${param.ParameterValue})`);
        }
        
        if (param.ParameterName === 'general_log' && param.ParameterValue === '0') {
          issues.push(`MySQL general logging is disabled - consider enabling for security auditing`);
        }
        
        if (param.ParameterName === 'slow_query_log' && param.ParameterValue === '0') {
          issues.push(`MySQL slow query logging is disabled - consider enabling for performance monitoring`);
        }

        // SQL Server の包含データベース認証が有効の場合（セキュリティリスク）
        if (param.ParameterName === 'contained database authentication' && param.ParameterValue === '1') {
          issues.push('SQL Server contained database authentication is enabled - security risk');
        }

        // PostgreSQL の共有ライブラリチェック
        if (param.ParameterName === 'shared_preload_libraries') {
          const securityLibraries = ['pg_stat_statements', 'auto_explain'];
          const hasSecurityLib = securityLibraries.some(lib => 
            param.ParameterValue?.toLowerCase().includes(lib)
          );
          
          if (!hasSecurityLib) {
            issues.push('PostgreSQL shared_preload_libraries should include security monitoring extensions');
          }
        }
        
        // PostgreSQL SSL設定
        if (param.ParameterName === 'ssl' && param.ParameterValue === 'off') {
          issues.push('PostgreSQL SSL is disabled');
        }
      }
    }
    
  } catch (error) {
    console.error('Error checking parameter group encryption:', error);
    issues.push(`Error checking parameter group: ${error}`);
  }
  
  return issues;
}

function getEncryptionParametersByEngine(engine: string): string[] {
  const engineLower = engine.toLowerCase();
  
  if (engineLower.includes('mysql') || engineLower.includes('mariadb')) {
    // MySQL RDSで実際に利用可能なセキュリティ関連パラメーター
    return [
      'require_secure_transport',  // SSL接続の強制
      'sql_mode',                  // セキュリティモード設定
      'general_log',               // 一般ログの有効化
      'slow_query_log'             // スロークエリログの有効化
    ];
  }
  
  if (engineLower.includes('postgres')) {
    return [
      'shared_preload_libraries',
      'ssl',
      'log_connections',
      'log_statement'
    ];
  }
  
  if (engineLower.includes('sqlserver')) {
    return [
      'contained database authentication',
      'backup compression default',
      'default trace enabled'
    ];
  }
  
  if (engineLower.includes('oracle')) {
    return [
      'audit_trail',
      'audit_sys_operations'
    ];
  }
  
  // 汎用的なセキュリティパラメーター
  return [
    'general_log',
    'slow_query_log'
  ];
}

async function getDBParameterGroup(dbInstanceId: string): Promise<string | null> {
  try {
    // RDSイベントからパラメーターグループを直接取得するのは困難なため、
    // 代替として、最近作成されたパラメーターグループを確認
    const command = new DescribeDBParameterGroupsCommand({});
    const response = await rdsClient.send(command);
    
    if (response.DBParameterGroups && response.DBParameterGroups.length > 0) {
      // 最新のパラメーターグループを取得（実際の運用では、より正確な関連付けが必要）
      const latestGroup = response.DBParameterGroups
        .sort((a: any, b: any) => {
          if (!a.DBParameterGroupName || !b.DBParameterGroupName) return 0;
          return a.DBParameterGroupName.localeCompare(b.DBParameterGroupName);
        })[0];
      
      return latestGroup.DBParameterGroupName || null;
    }
    
    return null;
  } catch (error) {
    console.error('Error getting parameter group:', error);
    return null;
  }
}

async function checkEBSEncryptionParameter(parameterGroupName: string): Promise<boolean> {
  try {
    const command = new DescribeDBParametersCommand({
      DBParameterGroupName: parameterGroupName,
      Source: 'user'
    });
    
    const response = await rdsClient.send(command);
    
    if (!response.Parameters) {
      console.log('No parameters found in the parameter group');
      return false;
    }

    // EBS暗号化に関連するパラメーターを確認
    // MySQL/MariaDBの場合: innodb_encrypt_tables
    // PostgreSQLの場合: shared_preload_libraries (pg_crypt等)
    // SQL Serverの場合: データベースレベルでの暗号化設定
    
    const encryptionParameters = [
      'innodb_encrypt_tables',        // MySQL/MariaDB
      'innodb_encrypt_log',           // MySQL/MariaDB
      'tde_enabled',                  // Oracle
      'rds.force_ssl',               // PostgreSQL/MySQL (SSL接続強制)
      'log_statement_stats',          // PostgreSQL (統計ログ)
      'log_connections',              // PostgreSQL (接続ログ)
      'contained database authentication'  // SQL Server (包含データベース認証)
    ];
    
    for (const param of response.Parameters) {
      if (param.ParameterName && encryptionParameters.includes(param.ParameterName)) {
        console.log(`Found encryption parameter: ${param.ParameterName} = ${param.ParameterValue}`);
        
        // パラメーターが無効（OFF, 0, false等）の場合
        if (param.ParameterValue === 'OFF' || 
            param.ParameterValue === '0' || 
            param.ParameterValue === 'false' ||
            param.ParameterValue === 'FORCE') {
          return true; // 暗号化が無効
        }

        // SQL Server の包含データベース認証が有効の場合（セキュリティリスク）
        if (param.ParameterName === 'contained database authentication' && param.ParameterValue === '1') {
          console.log('SQL Server contained database authentication is enabled - security risk detected');
          return true;
        }

        // PostgreSQL の shared_preload_libraries に暗号化ライブラリが含まれていない場合
        if (param.ParameterName === 'shared_preload_libraries') {
          const encryptionLibraries = ['pg_tde', 'pg_crypt', 'pgcrypto'];
          const hasEncryptionLib = encryptionLibraries.some(lib => 
            param.ParameterValue?.toLowerCase().includes(lib)
          );
          
          if (!hasEncryptionLib) {
            console.log('PostgreSQL shared_preload_libraries does not include encryption extensions');
            return true;
          }
        }
      }
    }
    
    return false; // 暗号化が有効または設定されていない
  } catch (error) {
    console.error('Error checking EBS encryption parameter:', error);
    return false;
  }
}

async function sendNotification(issues: string[], context: string, metadata?: any): Promise<void> {
  if (issues.length === 0) {
    console.log('No issues found, skipping notification');
    return;
  }

  const message = `RDS Encryption Issue Detected

Context: ${context}
Timestamp: ${new Date().toISOString()}

Issues Found:
${issues.map(issue => `- ${issue}`).join('\n')}

${metadata ? `Additional Information:\n${JSON.stringify(metadata, null, 2)}` : ''}

Please review and address these encryption configuration issues.`;

  const params = {
    TopicArn: process.env.SNS_TOPIC_ARN!,
    Subject: 'RDS Encryption Violation Alert',
    Message: message
  };

  try {
    await snsClient.send(new PublishCommand(params));
    console.log('Notification sent successfully');
  } catch (error) {
    console.error('Error sending notification:', error);
  }
}
