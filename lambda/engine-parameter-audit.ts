import { RDSClient, DescribeDBInstancesCommand } from '@aws-sdk/client-rds';

const rds = new RDSClient({});
const ENGINE = process.env.ENGINE || 'unknown';

/**
 * エンジン別の推奨/必須パラメータ（簡易版）。本番ではエンジンごとに適切な詳細パラメータを拡張。
 */
const REQUIRED_PARAMS: Record<string, { name: string; expected: string | RegExp; note?: string }[]> = {
  mysql: [
    { name: 'require_secure_transport', expected: 'ON' },
    { name: 'tls_version', expected: /TLSv1\.2|TLSv1\.3/ },
  ],
  postgres: [
    { name: 'rds.force_ssl', expected: '1' },
    { name: 'log_min_duration_statement', expected: /[0-9]+/ },
  ],
  oracle: [
    { name: 'local_listener', expected: /.*/ },
  ],
  sqlserver: [
    { name: 'rds.tls_version', expected: /TLS1_2/ },
  ],
};

export const handler = async (event: any) => {
  console.log('Engine audit start', { ENGINE, event });

  const instance = event.instance || {}; // DescribeDBInstances結果の1件
  const engine: string = (event.engine || instance.Engine || ENGINE).toLowerCase();
  const checks = REQUIRED_PARAMS[engine] || [];

  // ここでは簡略化: 実際のパラメータ値取得は既存パラメータグループ監査ルートで実施する想定。
  // この関数は"エンジン識別済み"をマークし、追加詳細チェックの拡張ポイントを示す。現状は COMPLIANT 相当情報のみ生成。

  const message = `Engine specific audit executed for ${engine}. (placeholder checks=${checks.map(c=>c.name).join(',')})`;
  const subject = `RDS Engine (${engine}) Parameter Audit`; 

  return { message, subject };
};
