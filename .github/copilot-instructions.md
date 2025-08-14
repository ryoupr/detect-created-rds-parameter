# Copilot Instructions (Project-Specific Guide)

このリポジトリで AI コーディングエージェントが即戦力になるための最小かつ実践的な指針。README 全文を再解説せず、設計判断と作業パターンを凝縮しています。

## 1. プロジェクト概要 / 目的

RDS (DBInstance / DBCluster / ParameterGroup) の暗号化/セキュリティ設定を継続監査し、AWS Config の NON_COMPLIANT 変更イベントを Step Functions 経由で Lambda → SNS 通知へ接続する仕組み。設定ファイル駆動で既存インフラ（SNS, Config Recorder, Delivery Channel, S3, IAM Role 等）を再利用可能。

## 2. 主要コンポーネント対応表

| レイヤ                        | 実装場所                            | 主責務                                                                 |
| ----------------------------- | ----------------------------------- | ---------------------------------------------------------------------- |
| CDK Stack                     | `lib/rds-encryption-audit-stack.ts` | Config ルール, EventBridge, Step Functions, Lambda, SNS 構築・タグ付与 |
| Lambda (監査/通知/パラメータ) | `lambda/*.ts`                       | イベント整形 / RDS 詳細取得 / 通知送信 / パラメータグループ評価補助    |
| 設定ファイル                  | `config/*.json` / `stack-config.ts` | 既存 vs 新規リソース選択, メール/SNS, 環境指定                         |
| テスト                        | `test/*.ts`                         | CDK Synth / リソース存在・プロパティ検証                               |
| 補助スクリプト                | `scripts/*.sh`                      | 検証用 RDS/VPC 構築・破棄 (タグ Application=... )                      |

## 3. Step Functions 定義ポリシー

- `definitionBody.fromChainable()` を利用 (旧 `definition` 廃止方向)。
- Choice 分岐: (1) リソース種別 (ParameterGroup 含む) → (2) エンジン種別。
- 末尾は `Succeed` で確実にチェーン終端。`Pass` の後に継ぎ足さない。
- 各 Lambda タスクは分岐毎にインスタンス化 (同一 Task の再利用でチェーン接続エラーを起こさない)。

## 4. イベント JSONPath ルール

AWS Config Compliance Change イベントの ResourceId / ResourceType は:

```
$.detail.newEvaluationResult.evaluationResultIdentifier.evaluationResultQualifier.resourceId
$.detail.newEvaluationResult.evaluationResultIdentifier.evaluationResultQualifier.resourceType
```

他のフィールド参照追加時も `newEvaluationResult.evaluationResultIdentifier` ブロックを起点にする。

## 5. 既存リソース再利用ロジック

`config/<file>.json` で `existingXxxArn` が指定されていればそのリソースを Import し、新規は作成しない。空文字列は使用せず、キーごと削除。再利用対象: SNS Topic / S3 Bucket / Config Role / Recorder / Delivery Channel / (Lambda Role)。

## 6. Lambda 実装スタイル

- 単純なハンドラ (入出力は EventBridge / Config Event JSON)。
- 追加パラメータは環境変数で CDK から注入。
- ログ: `console.log(JSON.stringify(obj))` で構造化寄り (独自ロガー不要)。
- 外部依存軽量維持 (AWS SDK v3 は Node.js 18 ランタイムに同梱 v2 利用で十分なら追加しない)。

## 7. テスト戦略

- `npm test` で ts-jest がオンザフライトランスパイル (事前 `npm run build` 不要)。
- スナップショットは未使用。`expect(stack).toHaveResourceLike` 形式で論理的検証。
- 新規リソース追加時は: (1) CDK Synth で論理 ID 確認 → (2) 既存テストに近い matcher 追加。

## 8. ネーミング / タグ付与

- 生成物共通タグ: 既存コードで `Application` など指定（将来的に環境差分タグを追加する際は衝突回避）。
- ネーミングは `rds-encryption-...` / `rds-parameter-...` プレフィックス踏襲。新規 Lambda も同一規則。

## 9. スクリプト運用 (`scripts/`)

- `setup-test-env.sh`: デフォルト VPC 不在時に検証用 VPC + 2 Subnet 自動生成。MySQL: unencrypted → 失敗時 encrypted フォールバック。Manifest を `.test-env-manifest.env` に出力。
- `cleanup-test-env.sh`: `Application` タグ一致リソースのみ削除。Manifest 参照し custom VPC のみ VPC/サブネット除去。
- コスト配慮のためデフォルトで小さい `db.t3.micro` 使用。自動実行は避け、明示呼び出しのみ。

## 10. 変更時の注意 (回帰防止)

- Step Functions: 既存 Choice 構造を壊す変更はテスト追加 (resourceType / engine 分岐)。
- JSONPath 変更は README とテスト両方更新。
- 既存リソース Import 分岐に新タイプ追加時は: config スキーマ / stack-config.ts / README の対応表 更新。

## 11. 追加実装テンプレ

新しい監査 Lambda を追加する際の最小手順例:

1. `lambda/new-audit-handler.ts` 追加 (handler エクスポート)。
2. Stack 内で `new lambda.Function(...)` 生成し同タグ付与。
3. State Machine 分岐に Task 追加 (既存 Succeed 直前に挿入)。
4. テストで `toHaveResourceLike('AWS::Lambda::Function', { Handler: 'new-audit-handler.handler' })` を追加。

## 12. 禁止 / 非推奨

- EC2 / ECS などの常駐 compute 追加
- 不要な外部 SaaS 連携 (最小構成維持)
- 無根拠な巨大依存パッケージ追加 (軽量継続)

## 13. 迅速な現状確認コマンド

```bash
npm test                # 合否
cdk synth               # テンプレ生成
cdk diff                # 差分
./scripts/setup-test-env.sh SHOW_STATUS=true WAIT_UNTIL_AVAILABLE=true  # 検証環境
```

---

改善余地や不明点があれば該当セクション番号を指定してフィードバックしてください。
