export interface LambdaConfig {
  functionName?: string;
  parameterGroupAuditFunctionName?: string;
  timeout?: number;
  memorySize?: number;
  logLevel?: 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';
  logRetentionDays?: number;
}

export interface StackConfig {
  // SNS設定
  sns: {
    // 既存のSNSトピックARNを指定する場合（指定がなければ新規作成）
    existingTopicArn?: string;
    // 新規作成時の設定
    topicName?: string;
    displayName?: string;
    // 通知先メールアドレス（既存トピック使用時は無視される）
    emailAddress?: string;
  };

  // AWS Config設定
  config: {
    // 既存のConfiguration RecorderのARNを指定する場合（指定がなければ新規作成）
    existingConfigurationRecorderArn?: string;
    // 既存のDelivery ChannelのARNを指定する場合（指定がなければ新規作成）
    existingDeliveryChannelArn?: string;
    // 既存のConfig Service RoleのARNを指定する場合（指定がなければ新規作成）
    existingConfigRoleArn?: string;
    // 新規作成時の設定
    configurationRecorderName?: string;
    deliveryChannelName?: string;
    configRoleName?: string;
    // Config配信頻度
    deliveryFrequency?: 'One_Hour' | 'Three_Hours' | 'Six_Hours' | 'Twelve_Hours' | 'TwentyFour_Hours';
  };

  // S3バケット設定
  s3: {
    // 既存のS3バケットARNを指定する場合（指定がなければ新規作成）
    existingBucketArn?: string;
    // 新規作成時の設定
    bucketNamePrefix?: string;
    lifecycleRuleDays?: number;
  };

  // IAMロール設定
  iam: {
    // 既存のLambda実行ロールARNを指定する場合（指定がなければ新規作成）
    existingLambdaRoleArn?: string;
    // 既存のConfig Service RoleのARNを指定する場合（指定がなければ新規作成）
    existingConfigRoleArn?: string;
    // 新規作成時の設定
    lambdaRoleName?: string;
    configRoleName?: string;
  };

  // Lambda設定
  lambda: LambdaConfig;

  // 環境固有設定
  environment: {
    name: string; // dev, staging, prod など
    region?: string;
  };
}

// デフォルト設定
export const defaultConfig: StackConfig = {
  sns: {
    topicName: 'rds-encryption-audit-notifications',
    displayName: 'RDS暗号化監査通知',
    emailAddress: 'security-admin@yourcompany.com',
  },
  config: {
    configurationRecorderName: 'rds-audit-recorder',
    deliveryChannelName: 'rds-audit-delivery-channel',
    configRoleName: 'RdsAuditConfigRole',
    deliveryFrequency: 'One_Hour',
  },
  s3: {
    bucketNamePrefix: 'rds-audit-config',
    lifecycleRuleDays: 365,
  },
  iam: {
    lambdaRoleName: 'RdsAuditLambdaRole',
    configRoleName: 'RdsAuditConfigRole',
  },
  lambda: {
    functionName: 'rds-encryption-audit',
    timeout: 5,
    memorySize: 256,
    logLevel: 'INFO',
    logRetentionDays: 30,
  },
  environment: {
    name: 'dev',
  },
};
