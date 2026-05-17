# AWS Resource Provenance Design

> **Nature**: cross-stack tag schema cleanup + k8s controller-created AWS resource の provenance 整備 + inventory doc 新設
>
> **Goal**: 全 AWS resource に「誰が管理しているか (= `ManagedBy`)」「どの stack 由来か (= `Component`)」 を tag で一意に識別できる schema を確立し、 inventory doc を source-of-truth として整備する。 SG だけでなく ALB / Target Group / EC2 / EBS / Launch Template / ENI も対象。

---

## 1. Background

### 出発点

AWS Security Group が IaC モジュールと k8s manifest の両方から auto-create され、 全体の所在が掴みにくいという課題から開始した。 調査の結果、 課題は SG 特有ではなく **k8s controller 経由で AWS に染み出すリソース全般** に共通すると分かった。

### Stack inventory

deployable IaC stack は計 **11** (= `aws/ai-assistant/` / `aws/alb/` / `aws/cost-management/` / `aws/eks/` / `aws/eks-logs/` / `aws/eks-metrics/` / `aws/eks-secrets/` / `aws/eks-traces/` / `aws/github-oidc-auth/` / `aws/karpenter/` / `aws/vpc/`)。 `aws/route53/` は `lookup` data source のみで deployable stack ではない (= Route53 hosted zone `panicboat.net` は IaC 外で provision 済、 各 stack は data source 経由で参照)。

### 既に解決している層

- Terraform-managed AWS リソース: 全 11 stack で `provider "aws"` の `default_tags { tags = var.common_tags }` 設定済 (= `aws/<stack>/modules/terraform.tf`)。 IaC 由来の SG / IAM / S3 / RDS / etc は common_tags が propagate 済。

### 未整備の層

- k8s controller (= AWS Load Balancer Controller / Karpenter / EBS CSI driver) が auto-create する AWS リソース (= ALB / Target Group / 自動 SG / EC2 instance / EBS volume / Launch Template / ENI) は controller 側で tag 設定する必要があり、 現状未設定。
- 既存 IaC tag schema は不整合 (= 後述 §2)。

### 触らないもの (= AWS / 各 controller 公式推奨に従う)

- AWS LB Controller の SG auto-create 自体: AWS 公式が推奨する controller-managed approach を維持。
- Karpenter の SG selector (= `securityGroupSelectorTerms` tag-based discovery): Karpenter 公式推奨。
- EKS cluster SG / node SG の rule 内容: `terraform-aws-modules/eks` module default に依存、 rule 変更は本 spec 範囲外。
- external-dns が作る Route53 record: API 仕様で resource tag を持てないため tag schema 対象外。 hosted zone 自体は IaC 管理 (= `aws/route53/`) で tag 済。

---

## 2. 現状の tag schema 実体

`aws/<stack>/envs/<env>/env.hcl` の `environment_tags` が `aws/<stack>/envs/<env>/terragrunt.hcl` の `inputs.common_tags` に merge され、 各 module の `var.common_tags` 経由で全 AWS resource に伝搬する。 root.hcl の `locals.common_tags` で定義されている `Component` / `ManagedBy` 等は child の `inputs.common_tags` override で消えるため **dead code**。

| Tag key | 設定箇所 | 現状の値 | 状態 |
|---|---|---|---|
| `Purpose` | `aws/<stack>/envs/<env>/env.hcl` の `environment_tags` (= 10 stack) または `additional_tags` (= github-oidc-auth のみ) | stack 名 (例: `vpc` / `eks` / `karpenter`) | 全 11 stack に存在、 ただし `aws/github-oidc-auth/envs/<env>/env.hcl` のみ `github-actions` で drift |
| `Purpose` | module 内 個別 resource の `tags = merge(var.common_tags, { Purpose = "<resource-specific>" })` | resource-specific (例: `github-actions-oidc-plan` / `bedrock-claude-access`) | per-resource 識別子として正しい使い方 |
| `ManagedBy` | `aws/<stack>/envs/<env>/terragrunt.hcl` の `inputs.common_tags` | `terragrunt` | 全 stack で同値、 stack 識別は別 tag (= 現状 `Purpose`) 併読が必要 |
| `Component` | `aws/<stack>/root.hcl` の `locals.common_tags` | stack 名 | **dead code** (= child override で消える) |
| `Environment` / `Owner` / `Project` / `Repository` | env.hcl + terragrunt.hcl | 各値 | 維持 |

**問題点**:

- 同じ概念 (= stack 識別) に対して `Purpose` (env.hcl) と `Component` (root.hcl) の 2 key が並存し、 後者は dead code。
- `Purpose` が stack 名と per-resource 識別子の **2 つの意味で多重使用** されている (= 同じ key で 2 軸を区別不能)。
- k8s controller 経由 AWS resource は schema に乗っていない。
- `aws/github-oidc-auth/` の `envs/<env>/terragrunt.hcl` は他 10 stack と構造が異なる (= `environment_tags` ではなく `additional_tags` を使い、 `common_tags = merge({ Environment }, additional_tags)` という slim merge のため `Project` / `ManagedBy` / `Repository` 等が **deployed tags に含まれない**)。 結果として github-oidc-auth 由来 AWS resource は `Environment` / `Purpose` (= 役割により値変動) / `Owner` の 3 tag しか持たず、 schema 不揃い。

---

## 3. 目標 tag schema

| Tag key | 役割 | 設定 scope | 値域 |
|---|---|---|---|
| `ManagedBy` | actor 識別 (= 誰が作り維持するか) | **全 AWS resource** (= IaC + k8s controller) | `terraform` / `aws-load-balancer-controller` / `karpenter` / `aws-ebs-csi-driver` |
| `Component` | stack 識別 (= どの IaC stack 由来か) | IaC のみ | stack-name と一致 (= `vpc` / `eks` / `alb` / `karpenter` / `eks-logs` / `eks-metrics` / `eks-traces` / `eks-secrets` / `cost-management` / `github-oidc-auth` / `ai-assistant`) |
| `Purpose` | per-resource 識別子 (= 同 stack 内で複数の resource role を区別する必要がある場合のみ) | 必要な resource のみ | resource-specific (例: `github-actions-oidc-plan` / `github-actions-oidc-apply` / `bedrock-claude-access` / `ai-assistant-cli`) |
| `Environment` / `Owner` / `Project` / `Repository` | 既存 meta | 維持 | 変更なし |

**設計意図**

- `Component` を **stack 識別の単一 key** に統一 (= 旧 `Purpose=<stack>` を rename + 旧 `Component` の dead code を生かす形に正規化)
- `Purpose` を **per-resource 識別子** に限定 (= 同 stack 内で plan/apply 等を区別する用途のみ、 schema 上の意味を 1 つに絞る)
- k8s controller-created resource は `ManagedBy=<controller-name>` 単独で provenance 確定 (= controller 名が unique なので `Component` 冗長)
- 探索フロー統一: AWS resource を見る → `ManagedBy` を読む → IaC なら `Component` で stack 特定 + IaC コード参照、 controller なら controller 名から Helm values / manifest を参照

---

## 4. 実装変更点

### 4-1. IaC tag schema 統一

| # | 変更 | ファイル | 内容 |
|---|---|---|---|
| 4-1-a | env.hcl で `Purpose` → `Component` rename | 全 `aws/<stack>/envs/<env>/env.hcl` (= 12 files) | `environment_tags` (= 10 stack) または `additional_tags` (= github-oidc-auth 2 env) 内の `Purpose = "<stack>"` を `Component = "<stack>"` に置き換える。 `aws/github-oidc-auth/envs/<env>/env.hcl` は値も `github-actions` → `github-oidc-auth` に normalize (= stack 名と一致させる) |
| 4-1-b | terragrunt.hcl で `ManagedBy` 値を simplify + github-oidc-auth は構造修正 | 全 `aws/<stack>/envs/<env>/terragrunt.hcl` (= 12 files) | 10 stack は `inputs.common_tags` の `ManagedBy = "terragrunt"` を `ManagedBy = "terraform"` に変更。 `aws/github-oidc-auth/envs/<env>/terragrunt.hcl` (2 env) は他 10 stack に揃える形に修正: merge 内の inline map に `ManagedBy = "terraform"` + `Project = "github-oidc-auth"` + `Repository = "panicboat/platform"` を追加 |
| 4-1-c | root.hcl の dead code は **本 spec では touch しない** | 全 `aws/<stack>/root.hcl` | `locals.common_tags` の `Component` / `ManagedBy` / `Team` 等は child の `inputs.common_tags` override で消えるため dead code だが、 envs/terragrunt.hcl で `common_tags` を override しない stack が将来追加された時の安全網として残置する (= cleanup は別 spec、 本 spec の rename は envs 側のみで完結) |
| 4-1-d | module 内 per-resource `Purpose` | 既存維持 | `aws/github-oidc-auth/modules/main.tf` と `aws/ai-assistant/modules/*.tf` の `Purpose=<resource-specific>` override は role 識別子として残す (= schema 上の正規な per-resource 用途) |

### 4-2. k8s controller の tag 設定

| # | 変更 | ファイル | 内容 |
|---|---|---|---|
| 4-2-a | AWS LB Controller `defaultTags` | `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` | `defaultTags: ManagedBy: aws-load-balancer-controller` を末尾に追加。 controller が auto-create する 全 ALB / NLB / Target Group / SG に伝搬。 既存 resource は次回 reconcile で patch (= idempotent) |
| 4-2-b | Karpenter `EC2NodeClass.spec.tags` | `kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml` | `spec.tags: ManagedBy: karpenter` を追加。 Karpenter が起動する EC2 instance + 紐づく EBS root volume + Launch Template + ENI に伝搬。 既存 instance は drift 維持 (= 次回 node replace 時に揃う) |
| 4-2-c | EBS CSI `extraVolumeTags` | `aws/eks/modules/addons.tf` | `aws-ebs-csi-driver` addon block に `configuration_values = jsonencode({ controller = { extraVolumeTags = { ManagedBy = "aws-ebs-csi-driver" } } })` を追加。 PVC 経由で dynamic provision される EBS volume に付与。 既存 PV 由来 EBS は本 spec では retag しない |

### 4-3. VPC default SG lockdown

| # | 変更 | ファイル | 内容 |
|---|---|---|---|
| 4-3-a | VPC default SG を IaC adopt + lockdown | `aws/vpc/modules/main.tf` の `module "vpc"` block | `manage_default_security_group = true`、 `default_security_group_ingress = []`、 `default_security_group_egress = []`、 `default_security_group_tags = merge(var.common_tags, { Name = "default-vpc-${var.environment}-locked" })` を追加 |

### 4-4. Apply 順序 + 依存

| # | 変更 | 依存 | 種別 |
|---|---|---|---|
| 1 | 4-1-a / 4-1-b (tag schema 統一、 4-1-c は no-op) | なし | terragrunt apply (11 stack 全部) |
| 2 | 4-3-a (VPC default SG lockdown) | なし | terragrunt apply (vpc) |
| 3 | 4-2-c (EBS CSI extraVolumeTags) | なし | terragrunt apply (eks) |
| 4 | 4-2-a (LB Controller defaultTags) | なし | flux reconcile |
| 5 | 4-2-b (Karpenter EC2NodeClass tags) | なし | flux reconcile |

= 5 件互いに独立、 1 PR にまとめ可能。 IaC は全 stack/env 分の plan 確認、 k8s 側は flux 反映後 controller log で適用確認。

---

## 5. Inventory doc

### Path

`docs/aws-resource-provenance.md` (新規)

### 構成

1. **Tag schema** (= §3 を抜粋): `ManagedBy` / `Component` / `Purpose` の定義 + 値域 + 設定箇所 (= env.hcl / Helm values / EC2NodeClass / addon configuration_values)
2. **Provenance map**: 主要 AWS resource type 別に「作成元 / `ManagedBy` 値 / `Component` 値 / 参照先 (IaC コード位置 or k8s manifest 位置)」 を table 化。 以下を網羅:
   - VPC / Subnet / Route Table / NAT GW / VPC default SG → `terraform` / `vpc`
   - EKS cluster / cluster SG / node SG / addon → `terraform` / `eks`
   - EKS managed addon (= aws-ebs-csi-driver / coredns / pod-identity-agent) → `terraform` / `eks`
   - IAM role IRSA (= ebs-csi / alb-controller / external-dns / cilium / karpenter-controller / etc.) → `terraform` / `eks` または `terraform` / `karpenter`
   - ACM certificate → `terraform` / `alb`
   - Route53 hosted zone (= `panicboat.net`) → **IaC 外** (= `aws/route53/lookup` の data source 経由参照のみ、 zone 自体は AWS console / 別 source-of-truth で provision)
   - Karpenter SQS / EventBridge / Node IAM / system_critical MNG → `terraform` / `karpenter`
   - GitHub OIDC IAM role (= plan / apply 各 1) → `terraform` / `github-oidc-auth` + `Purpose=<role-specific>`
   - Bedrock IAM role → `terraform` / `ai-assistant` + `Purpose=<role-specific>`
   - ALB / Target Group / auto-create SG → `aws-load-balancer-controller`
   - Karpenter-launched EC2 / EBS root / Launch Template / ENI → `karpenter`
   - PVC 経由 dynamic provision EBS volume → `aws-ebs-csi-driver`
   - Route53 record (= external-dns 作成) → **N/A** (= API 仕様で AWS tag 不可、 hosted zone 自体は IaC tag 済)
3. **Security Group inventory** (= provenance map の SG 部分を切り出した詳細):
   - 5 SG (= VPC default lockdown 後 / EKS cluster SG / EKS node SG / ALB `application` IngressGroup SG / ALB `monitoring-uis` IngressGroup SG) の owner / 用途 / rule overview / 参照点 (IaC コード位置 or controller 由来)
   - `terraform-aws-modules/eks` v21 が cluster SG / node SG に default で開けている主要 ingress / egress rule の概要 + どこを `*_additional_rules` で追加可能か
   - 図 (Mermaid): ALB → node SG → pod、 cluster SG ↔ node SG の主要 traffic flow
4. **Operational notes**:
   - 新規 IaC stack 追加時の規約 (= env.hcl で `Component = "<stack>"` を設定する template)
   - 新規 k8s controller (= AWS resource を作る) 導入時の規約 (= controller-specific `ManagedBy` tag を Helm values または manifest で設定する手順)
   - AWS console から resource provenance を辿る手順 (= `ManagedBy` を確認 → IaC なら `Component` で stack 特定 → IaC コード参照、 controller なら controller 名から Helm values / manifest を grep)

### 書かないもの (= source-of-truth に任せる)

- 各 SG の具体的 ingress / egress rule 内容 (= module README / source / `aws ec2 describe-security-groups` が source-of-truth)
- 各 IAM role の policy 内容 (= IaC コードと AWS console)
- resource 数 (= 数えるならスクリプト)

### Why this doc exists

- auto-create 系 AWS resource (= ALB / SG / EC2 / EBS) が出現した時に、 まず `ManagedBy` tag を読むだけで provenance が確定する規約を可視化
- 規約を文章化しないと、 将来 controller 追加時に tag 設定漏れが起き、 また schema drift が発生する (= governance を doc で固定)

---

## 6. Validation

### 各変更の apply 直後検証

| # | 変更 | 検証 | 期待結果 |
|---|---|---|---|
| 1 | env.hcl `Purpose` → `Component` rename | `terragrunt plan` (各 stack) | tag diff のみ (= `Purpose` 削除 + `Component` 追加)、 resource recreate なし |
| 2 | `ManagedBy = terraform` | 同上 | tag in-place update のみ |
| 3 | root.hcl dead code cleanup | 同上 | plan diff ゼロ (= dead code は既に伝搬していないため) |
| 4 | VPC default SG lockdown | `aws/vpc/envs/production` で `terragrunt plan` | `aws_default_security_group` 1 件 adopt + rule 削除 + tag 追加 |
| 5 | EBS CSI `extraVolumeTags` | `aws/eks/envs/production` で `terragrunt plan` | addon `configuration_values` update のみ (= IRSA / addon recreate なし) |
| 6 | LB Controller `defaultTags` | flux reconcile 後 `kubectl -n kube-system get deploy aws-load-balancer-controller -o yaml` | controller pod の args / env に `--default-tags ManagedBy=aws-load-balancer-controller` 反映 |
| 7 | Karpenter EC2NodeClass tags | `kubectl get ec2nodeclass system-components -o yaml` | `spec.tags.ManagedBy: karpenter` 存在 |

### End-to-end 検証 (= tag が AWS resource に伝搬したか)

```bash
# IaC 由来 SG: ManagedBy=terraform + Component=<stack> が付いているか sampling
aws ec2 describe-security-groups --filters "Name=tag:ManagedBy,Values=terraform" \
  --query 'SecurityGroups[].{Id:GroupId,Component:Tags[?Key==`Component`]|[0].Value}'

# LB Controller 由来 SG: 既存 ALB SG が patch されたか
aws ec2 describe-security-groups --filters "Name=tag:ManagedBy,Values=aws-load-balancer-controller" \
  --query 'SecurityGroups[].{Id:GroupId,Name:GroupName}'

# Karpenter 由来 EC2: 新規 launch instance に ManagedBy=karpenter
aws ec2 describe-instances --filters "Name=tag:ManagedBy,Values=karpenter" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Launched:LaunchTime}'

# EBS CSI 由来 volume: test PVC を 1 つ作成して新規 provision EBS の tag 確認、 後で削除
```

### Completion criteria

- [ ] IaC tag rename (`Purpose` → `Component`) が 11 stack 全部で apply 完了、 既存 AWS resource の tag が in-place update されている
- [ ] `ManagedBy = terraform` への変更が全 stack で apply 完了
- [ ] VPC default SG が IaC adopt + lockdown (= ingress / egress 空) 確認
- [ ] k8s 側 3 controller (= LB Controller / Karpenter / EBS CSI) が `ManagedBy=<controller>` tag を設定するよう変更が flux reconcile 完了
- [ ] 既存 ALB / SG / Target Group に LB Controller の `ManagedBy` tag が patch されたことを `aws ec2 describe-security-groups` で 1 件以上確認
- [ ] `docs/aws-resource-provenance.md` commit 済 + tag schema 規約 / provenance map / SG inventory 記載完了
- [ ] AWS console で任意の resource を 1 つ開き、 `ManagedBy` tag (+ IaC なら `Component`) のみで provenance が辿れることを目視確認

### スコープ外 (= 完了条件に含めない)

- 既存 Karpenter-launched EC2 instance の retag (= 既存は drift 許容、 次回 node replace で揃う)
- 既存 PV-provisioned EBS volume の retag (= 既存は手動 retag 対象外、 新規 PVC から揃える)
- EKS module default SG rule の中身変更 (= 解説 doc のみ、 rule 変更は別 spec)
- Route53 record の tag (= API 仕様で非対応、 doc 注記のみ)
- AWS LB Controller / Karpenter の SG auto-create / selector の挙動変更 (= AWS / Karpenter 公式推奨を維持)

---

## 7. Risk + mitigation

| Risk | mitigation |
|---|---|
| `Purpose` → `Component` rename で external tool (= cost-explorer / aws config rule / 既存 dashboard 等) が `Purpose=<stack>` を参照していると壊れる | `git grep "Purpose"` で repo 内利用箇所を確認、 外部 tool 側の利用 (= AWS Cost Categories / Config Rule / CloudWatch dashboards) を AWS console 上で sampling 確認。 該当があれば doc 経由の deprecation 期間を設けるか、 既存 `Purpose` tag を retain しつつ `Component` を **追加** する形 (= rename 廃止、 dual-write) に切り替え |
| VPC default SG lockdown 時に既存使用 resource があれば通信切断 | apply 前に `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<default-sg-id>` で attach 件数 0 を確認。 0 でない場合は対象 resource を別 SG に migrate してから lockdown |
| EBS CSI `configuration_values` 設定で addon が unhealthy 化 | `most_recent = true` + `resolve_conflicts_on_create = "OVERWRITE"` + `resolve_conflicts_on_update = "OVERWRITE"` で safe rollout。 apply 後 `kubectl get pods -n kube-system -l app=ebs-csi-controller` で Ready 確認 |
| EBS CSI driver の EKS managed addon `configurationValues` schema が `controller.extraVolumeTags` を受け付けない (= 想定 key が異なる version で違う、 例: `extraVolumeTags` 直下 / `controller.tagging` 等) | implementation 時に `aws eks describe-addon-configuration --addon-name aws-ebs-csi-driver --addon-version <version>` で正確な schema を確認、 不一致なら正しい key path に修正 |
| LB Controller `defaultTags` Helm value が chart version で sub-key 名が違う (= `defaultTags` vs `controllerConfig.defaultTags` vs cli flag `--default-tags`) | implementation 時に `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml` の chart version (= `3.3.0`) に対応する values.yaml を Helm chart README で確認、 正確な key 名で設定 |
| Karpenter EC2NodeClass の `spec.tags` が CRD version で受け付けない | EC2NodeClass `apiVersion: karpenter.k8s.aws/v1` が `spec.tags` を正式サポート (= Karpenter v1 docs 既定)。 既存 ec2nodeclass.yaml が v1 を使っていることを事前確認、 違えば CRD upgrade を確認 |
| envs/terragrunt.hcl で `common_tags` を override しない stack が将来追加された時に root.hcl の dead code が再び生きて schema drift | 本 spec で root.hcl は touch せず安全網として残置 (= §4-1-c)。 新規 stack template として envs/terragrunt.hcl で `common_tags` を明示 override する例を doc に記載 |

---

## 8. Out of scope

- ALB Controller / Karpenter の SG auto-create 自体の IaC 化 (= AWS / Karpenter 公式推奨に沿わないため見送り、 別途強い動機 (= compliance / cross-account / 同一 SG 共有等) が出てきたら再検討)
- EKS cluster / node SG の rule 自体の変更 (= 解説 doc のみ、 rule 追加 / 削除は別 spec)
- 既存 long-lived EC2 / EBS の retag バックフィル (= 自然な lifecycle 更新で順次揃う)
- 多軸 cost allocation tag schema 拡張 (= 本 spec は provenance 1 軸のみ、 cost / data-classification 等の追加軸は別途)
