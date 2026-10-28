# GCP project layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `gcp/<表示名>/<stack>/master` の構成にし、CI 専用 project `github-actions-master` を Terraform で作って CI が GCP に入れる状態に戻し、`google-oauth-production` の API と IAM を管理する。

**Architecture:** platform の terragrunt + OpenTofu。`github-actions-master/foundation` が project と Workload Identity を持ち、`google-oauth-production/project` が foundation の output（CI の principal）を dependency で受け取る。組織・請求先アカウントの権限と、管理外の API の無効化は手元から 1 回だけ行う。

**Tech Stack:** terragrunt v1.0.2、OpenTofu v1.12.6、hashicorp/google `~> 8.8`、gcloud。

**Spec:** `docs/superpowers/specs/2026-10-28-gcp-project-layout-design.md`

## Global Constraints

- コメントは英語で 1 行、"why not" だけ。タスクへの言及を書かない。
- コミットは `git commit -s`、`Co-Authored-By` を付けない。
- `aws/` のサービス名と重なる stack 名を使わない（`foundation`・`project` は重ならない）。
- 手元の apply は master アカウントの AWS credential（`AWS_PROFILE=default`）と gcloud の ADC で行う。
- plan ロール名 `github-oidc-auth-master-github-actions-plan-role`、apply ロール名 `github-oidc-auth-master-github-actions-apply-role`、AWS アカウント `559744160976`、組織 `731586494509`、請求先アカウント `01830F-ABC0AE-C3E6D2`。

## Review Focus

- plan ロールの principal が、どの project でも変更系の role を持たない（Task 1・Task 3 のテスト）。
- `google-oauth-production` の API を無効にした後も oauth2-proxy でログインできる（Task 4 の確認）。
- `github-actions-master` の project が誤って destroy されない（Task 1 のテスト）。

---

### Task 1: foundation module

**Files:**
- Create: `gcp/github-actions-master/project.hcl`、`gcp/github-actions-master/foundation/{root.hcl,Makefile,master/terragrunt.hcl,modules/*.tf,modules/tests/foundation.tftest.hcl}`
- Delete: `gcp/workload-identity/`、`gcp/billing/`、`gcp/project.hcl`

**Interfaces:**
- Produces: outputs `project_id`、`project_number`、`workload_identity_provider_name`、`plan_principal`、`apply_principal`

- [ ] **Step 1:** 今の `gcp/workload-identity/modules` を `foundation/modules` に移し、`google_project`（`project_id`/`name` = `github-actions-master`、`org_id`、`billing_account`、既定 network なし、削除防止）を足す。API から `billingbudgets` を外し `cloudbilling` を足す。quota 用の `serviceusage.serviceUsageConsumer` を plan から外す。`google_project` の属性名は provider のドキュメント（8.x）で確かめる。
- [ ] **Step 2:** テスト: 既存の 4 つ（master のアカウントだけ、role 名の取り出し、plan は閲覧だけ、apply は変更可）を移し、project が削除防止であることと既定 network を作らないことを足す。`tofu test`（`foundation/modules` で）が通る。
- [ ] **Step 3:** root.hcl は `../project.hcl` を読み、key は `platform/${get_path_from_repo_root()}/terraform.tfstate`。`terragrunt render` で key が `platform/gcp/github-actions-master/foundation/master/terraform.tfstate` になる。
- [ ] **Step 4:** Commit `refactor: move the GCP workload identity into the github-actions-master project`

### Task 2: Bootstrap github-actions-master（手元）

- [ ] **Step 1:** ユーザーが `gcloud auth application-default login` を実行済みであることを確かめる。
- [ ] **Step 2:** `AWS_PROFILE=default terragrunt apply`（`foundation/master`）。project・API・pool・provider・IAM ができる。
- [ ] **Step 3:** gcloud で組織に `roles/browser`（plan）と `roles/resourcemanager.projectCreator`（apply）、請求先アカウントに `roles/billing.viewer`（plan）と `roles/billing.user`（apply）を、principal set に付ける。
- [ ] **Step 4:** `gcloud iam workload-identity-pools create-cred-config <provider name> --aws --output-file=gcp/credential-configuration.json`。
- [ ] **Step 5:** 再度 plan して差分なし。Commit `chore: point the GCP credential configuration at the github-actions-master pool`

### Task 3: google-oauth-production/project

**Files:**
- Create: `gcp/google-oauth-production/project.hcl`（ID `panicboat-platform-auth`）、`gcp/google-oauth-production/project/{root.hcl,Makefile,master/terragrunt.hcl,modules/*.tf,modules/tests/project.tftest.hcl}`

**Interfaces:**
- Consumes: Task 1 の `plan_principal`・`apply_principal`（terragrunt `dependency`、plan 時の mock outputs あり）

- [ ] **Step 1:** module: `google_project_service`（`cloudresourcemanager`・`serviceusage`・`iam`、`disable_on_destroy = false`）と `google_project_iam_member`（owner `user:iam@panicboat.net`、plan に閲覧の role、apply に foundation と同じ変更の role）。
- [ ] **Step 2:** テスト: plan の principal に閲覧の role だけ、owner の user が残る。`tofu test` が通る。
- [ ] **Step 3:** 既存の API 3 つと owner を `import` block で取り込み、手元で apply。再度 plan して差分なし。
- [ ] **Step 4:** Commit `feat: manage the APIs and IAM of the google-oauth-production project`

### Task 4: Clean up（手元）

- [ ] **Step 1:** `google-oauth-production` で、残す 3 つ以外の API を `gcloud services disable` で無効にする。
- [ ] **Step 2:** oauth2-proxy で守っているサービス（EKS 上で稼働中のもの）にログインできることを確かめる。EKS が止まっていてサービスがなければ、OAuth client が無効になっていないこと（`gcloud` で project の状態）だけを確かめる。
- [ ] **Step 3:** 予算 `billingAccounts/01830F-ABC0AE-C3E6D2/budgets/28208f3d-6b1e-49fa-a1cd-96ad737240f9` を消す（quota project には `github-actions-master` を一時的に使い、使った API は戻す）。
- [ ] **Step 4:** S3 の `platform/gcp/billing/master/terraform.tfstate` と `platform/gcp/workload-identity/master/terraform.tfstate` と、その digest を消す。

### Task 5: CI wiring and docs

**Files:**
- Modify: `workflow-config.yaml`（`gcp/{project}/{service}/{environment}`）、`README.md`（GCP の行と、組織・請求先アカウントの権限を手元で付けること）

- [ ] **Step 1:** 変更して commit `ci: plan and apply GCP stacks under their project directory`
- [ ] **Step 2:** push して Draft PR。deploy ラベル（`deploy:foundation`・`deploy:project`）で CI の plan が 2 つとも差分なしになることを確かめる。
