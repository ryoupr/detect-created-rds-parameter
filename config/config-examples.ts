import { StackConfig } from './stack-config';

// 完全新規作成の設定例
export const newResourcesConfig: StackConfig = {
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
  },
  environment: {
    name: 'production',
    region: 'ap-northeast-1',
  },
};

// 既存リソースを部分的に利用する設定例
export const mixedResourcesConfig: StackConfig = {
  sns: {
    // 既存のSNSトピックを利用
    existingTopicArn: 'arn:aws:sns:ap-northeast-1:123456789012:existing-security-notifications',
  },
  config: {
    // 既存のConfig Service Roleを利用
    existingConfigRoleArn: 'arn:aws:iam::123456789012:role/existing-config-role',
    // 新規でRecorderとDelivery Channelを作成
    configurationRecorderName: 'rds-audit-recorder',
    deliveryChannelName: 'rds-audit-delivery-channel',
    deliveryFrequency: 'Three_Hours',
  },
  s3: {
    // 既存のS3バケットを利用
    existingBucketArn: 'arn:aws:s3:::existing-config-bucket',
  },
  iam: {
    // 新規でLambda実行ロールを作成
    lambdaRoleName: 'RdsAuditLambdaRole',
  },
  lambda: {
    functionName: 'rds-encryption-audit-prod',
    timeout: 10,
    memorySize: 512,
    logLevel: 'WARN',
  },
  environment: {
    name: 'production',
    region: 'ap-northeast-1',
  },
};

// 既存リソースを最大限利用する設定例
export const existingResourcesConfig: StackConfig = {
  sns: {
    existingTopicArn: 'arn:aws:sns:ap-northeast-1:123456789012:security-notifications',
  },
  config: {
    existingConfigurationRecorderArn: 'arn:aws:config:ap-northeast-1:123456789012:config-recorder/existing-recorder',
    existingDeliveryChannelArn: 'arn:aws:config:ap-northeast-1:123456789012:delivery-channel/existing-channel',
    existingConfigRoleArn: 'arn:aws:iam::123456789012:role/ConfigRole',
  },
  s3: {
    existingBucketArn: 'arn:aws:s3:::company-config-bucket',
  },
  iam: {
    existingLambdaRoleArn: 'arn:aws:iam::123456789012:role/LambdaExecutionRole',
  },
  lambda: {
    functionName: 'rds-encryption-audit-existing',
    timeout: 5,
    memorySize: 256,
    logLevel: 'INFO',
  },
  environment: {
    name: 'production',
    region: 'ap-northeast-1',
  },
};
