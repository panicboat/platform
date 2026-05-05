# EKS Production: Karpenter Tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plan 2 完了後の運用レビュー反映として `karpenter_bootstrap` MNG を `karpenter_controller_host` に rename し、`system-components` NodePool の requirements を簡素化 (capacity-type に SPOT 追加、category=m only、generation Gt 5) する 1 PR の implementation。

**Architecture:** Terraform `create_before_destroy` で MNG rename を単純実行 (新 MNG create → 旧 MNG destroy)。Kubernetes 側 (nodeSelector + nodepool.yaml) は Flux 経由で reconcile。Karpenter controller pod の一時 unavailable (~2-3 分) を許容、既存 system-components NodePool node には影響なし。

**Tech Stack:** terragrunt + OpenTofu / terraform-aws-modules/eks v21.19.0 (`karpenter` + `eks-managed-node-group` submodules) / Karpenter 1.6.5 / EKS 1.35 / Flux v2 / helmfile v1.4

**Spec:** `docs/superpowers/specs/2026-05-05-eks-production-karpenter-tuning-design.md`

---

## File Structure

PR で touch する 6 ファイルと、それぞれの責務:

| File | 責務 | Task |
|---|---|---|
| `aws/karpenter/modules/variables.tf` | `bootstrap_*` 5 variables を `controller_host_*` に rename | Task 1 |
| `aws/karpenter/modules/main.tf` | `module "karpenter_bootstrap"` rename + `name` 引数 + label key + コメント更新 | Task 2 |
| `kubernetes/components/karpenter/production/kustomization/nodepool.yaml` | requirements 変更 (capacity-type / category / generation) + Ge 不在コメント追加 | Task 3 |
| `kubernetes/components/karpenter/production/values.yaml.gotmpl` | nodeSelector label key 更新 + コメント | Task 4 |
| `kubernetes/components/karpenter/production/helmfile.yaml` | header コメントの bootstrap MNG 参照更新 | Task 5 |
| `kubernetes/README.md` | bootstrap 言及 2 箇所を新名に追従 | Task 6 |

**変更不要 (確認済):**
- `aws/karpenter/modules/outputs.tf`: bootstrap への参照なし、`module.karpenter.*` のみ参照
- `aws/karpenter/envs/production/terragrunt.hcl`: `bootstrap_*` を override しておらず default 値で動作
- `kubernetes/helmfile.yaml.gotmpl`: karpenter-bootstrap への直接参照なし、interruptionQueueName のみ参照

---

## Task 0: 前提条件の確認 + branch sync

**Files:** (read-only confirmation)

事前確認のみ。Plan 2 L7 lessons (squash merge 後の branch reset rollback) 対策として branch state を確認する。

- [ ] **Step 1: branch / worktree 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-tuning
git fetch origin main
git status
git log --oneline origin/main..HEAD
```

Expected:
- `On branch feat/eks-production-karpenter-tuning`
- spec の 2 commits (`8235c10`, `65e2708`) が ahead of origin/main
- working tree clean

- [ ] **Step 2: cluster current state 確認 (rollback 用 baseline)**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get nodes -L eks.amazonaws.com/nodegroup,karpenter.sh/nodepool,karpenter.sh/capacity-type
kubectl get nodepool system-components -o yaml | yq '.spec.template.spec.requirements'
aws eks list-nodegroups --cluster-name eks-production --region ap-northeast-1
```

Expected:
- nodes: `karpenter_bootstrap-...` MNG の 2 nodes (`t4g.small`) + `system-components` NodePool の 1-4 nodes (`c8g.*` 系) が Ready
- nodepool requirements に `capacity-type: ["on-demand"]` / `instance-category: ["m","c","r"]` / `instance-generation: Gt 7`
- `aws eks list-nodegroups` で `["karpenter_bootstrap-..."]` のみ

---

## Task 1: aws/karpenter/modules/variables.tf — bootstrap_* を controller_host_* に rename

**Files:**
- Modify: `aws/karpenter/modules/variables.tf`

terraform variable rename は state には影響しない (state は resource address ベース) ため、cosmetic 変更のみ。description block も新名に追従する。

- [ ] **Step 1: variables.tf を編集**

`aws/karpenter/modules/variables.tf` の line 18-52 (bootstrap MNG variables block) を以下で **完全置換**:

```hcl
# karpenter_controller_host MNG variables
# Controller host MNG hosts only the Karpenter controller pod (replicas=2). All other
# workloads (CoreDNS, Cilium operator, Flux, addons, etc.) run on Karpenter
# NodePool-managed instances (system-components NodePool) after migration.

variable "controller_host_instance_types" {
  description = "Instance types for the karpenter_controller_host managed node group (only hosts Karpenter controller pods)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "controller_host_desired_size" {
  description = "Desired number of nodes in the karpenter_controller_host node group"
  type        = number
  default     = 2
}

variable "controller_host_min_size" {
  description = "Minimum number of nodes in the karpenter_controller_host node group"
  type        = number
  default     = 2
}

variable "controller_host_max_size" {
  description = "Maximum number of nodes in the karpenter_controller_host node group"
  type        = number
  default     = 2
}

variable "controller_host_disk_size" {
  description = "EBS volume size (GiB) for karpenter_controller_host node group"
  type        = number
  default     = 20
}
```

- [ ] **Step 2: terragrunt validate で type/syntax check**

```bash
cd aws/karpenter/envs/production
TG_TF_PATH=tofu terragrunt init -upgrade
TG_TF_PATH=tofu terragrunt validate
```

Expected: `init` は provider download / module fetch で `success`、`validate` は `Success! The configuration is valid.`

注: この時点では `main.tf` の `var.bootstrap_*` 参照が未追従なので validate は **fail する** 想定 (next task で main.tf を更新するまで)。validate の error message が "Reference to undeclared input variable" で `var.bootstrap_instance_types` 等を指していれば OK (= variables の rename 自体は通っており、main.tf の追従待ち)。

```
Error: Reference to undeclared input variable
  on main.tf line 83, in module "karpenter_bootstrap":
  83:   instance_types = var.bootstrap_instance_types
```

このエラーが出ることが variable rename を確認する signal。

- [ ] **Step 3: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-tuning
git add aws/karpenter/modules/variables.tf
git commit -s -m "feat(aws/karpenter): rename bootstrap_* variables to controller_host_*

Plan 2 完了後の運用レビュー (Plan 2 learnings PR #278 / L1) で挙げた
karpenter_bootstrap MNG の命名再考に対応する 1 PR の Step 1。

variable rename は state に影響しない cosmetic 変更。次 commit で
main.tf の var.bootstrap_* 参照を var.controller_host_* に追従させる。"
```

---

## Task 2: aws/karpenter/modules/main.tf — module rename + name + labels + コメント

**Files:**
- Modify: `aws/karpenter/modules/main.tf`

`module "karpenter_bootstrap"` を `module "karpenter_controller_host"` に rename + `name = "karpenter_bootstrap"` を `"karpenter-controller-host"` に変更 + `var.bootstrap_*` 参照を `var.controller_host_*` に追従 + label key を `node-role/karpenter-bootstrap` から `node-role/karpenter-controller-host` に変更 + コメント更新。

terraform 上で module rename + name 変更は AWS API の MNG name immutability により **新 MNG create → 旧 MNG destroy** の create_before_destroy 動作になる (本 plan の core disruption point)。

- [ ] **Step 1: main.tf 上部のコメントブロック (line 1-19) を更新**

`aws/karpenter/modules/main.tf` の line 1-19 を以下で置換:

```hcl
# main.tf - Karpenter AWS-side infrastructure (Pod Identity authentication).
#
# This module provisions everything Karpenter needs in AWS:
# 1. Karpenter sub-module: SQS interruption queue + EventBridge rules +
#    Controller IAM role + EKS Pod Identity Association + Node IAM role +
#    EC2 Instance Profile.
# 2. karpenter_controller_host MNG: A small EKS managed node group
#    (t4g.small × 2) that hosts only the Karpenter controller pod itself
#    (chicken-and-egg bootstrap problem). All other workloads run on
#    Karpenter NodePool-managed instances (system-components NodePool).
#
# capacity-type は system-components NodePool 側で [spot, on-demand] を
# 採用しており、SQS interruption queue が spot 中断 (2-min warning) を
# 受けて Karpenter controller が gracefully drain & replace する経路を
# 提供する。
#
# Authentication mode は Pod Identity を採用 (sub-module v21.19.0 default)。
# Pod Identity Association が karpenter:karpenter ServiceAccount を IAM role
# に紐付けるため、Helm chart の serviceAccount.annotations に IRSA 情報を
# 入れる必要がない。
```

- [ ] **Step 2: `module "karpenter_bootstrap"` block (line 48-127) を `module "karpenter_controller_host"` に書き換え**

`aws/karpenter/modules/main.tf` の line 48-127 を以下で **完全置換**:

```hcl
# karpenter_controller_host managed node group.
#
# Standalone eks-managed-node-group submodule (not part of `module "eks"`)
# because we want Karpenter-related AWS resources to live in this stack
# rather than aws/eks/. See Plan 2 spec Decision 5 for rationale.

module "karpenter_controller_host" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.19.0"

  name         = "karpenter-controller-host"
  cluster_name = module.eks.cluster.name

  # Cluster info required by AL2023 user data generator. The standalone
  # eks-managed-node-group submodule does NOT auto-wire these from the
  # cluster name (unlike when MNGs live inside `module "eks"`), so we
  # must pass them explicitly. Sourced from aws/eks/lookup module.
  cluster_endpoint     = module.eks.cluster.endpoint
  cluster_auth_base64  = module.eks.cluster.certificate_authority_data
  cluster_service_cidr = module.eks.cluster.service_cidr
  cluster_ip_family    = module.eks.cluster.ip_family

  subnet_ids = module.vpc.subnets.private.ids

  # Cluster primary SG must be attached to nodes for cluster API access
  cluster_primary_security_group_id = module.eks.cluster.cluster_security_group_id

  # Node SG (from parent module "eks") required for node-to-node pod-network
  # traffic. Standalone eks-managed-node-group submodule does NOT attach this
  # automatically (unlike when MNGs live inside `module "eks"`), causing
  # cross-node pod traffic (e.g., controller host pod → CoreDNS on system
  # node) to be silently dropped. Sourced from aws/eks/lookup via tag-based
  # discovery.
  vpc_security_group_ids = [module.eks.cluster.node_security_group_id]

  ami_type       = "AL2023_ARM_64_STANDARD"
  instance_types = var.controller_host_instance_types
  capacity_type  = "ON_DEMAND"

  min_size     = var.controller_host_min_size
  max_size     = var.controller_host_max_size
  desired_size = var.controller_host_desired_size

  block_device_mappings = {
    root = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = var.controller_host_disk_size
        volume_type           = "gp3"
        delete_on_termination = true
      }
    }
  }

  labels = {
    "node-role/karpenter-controller-host" = "true"
  }

  taints = {
    karpenter-controller = {
      key    = "karpenter.sh/controller"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  update_config = {
    max_unavailable_percentage = 33
  }

  iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Same rationale as system MNG: CNI permissions are granted via IRSA
  # (vpc-cni IRSA bound to aws-node ServiceAccount), not via the node
  # IAM role.
  iam_role_attach_cni_policy = false

  tags = var.common_tags
}
```

- [ ] **Step 3: terragrunt validate**

```bash
cd aws/karpenter/envs/production
TG_TF_PATH=tofu terragrunt validate
```

Expected: `Success! The configuration is valid.` (Task 1 で出ていた undeclared variable error が解消)

- [ ] **Step 4: terragrunt plan で diff 確認**

```bash
TG_TF_PATH=tofu terragrunt plan
```

Expected diff:
- `module.karpenter_controller_host.aws_eks_node_group.this[0]` will be created
- `module.karpenter_bootstrap.aws_eks_node_group.this[0]` will be destroyed
- 関連 IAM role / instance profile / launch template (`module.karpenter_controller_host.aws_iam_role.this[0]` / `aws_launch_template.this[0]` 等) も create / destroy

Plan summary は概ね `Plan: ~10 to add, 0 to change, ~10 to destroy` (具体的な数は terraform-aws-modules/eks の internal 構造次第)。Karpenter sub-module (`module.karpenter`) の destroy / change は **発生しない** ことを確認 (controller IAM role / SQS / EventBridge は変更対象外)。

⚠️ もし `module.karpenter` 配下のリソースが destroy plan に含まれている場合は **STOP**。本 plan の scope 外の変更が混入している可能性 (例: 過去の terraform state 残骸、provider version drift)。原因調査が必要。

- [ ] **Step 5: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-tuning
git add aws/karpenter/modules/main.tf
git commit -s -m "feat(aws/karpenter): rename karpenter_bootstrap module to karpenter_controller_host

terraform module identifier + AWS MNG 物理名 + K8s label key を一斉に
role-explicit な命名に変更:

- module \"karpenter_bootstrap\" → module \"karpenter_controller_host\"
- name = \"karpenter_bootstrap\" → \"karpenter-controller-host\"
- node-role/karpenter-bootstrap label → node-role/karpenter-controller-host
- var.bootstrap_* 参照を var.controller_host_* に追従

terraform create_before_destroy で新 MNG create → 旧 MNG destroy。
Karpenter controller pod は新 MNG node に再 schedule される (~2-3 分の
controller unavailable を許容、既存 system-components NodePool node は
影響なし)。"
```

---

## Task 3: nodepool.yaml — requirements 変更 + Ge 不在コメント追加

**Files:**
- Modify: `kubernetes/components/karpenter/production/kustomization/nodepool.yaml`

NodePool requirements に SPOT 追加 + category=m only + generation Gt 5 への変更。ヘッダコメントを新仕様に。Ge operator 不在 + Karpenter docs link をコメントとして追加。

- [ ] **Step 1: nodepool.yaml を完全置換**

`kubernetes/components/karpenter/production/kustomization/nodepool.yaml` を以下で **完全置換**:

```yaml
# =============================================================================
# NodePool: system-components
# =============================================================================
# Karpenter が起動する EC2 instance の選定 + lifecycle policy:
# - architecture: arm64 only (cluster と一致)
# - capacity-type: spot + on-demand (Karpenter price-aware で spot 優先採用、
#   不足時 on-demand fallback。SPOT 中断は SQS interruption queue で
#   gracefully drain & replace される。system workload は全て冗長 or
#   reconcile-loop で中断耐性あり)
# - instance-category: m only (general-purpose、c/r は consolidation で
#   ほぼ選ばれず spec ノイズとして除外)
# - instance-generation: Gt 5 (= 実質 Ge 6 = m6g, m7g, m8g, 将来 m9g+。
#   K8s NodeSelectorRequirement に Ge / Le 演算子は存在しないため Gt 5
#   で表現。利用可能 instance type:
#   https://karpenter.sh/docs/reference/instance-types/)
# - instance-size: medium..4xlarge (medium 未満は burst、8xlarge+ は
#   bin-packing 悪化、metal は不要)
# - disruption: WhenEmptyOrUnderutilized + 30 日 expireAfter (OS patching
#   用 forced cycle)
# - limits.cpu: 200 (cluster 暴走時の上限、Phase 5 nginx + monorepo 想定)
# =============================================================================
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: system-components
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: system-components
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m"]
        # Gt 5 は実質 Ge 6 の意 (K8s NodeSelectorRequirement 仕様に Ge / Le
        # 演算子は存在しない)。generation 6 以降 (m6g, m7g, m8g, 将来 m9g+) を
        # 含める。利用可能 instance type は Karpenter docs を参照:
        # https://karpenter.sh/docs/reference/instance-types/
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["medium", "large", "xlarge", "2xlarge", "4xlarge"]
      expireAfter: 720h  # 30 days
  disruption:
    # Karpenter v1+ valid values: WhenEmpty | WhenEmptyOrUnderutilized
    # (v0.x の WhenUnderutilized は廃止。Plan 2 hotfix #274 で修正済)
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: "200"
```

- [ ] **Step 2: kustomize build で valid 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-tuning
kustomize build kubernetes/components/karpenter/production/kustomization 2>&1 | head -80
```

Expected: EC2NodeClass + NodePool の 2 リソースが render され、エラーなし。NodePool の requirements に新仕様 (capacity-type=[spot, on-demand] / category=[m] / generation Gt 5) が含まれること。

- [ ] **Step 3: Commit**

```bash
git add kubernetes/components/karpenter/production/kustomization/nodepool.yaml
git commit -s -m "feat(kubernetes/components/karpenter): simplify system-components NodePool requirements

system workload に最適化した requirements に絞る:

- capacity-type: [\"on-demand\"] → [\"spot\", \"on-demand\"] (cost ~70% 削減、
  Karpenter price-capacity-optimized で spot 優先 + 不足時 on-demand fallback)
- instance-category: [\"m\", \"c\", \"r\"] → [\"m\"] (general-purpose のみ、
  c/r は Karpenter consolidation でほぼ選ばれず spec ノイズ)
- instance-generation: Gt 7 (Graviton 4 のみ) → Gt 5 (m6g 以降。Ge 6 相当)

K8s NodeSelectorRequirement に Ge / Le 演算子は存在しないため Gt 5 で
表現。意図と Karpenter docs link をコメントで明示。"
```

---

## Task 4: values.yaml.gotmpl — nodeSelector label key 更新

**Files:**
- Modify: `kubernetes/components/karpenter/production/values.yaml.gotmpl`

Karpenter Helm chart に渡す `nodeSelector` の label key を `node-role/karpenter-bootstrap` から `node-role/karpenter-controller-host` に変更 + コメント更新。

- [ ] **Step 1: nodeSelector とコメント (line 12-22) を書き換え**

`kubernetes/components/karpenter/production/values.yaml.gotmpl` の line 12-22 を以下で置換:

```yaml
# =============================================================================
# Replicas / Pod placement (controller_host MNG への pin)
# =============================================================================
# replicas: 2 (chart デフォルト) を採用。HA 化済み。
replicas: 2

# Karpenter pod を karpenter_controller_host MNG 上のみに schedule する。
# Controller host MNG の taint `karpenter.sh/controller=true:NoSchedule` を
# tolerate しつつ、label `node-role/karpenter-controller-host=true` で
# 配置先を絞る。
nodeSelector:
  node-role/karpenter-controller-host: "true"
```

- [ ] **Step 2: helmfile template で render 確認**

```bash
cd kubernetes
helmfile -e production -l name=karpenter template 2>&1 | grep -A2 "nodeSelector:"
```

Expected: rendered manifest 内に `node-role/karpenter-controller-host: "true"` が含まれる。

注: helmfile template はオプション (subagent 環境で helmfile が install 済の場合のみ)。install されていない場合は `make hydrate ENV=production` (Task 7) で同等の検証を行う。install されておらず Task 7 でまとめて確認する場合はこの Step を skip して Step 3 に進む。

- [ ] **Step 3: Commit**

```bash
git add kubernetes/components/karpenter/production/values.yaml.gotmpl
git commit -s -m "feat(kubernetes/components/karpenter): update nodeSelector for controller_host MNG rename

Karpenter Helm chart の nodeSelector label key を新 MNG 命名に追従:

- node-role/karpenter-bootstrap: \"true\"
  → node-role/karpenter-controller-host: \"true\"

コメント内の MNG 参照表記も karpenter_bootstrap → karpenter_controller_host
に更新。"
```

---

## Task 5: helmfile.yaml — ヘッダコメントの MNG 参照更新

**Files:**
- Modify: `kubernetes/components/karpenter/production/helmfile.yaml`

ヘッダコメント (line 1-11) 内の "karpenter_bootstrap MNG" 表記を新名に更新。設定値 (releases / values) は変更不要。

- [ ] **Step 1: ヘッダコメント (line 1-11) を書き換え**

`kubernetes/components/karpenter/production/helmfile.yaml` の line 1-11 を以下で置換:

```yaml
# =============================================================================
# Karpenter Helmfile for production
# =============================================================================
# Provisions EC2 nodes for cluster workloads. Controller pod is pinned to
# karpenter_controller_host MNG via nodeSelector + toleration. Workload
# nodes are launched into Karpenter NodePool `system-components` (capacity
# type: spot + on-demand fallback)。
#
# Authentication: Pod Identity (provisioned by aws/karpenter/ stack の
# Pod Identity Association)。Helm chart の serviceAccount.annotations は
# 不要 (Pod Identity Association が SA-to-role mapping を直接管理)。
# =============================================================================
```

- [ ] **Step 2: Commit**

```bash
git add kubernetes/components/karpenter/production/helmfile.yaml
git commit -s -m "docs(kubernetes/components/karpenter): update helmfile header comment

karpenter_bootstrap MNG 表記を karpenter_controller_host MNG に追従。
NodePool の capacity-type が spot + on-demand fallback になった旨も
追記。"
```

---

## Task 6: kubernetes/README.md — bootstrap 言及 2 箇所更新

**Files:**
- Modify: `kubernetes/README.md` (line 337, line 458)

README 内の `karpenter_bootstrap` / `karpenter-bootstrap` 表記を新名に追従。

- [ ] **Step 1: line 337 を書き換え**

`kubernetes/README.md` の line 337 を以下で置換:

before:
```
| `karpenter_bootstrap` MNG | (`t4g.small × 2`) | Karpenter controller pod 専用の最小構成 EKS managed nodegroup。taint `karpenter.sh/controller=true:NoSchedule` で他 pod 排除、label `node-role/karpenter-bootstrap=true` で nodeSelector |
```

after:
```
| `karpenter_controller_host` MNG | (`t4g.small × 2`) | Karpenter controller pod 専用の最小構成 EKS managed nodegroup。taint `karpenter.sh/controller=true:NoSchedule` で他 pod 排除、label `node-role/karpenter-controller-host=true` で nodeSelector |
```

- [ ] **Step 2: line 458 を書き換え**

`kubernetes/README.md` の line 458 を以下で置換:

before:
```
| Karpenter pod が `karpenter_bootstrap` MNG 以外の node に schedule される | values.yaml.gotmpl の nodeSelector / tolerations が rendered manifest に反映されていない or bootstrap MNG の label / taint が誤り。`kubectl get pod -n karpenter -o wide` で 配置 node を確認、`kubectl get node -L node-role/karpenter-bootstrap` で label 確認 |
```

after:
```
| Karpenter pod が `karpenter_controller_host` MNG 以外の node に schedule される | values.yaml.gotmpl の nodeSelector / tolerations が rendered manifest に反映されていない or controller_host MNG の label / taint が誤り。`kubectl get pod -n karpenter -o wide` で 配置 node を確認、`kubectl get node -L node-role/karpenter-controller-host` で label 確認 |
```

- [ ] **Step 3: 残りの bootstrap 言及がないことを確認**

```bash
grep -n "karpenter-bootstrap\|karpenter_bootstrap" kubernetes/README.md
```

Expected: マッチなし (output 空)。

- [ ] **Step 4: Commit**

```bash
git add kubernetes/README.md
git commit -s -m "docs(kubernetes): update README for karpenter_controller_host MNG rename

Cluster overview セクション (line 337) と troubleshooting セクション
(line 458) の karpenter_bootstrap MNG 言及を karpenter_controller_host
に追従。"
```

---

## Task 7: make hydrate + PR push + Draft PR 作成

**Files:**
- Modify: `kubernetes/manifests/production/karpenter/` (hydrate 結果の auto-generated manifest)

Flux が apply する manifest (= `make hydrate` で生成される rendered yaml) を新仕様で生成 + commit + push + Draft PR 作成。

- [ ] **Step 1: make hydrate ENV=production**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-tuning/kubernetes
make hydrate ENV=production
```

Expected: `kubernetes/manifests/production/karpenter/` 配下に rendered manifest (deployment / service / nodepool / ec2nodeclass 等) が生成される。

- [ ] **Step 2: hydrated NodePool が新仕様を持つこと確認**

```bash
yq '.spec.template.spec.requirements' kubernetes/manifests/production/karpenter/karpenter.yaml.gotmpl 2>/dev/null || \
  yq 'select(.kind == "NodePool") | .spec.template.spec.requirements' kubernetes/manifests/production/karpenter/karpenter.yaml
```

(注: hydrate output ファイル名は実装パターンに従う。例: `karpenter.yaml`)

Expected: requirements に `capacity-type: ["spot", "on-demand"]` / `instance-category: ["m"]` / `instance-generation: Gt 5` が含まれる。

- [ ] **Step 3: hydrated nodeSelector が新 label key を持つこと確認**

```bash
yq 'select(.kind == "Deployment" and .metadata.name == "karpenter") | .spec.template.spec.nodeSelector' kubernetes/manifests/production/karpenter/karpenter.yaml
```

Expected: `node-role/karpenter-controller-host: "true"` が出力。

- [ ] **Step 4: hydrate 結果を Commit**

```bash
git add kubernetes/manifests/production/karpenter/
git status
git commit -s -m "chore(kubernetes/manifests): hydrate karpenter manifests for tuning PR

make hydrate ENV=production で rendered manifest を新仕様で再生成:
- NodePool requirements: capacity=[spot,on-demand]/category=[m]/gen=Gt 5
- Deployment nodeSelector: node-role/karpenter-controller-host=true"
```

(注: hydrate 結果に変更がない場合 = 既に最新 = `nothing to commit` で OK、Step 5 にスキップ)

- [ ] **Step 5: branch を push**

```bash
git push -u origin HEAD
```

Expected: `feat/eks-production-karpenter-tuning` branch が origin に作成される。

- [ ] **Step 6: Draft PR 作成**

```bash
gh pr create --draft --title "feat(eks): Karpenter tuning - rename bootstrap MNG + simplify NodePool requirements" --body "$(cat <<'EOF'
## Summary

Plan 2 (Karpenter migration, PR #271-#276) 完了後の運用レビューで判明した 2 点を 1 PR で扱う micro-plan の実装:

1. **MNG rename**: `karpenter_bootstrap` → `karpenter_controller_host` (HCL identifier) / `karpenter-controller-host` (AWS 物理名 + K8s label)。Plan 2 learnings PR #278 / L1 で挙げた命名再考に対応
2. **NodePool requirements 簡素化**:
   - `capacity-type`: `["on-demand"]` → `["spot", "on-demand"]` (cost ~70% 削減見込み)
   - `instance-category`: `["m", "c", "r"]` → `["m"]` (general-purpose only)
   - `instance-generation`: `Gt 7` (m8g のみ) → `Gt 5` (m6g 以降。Ge operator 不在のため Gt 5 で Ge 6 相当を表現)
   - `instance-size`: `medium..4xlarge` 維持

### Disruption 戦略

単純 rename (戦略 A): terraform `create_before_destroy` で新 MNG 起動 → 旧 MNG destroy。Karpenter controller pod が新 MNG node に再 schedule される間 (~2-3 分) controller unavailable。既存 system-components NodePool node の workload には影響なし。

## Code 変更 (本 PR)

- `aws/karpenter/modules/variables.tf`: `bootstrap_*` 5 vars を `controller_host_*` に rename
- `aws/karpenter/modules/main.tf`: `module "karpenter_bootstrap"` を `module "karpenter_controller_host"` に rename + `name` 引数 + `var.bootstrap_*` 参照 + label key + コメント更新
- `kubernetes/components/karpenter/production/kustomization/nodepool.yaml`: requirements 変更 (capacity-type / category / generation) + Ge 不在に関するコメント追加
- `kubernetes/components/karpenter/production/values.yaml.gotmpl`: nodeSelector label key 更新 + コメント
- `kubernetes/components/karpenter/production/helmfile.yaml`: header コメント更新
- `kubernetes/README.md`: bootstrap 言及 2 箇所を新名に追従
- `kubernetes/manifests/production/karpenter/`: hydrate 結果の auto-generated manifest

## Documents

- Spec: `docs/superpowers/specs/2026-05-05-eks-production-karpenter-tuning-design.md`
- Plan: `docs/superpowers/plans/2026-05-05-eks-production-karpenter-tuning.md`

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] `aws/karpenter/envs/production` で `terragrunt validate` 成功
- [x] `aws/karpenter/envs/production` で `terragrunt plan` が `module.karpenter_controller_host` create + `module.karpenter_bootstrap` destroy の create_before_destroy diff を返す
- [x] `kustomize build kubernetes/components/karpenter/production/kustomization` でエラーなし、NodePool に新仕様 requirements
- [x] `make hydrate ENV=production` で rendered manifest が新仕様 (NodePool requirements + Deployment nodeSelector) を持つ
- [x] `grep -n "karpenter-bootstrap\|karpenter_bootstrap" kubernetes/README.md` でマッチなし

### Cluster-level (CI / operator 実行、merge 後)

- [ ] CI Deploy job で `aws/karpenter/envs/production` の terragrunt apply が成功
- [ ] `aws eks list-nodegroups --cluster-name eks-production --region ap-northeast-1` で `["karpenter-controller-host-..."]` のみ (旧 `karpenter_bootstrap-...` が消えている)
- [ ] `kubectl get nodes -L eks.amazonaws.com/nodegroup,node-role/karpenter-controller-host` で controller-host MNG node 2 台が `Ready` + label `node-role/karpenter-controller-host=true` を持つ
- [ ] `kubectl get pods -n karpenter -o wide` で Karpenter deployment の 2 replica が新 MNG node 上で `Running 1/1`
- [ ] `kubectl get nodepool system-components -o yaml | yq .spec.template.spec.requirements` で新仕様 (capacity-type=[spot, on-demand] / category=[m] / generation Gt 5 / size medium..4xlarge) を持つ
- [ ] `kubectl get nodeclaims` で既存 NodeClaim (system-components-...) が `Ready=True` を維持
- [ ] (24-72h 観察) `kubectl get nodes -L karpenter.sh/capacity-type` で system-components NodePool node が SPOT capacity に自然遷移する
EOF
)"
```

Expected: PR が created、URL が表示される。

---

## (USER) PR review + merge → Verification

**Files:** (cluster 状態変更)

PR を merge して CI deploy が apply。MNG rename + NodePool requirements 反映の挙動を観察する。

- [ ] **Step 1: PR を Ready for review に変更 + merge**

```bash
gh pr ready
gh pr review --approve
gh pr merge --squash --delete-branch
gh run watch
```

Expected: `Hydrate Kubernetes (production)` workflow + `aws/karpenter` terragrunt apply workflow が success で完了 (~5-10 分)。

- [ ] **Step 2: 新 MNG node Ready 確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get nodes -L eks.amazonaws.com/nodegroup,node-role/karpenter-controller-host
```

Expected: `karpenter-controller-host-...` MNG の node が 2 台 `Ready` + label `node-role/karpenter-controller-host=true`。旧 `karpenter_bootstrap-...` MNG node が `SchedulingDisabled` または既に消えている。

- [ ] **Step 3: Karpenter pod 移行確認**

```bash
kubectl get pods -n karpenter -o wide
kubectl rollout status deployment/karpenter -n karpenter
```

Expected: Karpenter deployment の 2 replica が **新 MNG node 上** (`ip-...` が controller-host MNG node) で `Running 1/1`。`rollout status` が `successfully rolled out`。

- [ ] **Step 4: 旧 MNG destroy 完了確認**

```bash
aws eks list-nodegroups --cluster-name eks-production --region ap-northeast-1
```

Expected: `["karpenter-controller-host-..."]` のみ (旧 `karpenter_bootstrap-...` が消えている)。

⚠️ もし 5 分以上待っても旧 MNG が残る場合は Plan 2 learnings L6 (PDB blocker on rolling update) の再現の可能性。`kubectl get pods -n karpenter` で Karpenter pod が `CrashLoopBackOff` / `NotReady` になっていないか確認、なっていれば:

```bash
kubectl delete pod karpenter-... -n karpenter --force --grace-period=0
```

で eviction を bypass して再起動を促す (Plan 2 L6 既知 recovery 手順)。

- [ ] **Step 5: NodePool requirements 反映確認**

```bash
kubectl get nodepool system-components -o yaml | yq '.spec.template.spec.requirements'
```

Expected: requirements に新仕様:

```yaml
- key: kubernetes.io/arch
  operator: In
  values: ["arm64"]
- key: kubernetes.io/os
  operator: In
  values: ["linux"]
- key: karpenter.sh/capacity-type
  operator: In
  values: ["spot", "on-demand"]
- key: karpenter.k8s.aws/instance-category
  operator: In
  values: ["m"]
- key: karpenter.k8s.aws/instance-generation
  operator: Gt
  values: ["5"]
- key: karpenter.k8s.aws/instance-size
  operator: In
  values: ["medium", "large", "xlarge", "2xlarge", "4xlarge"]
```

- [ ] **Step 6: 既存 NodeClaim が `Ready=True` を維持**

```bash
kubectl get nodeclaims
```

Expected: 既存 NodeClaim (`system-components-...`) が `Ready=True` のまま稼働 (= NodePool 設定変更だけでは既存 node は drift しない)。

- [ ] **Step 7: 24-72h 後の SPOT 推移観察 (informational)**

```bash
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

Expected (24-72h 後): system-components NodePool 上の node が `karpenter.sh/capacity-type=spot` + m6g/m7g/m8g 系 instance type に自然遷移している (consolidation または expireAfter による置換、強制ではないので 30 日以内に発生すれば OK)。

⚠️ on-demand のままで spot に切り替わらない状態が 7 日以上続く場合は AZ-specific な spot pool 不足の可能性。`kubectl describe nodeclaim` の events で provision 失敗ログを確認。

---

## Self-review checklist

> Plan 完成後の self-review。Implementer が任意 task を実行する前に、Plan 自体の整合性を確認する。

### Spec coverage

Spec の各セクションが Plan 内のどの task で実装されているか:

- [x] **Goals G1 (rename)** → Tasks 1, 2, 4, 5, 6 (variables / main.tf / values.yaml.gotmpl / helmfile.yaml / README.md の rename)
- [x] **Goals G2 (NodePool requirements 簡素化 + SPOT)** → Task 3
- [x] **Goals G3 (1 PR / 単純 rename 戦略)** → Task 7 で 1 PR 作成、Task 2 で create_before_destroy 確認
- [x] **Decision 1 (rename 3 階層)** → Tasks 1 (HCL var), 2 (HCL module + AWS name + K8s label), 4 (K8s nodeSelector)
- [x] **Decision 2 (単純 rename = create_before_destroy)** → Task 2 Step 4 で plan diff 確認、(USER) Step 4 で旧 MNG destroy 確認
- [x] **Decision 3 (NodePool requirements 変更)** → Task 3
- [x] **Decision 4 (Ge 不在 → Gt 5 + コメント)** → Task 3 nodepool.yaml 内のコメント
- [x] **Decision 5 (SPOT 採用前提)** → Task 3 nodepool.yaml ヘッダコメント、PR description で言及
- [x] **Components matrix の全 6 ファイル** → Tasks 1-6 で 1 ファイルずつ
- [x] **Migration sequence の create_before_destroy** → Task 2 Step 4 + (USER) Steps 2-4
- [x] **Verification checklist** → (USER) Steps 2-7 + PR description Test plan
- [x] **エラーシナリオ (新 MNG 起動失敗 / nodeSelector 反映遅延 / Karpenter CrashLoop / PDB blocker / SPOT 中断頻発)** → (USER) Step 4 で L6 recovery、Step 7 で SPOT 推移観察

### Placeholder scan

- [x] `TBD` / `TODO` / `implement later` / `fill in details` 等の禁止文言なし
- [x] `<sha>` / `<XXX>` 等の placeholder は (USER) Step 1 の `gh pr merge` 等で実値が決まる、確定した部分は実値で書かれている
- [x] `git push` 後の PR URL は `gh pr create` の output で取得できるので placeholder 不要

### Type / signature consistency

- [x] **HCL variable 名** (`controller_host_instance_types` / `controller_host_desired_size` / `controller_host_min_size` / `controller_host_max_size` / `controller_host_disk_size`) は Task 1 (定義) と Task 2 (参照) で一致
- [x] **HCL module name** (`module "karpenter_controller_host"`) は Task 2 で一貫
- [x] **AWS MNG 物理名** (`name = "karpenter-controller-host"`) は Task 2 で確定、(USER) Step 2 / Step 4 で `karpenter-controller-host-...` を expect (terraform-aws-modules が name suffix を付ける)
- [x] **K8s label key** (`node-role/karpenter-controller-host`) は Task 2 (定義 in main.tf labels) と Task 4 (参照 in values.yaml.gotmpl nodeSelector) と Task 6 (README documentation) で一致
- [x] **NodePool requirements key 値** (`capacity-type` / `instance-category` / `instance-generation` / `instance-size`) は Task 3 nodepool.yaml と (USER) Step 5 で expected value が一致
- [x] **NodePool name** (`system-components`) と **EC2NodeClass name** (`system-components`) は変更なし、Task 3 で参照のみ

### CLAUDE.md 準拠

- [x] 出力言語日本語 (見出し英語、本文日本語)
- [x] コミット `-s` (Signed-off-by) — 全 task の commit step で `-s` 指定
- [x] `Co-Authored-By` 不付与 — 全 task の commit message に無し
- [x] PR は `--draft` — Task 7 で `gh pr create --draft`
- [x] 新規ブランチ初回 push: `git push -u origin HEAD` — Task 7 Step 5
- [x] Conventional Commits — 全 commit が `feat(scope):` / `docs(scope):` / `chore(scope):` 形式

### Plan 1c-β / Plan 2 の知見反映

- [x] **Plan 1c-β L1 (IRSA module の random suffix)** → 本 plan は IRSA を使わない (Pod Identity)。MNG name suffix は terraform-aws-modules が自動付与、(USER) Step 2 / 4 で suffix 込みで expected
- [x] **Plan 1c-β L2 (.terraform.lock.hcl gitignore)** → 本 plan で git add 対象として言及せず
- [x] **Plan 1c-β L3 (kube-proxy state drift)** → 本 plan では該当する state drift なし (rename は cosmetic + create_before_destroy で完結)
- [x] **Plan 1c-β L4 (REPLACE_FROM_TERRAGRUNT_OUTPUT 不要)** → 本 plan は terragrunt output 取得が不要 (rename だけで実値の変更なし)
- [x] **Plan 1c-β L5 (squash merge 後の branch reset rollback)** → Task 0 Step 1 で `git fetch origin main && git log --oneline origin/main..HEAD` 確認
- [x] **Plan 2 L1 (karpenter_bootstrap 命名再考)** → 本 plan で resolve
- [x] **Plan 2 L2 (cluster info wiring)** → Task 2 Step 2 の main.tf 全置換で cluster_endpoint / cluster_auth_base64 / cluster_service_cidr / cluster_ip_family の配線を保持
- [x] **Plan 2 L3 (inline policy)** → 本 plan で `module "karpenter"` 部分は変更しないため `enable_inline_policy = true` も保持
- [x] **Plan 2 L4 (consolidationPolicy v1+)** → Task 3 nodepool.yaml で `WhenEmptyOrUnderutilized` を保持 (v0.x の `WhenUnderutilized` 復活なし)
- [x] **Plan 2 L5 (node SG 明示 attach)** → Task 2 Step 2 の main.tf 全置換で `vpc_security_group_ids = [module.eks.cluster.node_security_group_id]` の配線を保持
- [x] **Plan 2 L6 (PDB blocker on rolling update)** → (USER) Step 4 で force delete pod recovery 手順を明示
- [x] **Plan 2 L7 (spec/plan divergence)** → 本 plan は spec 通りに書き、divergence 発生時は spec を正とする
