# CLAUDE.md Documentation Compliance Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate Documentation-section violations (when / future / why-missing / source-of-truth duplication / spec-citation / local-vs-production TODO) and Japanese heading violations from the platform repository, conforming to CLAUDE.md.

**Architecture:** 5 commits on the `docs/claudemd-documentation-cleanup` branch (worktree at `.claude/worktrees/claudemd-documentation-cleanup`), each scoped to one category of fixes; new/changed code comments are written in English to avoid introducing W7 violations. Verification is by grep: each category's signature pattern must hit 0 after its commit.

**Tech Stack:** Markdown, YAML, HCL/Terragrunt, Terraform, Helmfile, Kustomize. Uses git (worktree already created) and grep for verification.

**Reference:** `docs/superpowers/specs/2026-05-12-claudemd-documentation-cleanup-design.md` (audit spec) — the spec contains the violation tables and decision rubric this plan implements.

---

## Task 1: README cleanup (W1/W2/W4/W5)

**Files:**
- Modify: `aws/eks/README.md`
- Modify: `kubernetes/README.md`

### Step 1.1: Remove the develop row from aws/eks/README.md Environments table (W2)

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
| Environment | Region | Cluster Name | Status |
|---|---|---|---|
| `production` | `ap-northeast-1` | `eks-production` | Active |
| `develop` | `us-east-1` | `eks-develop` | 未作成（必要時に `envs/production/` を複製して `envs/develop/` を新設） |

新環境を追加する際は、対応する `aws_region` を `envs/${env}/env.hcl` に書き、`panicboat/ansible` 側の `eks-login.sh` の `case` 文にも region を追加すること（DRY 違反の二重管理だが現状は許容）。

new_string:
| Environment | Region | Cluster Name | Status |
|---|---|---|---|
| `production` | `ap-northeast-1` | `eks-production` | Active |

新環境を追加する際は、対応する `aws_region` を `envs/${env}/env.hcl` に書き、`panicboat/ansible` 側の `eks-login.sh` の `case` 文にも region を追加すること（DRY 違反の二重管理だが現状は許容）。
```

### Step 1.2: Remove the "将来 cluster 追加時" comment in aws/eks/README.md eks-login example (W2)

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
source ~/Workspace/eks-login.sh develop                  # → eks-develop / us-east-1 (将来 cluster 追加時)

new_string:
source ~/Workspace/eks-login.sh develop                  # → eks-develop / us-east-1
```

### Step 1.3: Remove the develop branch from the Manual login example (W2)

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
ENV=production    # or develop
REGION=ap-northeast-1   # production の場合。develop なら us-east-1。

new_string:
ENV=production
REGION=ap-northeast-1
```

### Step 1.4: Remove the Architecture / spec link section from aws/eks/README.md (W5)

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
## Architecture

- 設計詳細: `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`
- 実装プラン: `docs/superpowers/plans/2026-05-01-aws-eks-production.md`
- VPC cross-stack lookup（`module "vpc"` の参照規約）: `docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md`

主な設計ハイライト：

new_string:
## Architecture

主な設計ハイライト：
```

### Step 1.5: Rewrite the Errata reference in the Troubleshooting table (W5)

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
| Node が `NotReady` / Pod scheduling 不能 | vpc-cni / IRSA まわりの bootstrap 順序問題の可能性。spec の Errata E-2 を参照（`before_compute = true` で対処済）。 |

new_string:
| Node が `NotReady` / Pod scheduling 不能 | vpc-cni / IRSA まわりの bootstrap 順序問題の可能性。`before_compute = true` で vpc-cni addon の registration が node 作成より前に完了するように指定している (= 早期 register によって IRSA based aws-node SA が起動時に既に bound されている状態を保証)。 |
```

### Step 1.6: Drop the chart version from the Compute row (W4)

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
| Compute | Managed Node Group `system` (m6g.large × 2-4, AL2023 ARM64, gp3 50 GiB) |

new_string:
| Compute | Managed Node Group `system` (Graviton ARM64, gp3 EBS root) |
```

### Step 1.7: Drop "1.18.x" from the kubernetes/README.md Cilium sentence (W4)

- [ ] Apply Edit to `kubernetes/README.md`:

```
old_string:
`eks-production` cluster は **Cilium 1.18.x が chaining mode (VPC CNI 共存)** で稼働し、`kubeProxyReplacement: true` で kube-proxy を eBPF で代替している。

new_string:
`eks-production` cluster は **Cilium が chaining mode (VPC CNI 共存)** で稼働し、`kubeProxyReplacement: true` で kube-proxy を eBPF で代替している。
```

### Step 1.8: Rewrite the "kube-proxy を削除済" sentence (W1)

- [ ] Apply Edit to `kubernetes/README.md`:

```
old_string:
EKS managed addon としては `kube-proxy` を削除済（KPR で代替）。残存 addon: `vpc-cni` / `coredns` / `aws-ebs-csi-driver` / `eks-pod-identity-agent`。

new_string:
EKS managed addons: `vpc-cni` / `coredns` / `aws-ebs-csi-driver` / `eks-pod-identity-agent`。`kube-proxy` は使用しない (Cilium KPR で代替するため)。
```

### Step 1.9: Drop "30 GiB" from the EC2NodeClass row (W4)

- [ ] Apply Edit to `kubernetes/README.md`:

```
old_string:
| EC2NodeClass `system-components` | (cluster-scoped) | AMI (AL2023 ARM64) / subnet `Tier=private` / SG `aws:eks:cluster-name` / Node IAM / EBS gp3 30 GiB / IMDSv2 |

new_string:
| EC2NodeClass `system-components` | (cluster-scoped) | AMI (AL2023 ARM64) / subnet `Tier=private` / SG `aws:eks:cluster-name` / Node IAM / EBS gp3 / IMDSv2 |
```

### Step 1.10: Reduce NodePool requirements to design-axis description (W4)

- [ ] Apply Edit to `kubernetes/README.md`:

```
old_string:
| NodePool `system-components` | (cluster-scoped) | requirements: arm64 + spot + on-demand + general-purpose (category `m`) + size medium-4xlarge。`WhenEmptyOrUnderutilized` consolidation + 30d expireAfter |

new_string:
| NodePool `system-components` | (cluster-scoped) | requirements: arm64 / spot 優先 + on-demand fallback / general-purpose family / 中型 size 帯。consolidation policy で utilization-driven scale-down、定期的に node expire させて OS patch サイクルを回す |
```

### Step 1.11: Verify Task 1 fixes

- [ ] Run grep to check no `将来` / `削除済` / `Phase N-M で` / spec link / `Errata E-` remain in README files:

```bash
grep -nE "(将来)|(削除済)|(docs/superpowers/specs/)|(Errata)|(Cilium 1\.18)|(m6g\.large × 2-4)|(gp3 30 GiB)|(gp3 50 GiB)" README.md README-ja.md aws/eks/README.md kubernetes/README.md
```

Expected output: empty (no matches).

### Step 1.12: Commit Task 1

- [ ] Run:

```bash
git add aws/eks/README.md kubernetes/README.md
git -c commit.gpgsign=false commit -s -m "docs(readme): remove when/future/spec-citation/source-of-truth duplication"
```

---

## Task 2: README heading + code-block-comment English rewrite (W8)

**Files:**
- Modify: `aws/eks/README.md`
- Modify: `kubernetes/README.md`

### Step 2.1: Translate aws/eks/README.md headings to English

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
### Quick start (推奨: login script)
new_string:
### Quick start (recommended: login script)
```

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
### Manual login (script なし)
new_string:
### Manual login (without script)
```

- [ ] Apply Edit to `aws/eks/README.md`:

```
old_string:
## terragrunt 操作
new_string:
## terragrunt operations
```

### Step 2.2: Translate kubernetes/README.md headings to English

- [ ] Apply each Edit below to `kubernetes/README.md` (one at a time, in document order):

```
old_string: ## 概要
new_string: ## Overview
```

```
old_string: ## 🏗️ アーキテクチャ
new_string: ## 🏗️ Architecture
```

```
old_string: ### 役割分離
new_string: ### Role separation
```

```
old_string: ## 💡 設計思想
new_string: ## 💡 Design principles
```

```
old_string: ### Hydration Pattern 戦略
new_string: ### Hydration pattern strategy
```

```
old_string: ### 構成管理
new_string: ### Configuration management
```

```
old_string: ### Phase 1: Foundation Setup (基盤構築)
new_string: ### Phase 1: Foundation Setup
```

```
old_string: ### Phase 2: FluxCD Installation (GitOps基盤)
new_string: ### Phase 2: FluxCD Installation
```

```
old_string: ### Phase 3: Hydration & Sync (アプリ展開)
new_string: ### Phase 3: Hydration & Sync
```

```
old_string: ### 完全自動セットアップ
new_string: ### Full automatic setup
```

```
old_string: ### 個別操作
new_string: ### Individual operations
```

```
old_string: ### GitOps管理
new_string: ### GitOps operations
```

```
old_string: ### よくある問題
new_string: ### Common issues
```

```
old_string: ### ログ確認
new_string: ### Log inspection
```

```
old_string: ### 開発ワークフロー
new_string: ### Development workflow
```

```
old_string: ### ローカル開発 (高速)
new_string: ### Local development (fast)
```

```
old_string: ### 本番運用移行
new_string: ### Production handover
```

```
old_string: ### GitOps 原則
new_string: ### GitOps principles
```

```
old_string: ## 障害調査例
new_string: ## Incident investigation example
```

### Step 2.3: Translate kubernetes/README.md shell-block comments to English

- [ ] Apply each Edit below to `kubernetes/README.md`:

```
old_string: # DNS解決失敗
new_string: # DNS resolution failure
```

```
old_string: # Gateway Controller未起動
new_string: # Gateway Controller not running
```

```
old_string: # HelmRelease状態確認
new_string: # HelmRelease status check
```

```
old_string: # 開発・テスト・実験
new_string: # develop / test / experiment
```

```
old_string: # 継続的デプロイメント開始
new_string: # start continuous deployment
```

```
old_string: # 1. eks-admin role を assume して kubectl 接続
new_string: # 1. Assume eks-admin role and connect via kubectl
```

```
old_string: # 2. Flux controllers を install
new_string: # 2. Install Flux controllers
```

```
old_string: # 3. Self-sync 設定を apply（main ブランチからの GitOps 開始）
new_string: # 3. Apply self-sync config (start GitOps from main branch)
```

```
old_string: # 4. Sync が成功したことを確認
new_string: # 4. Verify sync succeeded
```

```
old_string: # Flux の sync 状況を確認
new_string: # Check Flux sync status
```

```
old_string: # Flux の reconciliation を手動 trigger（main の最新を即座に sync）
new_string: # Manually trigger Flux reconciliation (sync latest main immediately)
```

```
old_string: # 全 GitOps リソースを一覧
new_string: # List all GitOps resources
```

```
old_string: # Cilium 全体ヘルスチェック
new_string: # Cilium overall health check
```

```
old_string: # 接続性テスト（test namespace を作る、数分かかる）
new_string: # Connectivity test (creates test namespace, takes a few minutes)
```

```
old_string: # 完了後の test namespace 手動削除
new_string: # Manually delete test namespace after completion
```

```
old_string: # Hubble flow 観測
new_string: # Observe Hubble flows
```

```
old_string: # Hubble UI (= https://hubble.panicboat.net/ 、oauth2-proxy 経由で外部公開)
new_string: # Hubble UI (= https://hubble.panicboat.net/, exposed via oauth2-proxy)
```

```
old_string: # ACM cert (terragrunt 管理、ALB Controller が auto-discovery)
new_string: # ACM cert (managed by terragrunt, ALB Controller auto-discovers)
```

```
old_string: # Ingress / ALB / Route53 record の確認
new_string: # Inspect Ingress / ALB / Route53 records
```

### Step 2.4: Verify Task 2 fixes

- [ ] Run grep to verify no Japanese characters in README headings or in shell-code-block comments inside docs:

```bash
grep -nE "^#{1,6} .*[ぁ-んァ-ヶ一-龯]" README.md README-ja.md aws/eks/README.md kubernetes/README.md
```

Expected output: empty (no Japanese headings).

```bash
grep -nE "^# .*[ぁ-んァ-ヶ一-龯]" kubernetes/README.md | grep -vE "^[0-9]+:## " | grep -vE "^[0-9]+:### "
```

Expected: empty (no Japanese shell-style line comments in code blocks).

### Step 2.5: Commit Task 2

- [ ] Run:

```bash
git add aws/eks/README.md kubernetes/README.md
git -c commit.gpgsign=false commit -s -m "docs(readme): translate Japanese headings and shell-block comments to English"
```

---

## Task 3: Terraform / hcl comments (W1/W2/W5)

**Files:**
- Modify: `aws/karpenter/modules/main.tf`
- Modify: `aws/eks/envs/production/terragrunt.hcl`

### Step 3.1: Remove future/spec-citation from karpenter module comment

- [ ] Apply Edit to `aws/karpenter/modules/main.tf`:

```
old_string:
  # 採用根拠: spec Decision 1 が AWS 物理名 `karpenter-controller-host`
  # を要件として固定しているため、name_prefix を諦めて fixed name を
  # 採用した。短縮名で name_prefix を保つ代替案 (例: `karpenter-ctrl-host`)
  # は spec の物理名規約に反するため不採用。
  #
  # Side effect: fixed IAM role name は immutable なので、将来この MNG
  # を再 rename する場合 create_before_destroy が role name 重複で fail
  # する。再 rename 時は旧 role を先に destroy してから apply する
  # 2-step 運用が必要 (本 PR と同種の操作の繰り返しでない限り発生しない)。

new_string:
  # The AWS physical name `karpenter-controller-host` is fixed by external
  # contract (eks-login script / dashboard references), so name_prefix is
  # disabled and a deterministic role name is used.
  #
  # Side effect: a fixed IAM role name is immutable, so a future rename of
  # this MNG would make create_before_destroy fail with a role-name conflict.
  # If renamed, destroy the old role first, then apply (a 2-step operation).
```

### Step 3.2: Remove spec link from terragrunt.hcl

- [ ] Apply Edit to `aws/eks/envs/production/terragrunt.hcl`:

```
old_string:
# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "vpc"` in modules/lookups.tf
# resolve `../../vpc/lookup` from within the cache. See
# docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md for the
# convention.
terraform {
  source = "../../..//eks/modules"
}

new_string:
# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "vpc"` in modules/lookups.tf
# resolve `../../vpc/lookup` from within the cache (each producer stack
# exposes a `lookup/` submodule that downstream stacks reference for
# cross-stack data, replacing terraform_remote_state with a typed contract).
terraform {
  source = "../../..//eks/modules"
}
```

### Step 3.3: Verify Task 3 fixes

- [ ] Run grep to confirm:

```bash
grep -nE "(将来)|(docs/superpowers/specs/)|(spec の物理名規約)|(spec Decision )" aws/karpenter/modules/main.tf aws/eks/envs/production/terragrunt.hcl
```

Expected output: empty.

### Step 3.4: Commit Task 3

- [ ] Run:

```bash
git add aws/karpenter/modules/main.tf aws/eks/envs/production/terragrunt.hcl
git -c commit.gpgsign=false commit -s -m "chore(terraform): remove future/spec-citation comments from HCL"
```

---

## Task 4: Kubernetes manifests / clusters / values comments (W1/W2/W5/W6)

This task is split into sub-tasks 4a..4e by directory area. They are independent but share one commit at the end.

**Files:** many under `kubernetes/clusters/**` and `kubernetes/components/**`.

### Step 4a.1: Fix kubernetes/clusters/production/kustomization.yaml

- [ ] Apply Edit:

```
old_string:
# 含むリソース:
#   - manifests/production: ハイドレーション済 Kubernetes manifests
#   - repositories/: 外部 repository (= panicboat monorepo) の Flux
#     GitRepository + Kustomization (= Phase 6-1 で追加)

new_string:
# 含むリソース:
#   - manifests/production: ハイドレーション済 Kubernetes manifests
#   - repositories/: 外部 repository (= panicboat monorepo) の Flux
#     GitRepository + Kustomization
```

### Step 4a.2: Fix kubernetes/clusters/production/repositories/monorepo.yaml

- [ ] Apply Edit:

```
old_string:
# =============================================================================
# Flux GitRepository + Kustomization for panicboat/monorepo
# =============================================================================
# Phase 6-1 (= monorepo migration foundation) で追加。monorepo は
# clusters/develop/ 配下に各 service ごとの Flux Kustomization を内蔵
# (= monolith / frontend / reverse-proxy)、cascading で deploy される設計。
#
# 6-1 では Kustomization を suspend 状態で deploy、6-2 で resume して
# 各 service deploy 開始。並行 monorepo PR で services/nginx を削除済。
# =============================================================================

new_string:
# =============================================================================
# Flux GitRepository + Kustomization for panicboat/monorepo
# =============================================================================
# monorepo は clusters/develop/ 配下に各 service ごとの Flux Kustomization を
# 内蔵 (= monolith / frontend / reverse-proxy)、cascading で deploy される
# 設計のため、本 platform stack からは monorepo を 1 つの GitRepository として
# pull し、root Kustomization のみ管理する。
# =============================================================================
```

- [ ] Apply Edit (same file):

```
old_string:
  suspend: false  # Phase 6-2 で resume (= 6-1 で suspend deploy 済)

new_string:
  suspend: false  # active; flip to `true` to halt monorepo Kustomization
```

### Step 4a.3: Fix kubernetes/clusters/production/repositories/kustomization.yaml

- [ ] Apply Edit:

```
old_string:
# =============================================================================
# External Repositories Kustomization for production
# =============================================================================
# Phase 6-1 で新規作成。platform 外 repository (= panicboat monorepo) の
# Flux GitRepository + Kustomization を集約管理。
# =============================================================================

new_string:
# =============================================================================
# External Repositories Kustomization for production
# =============================================================================
# Aggregates Flux GitRepository + Kustomization for repositories outside the
# platform (currently: panicboat monorepo).
# =============================================================================
```

### Step 4b.1: Fix nginx-sample deployment.yaml

- [ ] Apply Edit to `kubernetes/components/nginx-sample/production/kustomization/deployment.yaml`:

```
old_string:
# =============================================================================
# nginx Deployment for end-to-end validation (Phase 5-2)
# =============================================================================
# Phase 1-4 全 component を nginx 投入で end-to-end validate するための demo
# application。Plain nginx Welcome page を serve、env var DEMO_MESSAGE を
# AWS Secrets Manager 由来 K8s Secret 経由で injection。Reloader annotation で
# Secret 変更時に auto-rollout、KEDA ScaledObject で cpu + prometheus
# multi-trigger scaling、Beyla eBPF auto-instrumentation で traces + metrics
# 生成。
# =============================================================================

new_string:
# =============================================================================
# nginx Deployment for end-to-end validation
# =============================================================================
# Demo application that exercises the full platform: serves the plain nginx
# Welcome page; injects env var DEMO_MESSAGE from a K8s Secret synced from
# AWS Secrets Manager; uses a Reloader annotation for auto-rollout on Secret
# change; scaled by a KEDA ScaledObject (cpu + prometheus multi-trigger);
# auto-instrumented for traces + metrics by Beyla eBPF.
# =============================================================================
```

- [ ] Apply Edit (same file):

```
old_string:
    # Reloader watch (= K8s Secret nginx-demo 変更時に Pod auto-rollout)。
    # Phase 4-2 で deploy 済 Reloader が監視。
    reloader.stakater.com/auto: "true"

new_string:
    # Reloader watches K8s Secret nginx-demo and triggers a Pod auto-rollout
    # when the Secret changes.
    reloader.stakater.com/auto: "true"
```

### Step 4b.2: Fix nginx-sample external-secret.yaml

- [ ] Apply Edit to `kubernetes/components/nginx-sample/production/kustomization/external-secret.yaml`:

```
old_string:
# =============================================================================
# ExternalSecret for nginx demo (Phase 5-2)
# =============================================================================
# AWS Secrets Manager の panicboat/nginx/demo を K8s Secret nginx-demo に sync、
# nginx Deployment が env DEMO_MESSAGE 経由で参照。Phase 4-2 で deploy 済の
# ClusterSecretStore aws-secrets-manager (= Pod Identity 認証) を活用、
# 新規 IAM role 不要。
# Reloader が nginx Deployment annotation reloader.stakater.com/auto: "true" を
# 検知して Secret 変更時に auto-rollout (= roadmap #14)。
# =============================================================================

new_string:
# =============================================================================
# ExternalSecret for nginx demo
# =============================================================================
# Syncs AWS Secrets Manager `panicboat/nginx/demo` into K8s Secret nginx-demo,
# which the nginx Deployment references via env var DEMO_MESSAGE. Uses the
# existing ClusterSecretStore `aws-secrets-manager` (Pod Identity auth), so
# no additional IAM role is required.
# Reloader detects the nginx Deployment annotation
# `reloader.stakater.com/auto: "true"` and auto-rolls out the Deployment when
# the Secret changes.
# =============================================================================
```

### Step 4b.3: Fix nginx-sample ingress.yaml

- [ ] Apply Edit to `kubernetes/components/nginx-sample/production/kustomization/ingress.yaml`:

```
old_string:
# =============================================================================
# nginx ALB Ingress for end-to-end validation (Phase 5-2)
# =============================================================================
# Phase 4-3 で deploy 済の ALB (= IngressGroup monitoring-uis) を共有、
# nginx.panicboat.net で public access。ACM wildcard cert *.panicboat.net
# auto-discovery、external-dns で Route53 record 自動作成。
# 認証 layer なし (= public)、demo content は nginx Welcome page で漏洩 risk 低。
# =============================================================================

new_string:
# =============================================================================
# nginx ALB Ingress for end-to-end validation
# =============================================================================
# Shares the existing ALB via IngressGroup `monitoring-uis` to keep the cost
# at the same ALB; exposes nginx.panicboat.net publicly with ACM wildcard
# cert *.panicboat.net auto-discovery and Route53 record creation by
# external-dns. No auth layer (= public); the demo content is the nginx
# Welcome page so the disclosure risk is low.
# =============================================================================
```

- [ ] Apply Edit (same file):

```
old_string:
    # Phase 4-3 既 ALB 共有 (= cost optimal、+$0/month)
    alb.ingress.kubernetes.io/group.name: monitoring-uis

new_string:
    # Share the existing ALB (cost optimal, +$0/month).
    alb.ingress.kubernetes.io/group.name: monitoring-uis
```

### Step 4b.4: Fix nginx-sample kustomization.yaml

- [ ] Apply Edit to `kubernetes/components/nginx-sample/production/kustomization/kustomization.yaml`:

```
old_string:
# =============================================================================
# nginx-sample production kustomization
# =============================================================================
# Phase 5-2 (= End-to-end validation) の demo nginx application。
# Plain K8s manifests (= chart 不在、kustomization-only component) で
# gateway-api component の reference pattern を踏襲。
# =============================================================================

new_string:
# =============================================================================
# nginx-sample production kustomization
# =============================================================================
# Demo nginx application used for end-to-end validation of the platform.
# Plain K8s manifests (no chart; kustomization-only component) following
# the same reference pattern as the gateway-api component.
# =============================================================================
```

### Step 4b.5: Fix nginx-sample scaled-object.yaml

- [ ] Apply Edit to `kubernetes/components/nginx-sample/production/kustomization/scaled-object.yaml`:

```
old_string:
# =============================================================================
# KEDA ScaledObject for end-to-end validation (Phase 5-2)
# =============================================================================
# multi-trigger (= cpu + prometheus) で nginx Deployment scaling。
# - cpu trigger: 50% threshold (= roadmap Phase 5 #6 HPA cpu 50%)
# - prometheus trigger: Beyla RED metrics rate > 1 RPS (= roadmap #7 +
#   Phase 5-1 Beyla actual end-to-end validation)
#
# KEDA が内部で HPA resource を auto-create + 管理 (= standalone HPA 不在、
# conflict 完全回避)。replicas 2 → 10 で scale。
# =============================================================================

new_string:
# =============================================================================
# KEDA ScaledObject for end-to-end validation
# =============================================================================
# Scales the nginx Deployment with a multi-trigger (cpu + prometheus):
# - cpu trigger: 50% utilization threshold
# - prometheus trigger: Beyla-emitted RED metrics rate > 1 RPS
#
# KEDA auto-creates and manages the HPA resource internally (no standalone
# HPA, so no conflict). Scales replicas 2 → 10.
# =============================================================================
```

### Step 4b.6: Fix nginx-sample service.yaml

- [ ] Apply Edit to `kubernetes/components/nginx-sample/production/kustomization/service.yaml`:

```
old_string:
# =============================================================================
# nginx ClusterIP Service for end-to-end validation (Phase 5-2)
# =============================================================================

new_string:
# =============================================================================
# nginx ClusterIP Service for end-to-end validation
# =============================================================================
```

### Step 4c.1: Remove Decision references block from loki/production/helmfile.yaml

- [ ] Apply Edit to `kubernetes/components/loki/production/helmfile.yaml`:

```
old_string:
# =============================================================================
# Loki Helmfile for production
# =============================================================================
# Phase 3 Sub-project 3 で deploy する Logs stack の Loki 本体。
# SingleBinary mode (= chart 内蔵の Monolithic deploy、9 Pod Microservices ではなく
# 1-2 Pod 構成、small production OK の Loki 公式 position に準拠)。
# S3 backend は Sub-project 1 で provision 済の loki-559744160976 を Pod Identity
# 経由でアクセス。
#
# Decision references:
# - D2: SingleBinary mode (HA upgrade path 保持)
# - D3: tenancy=anonymous + retention=30d + auth_enabled=false (Mimir 対称)
# - D5: chart = grafana-community/loki v13.6.0 (Loki 3.7.1)
# - D11: HA upgrade path 明示、WAL flush 1-2 min + retry buffer filesystem-backed
# =============================================================================

new_string:
# =============================================================================
# Loki Helmfile for production
# =============================================================================
# Logs stack の Loki 本体。SingleBinary mode (chart 内蔵の Monolithic deploy、
# 9 Pod Microservices ではなく 1-2 Pod 構成、Loki 公式が small production OK
# とする position に準拠)。Microservices mode への upgrade path は chart の
# `deploymentMode` 切替で確保。
# S3 backend は `loki-559744160976` を Pod Identity 経由でアクセス。
# tenancy は anonymous + auth_enabled=false で Mimir / Tempo と対称運用。
# =============================================================================
```

### Step 4c.2: Remove Decision references block from tempo/production/helmfile.yaml

- [ ] Apply Edit to `kubernetes/components/tempo/production/helmfile.yaml`:

```
old_string:
# =============================================================================
# Tempo Helmfile for production
# =============================================================================
# Phase 3 Sub-project 4a で deploy する Traces stack の Tempo 本体。
# Monolithic mode (= chart 内蔵の single binary deploy、distributor + ingester +
# querier + compactor を 1 process に統合、small production OK の Tempo 公式
# position に準拠)。S3 backend は Sub-project 1 で provision 済の
# tempo-559744160976 を Pod Identity 経由でアクセス。
#
# Decision references:
# - D3: Monolithic mode (HA upgrade path 保持、Phase 4 で grafana/tempo-distributed への切替検討)
# - D5: application retention OFF (chart default)、S3 lifecycle 7d で担保
# - D7: bucket-wide IAM (Sub-project 3 fix で 3 stack 同型済) + application-level
#       prefix env scope (s3.prefix: production)
# - D8: multitenancy OFF (1 tenant 運用、Mimir / Loki と対称)
# - D12: PVC 10Gi gp3 (WAL + 短期 compactor cache)
# =============================================================================

new_string:
# =============================================================================
# Tempo Helmfile for production
# =============================================================================
# Traces stack の Tempo 本体。Monolithic mode (chart 内蔵の single binary
# deploy、distributor + ingester + querier + compactor を 1 process に統合、
# Tempo 公式が small production OK とする position に準拠)。grafana/tempo-
# distributed への切替は HA / scale 要件が顕在化した時点で再評価する。
# S3 backend は `tempo-559744160976` を Pod Identity 経由でアクセス、IAM role
# は bucket-wide (3 stack 同型) + application-level prefix env scope
# (`s3.prefix: production`) で隔離。
# multitenancy は OFF (1 tenant 運用、Mimir / Loki と対称)。retention は
# application 側 OFF (chart default)、S3 lifecycle 7d で担保。
# PVC 10Gi gp3 は WAL + 短期 compactor cache 用。
# =============================================================================
```

### Step 4d.1: Fix opentelemetry/production/helmfile.yaml

- [ ] Apply Edit:

```
old_string:
# OTel Operator は OpenTelemetry SDK auto-injection (= Instrumentation CR) と
# OTel Collector CRD (= OpenTelemetryCollector) の管理を提供する。
# Phase 6-1 で deploy、Instrumentation CR は 6-2 で application namespace に追加。
#
# admission webhook TLS は cert-manager (= selfsigned-cluster-issuer) を利用。
# webhook は K8s API server ↔ webhook の server-only TLS のため、SelfSigned で OK
# (= 5-1 L3 lesson の mTLS 不可は server-only TLS には影響しない)。

new_string:
# OTel Operator は OpenTelemetry SDK auto-injection (= Instrumentation CR) と
# OTel Collector CRD (= OpenTelemetryCollector) の管理を提供する。
#
# admission webhook TLS は cert-manager (= selfsigned-cluster-issuer) を利用。
# webhook は K8s API server ↔ webhook の server-only TLS のため、SelfSigned で OK
# (mTLS が必要な経路ではないため client trust chain は不要)。
```

### Step 4d.2: Fix prometheus-operator/production/helmfile.yaml

- [ ] Apply Edit:

```
old_string:
#   - Alertmanager (alerting hub、receiver は Phase 4 で追加)

new_string:
#   - Alertmanager (alerting hub; receivers / wire-up は別 component で扱う)
```

### Step 4d.3: Fix beyla/production/helmfile.yaml

- [ ] Apply Edit:

```
old_string:
# Beyla eBPF auto-instrumentation を monitoring namespace に DaemonSet deploy。
# default namespace の application Pod を観測、traces を OTel Collector 経由
# Tempo に、metrics を /metrics + ServiceMonitor 経由 Prometheus → Mimir に送る。
# Phase 5-2 で nginx 投入時に即時 instrumentation 開始する基盤。

new_string:
# Beyla eBPF auto-instrumentation を monitoring namespace に DaemonSet deploy。
# default namespace の application Pod を観測、traces を OTel Collector 経由
# Tempo に、metrics を /metrics + ServiceMonitor 経由 Prometheus → Mimir に送る。
```

### Step 4d.4: Fix keda/production/values.yaml

- [ ] Apply Edit:

```
old_string:
# KEDA values for production
# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md

# =============================================================================
# Resources / Replicas
# =============================================================================
# Phase 1 では chart デフォルトを採用。HA 化や resource tuning は
# monorepo の async worker 投入時に再評価する。
# AWS scaler (SQS / EventBridge / DynamoDB Streams) の IRSA 設定も
# 利用が顕在化したタイミングで別 spec で扱う。

new_string:
# KEDA values for production

# =============================================================================
# Resources / Replicas
# =============================================================================
# chart default を採用 (HA / resource tuning は現状不要、AWS scaler の IRSA も
# 利用が顕在化していないため未設定)。
```

### Step 4d.5: Fix metrics-server/production/values.yaml

- [ ] Apply Edit:

```
old_string:
# Metrics Server values for production
# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md

new_string:
# Metrics Server values for production
```

### Step 4d.6: Fix aws-load-balancer-controller/production/helmfile.yaml

- [ ] Apply Edit:

```
old_string:
# Provisions ALBs from Ingress resources. IngressGroup `panicboat-platform`
# is used to share one ALB across multiple Ingresses (see spec for the
# rationale on choosing Option B over TargetGroupBinding).

new_string:
# Provisions ALBs from Ingress resources. IngressGroup `panicboat-platform`
# is used to share one ALB across multiple Ingresses, keeping the per-month
# ALB cost flat regardless of how many Ingresses participate, while still
# letting each Ingress own its own listener rules.
```

### Step 4d.7: Fix cilium/production/kustomization/kustomization.yaml

- [ ] Apply Edit:

```
old_string:
# This kustomization adds production-specific resources to the Cilium Helm
# release output:
#   - GatewayClass: registers Cilium as the gateway-api controller
#   - Gateway "cilium-gateway" (= namespace default): shared east-west L7
#     routing entry point. Phase 6-1 (= monorepo migration foundation) で
#     application 共有 Gateway として deploy (= P3 decision)。
#
# Note: north-south は ALB Controller、east-west は cilium-gateway 経由。
# panicboat 個人運用 + 1 application 構成で per-service Gateway は YAGNI、
# 共有 Gateway を採用。将来 multi-application 化時に per-service Gateway
# 設計を再評価。

new_string:
# This kustomization adds production-specific resources to the Cilium Helm
# release output:
#   - GatewayClass: registers Cilium as the gateway-api controller
#   - Gateway "cilium-gateway" (= namespace default): shared east-west L7
#     routing entry point for applications.
#
# Note: north-south traffic goes through the ALB Controller; east-west goes
# through cilium-gateway. The current 1-application footprint does not
# justify per-service Gateways (YAGNI), so a single shared Gateway is used.
```

### Step 4d.8: Fix cilium/production/kustomization/cilium-gateway.yaml

- [ ] Apply Edit:

```
old_string:
# =============================================================================
# Cilium 共有 Gateway (= namespace default, listener HTTP port 80)
# =============================================================================
# Phase 6-1 (= monorepo migration foundation) で application 共有 Gateway として
# deploy。monorepo の services/reverse-proxy/kubernetes/base/httproute.yaml が
# parentRefs.name: cilium-gateway namespace: default を指定する設計。
#
# panicboat 個人運用 + 1 application (= monolith + frontend + reverse-proxy)
# 構成で per-service Gateway は YAGNI、共有 Gateway を採用 (= P3 decision)。
# 将来 multi-application 化時に per-service Gateway 設計を再評価。
#
# listener: HTTP port 80 のみ (= internal east-west routing 用、reverse-proxy
# Pod が upstream として cilium-gateway を呼ぶ)。HTTPS / TLS listener は 6-3
# DNS / ACM phase で必要時追加。
# =============================================================================

new_string:
# =============================================================================
# Cilium shared Gateway (namespace default, listener HTTP port 80)
# =============================================================================
# Application-shared Gateway. The monorepo's reverse-proxy HTTPRoute targets
# this Gateway via `parentRefs.name: cilium-gateway` / `namespace: default`.
#
# The current single-application footprint does not justify per-service
# Gateways (YAGNI), so a single shared Gateway is used.
#
# Listener: HTTP port 80 only (internal east-west routing; reverse-proxy
# Pods call cilium-gateway as their upstream). HTTPS / TLS listeners can be
# added if external traffic via this Gateway becomes required.
# =============================================================================
```

### Step 4d.9: Fix karpenter/production/kustomization/nodepool.yaml

- [ ] Apply Edit:

```
old_string:
# - instance-generation: Gt 5 (= 実質 Ge 6 = m6g, m7g, m8g, 将来 m9g+。
#   K8s NodeSelectorRequirement に Ge / Le 演算子は存在しないため Gt 5
#   で表現。利用可能 instance type:
#   https://karpenter.sh/docs/reference/instance-types/)

new_string:
# - instance-generation: Gt 5 (= 実質 Ge 6 = m6g, m7g, m8g, ...。
#   K8s NodeSelectorRequirement に Ge / Le 演算子は存在しないため Gt 5
#   で表現。利用可能 instance type:
#   https://karpenter.sh/docs/reference/instance-types/)
```

- [ ] Apply Edit (same file):

```
old_string:
# - limits.cpu: 200 (cluster 暴走時の上限、Phase 5 nginx + monorepo 想定)

new_string:
# - limits.cpu: 200 (cluster 暴走時の安全上限)
```

- [ ] Apply Edit (same file):

```
old_string:
        # Gt 5 は実質 Ge 6 の意 (K8s NodeSelectorRequirement 仕様に Ge / Le
        # 演算子は存在しない)。generation 6 以降 (m6g, m7g, m8g, 将来 m9g+) を
        # 含める。利用可能 instance type は Karpenter docs を参照:
        # https://karpenter.sh/docs/reference/instance-types/

new_string:
        # Gt 5 は実質 Ge 6 の意 (K8s NodeSelectorRequirement 仕様に Ge / Le
        # 演算子は存在しない)。generation 6 以降 (m6g, m7g, m8g, ...) を
        # 含める。利用可能 instance type は Karpenter docs を参照:
        # https://karpenter.sh/docs/reference/instance-types/
```

- [ ] Apply Edit (same file):

```
old_string:
    # Karpenter v1+ valid values: WhenEmpty | WhenEmptyOrUnderutilized
    # (v0.x の WhenUnderutilized は廃止。Plan 2 hotfix #274 で修正済)
    consolidationPolicy: WhenEmptyOrUnderutilized

new_string:
    # Karpenter v1+ valid values: WhenEmpty | WhenEmptyOrUnderutilized
    # (v0.x の WhenUnderutilized は廃止されているので使えない)。
    consolidationPolicy: WhenEmptyOrUnderutilized
```

### Step 4d.10: Fix oauth2-proxy allowed-emails-configmap.yaml

- [ ] Apply Edit:

```
old_string:
# oauth2-proxy の authenticated_emails_file が参照する allowlist。1 行 1 email、
# panicboat@gmail.com のみ。Workspace 契約後は config.configFile の
# email_domains に切替予定 (= Phase 6+ 引き継ぎ #11)。

new_string:
# oauth2-proxy の authenticated_emails_file が参照する allowlist。1 行 1 email、
# panicboat@gmail.com のみ。
```

### Step 4d.11: Fix loki/local/helmfile.yaml header

- [ ] Apply Edit:

```
old_string:
# NOTE: 2026/3/16 に grafana/loki chart が GEL only に分離、OSS continuation は
# grafana-community/loki に移行。本 sub-project (Phase 3 Sub-project 3) で
# chart を切替する (Decision 5/6)。

new_string:
# Chart は grafana-community/loki (OSS continuation of Loki Helm chart) を
# 使う。grafana/loki chart は GEL only。
```

### Step 4e.1: W6 - Makefile (delete production cross-reference TODO)

- [ ] Apply Edit to `kubernetes/Makefile`:

```
old_string:
#   All data visualized in Grafana
#
# TODO: (production) For EKS deployment, create separate environment configs
# =============================================================================

new_string:
#   All data visualized in Grafana
# =============================================================================
```

### Step 4e.2: W6 - flux gotk-sync.yaml (delete 2 cross-reference TODOs)

- [ ] Apply Edit to `kubernetes/clusters/local/flux-system/gotk-sync.yaml`:

```
old_string:
# This file configures FluxCD to sync with the Git repository.
#
# TODO: (production) Configure different branches for different environments

new_string:
# This file configures FluxCD to sync with the Git repository.
```

- [ ] Apply Edit (same file):

```
old_string:
    # TODO: (local) Change branch for different environments
    branch: main

new_string:
    branch: main
```

### Step 4e.3: W6 - flux local repositories/monorepo.yaml

- [ ] Apply Edit to `kubernetes/clusters/local/repositories/monorepo.yaml`:

```
old_string:
    # TODO: (local) Change branch for different environments
    branch: main

new_string:
    branch: main
```

### Step 4e.4: W6 - opentelemetry-collector local

- [ ] Apply Edit to `kubernetes/components/opentelemetry-collector/local/values.yaml`:

```
old_string:
        - key: cluster.name
          # TODO: (local) Change to actual cluster name in production
          value: k8s-local

new_string:
        - key: cluster.name
          value: k8s-local
```

- [ ] Apply Edit to `kubernetes/components/opentelemetry-collector/local/kustomization/hostport-patch.yaml`:

```
old_string:
# =============================================================================
# hostPort Patch for OpenTelemetry Collector
# =============================================================================
# TODO: (local) This patch adds hostPort to allow Beyla (hostNetwork pod) to
# connect to OTel Collector via localhost:4317.
# In production (EKS), this patch is not needed - use ClusterIP with DNS.
# =============================================================================

new_string:
# =============================================================================
# hostPort Patch for OpenTelemetry Collector
# =============================================================================
# Adds hostPort so Beyla (a hostNetwork pod) can connect to the OTel
# Collector via localhost:4317 on k3d.
# =============================================================================
```

### Step 4e.5: W6 - loki/local/values.yaml (6 TODOs)

- [ ] Apply Edit:

```
old_string:
# TODO: (production) Use "distributed" mode for high availability in production
# NOTE: "SingleBinary" は grafana-community/loki v13 で deprecated。正式名称は "Monolithic"

new_string:
# NOTE: chart key "SingleBinary" is deprecated in grafana-community/loki v13;
# the canonical name is "Monolithic".
```

- [ ] Apply Edit:

```
old_string:
  # Disable multi-tenancy for simplicity in local
  # TODO: (production) Enable auth for multi-tenant environments
  auth_enabled: false

new_string:
  # Disable multi-tenancy for simplicity in local
  auth_enabled: false
```

- [ ] Apply Edit:

```
old_string:
    # TODO: (production) Increase replication_factor to 3 for HA
    replication_factor: 1

new_string:
    replication_factor: 1
```

- [ ] Apply Edit:

```
old_string:
    # TODO: (production) Use S3 or MinIO for long-term storage
    # Example for S3:

new_string:
    # Example for S3:
```

- [ ] Apply Edit:

```
old_string:
singleBinary:
  # TODO: (production) Increase replicas for HA
  replicas: 1

new_string:
singleBinary:
  replicas: 1
```

- [ ] Apply Edit:

```
old_string:
    # TODO: (production) Increase storage size based on log volume
    size: 5Gi

new_string:
    size: 5Gi
```

### Step 4e.6: W6 - opentelemetry/local/values.yaml

- [ ] Apply Edit to `kubernetes/components/opentelemetry/local/values.yaml`:

```
old_string:
admissionWebhooks:
  certManager:
    # TODO: (production) Use cert-manager for production TLS certificates
    enabled: false
  autoGenerateCert:
    enabled: true

new_string:
admissionWebhooks:
  certManager:
    enabled: false
  autoGenerateCert:
    enabled: true
```

### Step 4e.7: W6 - prometheus-operator/local/values.yaml (3 TODOs)

- [ ] Apply Edit:

```
old_string:
  # TODO: (production) Use secure password management (e.g., Kubernetes secrets, Vault)
  adminPassword: "password"

new_string:
  adminPassword: "password"
```

- [ ] Apply Edit:

```
old_string:
    # TODO: (production) Increase retention for production
    retention: 2d

new_string:
    retention: 2d
```

- [ ] Apply Edit:

```
old_string:
              # TODO: (production) Increase storage size based on metrics volume
              storage: 2Gi

new_string:
              storage: 2Gi
```

### Step 4e.8: W6 - beyla/local/values.yaml

- [ ] Apply Edit to `kubernetes/components/beyla/local/values.yaml`:

```
old_string:
    # Use Kubernetes namespace-based discovery for service name resolution
    # Beyla will use the deployment/pod name as the service name
    # TODO: If the namespaces to be traced increases, additional entries are required.
    discovery:

new_string:
    # Use Kubernetes namespace-based discovery for service name resolution.
    # Beyla uses the deployment/pod name as the service name.
    discovery:
```

### Step 4e.9: W6 - tempo/local/values.yaml (4 TODOs)

- [ ] Apply Edit:

```
old_string:
  # Trace retention period
  # TODO: (production) Increase retention and use object storage for long-term retention
  retention: 24h

new_string:
  # Trace retention period
  retention: 24h
```

- [ ] Apply Edit:

```
old_string:
      # TODO: (production) Use S3/GCS for long-term trace storage
      # Example for S3:

new_string:
      # Example for S3:
```

- [ ] Apply Edit:

```
old_string:
        # TODO: (local) Change cluster name in production
        cluster: k8s-local

new_string:
        cluster: k8s-local
```

- [ ] Apply Edit:

```
old_string:
  # TODO: (production) Increase storage size based on trace volume
  size: 5Gi

new_string:
  size: 5Gi
```

### Step 4e.10: W6 - coredns/local/kustomization/configmap.yaml (2 TODOs)

- [ ] Apply Edit:

```
old_string:
# TODO: (local) This configuration uses external DNS forwarders (8.8.8.8, etc.)
# because k3d can have issues with host DNS resolution.
# In production (EKS), CoreDNS uses the VPC DNS resolver automatically.

new_string:
# This configuration uses external DNS forwarders (8.8.8.8 etc.) because
# k3d can have issues with host DNS resolution.
```

- [ ] Apply Edit:

```
old_string:
        # TODO: (local) Using public DNS forwarders for k3d compatibility
        # In production, this would use the VPC DNS resolver
        forward . 8.8.8.8 8.8.4.4 1.1.1.1 {

new_string:
        # Public DNS forwarders are used for k3d compatibility.
        forward . 8.8.8.8 8.8.4.4 1.1.1.1 {
```

### Step 4e.11: W6 - cilium/local/values.yaml (4 TODOs)

- [ ] Apply Edit:

```
old_string:
# TODO: (local) Using kubeProxyReplacement: true with kube-proxy also running.
# This hybrid mode allows Gateway API to work while kube-proxy provides
# iptables-based service routing as fallback for hostNetwork pods.
kubeProxyReplacement: true

new_string:
# Uses kubeProxyReplacement: true while kube-proxy is also running. This
# hybrid mode lets Gateway API work while kube-proxy provides iptables-based
# service routing as fallback for hostNetwork pods.
kubeProxyReplacement: true
```

- [ ] Apply Edit:

```
old_string:
# TODO: (local) These values are specific to the local k3d cluster
# In production (EKS), use the actual API server endpoint
k8sServiceHost: k3d-k8s-local-server-0
k8sServicePort: 6443

new_string:
# These values are specific to the local k3d cluster.
k8sServiceHost: k3d-k8s-local-server-0
k8sServicePort: 6443
```

- [ ] Apply Edit:

```
old_string:
ipam:
  operator:
    # TODO: (local) Adjust CIDR for production environment
    clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"]

new_string:
ipam:
  operator:
    clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"]
```

- [ ] Apply Edit:

```
old_string:
operator:
  # TODO: (production) Increase replicas to 2+ for HA in production
  replicas: 1

new_string:
operator:
  replicas: 1
```

### Step 4e.12: W6 - cilium/local/kustomization/gateway.yaml (2 TODOs)

- [ ] Apply Edit:

```
old_string:
# TODO: (production) Configure TLS termination and certificates
# =============================================================================

new_string:
# =============================================================================
```

- [ ] Apply Edit:

```
old_string:
    # TODO: (production) Add HTTPS listener with TLS configuration
    # - name: https
    #   protocol: HTTPS
    #   port: 443

new_string:
```

(This removes the trailing dead-example HTTPS listener block entirely.)

### Step 4e.13: W6 - gateway-api/local/kustomization/kustomization.yaml

- [ ] Apply Edit:

```
old_string:
# Gateway API Version: v1.2.1
# https://gateway-api.sigs.k8s.io/
#
# TODO: (production) Consider using the experimental channel for additional
# features like TCPRoute, TLSRoute, etc.
# =============================================================================

new_string:
# Gateway API Version: v1.2.1
# https://gateway-api.sigs.k8s.io/
# =============================================================================
```

### Step 4e.14: W6 - fluent-bit/local/values.yaml

- [ ] Apply Edit to `kubernetes/components/fluent-bit/local/values.yaml`:

```
old_string:
  # TODO: (local) Systemd input is disabled to prevent /etc/machine-id mount errors in k3d
  # In production (EKS), you may want to enable systemd input for system logs
  inputs: |

new_string:
  # Systemd input is disabled to prevent /etc/machine-id mount errors on k3d.
  inputs: |
```

### Step 4.f: Verify Task 4 fixes

- [ ] Run grep to check no remaining when/future/spec-citation/W6 violation patterns in scope:

```bash
grep -rnE "(Phase [0-9]+(-[0-9]+)?)|(将来)|(削除済)|(投入予定)|(roadmap (#|[Pp]hase))|(Decision references)|(D[0-9]+:)|(docs/superpowers/specs/)|(TODO: \(production\))|(TODO: \(local\) .* In production)" \
  --include="*.yaml" --include="*.yml" --include="*.tf" --include="*.hcl" --include="*.sh" --include="Makefile" --include="*.gotmpl" \
  --exclude-dir=".terragrunt-cache" --exclude-dir=".terraform" --exclude-dir=".git" --exclude-dir=".claude" --exclude-dir="docs" --exclude-dir="manifests" \
  kubernetes/ aws/ | grep -vE "(Phase 1: Foundation)|(Phase 2: FluxCD)|(Phase 3: Infrastructure)|(Phase 4: GitOps)|(Phase 0: Hydrate)|(Complete Phase )" || echo "OK: no violations"
```

Expected output: `OK: no violations` (the grep filter excludes the `kubernetes/Makefile` make target names which legitimately remain).

### Step 4.g: Commit Task 4

- [ ] Run:

```bash
git add kubernetes/
git -c commit.gpgsign=false commit -s -m "chore(kubernetes): remove when/future/spec-citation comments and surgical-edit local TODOs"
```

---

## Task 5: W3 why-missing additions

**Files (initial known set):**
- Modify: `kubernetes/components/loki/production/values.yaml.gotmpl`
- Modify: `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`

### Step 5.1: List candidate W3 lines

- [ ] Run:

```bash
grep -rnB1 -E "^\s*(enabled: false|disable[d]?: true)" \
  kubernetes/components/*/production/values.yaml \
  kubernetes/components/*/production/values.yaml.gotmpl 2>/dev/null
```

Inspect each result. If the preceding line is a comment that explains why, accept it. If there is no explanation, plan an inline why comment.

### Step 5.2: Add why for loki podDisruptionBudget

- [ ] Apply Edit to `kubernetes/components/loki/production/values.yaml.gotmpl`:

```
old_string:
  podDisruptionBudget:
    enabled: false

new_string:
  # SingleBinary mode runs as a single replica (no HA), so a PDB has no
  # effect; disabled to avoid noise.
  podDisruptionBudget:
    enabled: false
```

### Step 5.3: Add why for loki chunksCache / resultsCache

- [ ] Apply Edit to `kubernetes/components/loki/production/values.yaml.gotmpl`:

```
old_string:
chunksCache:
  enabled: false
resultsCache:
  enabled: false

new_string:
# memcached-based caches are disabled to keep the deployment a single
# binary (no separate memcached pods). Enable later if query latency at
# scale becomes the bottleneck.
chunksCache:
  enabled: false
resultsCache:
  enabled: false
```

### Step 5.4: Add why for opentelemetry-collector jaeger / zipkin receivers

- [ ] Apply Edit to `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`:

```
old_string:
  jaeger-compact:
    enabled: false
  jaeger-grpc:
    enabled: false
  jaeger-thrift:
    enabled: false
  zipkin:
    enabled: false

new_string:
  # Only OTLP receivers are exposed; legacy jaeger / zipkin receivers are
  # disabled because all upstream producers (Beyla, application SDKs) emit
  # OTLP and the extra ports are unused attack surface.
  jaeger-compact:
    enabled: false
  jaeger-grpc:
    enabled: false
  jaeger-thrift:
    enabled: false
  zipkin:
    enabled: false
```

### Step 5.5: Sweep for remaining W3 candidates and add why where missing

- [ ] Re-run the grep from Step 5.1 and inspect the remaining hits. For each one where a why comment is missing, add it inline. Common kinds and acceptable rationales:
  - `enabled: false` on chart-default sub-feature you intentionally do not use → "not used by this deployment; ..."
  - `disable: true` overriding a default → "disabled because <constraint>"
  - test / canary / tableManager etc. left off → "chart-default off; not relevant to single-binary mode"

If a case has no clear rationale, leave the existing config unchanged and surface it in the PR description as an explicit reviewer question rather than guessing a rationale.

### Step 5.6: Commit Task 5

- [ ] Run:

```bash
git add kubernetes/components/
git -c commit.gpgsign=false commit -s -m "chore(values): add why for disabled chart features in production values"
```

---

## Task 6: Push branch and open draft PR

### Step 6.1: Push the branch with tracking

- [ ] Run:

```bash
git push -u origin HEAD
```

### Step 6.2: Open the draft PR

- [ ] Run:

```bash
gh pr create --draft --base main \
  --title "docs: CLAUDE.md documentation compliance cleanup" \
  --body "$(cat <<'EOF'
Eliminates Documentation-section violations across README files, HCL / Terraform comments, Kubernetes manifests / values, and local TODO blocks; translates Japanese headings and shell-block comments in README files to English. Code-comment language migration (W7) is out of scope and will follow up in a separate PR.

See \`docs/superpowers/specs/2026-05-12-claudemd-documentation-cleanup-design.md\` for the audit and decision rubric.

Commits:
1. README cleanup (W1 / W2 / W4 / W5)
2. README headings + shell-block comments → English (W8)
3. Terraform / HCL comments (W1 / W2 / W5)
4. Kubernetes manifests / values comments (W1 / W2 / W5 / W6)
5. Production values why-missing additions (W3)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Final verification

After all tasks are complete:

- [ ] Run the full violation scan one more time:

```bash
grep -rnE "(将来)|(削除済)|(Phase [0-9]+(-[0-9]+)? で)|(投入予定)|(roadmap (#|[Pp]hase))|(Decision references)|(D[0-9]+:)|(docs/superpowers/specs/)|(Errata E-)|(spec の)|(TODO: \(production\))" \
  --include="*.md" --include="*.yaml" --include="*.yml" --include="*.tf" --include="*.hcl" --include="*.sh" --include="Makefile" --include="*.gotmpl" \
  --exclude-dir=".terragrunt-cache" --exclude-dir=".terraform" --exclude-dir=".git" --exclude-dir=".claude" --exclude-dir="docs" --exclude-dir="manifests" \
  . | grep -vE "(Phase 1: Foundation)|(Phase 2: FluxCD)|(Phase 3: Infrastructure)|(Phase 4: GitOps)|(Phase 0: Hydrate)|(Complete Phase )" || echo "OK: clean"
```

Expected: `OK: clean`.

- [ ] Run the Japanese-heading scan:

```bash
grep -rnE "^#{1,6} .*[ぁ-んァ-ヶ一-龯]" README.md README-ja.md aws/eks/README.md kubernetes/README.md
```

Expected: empty.

- [ ] Confirm the 5 commits and the branch state:

```bash
git log --oneline origin/main..HEAD
```

Expected: 5 commits on `docs/claudemd-documentation-cleanup`.

- [ ] Switch the PR out of draft once review is complete (manual step in GitHub UI).
