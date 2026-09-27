# Comment Rules Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** リポジトリ全体のコードベースを走査し、AGENTS.md および Coding Rules に違反しているコメント（日本語コメント、複数行コメントブロック、バナー/デコレーション、自明な "What" コメント、変更履歴・タスク言及）をすべて修正・整理する。

**Architecture:** 違反コメントをカテゴリ（Root設定、Scripts、AWS Terraform/Terragrunt、Kubernetesマニフェスト/Helmfile）ごとに分類し、自明な説明や不要なバナーは削除、非自明な技術制約（Why not）のみを1行の英語コメントとして残す。最後に `hydrate-index.sh` で生成マニフェストを同期し、自動走査スクリプトで違反ゼロを検証する。

**Tech Stack:** Shell, Terraform/Terragrunt (HCL), Helmfile, Kustomize, Kubernetes YAML, Python (for verification)

## Global Constraints

- コード内の要素（変数名・関数名・コメント・コミットメッセージ）は英語 MUST
- コードコメントは Why not（なぜ "他のやり方" を採らなかったか＝制約・落とし穴）のみとし、自明な "what" は書かない MUST
- 1コメントは1行に収める MUST（複数行のコメントブロック・docstring は書かない）
- "when"（変更履歴）や現在のタスク・修正への言及をしない MUST
- 比較表現（"simple", "complex", "easy", "hard" など）を避ける MUST
- コミット時に `-s`（`--signoff`）オプションを使用する MUST
- コミットメッセージに `Co-Authored-By` を付与することを禁止 MUST

---

### Task 1: Clean Up Root Configuration and Entry Points

**Files:**
- Modify: `Makefile`
- Modify: `aqua.yaml`
- Modify: `workflow-config.yaml`

- [ ] **Step 1: Edit `Makefile`**
  - 行1-12の複数行コメントブロック（Usage、自明な説明、日本語）を削除。

- [ ] **Step 2: Edit `aqua.yaml`**
  - 行2-8の複数行コメントブロック（日本語、過去の事象言及）を、1行の英語制約コメント `# Kept at repo root so aqua resolves identically in local shells and CI without AQUA_CONFIG.` に修正。

- [ ] **Step 3: Edit `workflow-config.yaml`**
  - 行9-14のコメントアウトされたデッドコードを削除。

- [ ] **Step 4: Verify syntax and commit**
  - `git diff` を確認し、`-s` 付きでコミット。

---

### Task 2: Clean Up Lifecycle and Automation Scripts

**Files:**
- Modify: `scripts/eks-lifecycle/teardown.sh`
- Modify: `scripts/eks-lifecycle/lib/common.sh`
- Modify: `scripts/eks-lifecycle/lib/00-auth.sh`
- Modify: `scripts/eks-lifecycle/lib/10-k8s-cleanup.sh`
- Modify: `scripts/eks-lifecycle/lib/30-destroy-stacks.sh`
- Modify: `scripts/eks-lifecycle/lib/40-orphan-verify.sh`
- Modify: `scripts/kubernetes-hydrate/hydrate-component.sh`
- Modify: `scripts/kubernetes-hydrate/hydrate-index.sh`
- Modify: `scripts/post-flight/check-pod-identity-injection.sh`

- [ ] **Step 1: Edit `scripts/eks-lifecycle/teardown.sh` & `common.sh`**
  - 複数行ブロック・バナー・自明なセクション名を削除。
  - `common.sh` のBSD sed互換性などの非自明な制約コメントのみ1行英語で保持。

- [ ] **Step 2: Edit `scripts/eks-lifecycle/lib/00-auth.sh` & `10-k8s-cleanup.sh`**
  - 日本語コメントを英語の1行コメントに変換（フォールバック処理には `# FALLBACK:` プレフィックスを適用）。
  - 不要な自明コメントを削除。

- [ ] **Step 3: Edit `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` & `40-orphan-verify.sh`**
  - 日本語コメントおよび複数行コメントを1行英語（制約/Why not）に要約。

- [ ] **Step 4: Edit `scripts/kubernetes-hydrate/hydrate-component.sh` & `hydrate-index.sh`**
  - ファイル先頭の複数行説明ブロックを整理し、`--kube-version` などの技術制約は1行英語コメントに要約。

- [ ] **Step 5: Edit `scripts/post-flight/check-pod-identity-injection.sh`**
  - 冒頭のバナー・引き継ぎ事項言及・日本語コメントブロックを削除（詳細はREADMEに委譲）。
  - スクリプト内の日本語インラインコメントを英語の1行コメントに修正。

- [ ] **Step 6: Shellcheck / bash syntax check and commit**
  - `bash -n scripts/**/*.sh` で構文チェックし、`-s` 付きでコミット。

---

### Task 3: Clean Up AWS Terraform and Terragrunt Files

**Files:**
- Modify: `aws/**/root.hcl`
- Modify: `aws/**/env.hcl`
- Modify: `aws/**/terragrunt.hcl`
- Modify: `aws/**/main.tf`
- Modify: `aws/**/variables.tf`
- Modify: `aws/**/outputs.tf`
- Modify: `aws/**/terraform.tf`
- Modify: `aws/**/Makefile`

- [ ] **Step 1: Remove boilerplate header and section comments across `aws/`**
  - `root.hcl`, `env.hcl`, `terragrunt.hcl`, `Makefile` 等の自明な What コメント（ファイル名、プロバイダー説明、標準タグ説明など）を一括削除。

- [ ] **Step 2: Clean up and translate constraint comments in `aws/`**
  - `aws/iam-service-linked-roles/modules/main.tf`: 複数行日本語ブロックを1行英語 `# EC2 Spot SLR is an account singleton required for Karpenter spot instances, managed here to avoid recreate churn.` に集約。
  - `aws/route53/modules/main.tf`: DKIM split、Google MX、Apex TXT のコメントを1行英語に整形。
  - `aws/route53/modules/zone_access.tf`: 1行英語に整形。
  - `aws/route53/master/env.hcl`: 日本語コメントを英語化。
  - `aws/route53/master/terragrunt.hcl`: go-getter `//` コメントを1行英語に整形。
  - `aws/secrets-manager/modules/main.tf`: 日本語コメントブロックを1行英語 `# Secret containers only; secret values are kept out of tfstate/git to prevent plaintext leakage.` に集約。
  - `aws/vpc/modules/main.tf`: Default SG lockdown、Gateway VPC Endpoint の日本語コメントを1行英語に集約。

- [ ] **Step 3: Verify with tofu/terragrunt validation (or syntax check) and commit**
  - コミット（`-s`）。

---

### Task 4: Clean Up Kubernetes Core and Cluster Configurations

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`
- Modify: `kubernetes/clusters/production/**/*.yaml`

- [ ] **Step 1: Clean up `kubernetes/helmfile.yaml.gotmpl`**
  - 冒頭バナー・Usage を削除。
  - RECREATE marker convention ブロックを1行英語の参照コメントに集約。
  - `# STABLE:` コメントの日本語を英語に修正。
  - Mimir/Loki/Tempo の Source コメントを1行英語に整形。
  - コメントアウトされた `staging` ブロックを削除。

- [ ] **Step 2: Clean up `kubernetes/clusters/production/**/*.yaml`**
  - バナー、複数行ブロック、日本語コメントを削除または1行英語制約に整形。

- [ ] **Step 3: Commit**
  - コミット（`-s`）。

---

### Task 5: Clean Up Kubernetes Component Configurations

**Files:**
- Modify: `kubernetes/components/**/namespace.yaml`
- Modify: `kubernetes/components/**/production/helmfile.yaml`
- Modify: `kubernetes/components/**/production/values.yaml.gotmpl`
- Modify: `kubernetes/components/**/production/kustomization/*.yaml`

- [ ] **Step 1: Clean up `namespace.yaml` across all components**
  - バナー・自明な What コメントを削除。Falco などの非自明な分離理由（Why not）のみ1行英語で残す。

- [ ] **Step 2: Clean up `production/helmfile.yaml` across all components**
  - バナー・自明なリリース説明を削除。チャート固有の回避策（Why not）のみ1行英語で残す。

- [ ] **Step 3: Clean up `production/values.yaml.gotmpl` across all components**
  - バナー、区切り線、自明なセクション見出しを全削除。
  - CPU/メモリのサイジング根拠や設定制約のみ1行英語で残す。

- [ ] **Step 4: Clean up `production/kustomization/*.yaml` across all components**
  - バナー、自明コメントを削除。制約コメントのみ1行英語で残す。

- [ ] **Step 5: Commit**
  - コミット（`-s`）。

---

### Task 6: Hydrate Manifests and Final Full Scan Verification

**Files:**
- Generate: `kubernetes/manifests/production/00-namespaces/namespaces.yaml`

- [ ] **Step 1: Run hydrate script**
  - `bash scripts/kubernetes-hydrate/hydrate-index.sh production` を実行し、`00-namespaces/namespaces.yaml` に修正後の namespace 定義が反映されることを確認。

- [ ] **Step 2: Run automated violation detection scan**
  - スクリプトでリポジトリ全コード（generated manifest 除く）のコメントを走査し：
    - 日本語コメント: 0件
    - バナー (`# ===`, `# ---`): 0件
    - 複数行コメントブロック: 0件（または許容される特殊記号のみ）
    であることを検証。

- [ ] **Step 3: Review git diff and commit**
  - `git diff` を最終確認し、コミット（`-s`）。

- [ ] **Step 4: Push branch and create Draft PR**
  - `git push -u origin HEAD`
  - `gh pr create --draft --title "chore: clean up code comments per documentation rules" --body "..."`
