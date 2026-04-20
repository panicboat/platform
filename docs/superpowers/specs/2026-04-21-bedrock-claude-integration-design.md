# bedrock-claude Module Integration Design

## Overview

`aws/claude-code` と `aws/claude-code-action` の2つの Terraform モジュールを、`aws/bedrock-claude` に統合する。
統合後は旧ディレクトリを削除する。

## Architecture

### モジュール構成

```
platform/aws/bedrock-claude/
├── modules/
│   ├── main.tf           # data sources、locals（ARN 計算）、共有 Bedrock ポリシー
│   ├── role_cli.tf       # CLI IAM ロール + ポリシーアタッチ
│   ├── role_actions.tf   # Actions IAM ロール + ポリシーアタッチ
│   ├── variables.tf
│   └── outputs.tf
├── envs/
│   └── develop/
│       ├── env.hcl         # 共通（environment、aws_region、max_session_duration など）
│       ├── cli.hcl         # trusted_principal_arns
│       ├── actions.hcl     # github_repos、oidc_provider_arn
│       └── terragrunt.hcl  # 3つを include して inputs に展開
└── root.hcl
```

### IAM リソース

| リソース | 名前パターン | 用途 |
|----------|-------------|------|
| CLI IAM ロール | `{project}-{env}-claude-code-role`（既存名を維持） | ローカル開発（IAM user が `sts:AssumeRole`） |
| Actions IAM ロール | `{project}-{env}-github-actions-role`（既存名を維持） | CI/CD（GitHub OIDC が `sts:AssumeRoleWithWebIdentity`） |
| Bedrock ポリシー | `{project}-{env}-bedrock-claude-policy`（新規作成） | 両ロールにアタッチ |

> **Note:** ロール名は既存名を維持することでロールの再作成を回避する。名前を変える場合はポリシーアタッチの再作成が発生し、一時的にアクセス不可になる。

### Bedrock ポリシー

Cross-region inference profile 経由でのモデル呼び出しを許可する。

```
inference_profile_arns  →  InvokeModel / InvokeModelWithResponseStream  (条件なし)
foundation_model_arns   →  InvokeModel / InvokeModelWithResponseStream  (bedrock:InferenceProfileArn 条件付き)
*                       →  ListFoundationModels / GetFoundationModel
*                       →  aws-marketplace:ViewSubscriptions / Subscribe
```

条件キーは **`StringLike`** を使用する（`claude-code` モジュールの `StringEquals` バグを修正）。

## Data Flow

```
ローカル開発:
  IAM User → sts:AssumeRole → CLI ロール → Bedrock InvokeModel

GitHub Actions:
  OIDC Token → sts:AssumeRoleWithWebIdentity → Actions ロール → Bedrock InvokeModel
```

## Variables

| 変数 | 型 | デフォルト | 説明 |
|------|----|-----------|------|
| `project_name` | string | — | プロジェクト名 |
| `environment` | string | — | 環境名 |
| `trusted_principal_arns` | list(string) | — | CLI ロールを Assume できる IAM プリンシパル ARN |
| `github_org` | string | — | GitHub 組織名 |
| `github_repos` | list(string) | `[]` | OIDC を許可するリポジトリ |
| `oidc_provider_arn` | string | — | GitHub OIDC プロバイダー ARN |
| `max_session_duration` | number | `3600` | セッション最大時間（秒） |
| `additional_iam_policies` | list(string) | `[]` | 追加でアタッチするポリシー ARN |
| `bedrock_inference_profiles` | list(object) | ※下記 | 許可する inference profile 一覧 |
| `claude_model_region` | string | `us-west-2` | inference profile を作成するリージョン |
| `common_tags` | map(string) | `{}` | 全リソース共通タグ |

**デフォルト inference profiles:**

```hcl
[
  {
    profile_id     = "us.anthropic.claude-sonnet-4-6"
    model_id       = "anthropic.claude-sonnet-4-6"
    source_regions = ["us-east-1", "us-east-2"]
  },
  {
    profile_id     = "us.anthropic.claude-opus-4-7"
    model_id       = "anthropic.claude-opus-4-7"
    source_regions = ["us-east-1", "us-east-2"]
  },
  {
    profile_id     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    model_id       = "anthropic.claude-haiku-4-5-20251001-v1:0"
    source_regions = ["us-east-1", "us-east-2"]
  },
]
```

## Terragrunt Configuration

`terragrunt.hcl` は 3つの hcl ファイルを `include` して `inputs` に展開する。

```hcl
include "root"    { path = find_in_parent_folders("root.hcl") }
include "env"     { path = "env.hcl";     expose = true }
include "cli"     { path = "cli.hcl";     expose = true }
include "actions" { path = "actions.hcl"; expose = true }

inputs = {
  project_name   = "bedrock-claude"
  environment    = include.env.locals.environment
  aws_region     = include.env.locals.aws_region
  # ...共通変数...

  # CLI ロール用
  trusted_principal_arns = include.cli.locals.trusted_principal_arns

  # Actions ロール用
  github_org        = "panicboat"
  github_repos      = include.actions.locals.github_repos
  oidc_provider_arn = include.actions.locals.oidc_provider_arn
}
```

## Migration

既存ロールを `terraform import` で新 state に取り込む。リソースの再作成は不要。

```bash
# CLI ロール（claude-code から）
terraform import 'module.bedrock_claude.aws_iam_role.cli_role' \
  <project>-<env>-cli-role

# Actions ロール（claude-code-action から）
terraform import 'module.bedrock_claude.aws_iam_role.actions_role' \
  <project>-<env>-github-actions-role

# Bedrock ポリシー（新規作成 または 旧ポリシーを import）
terraform import 'module.bedrock_claude.aws_iam_policy.bedrock_policy' \
  arn:aws:iam::<account-id>:policy/<policy-name>
```

Remote state キー: `platform/bedrock-claude/${local.environment}/terraform.tfstate`

## Deletion of Legacy Directories

移行・apply 完了後に以下を削除する:

- `platform/aws/claude-code/`
- `platform/aws/claude-code-action/`

旧 Terraform state ファイル（S3）は手動削除、または残置でも実害なし。

## Error Handling

- `terraform import` 前に `terraform plan` で差分ゼロを確認してから apply
- ポリシーが重複した場合は旧ポリシーを先に削除してから import
- ロール名が変わる場合はアプリケーション側の参照（`workflow-config.yaml` の `iam_role_*`）も更新する

## Testing

- `terraform plan` で変更なし（diff なし）を確認
- `aws sts assume-role` で CLI ロールの Assume が通ることを確認
- GitHub Actions で `configure-aws-credentials` が通ることを確認
- `aws bedrock invoke-model` で Bedrock 呼び出しが通ることを確認
