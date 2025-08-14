import { Template } from 'aws-cdk-lib/assertions';
import * as cdk from 'aws-cdk-lib';
import { RdsEncryptionAuditStack } from '../lib/rds-encryption-audit-stack';

describe('RdsEncryptionAuditStack', () => {
  let template: Template;

  beforeAll(() => {
    const app = new cdk.App();
    const stack = new RdsEncryptionAuditStack(app, 'TestStack', {
      config: {
        sns: {},
        config: {},
        s3: {},
        iam: {},
        lambda: {},
        environment: { name: 'test' }
      } as any,
    });
    template = Template.fromStack(stack);
  });

  test('SNSトピックが作成される', () => {
    template.hasResourceProperties('AWS::SNS::Topic', {
      TopicName: 'rds-encryption-audit-notifications',
      DisplayName: 'RDS暗号化監査通知',
    });
  });

  test('Lambda関数が作成される', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'rds-encryption-audit',
      Runtime: 'nodejs18.x',
      Handler: 'index.handler',
      Timeout: 300,
      MemorySize: 256,
    });
  });

  test('Managed Config Rule (RDS storage encrypted) が作成される', () => {
    template.hasResourceProperties('AWS::Config::ConfigRule', {
      ConfigRuleName: 'rds-storage-encrypted-check',
      Source: {
        Owner: 'AWS',
        SourceIdentifier: 'RDS_STORAGE_ENCRYPTED',
      },
    });
  });

  test('Custom Config Rule (パラメーターグループ) が作成される', () => {
    template.hasResourceProperties('AWS::Config::ConfigRule', {
      ConfigRuleName: 'rds-parameter-group-settings-check',
      Source: {
        Owner: 'CUSTOM_LAMBDA',
      },
    });
  });

  test('EventBridge Ruleが作成される', () => {
    template.hasResourceProperties('AWS::Events::Rule', {
      EventPattern: {
        source: ['aws.config'],
        'detail-type': ['Config Rules Compliance Change'],
        detail: {
          newEvaluationResult: {
            complianceType: ['NON_COMPLIANT'],
          },
        },
      },
    });
  });

  test('S3バケットが作成される', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          {
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'AES256',
            },
          },
        ],
      },
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
      VersioningConfiguration: {
        Status: 'Enabled',
      },
    });
  });

  test('Configuration Recorderが作成される', () => {
    template.hasResourceProperties('AWS::Config::ConfigurationRecorder', {
      RecordingGroup: {
        AllSupported: false,
        IncludeGlobalResourceTypes: false,
        ResourceTypes: [
          'AWS::RDS::DBInstance',
          'AWS::RDS::DBCluster',
          'AWS::RDS::DBParameterGroup',
          'AWS::RDS::DBClusterParameterGroup',
        ],
      },
    });
  });

  test('Delivery Channelが作成される', () => {
    template.hasResourceProperties('AWS::Config::DeliveryChannel', {
      ConfigSnapshotDeliveryProperties: {
        DeliveryFrequency: 'One_Hour',
      },
    });
  });

  test('Lambda IAMロールが適切な権限を持つ', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      AssumeRolePolicyDocument: {
        Statement: [
          {
            Effect: 'Allow',
            Principal: {
              Service: 'lambda.amazonaws.com',
            },
            Action: 'sts:AssumeRole',
          },
        ],
      },
      ManagedPolicyArns: [
        {
          'Fn::Join': [
            '',
            [
              'arn:',
              { Ref: 'AWS::Partition' },
              ':iam::aws:policy/service-role/AWSLambdaBasicExecutionRole',
            ],
          ],
        },
      ],
    });
  });
});
