import { ConfigServiceClient, GetComplianceDetailsByConfigRuleCommand } from "@aws-sdk/client-config-service";

// Step Functionsから渡されるeventにはConfig違反イベント情報が含まれる
export const handler = async (event: any): Promise<{ message: string, subject: string }> => {
    // event.detailにConfig違反イベントが入っている想定
    const configRuleName = event?.detail?.configRuleName || 'UnknownRule';
    const resourceId = event?.detail?.resourceId || 'UnknownResource';
    const complianceType = event?.detail?.newEvaluationResult?.complianceType || 'NON_COMPLIANT';

    // 必要に応じてConfig APIで追加情報取得も可能
    // const client = new ConfigServiceClient({});
    // ...

    const message = `RDSパラメータグループの暗号化設定違反を検知しました。\nRule: ${configRuleName}\nResource: ${resourceId}\nCompliance: ${complianceType}`;
    const subject = `RDS Parameter Group Compliance Violation: ${resourceId}`;

    return { message, subject };
};
