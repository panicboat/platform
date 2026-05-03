# aws/cost-management — Cost Optimization Hub & Compute Optimizer Enrollment Design

## Purpose

AWS アカウント `559744160976` で **Cost Optimization Hub** および **Compute Optimizer** を有効化し、コスト最適化推奨を取得できる状態にする。両サービスとも account-level の opt-in が必要で、有効化しない限り推奨が一切提示されない。

## Scope

- 新規 Terragrunt サービス `aws/cost-management/` を追加する。
- 含めるリソース:
  - `aws_costoptimizationhub_enrollment_status`
  - `aws_costoptimizationhub_preferences`
  - `aws_computeoptimizer_enrollment_status`
- `develop` 環境（us-east-1）にのみデプロイする。Cost Optimization Hub / Compute Optimizer の API home region が `us-east-1` 固定であること、および両サービスとも account-wide enrollment であり同一アカウントを共有する `develop` / `production` 双方にデプロイすると衝突することの両方の理由から、`develop` のみとする。

## Out of Scope

- AWS Organization 連携。本アカウントは standalone のため `include_member_accounts = false` / `member_account_discount_visibility = "None"` 固定。Organization 導入時に再設計する。
- `aws_computeoptimizer_recommendation_preferences`（CPU vendor preference 等の細かいチューニング）。推奨が出てから必要に応じて追加。
- `github-oidc-auth` ロールへの IAM 権限追加。本サービスのデプロイには `cost-optimization-hub:*` および `compute-optimizer:*` の権限が必要だが、最小特権の権限定義は別 PR で扱う。本 PR ではローカルからの `terragrunt apply` を前提にする（README に明記）。
- Cost Optimization Hub / Compute Optimizer の推奨を Slack 等に通知するパイプライン。

## Architecture

### Service Layout

既存の `aws/{service}/modules + envs/{env}` 慣習に沿う。

```
aws/cost-management/
├── root.hcl
├── modules/
│   ├── terraform.tf              # provider, region 固定
│   ├── variables.tf
│   ├── cost_optimization_hub.tf  # enrollment + preferences
│   ├── compute_optimizer.tf      # enrollment
│   └── outputs.tf                # 空（output なし）
└── envs/
    └── develop/
        ├── env.hcl
        └── terragrunt.hcl
```

### Region Pinning

Cost Optimization Hub / Compute Optimizer の API は **us-east-1 のみで動作**する。`modules/terraform.tf` の `provider "aws"` で region を `"us-east-1"` ハードコードし、`var.aws_region` には依存させない。理由: 将来 `develop` 環境が別リージョンに移った場合でも Cost Management サービスは us-east-1 のまま稼働する必要があるため、env の region に依存させると壊れる。

### Resources

#### Cost Optimization Hub (`cost_optimization_hub.tf`)

`aws_costoptimizationhub_enrollment_status` リソースには provider 側の bug ([hashicorp/terraform-provider-aws#39520](https://github.com/hashicorp/terraform-provider-aws/issues/39520)) があり、毎回 plan で `+ include_member_accounts = false` / `~ status -> (known after apply)` の 1 件 perpetual diff が発生する。`lifecycle.ignore_changes`（`= all` を含む）でも、HCL から該当属性を消した上で `terragrunt import` し直しても抑止不可能 (現地検証済み)。

そのため **`terraform_data` + `local-exec` で AWS CLI を呼び出す workaround** を採用する:

```hcl
resource "terraform_data" "cost_optimization_hub_enrollment" {
  triggers_replace = {
    version = "v1"
  }

  provisioner "local-exec" {
    command = "aws cost-optimization-hub update-enrollment-status --status Active --region us-east-1"
  }
}
```

- `triggers_replace.version` を bump すると再 enroll される。enroll API は idempotent (Active なアカウントを再 Active にしても no-op)。
- `gruntwork-io/terragrunt-action@v3.2.0` は composite action で GitHub Actions ubuntu runner で直接動作するため、AWS CLI は標準で利用可能。
- 上流 issue が解消されたら native resource (`aws_costoptimizationhub_enrollment_status`) に戻す。

`aws_costoptimizationhub_preferences` は別の provider bug で apply 不能のため管理外:

- provider が `member_account_discount_visibility` を未指定でもデフォルト値 `"All"` で API に送る
- AWS は non-management account に対し `ValidationException: Only management accounts can update member account discount visibility.` で拒否
- AWS デフォルト `savings_estimation_mode = "AfterDiscounts"` で運用 (`aws cost-optimization-hub get-preferences` で確認)。standalone account には enterprise discount 契約が無いため `BeforeDiscounts` と `AfterDiscounts` は同じ値を返す
- Organization の management account になった時点で再評価する

#### Compute Optimizer (`compute_optimizer.tf`)

```hcl
resource "aws_computeoptimizer_enrollment_status" "this" {
  status                  = "Active"
  include_member_accounts = false
}
```

### Outputs

両サービスとも他の Terraform stack から参照する値を持たない。`outputs.tf` は空ファイルとして作成する（既存サービスとの構成一貫性のため）。

### Module File Split

Cost Optimization Hub と Compute Optimizer は独立した 2 サービスのため、`vpc/main.tf` のような単一ファイル集約ではなく、`ai-assistant/role_actions.tf` + `role_cli.tf` の先例に倣って 2 ファイルに分割する。

### Terragrunt Configuration

#### `aws/cost-management/root.hcl`

`vpc/root.hcl` を踏襲。差分:

- `project_name = "cost-management"`
- `Component = "cost-management"`
- state key: `platform/cost-management/${local.environment}/terraform.tfstate`
- `inputs` から `aws_region` を **削除**（modules 側で固定するため、env から渡しても無視される。混乱を避ける）。

#### `aws/cost-management/envs/develop/env.hcl`

```hcl
locals {
  environment = "develop"
  aws_region  = "us-east-1"

  environment_tags = {
    Environment = local.environment
    Purpose     = "cost-management"
    Owner       = "panicboat"
  }
}
```

#### `aws/cost-management/envs/develop/terragrunt.hcl`

`vpc/envs/production/terragrunt.hcl` と同形。`include` で `root` と `env` を合成し、`source = "../../modules"` を指定。`inputs` で `environment` / `common_tags` を渡し、`aws_region` は渡さない。

### Variables

`modules/variables.tf` は以下のみ:

- `environment` (string)
- `common_tags` (map(string), default `{}`)

`aws_region` 変数は **定義しない**（modules 側で region を固定するため）。

### CI / workflow-config.yaml への影響

`aws/cost-management/envs/develop/` ディレクトリができれば、既存の `stack_conventions` ルール `aws/{service}` にマッチして CI が自動的に動く。`workflow-config.yaml` への変更は不要。

ただし IAM 権限が現状の plan / apply ロールに不足している可能性が高いため、初回 CI apply はおそらく失敗する。本 PR の範囲ではローカルからの手動 apply を前提とし、IAM 権限追加は別 PR で対応する。

## Testing / Verification

- `terragrunt plan` がエラーなく完了し、3 リソースの create が予定されること。
- ローカルから `terragrunt apply` 実行後、AWS Console の Cost Optimization Hub に "Enrolled" 表示が出ること。
- AWS Console の Compute Optimizer ダッシュボードに "Opted In" 表示が出ること。
- 推奨データの生成には数時間〜24 時間かかるため、apply 直後の推奨表示までは検証範囲外。

## Migration / Rollback

- 既存リソースなし。新規構築のみ。
- ロールバックは `terragrunt destroy` で 3 リソースを削除すれば opt-out 状態に戻る（過去推奨履歴は AWS 側で破棄される）。

## Follow-ups (Out of This PR)

1. `aws/github-oidc-auth/` の plan / apply ロールに `cost-optimization-hub:*` および `compute-optimizer:*` の最小権限を追加し、CI から apply 可能にする。
2. AWS Organization を導入する際に、`include_member_accounts` / `member_account_discount_visibility` を再評価する。
3. Compute Optimizer の `recommendation_preferences` を必要に応じて追加（CPU vendor preference 等）。
