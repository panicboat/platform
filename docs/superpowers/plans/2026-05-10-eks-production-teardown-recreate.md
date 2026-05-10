# EKS Production Teardown + Recreate Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster `eks-production` の temporary teardown と冪等な recreate を、手元の `make eks-teardown ENV=production` / `make eks-recreate ENV=production` で実行できる lifecycle 機構を構築する。

**Architecture:** 3 Phase 順次実装。Phase 1 = S3 bucket の `force_destroy = true` 追加 (= attribute-only)。Phase 2 = IRSA / Karpenter node role の deterministic 化 + helmfile gotmpl の cluster 固有値を terragrunt output から hydrate-time に取得 (= atomic な大きな変更)。Phase 3 = `scripts/eks-lifecycle/` + root `Makefile` 新設で teardown / recreate orchestration script を実装。

**Tech Stack:** Terragrunt 0.83.2 + OpenTofu 1.6.0、Helmfile v1.4 + Kustomize、Flux CD、AWS CLI、kubectl、bash + Make。

**Spec reference:** `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md`

---

## File Structure

### Phase 1 で modify するファイル

- `aws/eks-logs/modules/main.tf` — S3 bucket resource に `force_destroy = true` 追加
- `aws/eks-metrics/modules/main.tf` — 同上
- `aws/eks-traces/modules/main.tf` — 同上

### Phase 2 で modify / create するファイル

- `aws/eks/modules/outputs.tf` — `cluster_endpoint_hostname` output 追加
- `aws/eks/modules/addons.tf` — `module "alb_controller_irsa"` / `module "external_dns_irsa"` に `use_name_prefix = false` 追加
- `aws/karpenter/modules/main.tf` — `module "karpenter"` に node IAM role deterministic 化 variable 追加
- `kubernetes/helmfile.yaml.gotmpl` — production env block の cluster 固有値を `exec terragrunt output` 化
- `kubernetes/components/cilium/production/helmfile.yaml` — `eksApiEndpoint` を `exec` 化
- `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml` — `albControllerRoleArn` / `vpcId` を `exec` 化
- `kubernetes/components/external-dns/production/helmfile.yaml` — `externalDnsRoleArn` を `exec` 化
- `.github/workflows/reusable--kubernetes-hydrator.yaml` — AWS OIDC + terragrunt setup step 追加
- `.github/aqua.yaml` — terragrunt + tofu パッケージ追加

### Phase 3 で create するファイル

- `Makefile` (repo root) — `eks-teardown` / `eks-recreate` targets
- `scripts/eks-lifecycle/README.md` — 利用方法 / 前提
- `scripts/eks-lifecycle/teardown.sh` — entry point
- `scripts/eks-lifecycle/recreate.sh` — entry point
- `scripts/eks-lifecycle/lib/common.sh` — ログ / fail fast / DRY_RUN wrapper
- `scripts/eks-lifecycle/lib/00-auth.sh` — apply role + admin role assume
- `scripts/eks-lifecycle/lib/10-k8s-cleanup.sh` — kubectl delete ingress / LB svc / Karpenter NodePool
- `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` — 8 stack を固定順で terragrunt destroy
- `scripts/eks-lifecycle/lib/40-orphan-verify.sh` — ENI / EBS / target group / SG / Route53 / CloudWatch log group の orphan 検出
- `scripts/eks-lifecycle/lib/50-apply-stacks.sh` — 8 stack を固定順で terragrunt apply
- `scripts/eks-lifecycle/lib/60-flux-bootstrap.sh` — re-hydrate + git push + flux bootstrap
- `scripts/eks-lifecycle/lib/70-reconcile-watch.sh` — Phase 単位で HelmRelease Ready wait

---

# Phase 1: S3 force_destroy

各 S3 bucket に `force_destroy = true` を追加し、teardown 時の bucket destroy 失敗を回避する。3 module はほぼ同一構造の変更。

### Task 1.1: aws/eks-logs に force_destroy 追加

**Files:**
- Modify: `aws/eks-logs/modules/main.tf`

注: S3 bucket は raw `aws_s3_bucket` resource ではなく `module "s3"` 経由 (= `terraform-aws-modules/s3-bucket/aws` v5.13.0) で作成されている。`force_destroy` は同 module の input variable としてサポートされているため、module block の top-level argument として追加する。

- [ ] **Step 1: 現状確認**

```bash
grep -B1 -A10 'module "s3"' aws/eks-logs/modules/main.tf
```

Expected: `module "s3"` ブロックに `force_destroy` 引数が無い

- [ ] **Step 2: `force_destroy = true` を追加**

`aws/eks-logs/modules/main.tf` の `module "s3"` ブロック内、`bucket = local.bucket_name` の直後（空行を挟んで）に追加:

```hcl
  force_destroy = true
```

- [ ] **Step 3: terraform fmt + validate**

```bash
cd aws/eks-logs && terraform fmt -recursive modules/
cd aws/eks-logs/envs/production && TG_TF_PATH=tofu terragrunt validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: terragrunt plan で確認**

```bash
cd aws/eks-logs/envs/production && TG_TF_PATH=tofu terragrunt plan
```

Expected: `~ resource "aws_s3_bucket" ... force_destroy = true` (in-place update のみ、再作成なし)

- [ ] **Step 5: Commit**

```bash
git add aws/eks-logs/modules/main.tf
git commit -s -m "feat(eks-logs): add force_destroy to S3 bucket

teardown 時の bucket 内オブジェクト削除を terragrunt destroy に
任せられるよう force_destroy = true を追加。

Phase 1 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 1.2: aws/eks-metrics に force_destroy 追加

**Files:**
- Modify: `aws/eks-metrics/modules/main.tf`

- [ ] **Step 1: 現状確認 + 同じ変更を `aws/eks-metrics/modules/main.tf` に適用**

```bash
grep -B1 -A10 'module "s3"' aws/eks-metrics/modules/main.tf
```

Task 1.1 と同じく `force_destroy = true` を `module "s3"` ブロックに追加 (= `bucket = local.bucket_name` の直後)。

- [ ] **Step 2: terraform fmt + plan**

```bash
cd aws/eks-metrics && terraform fmt -recursive modules/
cd aws/eks-metrics/envs/production && TG_TF_PATH=tofu terragrunt plan
```

Expected: in-place update のみ

- [ ] **Step 3: Commit**

```bash
git add aws/eks-metrics/modules/main.tf
git commit -s -m "feat(eks-metrics): add force_destroy to S3 bucket

Phase 1 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 1.3: aws/eks-traces に force_destroy 追加

**Files:**
- Modify: `aws/eks-traces/modules/main.tf`

- [ ] **Step 1: 同じ変更を `aws/eks-traces/modules/main.tf` に適用**

`force_destroy = true` を `module "s3"` ブロックに追加 (= `bucket = local.bucket_name` の直後)。

- [ ] **Step 2: terraform fmt + plan**

```bash
cd aws/eks-traces && terraform fmt -recursive modules/
cd aws/eks-traces/envs/production && TG_TF_PATH=tofu terragrunt plan
```

Expected: in-place update のみ

- [ ] **Step 3: Commit**

```bash
git add aws/eks-traces/modules/main.tf
git commit -s -m "feat(eks-traces): add force_destroy to S3 bucket

Phase 1 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 1.4: Phase 1 PR + apply 検証

- [ ] **Step 1: Phase 1 ブランチを push、Draft PR 作成**

```bash
git push -u origin HEAD
gh pr create --draft --title "feat(eks-{logs,metrics,traces}): add force_destroy to S3 buckets" \
  --body "Phase 1 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

teardown 時の S3 bucket destroy が hang しないよう force_destroy = true を 3 module に追加。
attribute-only 変更で resource recreate なし。"
```

- [ ] **Step 2: PR ready for review に変更 → CI plan job 完了確認**

```bash
gh pr ready
gh pr checks
```

Expected: terragrunt plan job が SUCCESS、diff は in-place update のみ

- [ ] **Step 3: Merge**

```bash
gh pr merge --squash --delete-branch
```

- [ ] **Step 4: main で apply 完了を確認**

```bash
gh run list --limit 5
```

CI apply ジョブが SUCCESS したことを確認。

- [ ] **Step 5: terragrunt show で state に force_destroy 反映確認**

```bash
cd aws/eks-logs/envs/production && TG_TF_PATH=tofu terragrunt show -json | jq '.. | objects | select(.type? == "aws_s3_bucket") | .values.force_destroy' | head -5
```

Expected: `true`

同じく eks-metrics / eks-traces も確認。

---

# Phase 2: Deterministic naming + hydrate-time substitution

Phase 2 は IRSA / Karpenter node role の deterministic 化と helmfile gotmpl の cluster 固有値を terragrunt output から hydrate-time に取得する変更を **同一 PR で atomic に適用** する。

### Task 2.1: Karpenter sub-module の deterministic 化 variable を investigation

**Files:**
- Read: `terraform-aws-modules/eks/aws//modules/karpenter` v21.19.0 の variable docs

- [ ] **Step 1: GitHub 上 module ソースを確認**

```bash
# HTTPie or curl で
curl -sL "https://raw.githubusercontent.com/terraform-aws-modules/terraform-aws-eks/v21.19.0/modules/karpenter/variables.tf" | grep -A3 "node_iam_role_use_name_prefix\|node_iam_role_name "
```

または web 上で `https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.19.0/modules/karpenter/variables.tf` を開いて確認。

- [ ] **Step 2: variable 名を確定**

期待値: `node_iam_role_use_name_prefix` (= bool, default `true`) が存在。代替策: `node_iam_role_name` を直接指定して固定名にする。

確認結果を以下のいずれかでメモして、Task 2.4 で使う:
- (A) `node_iam_role_use_name_prefix = false` をサポート → これを採用
- (B) サポートなし → `node_iam_role_name = "Karpenter-eks-production"` を直接指定

- [ ] **Step 3: 確定した variable 名 + 値を後続 task が参照できるようコメントに記録**

Task 2.4 step 1 の冒頭コメント `# variable: <NAME> = <VALUE> per Task 2.1 investigation` に書く（実装タスク内で確定値を挿入する形）。

---

### Task 2.2: aws/eks/modules/outputs.tf に cluster_endpoint_hostname 追加

**Files:**
- Modify: `aws/eks/modules/outputs.tf`

- [ ] **Step 1: 既存 outputs を確認**

```bash
grep -E "^output" aws/eks/modules/outputs.tf
```

Expected: `cluster_endpoint` あり、`cluster_endpoint_hostname` なし

- [ ] **Step 2: `cluster_endpoint_hostname` output 追加**

`aws/eks/modules/outputs.tf` の `cluster_endpoint` output の直後に追加:

```hcl
output "cluster_endpoint_hostname" {
  description = "EKS cluster API endpoint hostname (without https:// prefix). Consumed by Cilium k8sServiceHost via helmfile exec."
  value       = replace(module.eks.cluster_endpoint, "https://", "")
}
```

- [ ] **Step 3: terraform fmt + validate**

```bash
cd aws/eks && terraform fmt -recursive modules/
cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt validate
```

Expected: Success

- [ ] **Step 4: 一旦 commit (= 後続の addons.tf 変更とは独立した output 追加)**

```bash
git add aws/eks/modules/outputs.tf
git commit -s -m "feat(eks): expose cluster_endpoint_hostname output

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

helmfile gotmpl の Cilium k8sServiceHost を hydrate-time に
exec terragrunt output で動的取得するための output 追加。"
```

---

### Task 2.3: alb_controller_irsa / external_dns_irsa を deterministic 名に

**Files:**
- Modify: `aws/eks/modules/addons.tf`

- [ ] **Step 1: 該当箇所を確認**

```bash
grep -B1 -A12 "module \"alb_controller_irsa\"\|module \"external_dns_irsa\"" aws/eks/modules/addons.tf
```

- [ ] **Step 2: 各 module call に `use_name_prefix = false` を追加**

`aws/eks/modules/addons.tf` の `module "alb_controller_irsa"` ブロック内、`name = "eks-${var.environment}-alb-controller"` の直後に追加:

```hcl
  use_name_prefix = false
```

同じく `module "external_dns_irsa"` ブロック内、`name = "eks-${var.environment}-external-dns"` の直後にも追加:

```hcl
  use_name_prefix = false
```

- [ ] **Step 3: terraform fmt + validate + plan**

```bash
cd aws/eks && terraform fmt -recursive modules/
cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected: 2 つの IAM role が destroy → create で recreate される plan output。新名は timestamp suffix なし (`eks-production-alb-controller`、`eks-production-external-dns`)。

- [ ] **Step 4: Commit**

```bash
git add aws/eks/modules/addons.tf
git commit -s -m "feat(eks): deterministic IRSA role names for alb-controller / external-dns

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

use_name_prefix = false で role 名から timestamp suffix を除き、
recreate 後も同じ ARN で参照できるようにする。"
```

---

### Task 2.4: Karpenter node IAM role を deterministic 名に

**Files:**
- Modify: `aws/karpenter/modules/main.tf`

- [ ] **Step 1: Task 2.1 で確定した variable 名 + 値を `module "karpenter"` に追加**

`aws/karpenter/modules/main.tf` の `module "karpenter"` block 内、`tags = var.common_tags` の直前に追加:

```hcl
  # variable: <NAME-from-Task-2.1> = <VALUE-from-Task-2.1>
  # Karpenter sub-module v21.19.0 で node IAM role 名から timestamp suffix を
  # 除き、recreate 後も同じ role 名で参照できるようにする。
  node_iam_role_use_name_prefix = false
```

(A) Task 2.1 で `node_iam_role_use_name_prefix` がサポートと判明 → 上記そのまま。

(B) サポートなしと判明した場合は代替で `node_iam_role_name` を直接指定:

```hcl
  node_iam_role_name = "Karpenter-eks-${var.environment}"
```

- [ ] **Step 2: terraform fmt + validate + plan**

```bash
cd aws/karpenter && terraform fmt -recursive modules/
cd aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected: Karpenter node IAM role が destroy → create で recreate される plan output。新名は timestamp suffix なし (`Karpenter-eks-production` 等)。

- [ ] **Step 3: Commit**

```bash
git add aws/karpenter/modules/main.tf
git commit -s -m "feat(karpenter): deterministic node IAM role name

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

recreate 後も同じ role 名で EC2NodeClass.spec.role が参照できるよう
deterministic 化。"
```

---

### Task 2.5: aqua.yaml に terragrunt + tofu 追加

**Files:**
- Modify: `.github/aqua.yaml`

- [ ] **Step 1: 現状確認**

```bash
cat .github/aqua.yaml
```

Expected: helmfile / helm / kustomize / act / actionlint のみ

- [ ] **Step 2: terragrunt + tofu パッケージ追加**

`.github/aqua.yaml` の `packages:` リスト末尾に追加:

```yaml
  - name: gruntwork-io/terragrunt@v0.83.2
  - name: opentofu/opentofu@v1.6.0
```

- [ ] **Step 3: aqua install で動作確認 (= 手元)**

```bash
aqua install -c .github/aqua.yaml
which terragrunt && terragrunt --version
which tofu && tofu --version
```

Expected: terragrunt 0.83.2 / tofu 1.6.0 が解決

- [ ] **Step 4: Commit**

```bash
git add .github/aqua.yaml
git commit -s -m "chore(aqua): add terragrunt + tofu for hydrate workflow

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

CI hydrate workflow が helmfile exec terragrunt output 経由で
cluster 固有値を hydrate-time に取得するため。"
```

---

### Task 2.6: hydrate workflow に AWS OIDC + terragrunt setup 追加

**Files:**
- Modify: `.github/workflows/reusable--kubernetes-hydrator.yaml`

- [ ] **Step 1: 現状確認**

```bash
grep -B1 -A4 "configure-aws-credentials\|aqua-installer" .github/workflows/reusable--kubernetes-hydrator.yaml
```

Expected: `aqua-installer` あり、`configure-aws-credentials` なし

- [ ] **Step 2: workflow_call の inputs に AWS 認証情報を追加**

`.github/workflows/reusable--kubernetes-hydrator.yaml` の `workflow_call.inputs` ブロックに追加 (= `app-id` の直前):

```yaml
      aws-region:
        required: false
        type: string
        default: ''
        description: 'AWS region for terragrunt output access (= production hydrate のみ必須、local hydrate では空)'
      iam-role-plan:
        required: false
        type: string
        default: ''
        description: 'IAM role ARN for terragrunt plan/output access (= production hydrate のみ必須)'
```

- [ ] **Step 3: jobs.hydrate.permissions に id-token: write を追加**

```yaml
    permissions:
      contents: write
      pull-requests: write
      id-token: write
```

- [ ] **Step 4: Setup aqua step の直後に AWS OIDC step を追加**

`Setup aqua` step の直後（`Hydrate changed components` step の直前）に追加:

```yaml
      - name: Configure AWS credentials (= production hydrate のみ)
        if: inputs.iam-role-plan != ''
        uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.2.1
        with:
          role-to-assume: ${{ inputs.iam-role-plan }}
          aws-region: ${{ inputs.aws-region }}
```

- [ ] **Step 5: 呼び出し元 (= auto-label--deploy-trigger.yaml) で iam-role-plan を渡す**

`.github/workflows/auto-label--deploy-trigger.yaml` の hydrator job 呼び出しブロックを確認:

```bash
grep -B2 -A12 "uses: ./.github/workflows/reusable--kubernetes-hydrator.yaml" .github/workflows/auto-label--deploy-trigger.yaml
```

そこに `iam-role-plan` と `aws-region` を渡すよう追加 (= `with:` ブロック):

```yaml
      iam-role-plan: ${{ matrix.iam_role_plan || '' }}
      aws-region: ${{ matrix.aws_region || '' }}
```

注: `matrix` 構造は既存 workflow の作り次第なので、既存 pattern (= terragrunt-executor で iam-role-plan を渡している箇所) を確認して合わせる。

- [ ] **Step 6: actionlint + commit**

```bash
actionlint .github/workflows/reusable--kubernetes-hydrator.yaml .github/workflows/auto-label--deploy-trigger.yaml
git add .github/workflows/reusable--kubernetes-hydrator.yaml .github/workflows/auto-label--deploy-trigger.yaml
git commit -s -m "ci(hydrator): allow terragrunt output access via AWS OIDC

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

helmfile exec terragrunt output で hydrate-time に cluster 固有値を
取得するため、CI runner に AWS credentials が必要。"
```

---

### Task 2.7: kubernetes/helmfile.yaml.gotmpl の cluster 固有値を exec 化

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`

- [ ] **Step 1: production env block を hydrate-time exec に書き換え**

`kubernetes/helmfile.yaml.gotmpl` の `production:` env block を以下に置き換え (= 既存 line 21〜62 を変更):

```yaml
  production:
    values:
      - cluster:
          name: eks-production
          isLocal: false
          # eks-production cluster の API server endpoint hostname (= https:// 含まない)。
          # Source: aws/eks/envs/production terragrunt output cluster_endpoint_hostname
          eksApiEndpoint: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw cluster_endpoint_hostname") }}
          # VPC ID where the cluster lives. Source: aws/vpc/envs/production terragrunt output vpc_id
          vpcId: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt output -raw vpc_id") }}
          # IRSA role ARNs for foundation addons. Source: aws/eks/envs/production terragrunt output
          albControllerRoleArn: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw alb_controller_role_arn") }}
          externalDnsRoleArn: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw external_dns_role_arn") }}
        karpenter:
          # Source: aws/karpenter/envs/production terragrunt output
          nodeRoleName: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt output -raw node_role_name") }}
          interruptionQueueName: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt output -raw interruption_queue_name") }}
        mimir:
          # mimir の bucketName は account ID base で deterministic、Pod Identity role 名も deterministic
          bucketName: mimir-559744160976
          bucketPathPrefix: production
          podIdentityRoleName: eks-production-mimir
        loki:
          bucketName: loki-559744160976
          bucketPathPrefix: production
          podIdentityRoleName: eks-production-loki
        tempo:
          bucketName: tempo-559744160976
          bucketPathPrefix: production
          podIdentityRoleName: eks-production-tempo
```

- [ ] **Step 2: 一旦 commit (= 親 helmfile のみの変更)**

```bash
git add kubernetes/helmfile.yaml.gotmpl
git commit -s -m "feat(kubernetes): hydrate-time exec for production cluster IDs

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

eksApiEndpoint / vpcId / 各 IRSA role ARN を terragrunt output から
hydrate-time に取得するよう変更。recreate 後の自動追従を実現。"
```

---

### Task 2.8: 子 helmfile (cilium / alb-controller / external-dns) の重複定義を exec 化

**Files:**
- Modify: `kubernetes/components/cilium/production/helmfile.yaml`
- Modify: `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml`
- Modify: `kubernetes/components/external-dns/production/helmfile.yaml`

- [ ] **Step 1: cilium/production/helmfile.yaml の eksApiEndpoint を exec 化**

`kubernetes/components/cilium/production/helmfile.yaml` の `environments.production.values` ブロックを以下に置き換え:

```yaml
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の environments values を
    # 子 helmfile に auto-inherit しないため、ここで再定義する。
    # 値は kubernetes/helmfile.yaml.gotmpl の production env block と同期。
    values:
      - cluster:
          eksApiEndpoint: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw cluster_endpoint_hostname") }}
```

- [ ] **Step 2: aws-load-balancer-controller/production/helmfile.yaml の albControllerRoleArn / vpcId を exec 化**

```yaml
environments:
  production:
    values:
      - cluster:
          vpcId: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt output -raw vpc_id") }}
          albControllerRoleArn: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw alb_controller_role_arn") }}
```

- [ ] **Step 3: external-dns/production/helmfile.yaml の externalDnsRoleArn を exec 化**

```yaml
environments:
  production:
    values:
      - cluster:
          externalDnsRoleArn: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw external_dns_role_arn") }}
```

- [ ] **Step 4: 手元で hydrate を 1 回回して error なしを確認**

```bash
# 手元 AWS auth (apply role) を assume している前提
make -C kubernetes hydrate-component COMPONENT=cilium ENV=production
make -C kubernetes hydrate-component COMPONENT=aws-load-balancer-controller ENV=production
make -C kubernetes hydrate-component COMPONENT=external-dns ENV=production
```

Expected: 各コマンドが成功し、`kubernetes/manifests/production/` 配下に変更が出る。生成された manifest 内に `eksApiEndpoint` / `vpcId` / role ARN の current 値が埋まっている。

- [ ] **Step 5: hydrate を 2 回連続実行して idempotent 確認**

```bash
make -C kubernetes hydrate-component COMPONENT=cilium ENV=production
git diff kubernetes/manifests/production/cilium/  # = 何も出ないはず
```

Expected: 2 回目以降の hydrate で diff なし

- [ ] **Step 6: Commit**

```bash
git add kubernetes/components/cilium/production/helmfile.yaml \
        kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml \
        kubernetes/components/external-dns/production/helmfile.yaml \
        kubernetes/manifests/production/
git commit -s -m "feat(kubernetes): hydrate-time exec for child helmfiles + re-hydrate manifests

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

helmfile v1.4 inheritance 制限で子 helmfile に再定義していた
eksApiEndpoint / vpcId / IRSA role ARN を exec terragrunt output 化。"
```

---

### Task 2.9: 漏れチェック (audit pass)

**Files:**
- Inspect: `kubernetes/components/*/production/`、`kubernetes/helmfile.yaml.gotmpl`

- [ ] **Step 1: hardcoded cluster ID / VPC ID / timestamp suffix の漏れを検索**

```bash
grep -REn '[A-F0-9]{32}\.gr[0-9]+\.[a-z0-9-]+\.eks\.amazonaws\.com|vpc-[a-f0-9]{17}|role/[a-z0-9-]+-2026[0-9]+' kubernetes/components/*/production/ kubernetes/helmfile.yaml.gotmpl
```

Expected: matches 0 件 (= manifests 配下を除く source ファイル)

- [ ] **Step 2: matches があれば該当ファイルを exec 化、ステップ 1 を再実行**

検出された場合は同じ exec terragrunt output パターンで書き換え、再 hydrate。

- [ ] **Step 3: matches 0 件確認後、commit**

検出 + 修正があった場合のみ:

```bash
git add <fixed-files> kubernetes/manifests/production/
git commit -s -m "feat(kubernetes): exec-ize remaining hardcoded cluster IDs (audit pass)

Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

検出なしならスキップ。

---

### Task 2.10: Phase 2 PR + apply 検証

- [ ] **Step 1: Phase 2 ブランチを push、Draft PR 作成**

```bash
git push -u origin HEAD
gh pr create --draft --title "feat(eks): deterministic IRSA names + hydrate-time substitution" \
  --body "Phase 2 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

- aws/eks/modules/addons.tf: alb-controller / external-dns IRSA に use_name_prefix = false
- aws/karpenter/modules/main.tf: node IAM role を deterministic 化
- aws/eks/modules/outputs.tf: cluster_endpoint_hostname output 追加
- kubernetes/helmfile.yaml.gotmpl + 子 helmfile: cluster 固有値を exec terragrunt output 化
- .github/workflows/reusable--kubernetes-hydrator.yaml: AWS OIDC + terragrunt setup 追加
- .github/aqua.yaml: terragrunt + tofu 追加

apply 中に IRSA role が destroy → create でローテートされ、hydrate workflow が新 ARN で manifests を再生成する。
ALB controller / external-dns / Karpenter pods は短時間 (= 数十秒〜数分) 認証エラー後 self-healing。"
```

- [ ] **Step 2: PR ready、CI plan + hydrate jobs 完了確認**

```bash
gh pr ready
gh pr checks
```

Expected: terragrunt plan + hydrate-production が SUCCESS

- [ ] **Step 3: Merge**

```bash
gh pr merge --squash --delete-branch
```

- [ ] **Step 4: main の apply ジョブ + Flux reconcile 完了を確認**

```bash
gh run list --limit 5
# kubectl 側で
source ~/Workspace/eks-login.sh
kubectl get pods -A | grep -v Running
```

Expected: terragrunt apply + auto-commit hydrate + main 側 hydrate 全て SUCCESS、kubectl で全 Pod Running (= 短時間 IRSA rotation 後 self-heal 完了)

- [ ] **Step 5: deterministic 名で role 取得確認**

```bash
aws iam get-role --role-name eks-production-alb-controller --query Role.RoleName
aws iam get-role --role-name eks-production-external-dns --query Role.RoleName
KARPENTER_NODE_ROLE=$(cd aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt output -raw node_role_name)
aws iam get-role --role-name "$KARPENTER_NODE_ROLE" --query Role.RoleName
```

Expected: 全て NoSuchEntity ではなく role 名が返る

---

# Phase 3: Lifecycle scripts

`scripts/eks-lifecycle/` 配下に shell scripts、repo root に `Makefile` を新設し、`make eks-teardown ENV=production` / `make eks-recreate ENV=production` で teardown / recreate を実行できるようにする。

### Task 3.1: lib/common.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/common.sh`

- [ ] **Step 1: 共通 utilities を実装**

```bash
mkdir -p scripts/eks-lifecycle/lib
```

`scripts/eks-lifecycle/lib/common.sh`:

```bash
# common.sh - shared utilities for eks-lifecycle scripts.
#
# All numbered scripts (00-auth.sh ... 70-reconcile-watch.sh) source this
# file at the top to obtain logging, fail-fast, env validation, dry-run
# wrapper, and credential expiration tracking helpers.

# ----------------------------------------------------------------------------
# Fail-fast
# ----------------------------------------------------------------------------
set -euo pipefail

# ----------------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ----------------------------------------------------------------------------
# Logging functions
# ----------------------------------------------------------------------------
info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# ----------------------------------------------------------------------------
# Environment / CLI validation
# ----------------------------------------------------------------------------
require_env() {
  if [ "${ENV:-}" != "production" ]; then
    error "ENV must be 'production' (got: '${ENV:-<unset>}')"
    exit 1
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "required command not found: $cmd"
      exit 1
    fi
  done
}

# ----------------------------------------------------------------------------
# y/N confirmation (always interactive, even when DRY_RUN=1)
# ----------------------------------------------------------------------------
confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    info "Cancelled."
    exit 0
  fi
}

# ----------------------------------------------------------------------------
# DRY_RUN-aware command runner
# ----------------------------------------------------------------------------
# Usage: run aws ec2 describe-instances ...
# When DRY_RUN=1, prints the command without executing.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf "${YELLOW}[DRY-RUN]${NC} %s\n" "$*"
  else
    "$@"
  fi
}

# ----------------------------------------------------------------------------
# Repo root resolution (= for terragrunt invocations)
# ----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT

# ----------------------------------------------------------------------------
# AWS region from terragrunt env file (falls back to ap-northeast-1)
# ----------------------------------------------------------------------------
resolve_aws_region() {
  local env_file="${REPO_ROOT}/aws/eks/envs/${ENV}/env.hcl"
  if [ -f "$env_file" ]; then
    grep -E '^\s*aws_region\s*=' "$env_file" | head -1 | sed -E 's/^\s*aws_region\s*=\s*"([^"]+)".*/\1/'
  else
    echo "ap-northeast-1"
  fi
}

# ----------------------------------------------------------------------------
# Credentials expiration tracking
# ----------------------------------------------------------------------------
# 00-auth.sh writes UNIX epoch to this file when credentials are obtained.
# Subsequent steps check age and re-source 00-auth.sh if < 5 min remaining.
CREDS_EXPIRE_FILE="/tmp/eks-lifecycle-creds-expire-$$"
export CREDS_EXPIRE_FILE

creds_expiring_soon() {
  if [ ! -f "$CREDS_EXPIRE_FILE" ]; then
    return 0  # No record means we should re-auth
  fi
  local expire_at now remaining
  expire_at=$(cat "$CREDS_EXPIRE_FILE")
  now=$(date +%s)
  remaining=$((expire_at - now))
  if [ "$remaining" -lt 300 ]; then
    return 0  # Less than 5 min remaining
  fi
  return 1
}
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/common.sh
```

Expected: 致命的 warning 0 件 (= info / hint 程度は許容)

- [ ] **Step 3: Commit**

```bash
git add scripts/eks-lifecycle/lib/common.sh
git commit -s -m "feat(eks-lifecycle): common.sh utilities

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.2: lib/00-auth.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/00-auth.sh`

- [ ] **Step 1: auth step 実装**

```bash
#!/usr/bin/env bash
# 00-auth.sh - Assume apply role + admin role, configure kubeconfig.
#
# Sources common.sh for utilities. Sets:
#   - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
#     (= apply role credentials, used by terragrunt apply/destroy)
#   - KUBECONFIG (= updated to talk to eks-${ENV} via admin role assume)
#   - CLUSTER_EXISTS (= "true" or "false", consumed by 10-k8s-cleanup.sh)
#
# Idempotent: re-sourcing replaces credentials with a fresh assume.

# Source common.sh from same directory
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"

require_env
require_cmd aws jq kubectl

REGION="$(resolve_aws_region)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

APPLY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-oidc-auth-${ENV}-github-actions-apply-role"
ADMIN_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/eks-admin-${ENV}"

info "Assuming apply role: ${APPLY_ROLE_ARN}"
APPLY_CREDS=$(aws sts assume-role \
  --role-arn "$APPLY_ROLE_ARN" \
  --role-session-name "eks-lifecycle-${USER:-debug}-$$" \
  --query Credentials \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$APPLY_CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$APPLY_CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$APPLY_CREDS" | jq -r .SessionToken)
EXPIRATION=$(echo "$APPLY_CREDS" | jq -r .Expiration)
date -d "$EXPIRATION" +%s 2>/dev/null > "$CREDS_EXPIRE_FILE" || \
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "${EXPIRATION%+*}+0000" +%s > "$CREDS_EXPIRE_FILE"

ok "Apply role credentials valid until: $EXPIRATION"

info "Assuming admin role for kubectl: ${ADMIN_ROLE_ARN}"
if ! ADMIN_CREDS=$(aws sts assume-role \
  --role-arn "$ADMIN_ROLE_ARN" \
  --role-session-name "eks-lifecycle-admin-${USER:-debug}-$$" \
  --query Credentials \
  --output json 2>/dev/null); then
  warn "Admin role not found (= cluster may already be destroyed). Setting CLUSTER_EXISTS=false."
  export CLUSTER_EXISTS="false"
  return 0 2>/dev/null || exit 0
fi

# Save admin creds to a temp file (separate from apply creds)
ADMIN_CREDS_FILE="/tmp/eks-lifecycle-admin-creds-$$"
echo "$ADMIN_CREDS" > "$ADMIN_CREDS_FILE"
export ADMIN_CREDS_FILE

# Use admin creds in a sub-shell to update kubeconfig
(
  AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId "$ADMIN_CREDS_FILE")
  AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey "$ADMIN_CREDS_FILE")
  AWS_SESSION_TOKEN=$(jq -r .SessionToken "$ADMIN_CREDS_FILE")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if aws eks update-kubeconfig --region "$REGION" --name "eks-${ENV}" >/dev/null 2>&1; then
    exit 0
  else
    exit 1
  fi
) && CLUSTER_REACHABLE="true" || CLUSTER_REACHABLE="false"

if [ "$CLUSTER_REACHABLE" = "true" ] && kubectl get nodes >/dev/null 2>&1; then
  ok "Cluster reachable via admin role"
  export CLUSTER_EXISTS="true"
else
  warn "Cluster not reachable (= already destroyed?). Setting CLUSTER_EXISTS=false."
  export CLUSTER_EXISTS="false"
fi

# Helper for sub-scripts that need admin credentials (= kubectl ops in 60/70)
use_admin_creds() {
  if [ -f "$ADMIN_CREDS_FILE" ]; then
    export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId "$ADMIN_CREDS_FILE")
    export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey "$ADMIN_CREDS_FILE")
    export AWS_SESSION_TOKEN=$(jq -r .SessionToken "$ADMIN_CREDS_FILE")
  fi
}

use_apply_creds() {
  export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<< "$APPLY_CREDS")
  export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<< "$APPLY_CREDS")
  export AWS_SESSION_TOKEN=$(jq -r .SessionToken <<< "$APPLY_CREDS")
}

# Default to apply creds for terragrunt operations
use_apply_creds
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/00-auth.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/eks-lifecycle/lib/00-auth.sh
git commit -s -m "feat(eks-lifecycle): 00-auth.sh - apply + admin role assume

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.3: lib/10-k8s-cleanup.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/10-k8s-cleanup.sh`

- [ ] **Step 1: k8s cleanup step 実装**

```bash
#!/usr/bin/env bash
# 10-k8s-cleanup.sh - Pre-teardown k8s resource cleanup.
#
# Deletes Ingress / LoadBalancer Service / Karpenter NodePool to release
# AWS resources (target groups / ENIs / EC2 instances) BEFORE we run
# terragrunt destroy on the EKS cluster itself. Skipped if cluster is
# not reachable.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env

if [ "${CLUSTER_EXISTS:-}" != "true" ]; then
  warn "CLUSTER_EXISTS=false. Skipping k8s cleanup."
  exit 0
fi

use_admin_creds

info "Step 10.1: Deleting all Ingress resources (= ALB target group / ENI release)"
run kubectl delete ingress --all -A --timeout=180s || warn "ingress deletion incomplete (= some may need manual finalizer removal)"

info "Step 10.2: Deleting LoadBalancer Services (= NLB / ENI release)"
run kubectl delete svc -A --field-selector spec.type=LoadBalancer --timeout=180s || warn "LB service deletion incomplete"

info "Step 10.3: Deleting Karpenter NodePools (= EC2 drain + terminate)"
if kubectl get nodepools.karpenter.sh >/dev/null 2>&1; then
  run kubectl delete nodepools.karpenter.sh --all --timeout=300s || warn "NodePool deletion incomplete"
fi

info "Step 10.4: Waiting for Karpenter nodes to be removed"
if [ "${DRY_RUN:-0}" != "1" ]; then
  if kubectl get nodes -l karpenter.sh/nodepool >/dev/null 2>&1; then
    kubectl wait nodes -l karpenter.sh/nodepool --for=delete --timeout=600s || \
      warn "Karpenter nodes did not all drain in 600s. Manually run: kubectl get nodes -l karpenter.sh/nodepool; kubectl delete node <name> --force"
  fi
fi

info "Step 10.5: Sanity check - listing remaining pods"
run kubectl get pods -A -o wide || true

ok "k8s cleanup complete"
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/10-k8s-cleanup.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/eks-lifecycle/lib/10-k8s-cleanup.sh
git commit -s -m "feat(eks-lifecycle): 10-k8s-cleanup.sh

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.4: lib/30-destroy-stacks.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/30-destroy-stacks.sh`

- [ ] **Step 1: terragrunt destroy 8 stacks (固定順)**

```bash
#!/usr/bin/env bash
# 30-destroy-stacks.sh - Destroy 8 EKS-related stacks in fixed order.
#
# Order:
#   karpenter -> eks-secrets -> eks-logs -> eks-metrics -> eks-traces
#   -> eks -> alb -> vpc
#
# Each stack runs `terragrunt destroy -auto-approve`. On failure, fail
# fast with a diagnostic. 30s sleep between stacks for AWS API
# eventual consistency.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd terragrunt tofu

STACKS=(
  "karpenter"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
  "eks"
  "alb"
  "vpc"
)

confirm "About to DESTROY 8 stacks for ENV=${ENV}. Continue?"

for stack in "${STACKS[@]}"; do
  info "Step 30.${stack}: terragrunt destroy aws/${stack}/envs/${ENV}"

  # Refresh credentials if expiring soon
  if creds_expiring_soon; then
    info "Credentials expiring soon, re-assuming..."
    # shellcheck source=lib/00-auth.sh
    . "${LIB_DIR}/00-auth.sh"
  fi

  if ! ( cd "${REPO_ROOT}/aws/${stack}/envs/${ENV}" && \
         run env TG_TF_PATH=tofu terragrunt destroy -auto-approve ); then
    error "terragrunt destroy failed at aws/${stack}. Manually inspect:
    cd aws/${stack}/envs/${ENV} && TG_TF_PATH=tofu terragrunt destroy
After resolving, re-run: make eks-teardown-aws ENV=${ENV}"
    exit 1
  fi

  ok "${stack} destroyed"

  if [ "${DRY_RUN:-0}" != "1" ]; then
    info "Sleeping 30s for AWS API eventual consistency..."
    sleep 30
  fi
done

ok "All 8 stacks destroyed"
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/30-destroy-stacks.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/eks-lifecycle/lib/30-destroy-stacks.sh
git commit -s -m "feat(eks-lifecycle): 30-destroy-stacks.sh

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.5: lib/40-orphan-verify.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/40-orphan-verify.sh`

- [ ] **Step 1: orphan resource 検出 step 実装**

```bash
#!/usr/bin/env bash
# 40-orphan-verify.sh - Detect orphan AWS resources after teardown.
#
# Reports (does NOT delete) any resources tagged with the production EKS
# environment that survived terragrunt destroy. Exits non-zero if any
# orphan is found, with example deletion commands for the operator.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd aws jq

REGION="$(resolve_aws_region)"
ORPHAN_FOUND=0

info "Step 40.1: ENI (= VPC CNI / Cilium / ALB controller / Karpenter)"
ENI_IDS=$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=tag:Project,Values=eks" "Name=tag:Environment,Values=${ENV}" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
if [ -n "$ENI_IDS" ]; then
  warn "Orphan ENIs: $ENI_IDS"
  warn "  delete: aws ec2 delete-network-interface --network-interface-id <id>"
  ORPHAN_FOUND=1
fi

info "Step 40.2: EBS volumes (= released by PVC reclaimPolicy=Delete)"
EBS_IDS=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:KubernetesCluster,Values=eks-${ENV}" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text)
if [ -n "$EBS_IDS" ]; then
  warn "Orphan EBS volumes: $EBS_IDS"
  warn "  delete: aws ec2 delete-volume --volume-id <id>"
  ORPHAN_FOUND=1
fi

info "Step 40.3: Target groups (= ALB controller created)"
TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName, 'k8s-')].TargetGroupArn" --output text)
if [ -n "$TG_ARNS" ]; then
  warn "Orphan target groups: $TG_ARNS"
  warn "  delete: aws elbv2 delete-target-group --target-group-arn <arn>"
  ORPHAN_FOUND=1
fi

info "Step 40.4: Security groups"
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=tag:Environment,Values=${ENV}" "Name=tag:Project,Values=eks" \
  --query 'SecurityGroups[?GroupName != `default`].GroupId' --output text)
if [ -n "$SG_IDS" ]; then
  warn "Orphan SGs: $SG_IDS"
  warn "  delete: aws ec2 delete-security-group --group-id <id>"
  ORPHAN_FOUND=1
fi

info "Step 40.5: Route53 stale external-dns records"
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name panicboat.net --query 'HostedZones[0].Id' --output text 2>/dev/null | sed 's|/hostedzone/||')
if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
  STALE_RECORDS=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?starts_with(Name, '_external-dns.') || (Type == 'A' && contains(Name, '.panicboat.net'))].[Name,Type]" \
    --output text)
  if [ -n "$STALE_RECORDS" ]; then
    warn "Stale Route53 records (= external-dns owned, not auto-cleaned):"
    echo "$STALE_RECORDS" | sed 's/^/    /'
    warn "  delete: aws route53 change-resource-record-sets --hosted-zone-id ${HOSTED_ZONE_ID} --change-batch ..."
    ORPHAN_FOUND=1
  fi
fi

info "Step 40.6: CloudWatch log groups"
LG_NAMES=$(aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "/aws/eks/eks-${ENV}" \
  --query 'logGroups[].logGroupName' --output text)
if [ -n "$LG_NAMES" ]; then
  warn "Orphan CloudWatch log groups: $LG_NAMES"
  warn "  delete: aws logs delete-log-group --log-group-name <name>"
  ORPHAN_FOUND=1
fi

if [ "$ORPHAN_FOUND" -eq 1 ]; then
  error "Orphan resources detected. Resolve manually using the delete commands above, then re-run make eks-teardown-verify to confirm."
  exit 1
fi

ok "No orphan resources detected. Teardown complete."
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/40-orphan-verify.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/eks-lifecycle/lib/40-orphan-verify.sh
git commit -s -m "feat(eks-lifecycle): 40-orphan-verify.sh

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.6: lib/50-apply-stacks.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/50-apply-stacks.sh`

- [ ] **Step 1: terragrunt apply 8 stacks (固定順)**

```bash
#!/usr/bin/env bash
# 50-apply-stacks.sh - Apply 8 EKS-related stacks in fixed order.
#
# Order:
#   vpc -> alb -> eks -> karpenter -> eks-secrets
#   -> eks-logs -> eks-metrics -> eks-traces
#
# Each stack runs `terragrunt apply -auto-approve`. On failure, fail
# fast with a diagnostic. 30s sleep between stacks for AWS API
# eventual consistency.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd terragrunt tofu

STACKS=(
  "vpc"
  "alb"
  "eks"
  "karpenter"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
)

confirm "About to APPLY 8 stacks for ENV=${ENV}. Continue?"

for stack in "${STACKS[@]}"; do
  info "Step 50.${stack}: terragrunt apply aws/${stack}/envs/${ENV}"

  # Refresh credentials if expiring soon
  if creds_expiring_soon; then
    info "Credentials expiring soon, re-assuming..."
    # shellcheck source=lib/00-auth.sh
    . "${LIB_DIR}/00-auth.sh"
  fi

  if ! ( cd "${REPO_ROOT}/aws/${stack}/envs/${ENV}" && \
         run env TG_TF_PATH=tofu terragrunt apply -auto-approve ); then
    error "terragrunt apply failed at aws/${stack}. Common causes:
  - eventual consistency (= retry after 30s)
  - missing dependency from previous stack
Manually inspect:
  cd aws/${stack}/envs/${ENV} && TG_TF_PATH=tofu terragrunt apply
After resolving, re-run: make eks-recreate-aws ENV=${ENV}"
    exit 1
  fi

  ok "${stack} applied"

  if [ "${DRY_RUN:-0}" != "1" ]; then
    info "Sleeping 30s for AWS API eventual consistency..."
    sleep 30
  fi
done

ok "All 8 stacks applied"
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/50-apply-stacks.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/eks-lifecycle/lib/50-apply-stacks.sh
git commit -s -m "feat(eks-lifecycle): 50-apply-stacks.sh

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.7: lib/60-flux-bootstrap.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/60-flux-bootstrap.sh`

- [ ] **Step 1: hydrate + git push + flux bootstrap**

```bash
#!/usr/bin/env bash
# 60-flux-bootstrap.sh - Re-hydrate manifests with new cluster IDs, push
# to main, then apply Flux bootstrap manifests.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd kubectl flux git make

if [ "${CLUSTER_EXISTS:-}" != "true" ]; then
  error "Cluster not reachable. Run make eks-recreate-aws ENV=${ENV} first."
  exit 1
fi

use_admin_creds

info "Step 60.1: Wait for system MNG nodes to be Ready"
run kubectl wait --for=condition=Ready node --all --timeout=300s

info "Step 60.2: Re-hydrate kubernetes/manifests/${ENV}/ with new cluster IDs"
use_apply_creds  # = hydrate needs terragrunt output access via apply role

# Hydrate every component (= same as CI hydrate workflow does for changed components)
COMPONENTS=$(ls -d "${REPO_ROOT}/kubernetes/components/"*/ 2>/dev/null | xargs -n1 basename)
for comp in $COMPONENTS; do
  if [ -d "${REPO_ROOT}/kubernetes/components/${comp}/${ENV}" ]; then
    info "Hydrating ${comp}..."
    run make -C "${REPO_ROOT}/kubernetes" hydrate-component COMPONENT="$comp" ENV="$ENV"
  fi
done
run make -C "${REPO_ROOT}/kubernetes" hydrate-index ENV="$ENV"

info "Step 60.3: Show diff and confirm git commit"
( cd "$REPO_ROOT" && run git status kubernetes/manifests/${ENV}/ )
( cd "$REPO_ROOT" && run git diff --stat kubernetes/manifests/${ENV}/ )

if [ "${DRY_RUN:-0}" = "1" ]; then
  info "[DRY-RUN] Skipping git commit + push"
else
  if [ -n "$(cd "$REPO_ROOT" && git status --porcelain kubernetes/manifests/${ENV}/)" ]; then
    confirm "Commit + push hydrated manifests to main?"
    ( cd "$REPO_ROOT" && \
      git add "kubernetes/manifests/${ENV}/" && \
      git commit -s -m "chore(kubernetes/manifests/${ENV}): re-hydrate after cluster recreate

eksApiEndpoint / vpcId / IRSA role ARN を新 cluster の terragrunt output で
更新。Flux が次の reconcile で pickup する。" && \
      git push origin main )
  else
    info "No manifest changes (= terragrunt outputs match git)."
  fi
fi

use_admin_creds  # = back to admin for kubectl ops

info "Step 60.4: Apply Flux bootstrap manifests"
run kubectl apply -k "${REPO_ROOT}/kubernetes/clusters/${ENV}/"

info "Step 60.5: Wait for flux-system Kustomization to be Ready"
run kubectl wait kustomization/flux-system -n flux-system \
  --for=condition=Ready --timeout=300s

run flux get sources git -A
run flux get kustomizations -A

ok "Flux bootstrap complete"
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/60-flux-bootstrap.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/eks-lifecycle/lib/60-flux-bootstrap.sh
git commit -s -m "feat(eks-lifecycle): 60-flux-bootstrap.sh

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.8: lib/70-reconcile-watch.sh

**Files:**
- Create: `scripts/eks-lifecycle/lib/70-reconcile-watch.sh`

- [ ] **Step 1: Phase 単位で HelmRelease Ready wait**

```bash
#!/usr/bin/env bash
# 70-reconcile-watch.sh - Wait for all HelmReleases to become Ready,
# grouped by roadmap Phase 1-5.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd kubectl flux

if [ "${CLUSTER_EXISTS:-}" != "true" ]; then
  error "Cluster not reachable. Run make eks-recreate-aws ENV=${ENV} first."
  exit 1
fi

use_admin_creds

# Helper: wait for given HelmReleases (= ns/name pairs) to be Ready.
wait_helmreleases() {
  local timeout="$1"; shift
  local hr
  for hr in "$@"; do
    local ns="${hr%%/*}"
    local name="${hr#*/}"
    info "Waiting HelmRelease ${ns}/${name} (timeout ${timeout}) ..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
      printf "${YELLOW}[DRY-RUN]${NC} kubectl wait helmrelease/%s -n %s --for=condition=Ready --timeout=%s\n" \
        "$name" "$ns" "$timeout"
      continue
    fi
    if ! kubectl wait "helmrelease/${name}" -n "$ns" --for=condition=Ready --timeout="$timeout" 2>/dev/null; then
      error "HelmRelease ${ns}/${name} not Ready in ${timeout}. Inspect:
    flux logs -n ${ns}
    kubectl describe helmrelease ${name} -n ${ns}"
      exit 1
    fi
  done
}

info "Phase 1: foundation addons"
wait_helmreleases 600s \
  kube-system/cilium \
  kube-system/aws-load-balancer-controller \
  external-dns/external-dns \
  external-secrets/external-secrets \
  kube-system/metrics-server \
  keda/keda

info "Phase 2: Karpenter"
wait_helmreleases 600s karpenter/karpenter

info "Phase 3: observability"
wait_helmreleases 1200s \
  monitoring/kube-prometheus-stack \
  monitoring/mimir-distributed \
  monitoring/loki \
  monitoring/tempo \
  monitoring/fluent-bit \
  monitoring/opentelemetry-collector \
  monitoring/beyla

info "Phase 4: cert-manager + reloader"
wait_helmreleases 600s \
  cert-manager/cert-manager \
  reloader/reloader

info "Phase 5: oauth2-proxy + nginx-sample"
wait_helmreleases 600s \
  oauth2-proxy/oauth2-proxy \
  default/nginx-sample

info "Status summary:"
run kubectl get helmreleases -A
run kubectl get kustomizations -A

# Final check: any Failed?
if [ "${DRY_RUN:-0}" != "1" ]; then
  if kubectl get helmreleases -A -o json | \
     jq -e '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False"))' >/dev/null 2>&1; then
    error "Some HelmReleases are in Failed state. Inspect with: flux get helmreleases -A"
    exit 1
  fi
fi

ok "All HelmReleases Ready. Recreate complete."
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck scripts/eks-lifecycle/lib/70-reconcile-watch.sh
```

注: 上記 HelmRelease の namespace / name は推定値。Task 3.8 step 3 で実際の `kubectl get helmreleases -A` 出力 (= teardown 前 cluster) と突き合わせて修正。teardown 前 cluster で `kubectl get helmreleases -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'` を実行して fix list を作る。

- [ ] **Step 3: 実 cluster の HelmRelease 一覧で 70 script を補正**

```bash
source ~/Workspace/eks-login.sh production
kubectl get helmreleases -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'
```

出力された一覧と 70 script の `wait_helmreleases` 引数を突き合わせ、ずれがあれば修正。

- [ ] **Step 4: Commit**

```bash
git add scripts/eks-lifecycle/lib/70-reconcile-watch.sh
git commit -s -m "feat(eks-lifecycle): 70-reconcile-watch.sh

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.9: teardown.sh + recreate.sh entry scripts

**Files:**
- Create: `scripts/eks-lifecycle/teardown.sh`
- Create: `scripts/eks-lifecycle/recreate.sh`

- [ ] **Step 1: teardown.sh**

```bash
#!/usr/bin/env bash
# teardown.sh - Top-level entry: run all teardown steps in order.
# Equivalent to: make eks-teardown-k8s + eks-teardown-aws + eks-teardown-verify
#
# Each sub-script sources 00-auth.sh internally, so we don't need to
# manage auth here. Sub-scripts run as separate bash processes via the
# Makefile too, so this entry mirrors that behavior.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
"${LIB_DIR}/10-k8s-cleanup.sh"
"${LIB_DIR}/30-destroy-stacks.sh"
"${LIB_DIR}/40-orphan-verify.sh"
```

- [ ] **Step 2: recreate.sh**

```bash
#!/usr/bin/env bash
# recreate.sh - Top-level entry: run all recreate steps in order.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
"${LIB_DIR}/50-apply-stacks.sh"
"${LIB_DIR}/60-flux-bootstrap.sh"
"${LIB_DIR}/70-reconcile-watch.sh"
```

- [ ] **Step 3: chmod + shellcheck**

```bash
chmod +x scripts/eks-lifecycle/teardown.sh scripts/eks-lifecycle/recreate.sh
chmod +x scripts/eks-lifecycle/lib/*.sh
shellcheck scripts/eks-lifecycle/teardown.sh scripts/eks-lifecycle/recreate.sh
```

- [ ] **Step 4: Commit**

```bash
git add scripts/eks-lifecycle/teardown.sh scripts/eks-lifecycle/recreate.sh
git update-index --chmod=+x scripts/eks-lifecycle/teardown.sh scripts/eks-lifecycle/recreate.sh
git update-index --chmod=+x scripts/eks-lifecycle/lib/*.sh
git commit -s -m "feat(eks-lifecycle): teardown.sh + recreate.sh entry scripts

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.10: root Makefile

**Files:**
- Create: `Makefile`

- [ ] **Step 1: root Makefile**

```make
# Makefile (repo root) - EKS production lifecycle entry points
#
# Usage:
#   make eks-teardown ENV=production           # full teardown
#   make eks-teardown-k8s ENV=production       # k8s cleanup only
#   make eks-teardown-aws ENV=production       # terragrunt destroy only
#   make eks-teardown-verify ENV=production    # orphan verify only
#   make eks-recreate ENV=production           # full recreate
#   make eks-recreate-aws ENV=production       # terragrunt apply only
#   make eks-recreate-flux ENV=production      # flux bootstrap only
#   make eks-recreate-watch ENV=production     # reconcile watch only
#
#   DRY_RUN=1 make eks-teardown ENV=production # echo commands without exec
#
# See docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

ENV ?=

.PHONY: help eks-teardown eks-teardown-k8s eks-teardown-aws eks-teardown-verify
.PHONY: eks-recreate eks-recreate-aws eks-recreate-flux eks-recreate-watch

help:
	@echo "EKS Lifecycle commands:"
	@echo ""
	@echo "  make eks-teardown ENV=production"
	@echo "  make eks-recreate ENV=production"
	@echo ""
	@echo "  ENV=$(ENV)"
	@echo "  DRY_RUN=$(DRY_RUN) (= '1' for dry-run, anything else for live)"

eks-teardown: eks-teardown-k8s eks-teardown-aws eks-teardown-verify
	@printf "\033[0;32m[OK]\033[0m teardown complete\n"

eks-teardown-k8s:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/10-k8s-cleanup.sh

eks-teardown-aws:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/30-destroy-stacks.sh

eks-teardown-verify:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/40-orphan-verify.sh

eks-recreate: eks-recreate-aws eks-recreate-flux eks-recreate-watch
	@printf "\033[0;32m[OK]\033[0m recreate complete\n"

eks-recreate-aws:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/50-apply-stacks.sh

eks-recreate-flux:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/60-flux-bootstrap.sh

eks-recreate-watch:
	ENV=$(ENV) DRY_RUN=$(DRY_RUN) bash scripts/eks-lifecycle/lib/70-reconcile-watch.sh
```

- [ ] **Step 2: make help が動くか確認**

```bash
make help ENV=production
make help DRY_RUN=1 ENV=production
```

Expected: help message が表示される

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -s -m "feat(eks-lifecycle): root Makefile

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.11: scripts/eks-lifecycle/README.md

**Files:**
- Create: `scripts/eks-lifecycle/README.md`

- [ ] **Step 1: README.md**

````markdown
# EKS Lifecycle

Temporary teardown / idempotent recreate of `eks-production` cluster + 周辺 AWS stacks. 手元 shell から実行する想定 (= CI 経由 trigger は未対応)。

詳細設計: `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md`

## Prerequisites

- 操作者の IAM principal が `sts:AssumeRole` で以下を assume できること:
  - `arn:aws:iam::<acct>:role/github-oidc-auth-production-github-actions-apply-role`
  - `arn:aws:iam::<acct>:role/eks-admin-production`
- 手元に installed: `tofu`, `terragrunt`, `kubectl`, `flux`, `jq`, `aws`, `make`, `bash`
- repo root から `make` を実行する (= `Makefile` がある場所)

## Usage

### Teardown (= cluster + 周辺 stacks を削除)

```bash
# Dry-run (= AWS / kubectl コマンドを echo のみ、実行しない)
DRY_RUN=1 make eks-teardown ENV=production

# Live run
make eks-teardown ENV=production
```

実行内容:

1. `10-k8s-cleanup.sh`: kubectl delete ingress / LB svc / Karpenter NodePool、ノード drain 待機
2. `30-destroy-stacks.sh`: 8 stacks を固定順で `terragrunt destroy` (= karpenter → eks-secrets → eks-logs/metrics/traces → eks → alb → vpc)
3. `40-orphan-verify.sh`: ENI / EBS / target group / SG / Route53 record / CloudWatch log group の orphan 検出 (= 削除はしない、人間に diagnostic 提示)

部分実行:

```bash
make eks-teardown-k8s ENV=production       # k8s cleanup only
make eks-teardown-aws ENV=production       # terragrunt destroy only
make eks-teardown-verify ENV=production    # orphan verify only
```

### Recreate (= cluster 再作成)

```bash
# Dry-run
DRY_RUN=1 make eks-recreate ENV=production

# Live run
make eks-recreate ENV=production
```

実行内容:

1. `50-apply-stacks.sh`: 8 stacks を固定順で `terragrunt apply` (= vpc → alb → eks → karpenter → eks-secrets → eks-logs/metrics/traces)
2. `60-flux-bootstrap.sh`: hydrate-component で manifests を新 cluster ID で再生成 → git commit + push → `kubectl apply -k kubernetes/clusters/production/`
3. `70-reconcile-watch.sh`: 全 HelmRelease が Ready になるまで Phase 単位で wait

## Failure handling

- 各 step は **fail fast** (= 即 exit 1)、診断メッセージで「次に何を打つべきか」を提示
- partial state からの再 run は idempotent: `make eks-teardown` / `make eks-recreate` は何度叩いても安全
- ロールバックは前進復旧のみ (= teardown 中断は再 teardown、recreate 中断は再 recreate)
- credentials 期限 1h は `00-auth.sh` が自動再 assume

## What is preserved through teardown

- AWS Secrets Manager service の secret 値 (= terragrunt 管理外で手動管理)
- `aws/route53` (= panicboat.net hosted zone)
- `aws/github-oidc-auth` / `ai-assistant` / `cost-management` (= EKS 非依存)
- terragrunt remote state (= S3 + DynamoDB)

## What is destroyed

- `aws/eks`, `aws/karpenter`, `aws/eks-secrets`, `aws/eks-logs`, `aws/eks-metrics`, `aws/eks-traces` (= EKS 専用)
- `aws/alb` (= ACM wildcard cert *.panicboat.net、recreate 時は DNS validation 5〜10 分)
- `aws/vpc` (= NAT gateway 含む)
````

- [ ] **Step 2: Commit**

```bash
git add scripts/eks-lifecycle/README.md
git commit -s -m "feat(eks-lifecycle): README.md

Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md"
```

---

### Task 3.12: Phase 3 PR + dry-run validation

- [ ] **Step 1: Phase 3 ブランチを push、Draft PR 作成**

```bash
git push -u origin HEAD
gh pr create --draft --title "feat(eks-lifecycle): teardown + recreate scripts" \
  --body "Phase 3 of docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

scripts/eks-lifecycle/ + root Makefile による teardown / recreate orchestrator。
Phase 1 + Phase 2 が apply 済の前提で動作する。

Live run validation はマージ後に手元で実施 (= cluster を実際に teardown + recreate)。"
```

- [ ] **Step 2: shellcheck CI (= 既存 lint-actions.yml で shellcheck 走る場合) 確認**

```bash
gh pr checks
```

- [ ] **Step 3: 手元で dry-run**

```bash
make eks-teardown DRY_RUN=1 ENV=production
make eks-recreate DRY_RUN=1 ENV=production
```

Expected:
- 各 step の AWS / kubectl コマンドが `[DRY-RUN]` プレフィックス付きで出力
- 8 stack が固定順 (= teardown: karpenter→...→vpc、recreate: vpc→...→eks-traces) で iterate
- HelmRelease wait の対象が roadmap Phase 1-5 と一致

- [ ] **Step 4: Merge**

```bash
gh pr merge --squash --delete-branch
```

---

### Task 3.13: Live run validation (= 本番 1 周)

> **重要**: このタスクは **production cluster を実際に teardown + recreate** する。AWS Secrets Manager service の secret 値は preserve されるが、cluster 上のすべての pod / service / その他リソースは消える。実行前に panicboat 個人運用で **業務影響無し** であることを確認。

- [ ] **Step 1: Phase 1 / 2 retrofit 確認**

```bash
# Phase 1
grep "force_destroy = true" aws/eks-logs/modules/main.tf aws/eks-metrics/modules/main.tf aws/eks-traces/modules/main.tf

# Phase 2 (deterministic naming)
aws iam get-role --role-name eks-production-alb-controller --query Role.RoleName
aws iam get-role --role-name eks-production-external-dns --query Role.RoleName
KARPENTER_NODE_ROLE=$(cd aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt output -raw node_role_name)
aws iam get-role --role-name "$KARPENTER_NODE_ROLE" --query Role.RoleName

# Phase 2 (audit pass)
grep -REn '[A-F0-9]{32}\.gr[0-9]+\.[a-z0-9-]+\.eks\.amazonaws\.com|vpc-[a-f0-9]{17}|role/[a-z0-9-]+-2026[0-9]+' kubernetes/components/*/production/ kubernetes/helmfile.yaml.gotmpl
```

Expected: Phase 1 は 3 件 force_destroy あり、Phase 2 は role 名取得成功 + audit grep の matches 0 件

- [ ] **Step 2: teardown live run**

```bash
make eks-teardown ENV=production
```

完了後 checklist:

- [ ] `aws eks describe-cluster --name eks-production` → ResourceNotFoundException
- [ ] `aws ec2 describe-vpcs --filters Name=tag:Environment,Values=production --query 'Vpcs[].VpcId'` → 空
- [ ] `aws iam get-role --role-name eks-production-alb-controller` → NoSuchEntity
- [ ] step 40 が exit 0 (= orphan 0 件)
- [ ] AWS Secrets Manager の secret 値が **そのまま残存** (= `aws secretsmanager list-secrets --query 'SecretList[].Name'`)

- [ ] **Step 3: 24h 経過後 cost 確認**

```bash
# AWS Cost Explorer で前日課金を確認
aws ce get-cost-and-usage --time-period Start=$(date -v-1d +%Y-%m-%d),End=$(date +%Y-%m-%d) --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

Expected: NAT Gateway / EC2 / EBS の課金停止、Route53 hosted zone $0.50/月程度のみ残

- [ ] **Step 4: recreate live run**

```bash
make eks-recreate ENV=production
```

完了後 checklist:

- [ ] `kubectl get nodes` → system MNG 2 ノード Ready
- [ ] Phase 1 全 HelmRelease Ready
- [ ] Phase 2 NodePool Ready
- [ ] Phase 3 全 observability HelmRelease Ready
- [ ] Phase 4 cert-manager / external-secrets / reloader Ready
- [ ] Phase 5 oauth2-proxy / nginx-sample Ready
- [ ] **ESO 経由で AWS Secrets Manager secret 値が `kubectl get secret -n default <name> -o jsonpath='{.data.<key>}' | base64 -d` で取得でき、teardown 前と同一値**
- [ ] `curl https://<nginx host>.panicboat.net/` → HTTP 200
- [ ] Tempo UI で nginx の HTTP request span を query → 検出

- [ ] **Step 5: spec の §7.4 完了条件すべて pass を確認**

`docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md` §7.4 に記載の 6 つの完了条件すべて pass を spec に handoff doc 等で記録。
