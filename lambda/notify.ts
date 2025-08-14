import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

const sns = new SNSClient({});
const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN;

export const handler = async (event: any): Promise<void> => {
    // eventには監査Lambdaの結果が渡される想定
    const message = event?.message || 'Config違反検知';
    const subject = event?.subject || 'RDS Config Violation';

    if (!SNS_TOPIC_ARN) {
        console.error('SNS_TOPIC_ARN is not set');
        return;
    }

    try {
        await sns.send(new PublishCommand({
            TopicArn: SNS_TOPIC_ARN,
            Message: message,
            Subject: subject,
        }));
        console.log('SNS通知を送信しました');
    } catch (error) {
        console.error('SNS通知送信エラー:', error);
        throw error;
    }
};
