import { ConfigServiceClient, PutEvaluationsCommand } from "@aws-sdk/client-config-service";
import { RDSClient, DescribeDBParametersCommand, DescribeDBClusterParametersCommand, Parameter } from "@aws-sdk/client-rds";
import type { EventBridgeEvent } from 'aws-lambda';

// イベント詳細の型定義
interface ConfigRuleEventDetail {
    invokingEvent: string;
    resultToken: string;
    ruleParameters: string;
    configRuleName: string;
}

// 設定項目の型定義
interface ConfigurationItem {
    resourceType: string;
    resourceId: string;
    configurationItemCaptureTime: string;
}

// 呼び出しイベントの型定義
interface InvokingEvent {
    configurationItem: ConfigurationItem;
}

const configClient = new ConfigServiceClient({});
const rdsClient = new RDSClient({});

/**
 * パラメータグループのタイプを判別します。
 * @param resourceType - AWSリソースタイプ
 * @returns 'cluster'、'instance'、または null
 */
function getParameterGroupType(resourceType: string): 'cluster' | 'instance' | null {
    if (resourceType === 'AWS::RDS::DBClusterParameterGroup') {
        return 'cluster';
    }
    if (resourceType === 'AWS::RDS::DBParameterGroup') {
        return 'instance';
    }
    return null;
}

/**
 * パラメータグループのパラメータを取得します。
 * @param groupName - パラメータグループ名
 * @param groupType - パラメータグループのタイプ ('cluster' または 'instance')
 * @returns パラメータの配列
 */
async function getParameters(groupName: string, groupType: 'cluster' | 'instance'): Promise<Parameter[] | undefined> {
    if (groupType === 'cluster') {
        const command = new DescribeDBClusterParametersCommand({ DBClusterParameterGroupName: groupName });
        const result = await rdsClient.send(command);
        return result.Parameters;
    } else {
        const command = new DescribeDBParametersCommand({ DBParameterGroupName: groupName });
        const result = await rdsClient.send(command);
        return result.Parameters;
    }
}

export const handler = async (event: EventBridgeEvent<"Config Rule", ConfigRuleEventDetail>): Promise<void> => {
    console.log('Event:', JSON.stringify(event, null, 2));

    const invokingEvent: InvokingEvent = JSON.parse(event.detail.invokingEvent);
    const configurationItem = invokingEvent.configurationItem;
    const resourceType = configurationItem.resourceType;
    const resourceId = configurationItem.resourceId; // パラメータグループ名
    const ruleParameters = JSON.parse(event.detail.ruleParameters || '{}');

    let compliance: 'COMPLIANT' | 'NON_COMPLIANT' | 'NOT_APPLICABLE' = 'NOT_APPLICABLE';
    let annotation = 'リソースタイプが評価対象外です。';

    const groupType = getParameterGroupType(resourceType);

    if (groupType && Object.keys(ruleParameters).length > 0) {
        try {
            const parameters = await getParameters(resourceId, groupType);
            if (!parameters) {
                throw new Error('パラメータの取得に失敗しました。');
            }

            let allParamsCompliant = true;
            const annotations: string[] = [];

            for (const key in ruleParameters) {
                const expectedValue = ruleParameters[key];
                const param = parameters.find(p => p.ParameterName === key);

                if (!param) {
                    allParamsCompliant = false;
                    annotations.push(`パラメータ '${key}' が見つかりません。`);
                } else if (String(param.ParameterValue) !== String(expectedValue)) {
                    allParamsCompliant = false;
                    annotations.push(`パラメータ '${key}' の値が '${param.ParameterValue}' ですが、期待値は '${expectedValue}' です。`);
                }
            }

            if (allParamsCompliant) {
                compliance = 'COMPLIANT';
                annotation = '必須パラメータはすべて準拠しています。';
            } else {
                compliance = 'NON_COMPLIANT';
                annotation = annotations.join(' ');
            }

        } catch (error) {
            console.error("パラメータのチェック中にエラーが発生しました:", error);
            compliance = 'NON_COMPLIANT';
            annotation = `パラメータチェックエラー: ${(error as Error).message}`;
        }
    } else if (groupType) {
        compliance = 'NOT_APPLICABLE';
        annotation = '評価するルールパラメータが提供されていません。';
    }

    const putEvaluationsRequest = {
        Evaluations: [
            {
                ComplianceResourceType: resourceType,
                ComplianceResourceId: resourceId,
                ComplianceType: compliance,
                Annotation: annotation,
                OrderingTimestamp: new Date(configurationItem.configurationItemCaptureTime),
            },
        ],
        ResultToken: event.detail.resultToken,
    };

    try {
        await configClient.send(new PutEvaluationsCommand(putEvaluationsRequest));
        console.log('評価を正常に送信しました。');
    } catch (error) {
        console.error('評価の送信中にエラーが発生しました:', error);
    }
};
