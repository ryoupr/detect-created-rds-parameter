import { ScheduledEvent, Context } from 'aws-lambda';
import { RDSClient, DescribeDBParameterGroupsCommand, DescribeDBParametersCommand, DescribeDBInstancesCommand } from '@aws-sdk/client-rds';
import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';

const rdsClient = new RDSClient({ region: process.env.AWS_REGION });
const snsClient = new SNSClient({ region: process.env.AWS_REGION });

interface ParameterGroupAuditResult {
  parameterGroupName: string;
  engine: string;
  hasEncryptionIssues: boolean;
  issues: string[];
  associatedInstances: string[];
}

export const handler = async (event: ScheduledEvent, context: Context): Promise<void> => {
  console.log('Starting scheduled RDS parameter group audit...');
  console.log('Event:', JSON.stringify(event, null, 2));

  try {
    // すべてのパラメーターグループを取得
    const parameterGroups = await getAllParameterGroups();
    console.log(`Found ${parameterGroups.length} parameter groups to audit`);

    const auditResults: ParameterGroupAuditResult[] = [];

    // 各パラメーターグループを監査
    for (const parameterGroup of parameterGroups) {
      if (!parameterGroup.DBParameterGroupName) continue;

      console.log(`Auditing parameter group: ${parameterGroup.DBParameterGroupName}`);
      
      const auditResult = await auditParameterGroup(
        parameterGroup.DBParameterGroupName,
        parameterGroup.DBParameterGroupFamily || 'unknown'
      );

      if (auditResult.hasEncryptionIssues) {
        auditResults.push(auditResult);
      }
    }

    // 問題が見つかった場合は通知を送信
    if (auditResults.length > 0) {
      await sendAuditReport(auditResults);
    } else {
      console.log('No encryption issues found in any parameter groups');
    }

  } catch (error) {
    console.error('Error during scheduled audit:', error);
    await sendErrorNotification(error as Error);
    throw error;
  }
};

async function getAllParameterGroups() {
  const parameterGroups = [];
  let marker: string | undefined;

  do {
    const command = new DescribeDBParameterGroupsCommand({
      Marker: marker,
      MaxRecords: 100
    });

    const response = await rdsClient.send(command);
    
    if (response.DBParameterGroups) {
      parameterGroups.push(...response.DBParameterGroups);
    }
    
    marker = response.Marker;
  } while (marker);

  return parameterGroups;
}

async function auditParameterGroup(parameterGroupName: string, engine: string): Promise<ParameterGroupAuditResult> {
  const result: ParameterGroupAuditResult = {
    parameterGroupName,
    engine,
    hasEncryptionIssues: false,
    issues: [],
    associatedInstances: []
  };

  try {
    // パラメーターグループに関連付けられたインスタンスを取得
    result.associatedInstances = await getAssociatedInstances(parameterGroupName);

    // パラメーターを取得して暗号化設定をチェック
    const command = new DescribeDBParametersCommand({
      DBParameterGroupName: parameterGroupName,
      Source: 'user'
    });

    const response = await rdsClient.send(command);

    if (!response.Parameters) {
      return result;
    }

    // エンジンタイプに基づいて暗号化パラメーターをチェック
    const encryptionIssues = checkEncryptionParameters(response.Parameters, engine);
    
    if (encryptionIssues.length > 0) {
      result.hasEncryptionIssues = true;
      result.issues = encryptionIssues;
    }

  } catch (error) {
    console.error(`Error auditing parameter group ${parameterGroupName}:`, error);
    result.issues.push(`Error auditing parameter group: ${error}`);
    result.hasEncryptionIssues = true;
  }

  return result;
}

async function getAssociatedInstances(parameterGroupName: string): Promise<string[]> {
  try {
    const command = new DescribeDBInstancesCommand({});
    const response = await rdsClient.send(command);
    
    const associatedInstances: string[] = [];
    
    if (response.DBInstances) {
      for (const instance of response.DBInstances) {
        if (instance.DBParameterGroups) {
          for (const paramGroup of instance.DBParameterGroups) {
            if (paramGroup.DBParameterGroupName === parameterGroupName) {
              if (instance.DBInstanceIdentifier) {
                associatedInstances.push(instance.DBInstanceIdentifier);
              }
              break;
            }
          }
        }
      }
    }
    
    return associatedInstances;
  } catch (error) {
    console.error('Error getting associated instances:', error);
    return [];
  }
}

function checkEncryptionParameters(parameters: any[], engine: string): string[] {
  const issues: string[] = [];
  
  // エンジンタイプに基づく暗号化パラメーターの定義
  const encryptionParametersByEngine: { [key: string]: { [param: string]: string[] } } = {
    'mysql': {
      'innodb_encrypt_tables': ['OFF', '0'],
      'innodb_encrypt_log': ['OFF', '0'],
      'innodb_encryption_threads': ['0'],
      'rds.force_ssl': ['OFF', '0']
    },
    'mariadb': {
      'innodb_encrypt_tables': ['OFF', '0'],
      'innodb_encrypt_log': ['OFF', '0'],
      'innodb_encryption_threads': ['0'],
      'rds.force_ssl': ['OFF', '0']
    },
    'postgres': {
      'shared_preload_libraries': [], // PostgreSQLの場合、特定の値をチェック
      'rds.force_ssl': ['OFF', '0'],
      'log_connections': ['OFF', '0'],
      'log_statement_stats': ['OFF', '0']
    },
    'oracle-ee': {
      'tde_configuration': ['NONE', 'OFF']
    },
    'sqlserver-se': {
      'contained database authentication': ['1'], // SQL Server Standard Edition
      'backup compression default': ['0']
    },
    'sqlserver-ee': {
      'contained database authentication': ['1'], // SQL Server Enterprise Edition
      'backup compression default': ['0']
    },
    'sqlserver-ex': {
      'contained database authentication': ['1'], // SQL Server Express Edition
      'backup compression default': ['0']
    },
    'sqlserver-web': {
      'contained database authentication': ['1'], // SQL Server Web Edition
      'backup compression default': ['0']
    }
  };

  const engineLower = engine.toLowerCase();
  const relevantParameters = encryptionParametersByEngine[engineLower];

  if (!relevantParameters) {
    console.log(`No encryption parameters defined for engine: ${engine}`);
    return issues;
  }

  for (const param of parameters) {
    if (!param.ParameterName || !param.ParameterValue) continue;

    const paramName = param.ParameterName;
    const paramValue = param.ParameterValue;

    if (relevantParameters[paramName]) {
      const problematicValues = relevantParameters[paramName];
      
      if (problematicValues.includes(paramValue)) {
        issues.push(`Parameter '${paramName}' is set to '${paramValue}' which disables encryption`);
      }
    }

    // PostgreSQLの特別な処理: shared_preload_librariesに暗号化関連ライブラリが含まれているかチェック
    if (engineLower === 'postgres' && paramName === 'shared_preload_libraries') {
      const encryptionLibraries = ['pg_tde', 'pg_crypt', 'pgcrypto'];
      const hasEncryptionLib = encryptionLibraries.some(lib => 
        paramValue.toLowerCase().includes(lib)
      );
      
      if (!hasEncryptionLib) {
        issues.push(`PostgreSQL shared_preload_libraries does not include encryption extensions (${encryptionLibraries.join(', ')})`);
      }
    }

    // SQL Serverの特別な処理: 包含データベース認証が有効になっている場合は問題
    if (engineLower.startsWith('sqlserver') && paramName === 'contained database authentication' && paramValue === '1') {
      issues.push(`SQL Server contained database authentication is enabled, which may weaken security`);
    }
  }

  return issues;
}

async function sendAuditReport(auditResults: ParameterGroupAuditResult[]): Promise<void> {
  const topicArn = process.env.SNS_TOPIC_ARN;
  if (!topicArn) {
    console.error('SNS_TOPIC_ARN environment variable not set');
    return;
  }

  const report = {
    reportType: 'Scheduled RDS Parameter Group Audit',
    timestamp: new Date().toISOString(),
    region: process.env.AWS_REGION,
    totalIssuesFound: auditResults.length,
    issues: auditResults.map(result => ({
      parameterGroupName: result.parameterGroupName,
      engine: result.engine,
      associatedInstances: result.associatedInstances,
      encryptionIssues: result.issues
    }))
  };

  const subject = `[SECURITY AUDIT] RDS Parameter Group Encryption Issues Detected (${auditResults.length} groups affected)`;

  try {
    const command = new PublishCommand({
      TopicArn: topicArn,
      Message: JSON.stringify(report, null, 2),
      Subject: subject
    });

    await snsClient.send(command);
    console.log('Audit report sent successfully');
  } catch (error) {
    console.error('Error sending audit report:', error);
    throw error;
  }
}

async function sendErrorNotification(error: Error): Promise<void> {
  const topicArn = process.env.SNS_TOPIC_ARN;
  if (!topicArn) {
    console.error('SNS_TOPIC_ARN environment variable not set');
    return;
  }

  const errorReport = {
    reportType: 'RDS Parameter Group Audit Error',
    timestamp: new Date().toISOString(),
    region: process.env.AWS_REGION,
    error: error.message,
    stack: error.stack
  };

  const subject = '[ERROR] RDS Parameter Group Audit Failed';

  try {
    const command = new PublishCommand({
      TopicArn: topicArn,
      Message: JSON.stringify(errorReport, null, 2),
      Subject: subject
    });

    await snsClient.send(command);
    console.log('Error notification sent successfully');
  } catch (notificationError) {
    console.error('Error sending error notification:', notificationError);
  }
}
