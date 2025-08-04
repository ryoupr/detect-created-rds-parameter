# RDS セキュリティ監査システム

AWS CDKを利用したRDSインスタンスとパラメーターグループのセキュリティ監査システムです。RDSリソースの作成・変更を自動検知し、ストレージ暗号化やセキュリティパラメーターの設定を監査してSNS通知を送信します。

**バージョン**: 0.1.0  
**CDK**: 2.1023.0  
**Node.js**: 18.x以降  
**AWS SDK**: v3

## 🏗️ システムアーキテクチャ

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Amazon RDS    │ ──▶│  EventBridge    │ ──▶│ Lambda Function │
│  Events         │    │   Rules         │    │ RDS Audit       │
│ ・Instance      │    │ ・DB_INSTANCE   │    │ ・暗号化チェック │
│ ・Parameter     │    │ ・PARAMETER_GRP │    │ ・パラメータ監査 │
│   Group         │    │ ・Scheduled     │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                                        │
┌─────────────────┐    ┌─────────────────┐             │
│  CloudWatch     │ ◀──│   Amazon SNS    │ ◀───────────┘
│  Logs           │    │   Notifications │
└─────────────────┘    └─────────────────┘
```

## 📋 主な機能

### 1. リアルタイム監視

- **RDSインスタンスイベント**: 作成・変更・再起動時の暗号化状態チェック
- **パラメーターグループイベント**: 設定変更時のセキュリティパラメーター監査
- **EventBridge統合**: AWSネイティブイベントによる即座の検知

### 2. 定期監査

- **スケジュール実行**: 毎日定時での全RDSリソース監査
- **包括的チェック**: 既存の全インスタンスとパラメーターグループの再評価

### 3. 多エンジン対応

- **MySQL/MariaDB**: `general_log`, `slow_query_log`, `require_secure_transport`
- **PostgreSQL**: `shared_preload_libraries`, `ssl`, `log_connections`
- **SQL Server**: `contained database authentication`
- **Oracle**: `audit_trail`, `audit_sys_operations`

### 4. 検知項目

- ✅ **ストレージ暗号化**: EBS暗号化の有効/無効
- ✅ **KMS設定**: デフォルトキー vs カスタマー管理キー
- ✅ **セキュリティログ**: 監査ログの有効化状況
- ✅ **SSL/TLS**: 暗号化通信の強制設定

## 📁 プロジェクト構成

```
detect-created-rds-parameter/
├── 📁 lambda/                      # Lambda関数ソースコード
│   ├── rds-parameter-audit.ts      # イベント駆動監査
│   ├── scheduled-audit.ts          # 定期監査
│   ├── package.json               # Lambda依存関係
│   └── tsconfig.json              # Lambda TypeScript設定
├── 📁 scripts/                     # デプロイ・テストスクリプト
│   ├── deploy.sh                  # デプロイスクリプト
│   ├── setup-test-env.sh          # テスト環境構築
│   ├── test.sh                    # システムテスト
│   ├── cleanup-test-env.sh        # テスト環境クリーンアップ
│   └── delete-rds-instances.sh    # RDSインスタンス削除ツール
├── 📁 test/                       # テストコード
│   └── detect-created-rds-parameter.test.ts
├── 📋 ARCHITECTURE.drawio         # アーキテクチャ図ソース
├── 📋 cdk.json                    # CDK設定
├── 📋 cdk.context.json            # CDKコンテキスト
├── 📋 package.json                # プロジェクト設定
├── 📋 tsconfig.json               # TypeScript設定
├── 📋 jest.config.js              # Jest設定
├── 📋 .gitignore                  # Git除外設定
├── 📋 .npmignore                  # npm除外設定
└── 📖 README.md                   # このファイル
```

## 🚀 クイックスタート

### 前提条件

```bash
# 必要なツール
- Node.js 18.x以降
- AWS CLI設定済み
- AWS CDK v2.1023.0

# AWS権限
- VPC/Subnet操作権限
- RDS操作権限（読み取り専用）
- Lambda/EventBridge/SNS操作権限
- IAMロール作成権限
```

### 1. インストール

```bash
# プロジェクトクローン
git clone <repository-url>
cd detect-created-rds-parameter

# 依存関係インストール
npm install

# Lambda依存関係インストール
cd lambda && npm install && cd ..

# CDK Bootstrap（初回のみ）
npx cdk bootstrap
```

### 2. デプロイ

**方法1: 環境変数を使用（推奨）**

```bash
export ALERT_EMAIL=your-email@example.com
./scripts/deploy.sh
```

**方法2: CDKコンテキストを使用**

```bash
cdk deploy --context alertEmail=your-email@example.com
```

**方法3: 対話式デプロイスクリプト**

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
# メールアドレスの入力を求められます
```

### 3. テスト環境構築

```bash
# テスト環境のセットアップ
chmod +x scripts/setup-test-env.sh
./scripts/setup-test-env.sh

# 暗号化無効のテストインスタンス作成（アラート発生）
aws rds create-db-instance \
  --db-instance-identifier test-mysql-unencrypted \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --master-username admin \
  --master-user-password TestPassword123 \
  --db-parameter-group-name test-mysql-params \
  --db-subnet-group-name test-db-subnet-group \
  --allocated-storage 20 \
  --storage-encrypted false
```

### 4. システムテスト

```bash
# 統合テスト実行
chmod +x scripts/test.sh
./scripts/test.sh
```

## ⚙️ 設定オプション

### メール通知設定

**方法1: 環境変数（推奨）**

```bash
ALERT_EMAIL=alerts@company.com cdk deploy
```

**方法2: CDKコンテキスト**

```bash
cdk deploy --context alertEmail=alerts@company.com
```

**方法3: cdk.jsonファイル**

```json
{
  "context": {
    "alertEmail": "alerts@company.com"
  }
}
```

### 監査頻度変更

`lib/detect-created-rds-parameter-stack.ts`:

```typescript
// 毎日 → 毎時間に変更
schedule: events.Schedule.rate(cdk.Duration.hours(1))
```

### 監視パラメーター追加

`lambda/rds-parameter-audit.ts`の`getEncryptionParametersByEngine()`:

```typescript
if (engineLower.includes('mysql')) {
  return [
    'require_secure_transport',
    'general_log',
    'slow_query_log',
    'your_custom_parameter'  // 追加
  ];
}
```

## 🔍 監視内容詳細

### RDSインスタンス監視

| 項目 | 内容 | アラート条件 |
|------|------|-------------|
| ストレージ暗号化 | EBS暗号化状態 | `StorageEncrypted = false` |
| KMS設定 | キー管理方式 | デフォルトキー使用時 |
| バックアップ暗号化 | バックアップの暗号化 | 無効時 |

### パラメーターグループ監視

#### MySQL/MariaDB

- `require_secure_transport`: SSL接続強制
- `general_log`: 一般クエリログ
- `slow_query_log`: スロークエリログ

#### PostgreSQL

- `shared_preload_libraries`: セキュリティ拡張ライブラリ
- `ssl`: SSL設定
- `log_connections`: 接続ログ

#### SQL Server

- `contained database authentication`: 包含DB認証（リスク）

## 🧪 テストシナリオ

### 1. 基本動作テスト

```bash
# 定期監査Lambda手動実行
./scripts/test.sh

# CloudWatchログ確認
aws logs tail /aws/lambda/DetectCreatedRdsParameter-ScheduledRDSParameterAuditFunction --follow
```

### 2. アラート発生テスト

```bash
# 暗号化無効インスタンス作成
aws rds create-db-instance \
  --db-instance-identifier test-unencrypted \
  --storage-encrypted false \
  # その他のパラメーター...

# インスタンス再起動（イベント発生）
aws rds reboot-db-instance --db-instance-identifier test-unencrypted
```

### 3. パラメーターグループテスト

```bash
# 危険な設定のパラメーターグループ作成
aws rds modify-db-parameter-group \
  --db-parameter-group-name test-mysql-params \
  --parameters 'ParameterName=general_log,ParameterValue=0,ApplyMethod=immediate'
```

## 📊 運用監視

### CloudWatchメトリクス

- Lambda実行回数・エラー率
- SNS配信成功率
- EventBridge ルールマッチ数

### ログ確認

```bash
# Lambda実行ログ
aws logs tail /aws/lambda/DetectCreatedRdsParameter-RDSParameterAuditFunction

# 定期監査ログ
aws logs tail /aws/lambda/DetectCreatedRdsParameter-ScheduledRDSParameterAuditFunction
```

### アラート例

```
件名: RDS Encryption Violation Alert

Context: RDS Instance: test-mysql-unencrypted
Timestamp: 2025-07-30T09:54:47.533Z

Issues Found:
- RDS instance storage encryption is disabled
- MySQL general logging is disabled - consider enabling for security auditing
- MySQL slow query logging is disabled - consider enabling for performance monitoring

Please review and address these encryption configuration issues.
```

## 🛠️ トラブルシューティング

### よくある問題

#### 1. Lambda実行エラー

```bash
# ログ確認
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/DetectCreatedRdsParameter

# 権限確認
aws iam list-attached-role-policies --role-name DetectCreatedRdsParameter-RDSParameterAuditLambdaRole
```

#### 2. SNS通知が届かない

- SNSサブスクリプション確認済みか
- スパムフォルダ確認
- SNSトピック権限確認

#### 3. EventBridgeイベントが検知されない

```bash
# EventBridgeルール確認
aws events list-rules --name-prefix DetectCreatedRdsParameter

# ルールターゲット確認
aws events list-targets-by-rule --rule DetectCreatedRdsParameter-RDSCreationEventRule
```

## 🧹 クリーンアップ

### 1. CDKスタック削除

```bash
cdk destroy
```

### 2. テストリソース削除

```bash
# RDSインスタンス削除
aws rds delete-db-instance \
  --db-instance-identifier test-mysql-unencrypted \
  --skip-final-snapshot

# パラメーターグループ削除
aws rds delete-db-parameter-group --db-parameter-group-name test-mysql-params

# DBサブネットグループ削除
aws rds delete-db-subnet-group --db-subnet-group-name test-db-subnet-group
```

### 3. RDSインスタンス削除ツール（推奨）

一覧表示から番号で選択して安全に削除：

```bash
# インタラクティブな削除ツール
./scripts/delete-rds-instances.sh
```

**機能:**

- 番号付きインスタンス一覧表示
- 複数選択対応（例: `1,3,5` または `1-3,5`）
- 最終スナップショット作成オプション
- 削除前の確認プロンプト

## 🔒 セキュリティ考慮事項

- **最小権限の原則**: Lambda関数は読み取り専用権限
- **データ保護**: パスワードやセンシティブ情報の非出力
- **通信暗号化**: AWS API通信はHTTPS
- **監査ログ**: CloudWatchによる操作ログ記録

## 📈 今後の拡張案

- [ ] Slack/Teams通知対応
- [ ] カスタムメトリクス収集
- [ ] 自動修復機能
- [ ] Aurora クラスター対応強化
- [ ] Config Rules連携

## 🤝 貢献

1. このリポジトリをフォーク
2. 機能ブランチを作成: `git checkout -b feature/amazing-feature`
3. 変更をコミット: `git commit -m 'Add amazing feature'`
4. ブランチをプッシュ: `git push origin feature/amazing-feature`
5. プルリクエストを作成

## 📄 ライセンス

MIT License - 詳細は[LICENSE](LICENSE)ファイルを参照

## 💻 利用可能なスクリプト

プロジェクトには以下の便利なスクリプトが含まれています：

### NPMスクリプト

```bash
# ビルド関連
npm run build              # TypeScriptコンパイル
npm run build-lambda       # Lambda関数のビルド
npm run watch              # ファイル変更監視

# CDK操作
npm run synth              # CloudFormationテンプレート生成
npm run diff               # デプロイ前の差分確認
npm run deploy             # デプロイ実行
npm run destroy            # スタック削除

# テスト
npm test                   # Jestテスト実行
npm run test-system        # システムテスト実行

# 環境管理
npm run setup-test-env     # テスト環境構築
```

### シェルスクリプト

```bash
# デプロイ・運用
./scripts/deploy.sh           # 対話式デプロイ
./scripts/test.sh             # システムテスト実行
./scripts/setup-test-env.sh   # テスト環境構築
./scripts/cleanup-test-env.sh # テスト環境削除
./scripts/delete-rds-instances.sh # RDSインスタンス削除ツール
```

## 🔧 技術仕様

### 依存関係

**メインプロジェクト**:

- `aws-cdk-lib`: ^2.206.0
- `constructs`: ^10.4.2
- `typescript`: ~5.6.3

**Lambda関数**:

- `@aws-sdk/client-rds`: ^3.0.0
- `@aws-sdk/client-sns`: ^3.0.0
- `@types/aws-lambda`: ^8.10.152

### Lambda関数仕様

| 関数名 | ランタイム | メモリ | タイムアウト | トリガー |
|--------|-----------|--------|-------------|----------|
| RDSParameterAuditFunction | Node.js 18.x | 128MB | 5分 | EventBridge |
| ScheduledRDSParameterAuditFunction | Node.js 18.x | 128MB | 10分 | CloudWatch Events |

### EventBridge Rules

| ルール名 | イベントパターン | 説明 |
|---------|----------------|------|
| RDSCreationEventRule | `aws.rds` DB Instance Event | RDSインスタンス作成・変更 |
| RDSParameterGroupEventRule | `aws.rds` Parameter Group Event | パラメーターグループ変更 |
| ScheduledParameterGroupAudit | Schedule: rate(24 hours) | 定期監査実行 |

## 📚 関連ドキュメント

関連ドキュメントは内部資料として管理されています。

## 📧 サポート

質問や問題がある場合は、GitHubのIssuesでお知らせください。
