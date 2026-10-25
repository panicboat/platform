# GCP Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** platform に `gcp/workload-identity/master` と `gcp/billing/master` の terragrunt stack を足し、CI の plan / apply で GCP を扱えるようにする。

**Architecture:** state は既存の S3 bucket に置く。CI では runner がすでに assume している AWS master の plan / apply role を、GCP の Workload Identity Federation で GCP の credential に交換する。権限は federated principal（`principalSet`）に直接付け、service account は作らない。

**Tech Stack:** OpenTofu 1.12.6、terragrunt v1.0.2（どちらも `aqua.yaml`）、`hashicorp/google` provider `~> 8.8`（registry の最新は 8.8.1、VERIFIED）、gcloud CLI

**Spec:** `docs/superpowers/specs/2026-10-25-gcp-foundation-design.md`

## Global Constraints

- state key は `platform/gcp/<service>/<environment>/terraform.tfstate`、bucket は `terragrunt-state-${get_aws_account_id()}`、lock table は `terragrunt-state-locks`、region は `ap-northeast-1`
- GCP のサービス名（`gcp/` 直下のディレクトリ名）は `aws/` 直下のディレクトリ名と重ねない
- 信頼する AWS アカウントは `559744160976` だけ。role 名は `github-oidc-auth-master-github-actions-plan-role` と `github-oidc-auth-master-github-actions-apply-role`
- service account key・GitHub secret を作らない
- module の `terraform.tf` は既存と同じ `required_version = "1.13.1"` を書く
- stack の挙動を決める値は `gcp/<service>/` の中に置く。`gcp/project.hcl` を変えても dispatcher は label を付けず、plan / apply が走らないため。`gcp/project.hcl` には変わらない識別子（`project_id`・`billing_account_id`）と CI の credential の切り替えだけを置く
- テストは `modules/tests/*.tftest.hcl` に置き、`aqua exec -- tofu test` で実行する
- コメントは 1 行。タスクや修正への言及をしない（AGENTS.md）
- commit は `git commit -s`、`Co-Authored-By` を付けない、message は英語（AGENTS.md）
- 手作業（Task 1・3・6）はユーザーが行い、Claude が手順を案内する。Claude は GCP の Console 操作や認証をユーザーに代わって行わない

## Review Focus

- 手元で terragrunt を動かすとき（`GITHUB_ACTIONS` が未設定）は `GOOGLE_APPLICATION_CREDENTIALS` を設定しない。手元の gcloud の credential が使われるべき → Task 4 のテスト
- AWS の develop（`270242382571`）・production（`337169763788`）アカウントの role は、pool に受け付けられない → Task 2 のテスト
- plan role の principal に、変更できる role が 1 つも付かない → Task 2 のテスト
- stack を destroy しても API は無効化されない（他の resource が使っている API を止めない） → Task 2 のテスト
- 予算の通貨は請求先アカウントの通貨と一致しないと作成できない → Task 1 で通貨を控え、Task 5 のテストで入力どおりの通貨と額を使うことを確かめる

---

### Task 1: GCP のアカウント・請求先アカウント・プロジェクトを作る（手作業）

**Files:**
- Create: `gcp/project.hcl`

**Interfaces:**
- Produces: `gcp/project.hcl` の `locals { project_id, billing_account_id }`。Task 4 で `terraform_env_vars` を足す。請求先アカウントの通貨は Task 5 で使う

- [ ] **Step 1: 請求先アカウントを作る**

ユーザーが https://console.cloud.google.com/ で GCP を始め、請求先アカウントを作る。Claude は画面の手順を案内する。
完了条件: `gcloud billing accounts list` に `OPEN: True` の請求先アカウントが 1 つ出る。その ID と通貨（Console の請求先アカウントの概要に表示される）を控える。

- [ ] **Step 2: プロジェクトを作り、請求先アカウントにひも付ける**

プロジェクト ID はユーザーが決める（作成後に変えられない。候補: `panicboat-platform`）。

```bash
gcloud projects create <project_id>
gcloud billing projects link <project_id> --billing-account=<billing_account_id>
```

完了条件: `gcloud billing projects describe <project_id>` が `billingEnabled: true` を返す。

- [ ] **Step 3: `gcp/project.hcl` を書く**

`project_id`・`billing_account_id` を locals に置く。請求先アカウントの通貨は Task 5 の入力に使うので、ユーザーとの会話に控えておく。

- [ ] **Step 4: Commit**

```bash
git add gcp/project.hcl
git commit -s -m "feat(gcp): record the GCP project and billing account"
```

---

### Task 2: `gcp/workload-identity` stack

**Files:**
- Create: `gcp/workload-identity/root.hcl`, `gcp/workload-identity/Makefile`, `gcp/workload-identity/master/terragrunt.hcl`
- Create: `gcp/workload-identity/modules/terraform.tf`, `variables.tf`, `main.tf`, `outputs.tf`
- Test: `gcp/workload-identity/modules/tests/workload_identity.tftest.hcl`

**Interfaces:**
- Consumes: `gcp/project.hcl` の `project_id`
- Produces: output `workload_identity_provider_name`（`google_iam_workload_identity_pool_provider.aws.name`）、`plan_principal`、`apply_principal`（どちらも `principalSet://iam.googleapis.com/<pool name>/attribute.aws_role/<role 名>`）

- [ ] **Step 1: テストを書く**

`mock_provider "google"` を使い、`google_iam_workload_identity_pool` の `name` を `projects/123456789012/locations/global/workloadIdentityPools/terragrunt` に mock する。variables は `project_id = "panicboat-test"`、`aws_account_id = "559744160976"`、`plan_role_name`・`apply_role_name` は Global Constraints の値。`command = apply` で次を検証する。

```hcl
run "restricts_pool_to_master_account" {
  assert {
    condition     = google_iam_workload_identity_pool_provider.aws.attribute_condition == "assertion.arn.startsWith('arn:aws:sts::559744160976:assumed-role/')"
    error_message = "The provider must accept only assumed roles of the master account."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.aws.aws[0].account_id == "559744160976"
    error_message = "The provider must trust the master account."
  }
}

run "maps_the_assumed_role_name" {
  assert {
    condition     = google_iam_workload_identity_pool_provider.aws.attribute_mapping["attribute.aws_role"] == "assertion.arn.extract('assumed-role/{role_name}/')"
    error_message = "The provider must expose the role name as attribute.aws_role."
  }
}

run "grants_only_read_roles_to_the_plan_role" {
  assert {
    condition = toset([for m in google_project_iam_member.this : m.role if m.member == output.plan_principal]) == toset(["roles/viewer", "roles/iam.securityReviewer"])
    error_message = "The plan role must get only read roles."
  }
}

run "grants_admin_roles_to_the_apply_role" {
  assert {
    condition = toset([for m in google_project_iam_member.this : m.role if m.member == output.apply_principal]) == toset(["roles/editor", "roles/resourcemanager.projectIamAdmin", "roles/iam.workloadIdentityPoolAdmin", "roles/serviceusage.serviceUsageAdmin"])
    error_message = "The apply role must get the admin roles."
  }
}

run "keeps_services_enabled_on_destroy" {
  assert {
    condition     = toset(keys(google_project_service.this)) == toset(["iam.googleapis.com", "sts.googleapis.com", "iamcredentials.googleapis.com", "cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com", "billingbudgets.googleapis.com"])
    error_message = "The stack must enable exactly the required services."
  }
  assert {
    condition     = alltrue([for s in google_project_service.this : s.disable_on_destroy == false])
    error_message = "Destroying the stack must not disable services."
  }
}
```

Review Focus の develop・production アカウントの拒否は、`attribute_condition` が master の ID だけを含むことで上の 1 つ目の run が担う。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `cd gcp/workload-identity/modules && aqua exec -- tofu init -backend=false && aqua exec -- tofu test`
Expected: resource が未定義のため FAIL

- [ ] **Step 3: module を実装する**

- `variables.tf`: `project_id`・`aws_account_id`・`plan_role_name`・`apply_role_name`（すべて `string`）
- `terraform.tf`: `hashicorp/google` `~> 8.8`、`provider "google" { project = var.project_id }`
- `main.tf`:
  - `google_project_service.this`（`for_each` は Step 1 の 6 つ、`disable_on_destroy = false`）
  - `google_iam_workload_identity_pool.this`（`workload_identity_pool_id = "terragrunt"`）
  - `google_iam_workload_identity_pool_provider.aws`（`workload_identity_pool_provider_id = "aws"`、`aws { account_id }`、`attribute_mapping` は `google.subject = "assertion.arn"` と Step 1 の `attribute.aws_role`、`attribute_condition` は Step 1 の値）
  - `google_project_iam_member.this`（plan の 2 role と apply の 4 role を `for_each` で展開。key は `"<plan|apply>/<role>"`）
- `outputs.tf`: Interfaces の 3 つ

- [ ] **Step 4: テストが通ることを確かめる**

Run: `cd gcp/workload-identity/modules && aqua exec -- tofu test && aqua exec -- tofu fmt -check -recursive .`
Expected: `5 passed, 0 failed`、fmt の出力なし

- [ ] **Step 5: terragrunt の設定を書く**

- `root.hcl`: `aws/github-oidc-auth/root.hcl` と同じ形。key は `platform/gcp/workload-identity/${local.environment}/terraform.tfstate`。`read_terragrunt_config("${get_repo_root()}/gcp/project.hcl")` の `project_id` を inputs に渡す
- `master/terragrunt.hcl`: `include "root"`、`terraform { source = "../modules" }`、inputs に `aws_account_id`・`plan_role_name`・`apply_role_name`（Global Constraints の値）
- `Makefile`: `aws/github-oidc-auth/Makefile` と同じ target。help の環境一覧は `master` だけ

- [ ] **Step 6: state key を確かめる**

Run: `cd gcp/workload-identity/master && aqua exec -- terragrunt render --json | jq -r '.remote_state.config.key'`
Expected: `platform/gcp/workload-identity/master/terraform.tfstate`

- [ ] **Step 7: Commit**

```bash
git add gcp/workload-identity
git commit -s -m "feat(gcp): add the workload identity stack for terragrunt in CI"
```

---

### Task 3: `gcp/workload-identity/master` を手元から apply する（手作業）

**Interfaces:**
- Consumes: Task 2 の stack
- Produces: GCP 上の pool・provider・IAM、output `workload_identity_provider_name`

- [ ] **Step 1: 手元の credential を用意する**

ユーザーが実行する。AWS は master アカウント（state の S3 を読み書きできる credential）を使う。

```bash
gcloud auth login
gcloud auth application-default login
gcloud auth application-default set-quota-project <project_id>
```

完了条件: `gcloud auth application-default print-access-token` が token を返す。

- [ ] **Step 2: plan して確かめる**

Run: `cd gcp/workload-identity && make plan ENV=master`
Expected: pool 1・provider 1・IAM member 6・service 6 の追加だけで、変更・削除がない

- [ ] **Step 3: apply する**

Run: `cd gcp/workload-identity && make apply ENV=master && make output ENV=master`
Expected: `workload_identity_provider_name` が `projects/<number>/locations/global/workloadIdentityPools/terragrunt/providers/aws`

---

### Task 4: CI で GCP の credential を使えるようにする

**Files:**
- Create: `gcp/credential-configuration.json`
- Modify: `gcp/project.hcl`、`gcp/workload-identity/root.hcl`、`workflow-config.yaml`（terragrunt の `paths`）、`README.md`、`README-ja.md`

**Interfaces:**
- Consumes: Task 3 の `workload_identity_provider_name`
- Produces: `gcp/project.hcl` の `terraform_env_vars`（map(string)）。`gcp/*/root.hcl` は `terraform { extra_arguments "gcp_credentials" { commands = get_terraform_commands_that_need_vars() ... env_vars = local.project.locals.terraform_env_vars } }` で使う

- [ ] **Step 1: credential の設定ファイルを作る**

Run: `gcloud iam workload-identity-pools create-cred-config <workload_identity_provider_name> --aws --output-file=gcp/credential-configuration.json`
Expected: `subject_token_type` が `urn:ietf:params:aws:token-type:aws4_request` の JSON ができ、秘密情報（key・token）を含まない

- [ ] **Step 2: 切り替えが動かないことを確かめる（失敗するテスト）**

Run: `cd gcp/workload-identity/master && GITHUB_ACTIONS=true aqua exec -- terragrunt render --json | jq -r '.terraform.extra_arguments.gcp_credentials.env_vars.GOOGLE_APPLICATION_CREDENTIALS'`
Expected: `null`（まだ設定していない）

- [ ] **Step 3: `terraform_env_vars` と `extra_arguments` を実装する**

`terraform_env_vars` は `get_env("GITHUB_ACTIONS", "") == "true"` のときだけ `{ GOOGLE_APPLICATION_CREDENTIALS = "${get_repo_root()}/gcp/credential-configuration.json" }`、それ以外は `{}`。

- [ ] **Step 4: CI と手元の両方を確かめる**

Run: `cd gcp/workload-identity/master && GITHUB_ACTIONS=true aqua exec -- terragrunt render --json | jq -r '.terraform.extra_arguments.gcp_credentials.env_vars.GOOGLE_APPLICATION_CREDENTIALS'`
Expected: `.../gcp/credential-configuration.json` で終わるパス

Run: `cd gcp/workload-identity/master && env -u GITHUB_ACTIONS aqua exec -- terragrunt render --json | jq -c '.terraform.extra_arguments.gcp_credentials.env_vars'`
Expected: `{}`

- [ ] **Step 5: `workflow-config.yaml` に GCP の path を足す**

terragrunt stack の `paths` に `"gcp/{service}/{environment}"` を足す。

- [ ] **Step 6: 設定の検証を通す**

Run: `bash ../../../.github/scripts/terragrunt-release/validate-apply-trigger.sh workflow-config.yaml && bash ../../../.github/scripts/terragrunt-release/check-release-configs.sh workflow-config.yaml && comm -12 <(ls aws) <(ls gcp)`
Expected: 2 つの script が exit 0 で、`comm` の出力が空（`aws/` と同名のものが `gcp/` 直下にない）

- [ ] **Step 7: README を更新する**

`README.md` と `README-ja.md` の stack 一覧・ディレクトリ構成・Authentication の節に `gcp/` を足す。Authentication には「CI は AWS master の plan / apply role を GCP の Workload Identity Federation で GCP の credential に交換する」ことと、初回の bootstrap（Task 1・3・6 の手作業）を書く。

- [ ] **Step 8: Commit**

```bash
git add gcp workflow-config.yaml README.md README-ja.md
git commit -s -m "feat(gcp): run the GCP stacks in CI with the AWS roles"
```

---

### Task 5: `gcp/billing` stack

**Files:**
- Create: `gcp/billing/root.hcl`、`gcp/billing/Makefile`、`gcp/billing/master/terragrunt.hcl`
- Create: `gcp/billing/modules/terraform.tf`、`variables.tf`、`main.tf`、`outputs.tf`
- Test: `gcp/billing/modules/tests/budget.tftest.hcl`

**Interfaces:**
- Consumes: `gcp/project.hcl` の `project_id`・`billing_account_id`・`terraform_env_vars`、Task 1 で控えた請求先アカウントの通貨
- Produces: output `budget_name`

- [ ] **Step 1: テストを書く**

`mock_provider "google"`、variables は `project_id = "panicboat-test"`、`billing_account_id = "000000-000000-000000"`、`budget_currency_code = "JPY"`、`budget_amount = 800`。

```hcl
run "sets_the_monthly_budget" {
  command = plan
  assert {
    condition     = google_billing_budget.monthly.amount[0].specified_amount[0].currency_code == "JPY" && google_billing_budget.monthly.amount[0].specified_amount[0].units == "800"
    error_message = "The budget must use the given currency and amount."
  }
}

run "notifies_at_each_threshold" {
  command = plan
  assert {
    condition     = [for r in google_billing_budget.monthly.threshold_rules : r.threshold_percent] == [0.5, 0.9, 1.0]
    error_message = "The budget must notify at 50%, 90% and 100%."
  }
}
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `cd gcp/billing/modules && aqua exec -- tofu init -backend=false && aqua exec -- tofu test`
Expected: FAIL

- [ ] **Step 3: module を実装する**

- `variables.tf`: `project_id`（string）、`billing_account_id`（string）、`budget_currency_code`（string）、`budget_amount`（number）
- `terraform.tf`: `provider "google" { project = var.project_id, billing_project = var.project_id, user_project_override = true }`（Budget API の quota project をこのプロジェクトにするため）
- `main.tf`: `google_billing_budget.monthly`（`display_name = "monthly"`、`budget_filter` は付けず請求先アカウント全体を対象にする、`threshold_rules` は 0.5・0.9・1.0）

- [ ] **Step 4: テストが通ることを確かめる**

Run: `cd gcp/billing/modules && aqua exec -- tofu test && aqua exec -- tofu fmt -check -recursive .`
Expected: `2 passed, 0 failed`、fmt の出力なし

- [ ] **Step 5: terragrunt の設定を書き、state key を確かめる**

`root.hcl`・`master/terragrunt.hcl`・`Makefile` は Task 2 Step 5 と同じ形（key は `platform/gcp/billing/${local.environment}/terraform.tfstate`、`extra_arguments "gcp_credentials"` も同じ）。`master/terragrunt.hcl` の inputs に `budget_currency_code`（Task 1 の通貨）と `budget_amount`（月 5 USD 相当の整数。USD なら `5`、JPY なら `800`）を置く。

Run: `cd gcp/billing/master && aqua exec -- terragrunt render --json | jq -r '.remote_state.config.key'`
Expected: `platform/gcp/billing/master/terraform.tfstate`

- [ ] **Step 6: Commit**

```bash
git add gcp/billing
git commit -s -m "feat(gcp): add a monthly budget alert to the billing account"
```

---

### Task 6: 請求先アカウントの権限を付ける（手作業）

**Interfaces:**
- Consumes: Task 3 の output `plan_principal`・`apply_principal`

- [ ] **Step 1: plan と apply の principal に権限を付ける**

ユーザーが実行する。

```bash
gcloud billing accounts add-iam-policy-binding <billing_account_id> --member='<plan_principal>' --role=roles/billing.viewer
gcloud billing accounts add-iam-policy-binding <billing_account_id> --member='<apply_principal>' --role=roles/billing.costsManager
```

完了条件: `gcloud billing accounts get-iam-policy <billing_account_id>` に 2 つの binding が出る。
`principalSet` を member に指定できずエラーになったら、spec の Budget の節に従い service account を経由する方式に切り替える。そのときは Task 2 に plan 用・apply 用の service account と `roles/iam.workloadIdentityUser` を足し、Task 4 の設定ファイルを `--service-account` 付きで作り直す（plan か apply かで設定ファイルを分ける必要が出るので、ユーザーに相談してから進める）。

---

### Task 7: Draft PR を作り、CI の plan を確かめる

- [ ] **Step 1: push して Draft PR を作る**

`.github/pull_request_template.md`（なければ `panicboat/.github` のテンプレート）の見出しに従って本文を書く。

```bash
git push -u origin HEAD
gh pr create --draft --title "feat: provision GCP from platform with terragrunt" --body-file <本文>
```

- [ ] **Step 2: label を付けて CI の plan を確かめる**

dispatcher が `deploy:workload-identity` と `deploy:billing` を付けることを確かめる。
Expected:
- `workload-identity:master` の plan が `No changes`（Task 3 で apply 済みで、CI の credential で GCP を読めている）
- `billing:master` の plan が `google_billing_budget.monthly` の 1 件追加だけ
- `github-oidc-auth` の plan は走らない

- [ ] **Step 3: ユーザーに渡す**

merge はユーザーが行う。merge 後、`billing:master` の apply が成功し、Console の予算一覧に `monthly` が出ることをユーザーと確かめる。
