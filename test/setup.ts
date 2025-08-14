// テスト用の環境変数設定
process.env.AWS_REGION = 'ap-northeast-1';
process.env.SNS_TOPIC_ARN = 'arn:aws:sns:ap-northeast-1:123456789012:test-topic';

// AWS SDKのモック設定
jest.mock('@aws-sdk/client-rds');
jest.mock('@aws-sdk/client-sns');
