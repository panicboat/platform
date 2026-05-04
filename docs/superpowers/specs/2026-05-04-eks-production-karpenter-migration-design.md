# EKS Production: Karpenter Migration (Plan 2)

**Phase**: Phase 2 (Compute autoscaling) — `aws-eks-production` roadmap

**前提**: Plan 1a (Flux) / 1b (Cilium chaining) / 1c-α (Gateway API + Metrics Server + KEDA) / 1c-β (ALB Controller + ExternalDNS + ACM) すべて merged.

## Goals

### G1: System workloads を Karpenter on-demand で運用する

`aws-eks-production` cluster の system / workload pod (CoreDNS / Cilium operator / Flux / Foundation addons / 将来の application) を **Karpenter NodePool が起動する on-demand instance** 上で稼働させる。Bootstrap MNG は Karpenter controller pod のみを host する最小構成 (`t4g.small × 2`) に縮小する。

### G2: Operational simplicity (priority B)

Cluster operator が日常運用で意識する autoscaler を **Karpenter NodePool 一系統** に集約する。Bootstrap MNG は概念上「Karpenter の起点」として分離し、運用視点では「不変インフラ」として扱う (touch しない)。Pod placement のルールが clean:

- Bootstrap MNG: Karpenter controller pod のみ (taint で他を排除)
- Karpenter NodePool: それ以外全部 (taint なし)

### G3: Cost reduction (priority A)

| 項目 | 現状 (Plan 1c-β 完了時) | 移行後 |
|---|---|---|
| 常時稼働 EC2 (idle 時) | `m6g.large × 2 = ~$112/月` | `t4g.small × 2 = ~$30/月` (-73%) |
| Workload EC2 | (system MNG 内に同居) | Karpenter NodePool が pod 需要に応じて動的起動、consolidation で最小化 |
| EBS root volume (現 50 GiB) | 50 GiB × 2 = 100 GiB | bootstrap 20 GiB × 2 + Karpenter 30 GiB × N |

## Non-goals

- **Spot capacity の採用** — 全 NodePool node は on-demand only。SQS interruption queue + EventBridge rules は infrastructure を provision するが consumer はいない (将来の spot NodePool で実用化)。
- **Multi-NodePool 設計** — 単一 NodePool (`system-components` 命名) で本 spec の要件を全部カバー。将来 GPU / observability heavy / spot 用の追加 NodePool は別 spec で。
- **Architecture hybrid** — ARM64 only。x86 fallback は持たない。
- **EKS Auto Mode 移行** — AWS 管理 Karpenter ではなく self-managed Karpenter で構築。EKS module の rewrite を避ける。
- **Plan 1c-β IRSA 全体の Pod Identity 移行** — 本 spec の Karpenter は Pod Identity を採用するが、Plan 1c-β で IRSA 採用済の ALB Controller / ExternalDNS は IRSA のまま据え置き (Karpenter とは独立、別 spec で扱う)。本 cluster は IRSA と Pod Identity が混在する状態に一時的になる。
- **Karpenter consolidation の per-workload tuning** — disruption budget は chart デフォルト + NodePool 全体設定のみ。observability 整備後 (Phase 3 後) に詳細 tuning は別 spec で。

## Architecture decisions

### Decision 1: System workloads を Karpenter on-demand で運用 (Roadmap Decision 5 を上書き)

`aws-eks-production` spec の Decision 5 (system MNG 据え置き + Karpenter は workload 専用の二層) を **本 spec で上書きする**。Bootstrap MNG (`t4g.small × 2`) を Karpenter controller の起点にし、それ以外を全部 Karpenter NodePool に集約する。

採用理由:
1. **Operational simplicity (priority B)**: autoscaler 一系統に集約。Bootstrap MNG は概念上「Karpenter の起点」として運用視点から分離。
2. **Cost reduction (priority A)**: 常時 EC2 を ~73% 削減 + workload node の consolidation。
3. PDB を尊重する Karpenter consolidation により CoreDNS 等 critical addon の HA は担保される。

トレードオフ:
1. Karpenter controller 自身が落ちた時、新規 node provisioning ができない。
   - 緩和: Bootstrap MNG が冗長 (replicas=2、AZ 分散)。両 node 同時落ちは AZ 障害級で、その場合は `terragrunt apply` で MNG re-create (state 保持)。
2. Bootstrap MNG が「ただの Karpenter ホスト」として残る — 完全な「all-Karpenter」ではない (Fargate 案を Cilium chaining 非対応で除外したため)。
3. CoreDNS pod が consolidation で evict される頻度が現状 (managed nodegroup 上で固定) より上がる。
   - 緩和: PDB (chart デフォルトで `maxUnavailable: 1`) + replicas≥2 + Karpenter consolidation が PDB を尊重。

### Decision 2: Capacity type は on-demand only

採用理由: priority B (operational simplicity) を spot interruption handling より優先。System pod (CoreDNS / Cilium operator / Flux 等) は interrupt 耐性低く、現時点で spot に乗せる pod が存在しない。

トレードオフ: spot による直接割引なし。Cost saving は consolidation のみ。

将来: Phase 5 (nginx) / monorepo migration 時に application pod を spot に逃がす別 spec を作成。SQS interruption queue + EventBridge rules を本 spec で provision するため、その時点で infra 追加は不要。

### Decision 3: Instance flexibility は ARM64 + 最新世代 (Graviton 4) のみ

NodePool requirements:

| Key | Operator | Values |
|---|---|---|
| `kubernetes.io/arch` | In | `[arm64]` |
| `karpenter.sh/capacity-type` | In | `[on-demand]` |
| `karpenter.k8s.aws/instance-category` | In | `[m, c, r]` |
| `karpenter.k8s.aws/instance-generation` | Gt | `7` (= 8 のみ) |
| `karpenter.k8s.aws/instance-size` | In | `[medium, large, xlarge, 2xlarge, 4xlarge]` |

採用理由:
1. ARM64 only: 既存方針継続 (現 cluster は AL2023 ARM64)。monorepo 移行時も ARM64 image build 前提。
2. Graviton 4 only: 最新世代 (m8g/c8g/r8g) で coup-perf。
3. Size medium-4xlarge: nano/micro/small/medium 未満は burst 挙動が予測しづらい。8xlarge 以上は単一 pod が大きな node を独占して bin-packing 悪化。

トレードオフ:
1. Graviton 4 capacity が逼迫している region では provisioning 失敗のリスク。ap-northeast-1 では現状問題なし。
2. 古い世代 (gen 6/7) を排除しているので、capacity 不足時に逃げ場がない。
   - 緩和: 発生時は NodePool requirements の `instance-generation: Gt 5` で gen 6/7 (m6g/m7g) も許可して復旧。

実際に展開される instance 候補: `m8g.{medium,large,xlarge,2xlarge,4xlarge}` + `c8g.*` + `r8g.*` の **15 通り**。

### Decision 4: 3-PR split で migration

| PR | 内容 | State after apply |
|---|---|---|
| **PR 1 (AWS infra parallel add)** | `karpenter-bootstrap` MNG 新設 (in `aws/eks/`) + 新 stack `aws/karpenter/` 作成 (Karpenter sub-module で SQS / EventBridge / Pod Identity / Node IAM / EC2 Instance Profile) + cross-stack lookup (`aws/eks/lookup/`) | 4 nodes (system × 2 + bootstrap × 2)。Karpenter は未 install |
| (USER GATE 1) | PR 1 merge + apply 確認 + terragrunt outputs 取得 | — |
| **PR 2 (Kubernetes layer)** | Karpenter Helm release + EC2NodeClass + NodePool + helmfile values 転記 + README | Karpenter pod が bootstrap MNG 上で Ready。NodePool 登録済 (まだ pending pod 無いので node 起動なし) |
| (USER GATE 2) | Smoke test + cordon + drain + 移行完了確認 | 全 system pod が Karpenter NodePool 上で稼働。system MNG は cordoned/empty |
| **PR 3 (AWS cleanup)** | `system` MNG block 削除 | system MNG destroyed。bootstrap MNG + Karpenter-managed nodes のみ |

採用理由: 各 PR が独立 testable / rollback 可能。USER GATE で実 cluster 状態を見ながら進める。Plan 1c-β の 2-PR + USER GATE パターンの拡張で、慣れた進行。

トレードオフ:
1. PR 数が増える (3 PR + 2 USER GATE)。
2. `aws/eks/modules/node_groups.tf` を 2 回触る (PR 1 で bootstrap 追加、PR 3 で system 削除)。

### Decision 5: Karpenter の AWS リソースは独立 stack `aws/karpenter/` に分離 + Pod Identity を採用

Karpenter の AWS-side infra (`terraform-aws-modules/eks/aws//modules/karpenter` sub-module) を `aws/eks/modules/` 内ではなく **新 stack `aws/karpenter/`** で管理する。Plan 1c-β の `aws/alb/` 同様、Karpenter 関連リソースを独立した terragrunt stack として扱う。

Authentication mode は **Pod Identity** (sub-module の v21.19.0 デフォルト) を採用。Karpenter ServiceAccount は EKS Pod Identity Association 経由で IAM role を assume する。

#### `aws/eks/lookup/` 新設 (cross-stack lookup module)

`aws/karpenter/` から EKS cluster 情報 (`cluster_name`、Pod Identity の場合は OIDC provider 不要) を参照するため、`aws/vpc/lookup/` / `aws/route53/lookup/` 同型の shared lookup module `aws/eks/lookup/` を新設する。`data "aws_eks_cluster"` を pass-through。

#### Stack 分離の採用理由

1. **Operational simplicity (priority B)**: 「Karpenter 関連の AWS リソースは全部 `aws/karpenter/`」という mental model が clean。Plan 1c-β の `aws/alb/` precedent と一貫。
2. **Lifecycle 分離**: Karpenter sub-module の version up (例: v21 → v22) が EKS module の terraform state file に触らずに済む。
3. **`aws/eks/modules/` のスリム維持**: Plan 1a/1b/1c-α/1c-β で addons.tf 等が膨張気味。Karpenter は新 stack に逃がす。

#### Pod Identity の採用理由

1. **v21.19.0 module のデフォルト**: `enable_irsa` 等の variable は v21 で廃止済。IRSA を使うには `iam_role_source_assume_policy_documents` で OIDC trust policy を注入する custom 実装が必要で、module の trust policy に Pod Identity statement (`pods.eks.amazonaws.com`) が常時残る歪んだ状態になる。
2. **コードのシンプルさ (priority B)**: Pod Identity を素直に採用すれば `module "karpenter"` 呼び出しが minimal config (cluster_name + node_iam_role_additional_policies + tags) で済む。
3. **AWS 推奨方向**: Pod Identity は EKS で新規採用される認証方式の主流。`eks-pod-identity-agent` addon は Plan 1a で既に install 済。
4. **chart 側のシンプル化**: Karpenter Helm chart の serviceAccount.annotations に `eks.amazonaws.com/role-arn` を入れる必要なし (Pod Identity Association が SA-to-role mapping を直接管理)。

#### 採用しなかった代替案

1. **IRSA を強引に維持**: v21 module の interface 変更により custom assume policy 注入が必要。trust policy に dormant Pod Identity statement が残るため操作的に「綺麗じゃない」状態になる。priority B (operational simplicity) と矛盾。
2. **terraform-aws-modules/iam の iam-role-for-service-accounts で Karpenter 用 IRSA role を手動構築**: SQS / EventBridge / Node IAM 等の他リソースは別途 module 化が必要で、車輪の再発明。

#### Plan 1c-β との一貫性について

Plan 1c-β の ALB Controller / ExternalDNS は IRSA のまま据え置き。本 spec で導入する Karpenter のみ Pod Identity を採用するため、cluster 内に **IRSA と Pod Identity が混在**する一時的状態になる。Plan 1c-β の IRSA を Pod Identity に揃える場合は別 spec で扱う (Future Specs 参照)。

トレードオフ:
1. Stack が 1 つ増える: `aws/karpenter/` の Makefile / root.hcl / envs/production/ / modules/ の boilerplate。CI deploy job も 1 つ増える (`Deploy Terragrunt (karpenter:production)`)。
2. Cross-stack lookup が 1 つ増える: `aws/eks/lookup/` 経由で `aws/karpenter/` が EKS cluster 情報を取得。
3. Sub-module の挙動 (SQS queue 名や EventBridge rule 名のフォーマット) は module 側で決まり、自由度が下がる。
   - 緩和: 命名は cluster name から自動生成、本 cluster だけなので名前競合の心配なし。
4. cluster 内に IRSA + Pod Identity 混在状態が一時的に存在する (上述、Future Specs で解消)。

## Components matrix

### AWS layer (terragrunt)

| Component | Stack / File | PR | 役割 |
|---|---|---|---|
| `karpenter-bootstrap` MNG | `aws/eks/modules/node_groups.tf` | PR 1 (add) | Karpenter controller pod 専用、`t4g.small × 2`、taint `karpenter.sh/controller=true:NoSchedule`、label `node-role/karpenter-bootstrap=true` |
| `aws/eks/lookup/` (new shared module) | `aws/eks/lookup/{terraform,variables,main,outputs}.tf` | PR 1 (add) | EKS cluster 情報を cross-stack で公開 (`data "aws_eks_cluster"` pass-through)。`aws/karpenter/` と将来の他 stack が consume |
| `aws/karpenter/` (new stack) | `aws/karpenter/Makefile` + `root.hcl` + `envs/production/{env.hcl, terragrunt.hcl}` | PR 1 (add) | terragrunt stack の boilerplate (Plan 1c-β `aws/alb/` 同型) |
| Karpenter sub-module + outputs | `aws/karpenter/modules/{terraform,variables,lookups,main,outputs}.tf` | PR 1 (add) | `terraform-aws-modules/eks/aws//modules/karpenter` で SQS + EventBridge + Pod Identity (IRSA ではない) + Node IAM + Instance Profile を一括 provision。`aws/eks/lookup/` 経由で cluster 情報を取得。outputs: `node_role_name` / `interruption_queue_name` (Pod Identity なので controller_role_arn は kubernetes 側で不要) |
| `system` MNG (existing) | `aws/eks/modules/node_groups.tf` | PR 3 (remove) | Migration 完了後に block 削除 |

### Kubernetes layer (helmfile)

| Component | Path | 役割 |
|---|---|---|
| Karpenter Helm release | `kubernetes/components/karpenter/production/helmfile.yaml` | Chart `oci://public.ecr.aws/karpenter/karpenter` v1.6.x、namespace=karpenter |
| Karpenter Helm values | `kubernetes/components/karpenter/production/values.yaml.gotmpl` | bootstrap MNG への nodeSelector + toleration、`settings.clusterName` / `settings.interruptionQueue`。**IRSA annotation は不要** (Pod Identity Association が SA-to-role を直接管理)、ServiceAccount は chart デフォルトで作成 |
| Karpenter Namespace | `kubernetes/components/karpenter/production/namespace.yaml` | `karpenter` namespace |
| Kustomization bundle | `kubernetes/components/karpenter/production/kustomization/kustomization.yaml` | EC2NodeClass + NodePool を bundle |
| EC2NodeClass CRD | `kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml` | AMI alias `al2023@latest`、subnet selector `Tier=private`、SG selector (cluster + node)、role 参照 (Node IAM)、blockDeviceMappings (gp3 30 GiB)、IMDSv2 token required |
| NodePool CRD | `kubernetes/components/karpenter/production/kustomization/nodepool.yaml` | Decision 3 の requirements + `disruption.consolidationPolicy=WhenUnderutilized` + `disruption.expireAfter=720h` + `limits.cpu=200` |
| `kubernetes/helmfile.yaml.gotmpl` | (existing, modify) | production env values に `karpenter.{nodeRoleName,interruptionQueueName}` 追加 (controllerRoleArn は Pod Identity のため不要) |
| `kubernetes/README.md` | (existing, modify) | Production Operations 更新 |

## Cross-stack value flow

```
[PR 1: AWS apply]
  aws/eks/envs/production
  └─ karpenter-bootstrap MNG provision (4 nodes 体制)

  aws/karpenter/envs/production (NEW stack)
  ├─ aws/eks/lookup module 経由で cluster_name を取得
  └─ Karpenter sub-module (SQS / EventBridge / Pod Identity Association +
     Controller IAM role / Node IAM / Instance Profile)
                          ↓ outputs (aws/karpenter/modules/outputs.tf)
  cd aws/karpenter/envs/production && terragrunt output -json:
  - node_role_name             → EC2NodeClass.spec.role
  - interruption_queue_name    → Helm values.settings.interruptionQueue
  (controller_role_arn は Pod Identity Association が SA-to-role を直接
   管理するため kubernetes 側へ転記する必要なし)

[Manual transcribe: USER GATE 1 後、controller が記録]

[PR 2: Kubernetes apply]
  kubernetes/helmfile.yaml.gotmpl
  └─ production env values:
      cluster:
        name: eks-production              (既存)
        vpcId: vpc-...                    (既存)
        eksApiEndpoint: ...               (既存)
        albControllerRoleArn: ...         (既存)
        externalDnsRoleArn: ...           (既存)
      karpenter:
        nodeRoleName: ...                 ← NEW (EC2NodeClass.spec.role)
        interruptionQueueName: ...        ← NEW (chart settings)
                                ↓
  kubernetes/components/karpenter/production/
  ├─ helmfile.yaml: chart pin + interruption queue (NO IRSA annotation)
  ├─ values.yaml.gotmpl: nodeSelector + toleration + settings (clusterName + interruptionQueue)
  └─ kustomization/{ec2nodeclass,nodepool}.yaml: NodePool 参照
```

## Migration sequence (詳細)

### PR 1: AWS infrastructure (parallel add)

**Files**:
- `aws/eks/modules/variables.tf` (modify): bootstrap-specific variables 5 件追加
- `aws/eks/modules/node_groups.tf` (modify): Add `karpenter-bootstrap` block (既存 `system` 据え置き)
- `aws/eks/lookup/{terraform,variables,main,outputs}.tf` (new shared module): cross-stack lookup
- `aws/karpenter/Makefile` + `root.hcl` (new stack): boilerplate
- `aws/karpenter/envs/production/{env.hcl,terragrunt.hcl}` (new env)
- `aws/karpenter/modules/{terraform,variables,lookups,main,outputs}.tf` (new module): Karpenter sub-module 呼び出し + Pod Identity + outputs

**State after apply**:
- 4 EKS managed nodes (`system × 2 = m6g.large` + `karpenter-bootstrap × 2 = t4g.small`)
- Bootstrap MNG: taint で空 (Karpenter pod もまだ install 前)
- SQS interruption queue + EventBridge rules: created (まだ consumer なし、idle)
- Karpenter Controller IAM role + Pod Identity Association (`karpenter:karpenter` SA → IAM role)、Node IAM role、EC2 Instance Profile: created (まだ assumeRole する pod / EC2 なし)
- Pod 配置: 既存 system MNG (×2 m6g.large) 上に ~28 pod 全部

### USER GATE 1

1. PR 1 merge: `gh pr ready && gh pr review --approve && gh pr merge --squash --delete-branch`
2. CI が `Deploy Terragrunt (eks:production)` + `Deploy Terragrunt (karpenter:production)` を実行 → bootstrap MNG + Karpenter sub-module が provision される (2 stack なので 2 deploy job)
3. `kubectl get nodes -L eks.amazonaws.com/nodegroup` で 4 node Ready 確認
4. Controller が `cd aws/karpenter/envs/production && terragrunt output -json` で `node_role_name` / `interruption_queue_name` を取得 → PR 2 で kubernetes/helmfile.yaml.gotmpl に転記する

### PR 2: Kubernetes layer (Karpenter install)

**Files**:
- `kubernetes/helmfile.yaml.gotmpl` (modify): production env values に `karpenter.*` 追加 (PR 1 の terragrunt output から実値)
- `kubernetes/components/karpenter/production/helmfile.yaml` (new): Helm release config
- `kubernetes/components/karpenter/production/values.yaml.gotmpl` (new): chart values
- `kubernetes/components/karpenter/production/namespace.yaml` (new): karpenter namespace
- `kubernetes/components/karpenter/production/kustomization/kustomization.yaml` (new)
- `kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml` (new)
- `kubernetes/components/karpenter/production/kustomization/nodepool.yaml` (new)
- `kubernetes/manifests/production/` (auto-generated by `make hydrate`)
- `kubernetes/README.md` (modify): Production Operations 更新

**State after Flux reconcile**:
- Karpenter pod (replicas=2) が **bootstrap MNG 上で Running** (toleration + nodeSelector で確実に bootstrap に配置)
- `EC2NodeClass system-components` + `NodePool system-components` が CRD として登録 (まだ NodePool を要求する Pending pod 無し → node 起動なし)
- 既存 ~28 pod は引き続き **既存 system MNG (m6g.large × 2) 上で稼働**

### USER GATE 2: Manual migration (cordon + drain)

本 spec の最も慎重な部分。**Drain は 1 node 単位で逐次**、PDB を尊重する。

#### Step 1: Karpenter health check

```bash
kubectl get pods -n karpenter           # READY 2/2
kubectl logs -n karpenter deploy/karpenter --tail=20 | grep -iE "(fail|error)"
```

#### Step 2: Smoke test (Karpenter が Graviton 4 instance を自動 provision することを確認)

```bash
# arm64 nginx を 1 つ deploy → Karpenter が NodePool system-components の requirement を満たす
# instance を起動するはず (m8g.medium / c8g.medium 等)
kubectl create deployment smoke-target --image=nginx:alpine --replicas=1
# Karpenter NodeClaim → EC2 起動 → join → pod schedule。通常 60-120 秒
kubectl get nodeclaims                  # `system-components-xxxxx` が Launched / Registered / Ready
kubectl get nodes -L node.kubernetes.io/instance-type
# 新 node が m8g.* / c8g.* / r8g.* で起動していることを確認
kubectl get pod -l app=smoke-target -o wide  # 新 node 上で Running
# cleanup
kubectl delete deployment smoke-target
# Karpenter consolidation で empty node が auto-cleanup される (TTL 30 秒)
kubectl get nodes                       # 4 node に戻る
```

#### Step 3: 既存 system MNG の cordon (両 node)

```bash
for node in $(kubectl get nodes -l 'eks.amazonaws.com/nodegroup=system' -o name); do
  kubectl cordon $node
done
kubectl get nodes -L eks.amazonaws.com/nodegroup
# system × 2 が SchedulingDisabled
```

#### Step 4: Drain (1 node ずつ、PDB 尊重)

```bash
# 1 node 目
kubectl drain ip-10-0-XXX-XXX.ap-northeast-1.compute.internal \
  --ignore-daemonsets --delete-emptydir-data --timeout=10m

# Karpenter が pending pod を見て m8g.medium / c8g.large 等を 1-2 個 provision するはず
# 全 pod が新 node に移ったら次の node を drain
kubectl drain ip-10-0-YYY-YYY.ap-northeast-1.compute.internal \
  --ignore-daemonsets --delete-emptydir-data --timeout=10m
```

#### Step 5: 移行完了確認

```bash
kubectl get pods -A -o wide --field-selector=status.phase=Running | awk 'NR>1 {print $8}' | sort | uniq -c
# bootstrap × 2 + karpenter-managed × N に集約 (system × 2 は空)
kubectl get nodes -L eks.amazonaws.com/nodegroup -L karpenter.sh/nodepool
flux get all -A | grep -v "True"        # 結果が empty (全部 Ready)
```

### PR 3: AWS cleanup (system MNG 撤去)

**Files**:
- `aws/eks/modules/node_groups.tf` (modify): `system` block 削除。`karpenter-bootstrap` のみ残る
- `aws/eks/modules/variables.tf` (modify): `var.node_*` の整理 (bootstrap 専用に rename or 削除)

**State after apply**:
- Bootstrap MNG (`t4g.small × 2`) + Karpenter NodePool managed nodes (動的、N=current load-dependent)
- system MNG **destroyed** (drain 済 + cordon 済 = pod なし → 安全に terminate)
- Plan 2 完了

### エラーシナリオと対処

| シナリオ | 対処 |
|---|---|
| Step 4 drain で PDB が blocker (`Cannot evict pod`) | 該当 deployment の replicas を一時的に増やすか、PDB を update して `maxUnavailable` を増やす |
| Karpenter が m8g.medium 等の provision に失敗 (capacity 不足) | NodePool の `instance-generation: Gt 7` 制約を一時緩和 (`Gt 5` で gen 6/7 も許可) して再試行 |
| Drain 中に Karpenter pod が再起動 → bootstrap × 2 で HA 確保 | replica=2 なので 1 pod down は問題なし。両方 down する事態なら bootstrap MNG 再起動で回復 |
| 全 bootstrap node が同時に落ちる | `terragrunt apply` で MNG re-create (state は保持される) |

## Verification checklist

### PR 1 後 (terragrunt apply 後)
- [ ] `kubectl get nodes -L eks.amazonaws.com/nodegroup` で 4 node Ready (`system × 2 = m6g.large` + `karpenter-bootstrap × 2 = t4g.small`)
- [ ] `aws iam list-roles --query "Roles[?contains(RoleName, 'KarpenterController')]"` で Karpenter controller IAM role 存在
- [ ] `aws eks list-pod-identity-associations --cluster-name eks-production --namespace karpenter` で karpenter ServiceAccount に Pod Identity Association が紐付いている
- [ ] `aws iam get-role --role-name <karpenter_node_role_name>` で Node IAM role 存在 + EC2 service principal trust
- [ ] `aws sqs get-queue-attributes --queue-url <interruption_queue_url>` で queue 存在
- [ ] `aws events list-rules --name-prefix <cluster>-karpenter` で 4 rule 存在 (Spot Interruption / Health / State Change / Scheduled Change)
- [ ] terragrunt outputs から 3 値を取得可能

### PR 2 後 (Flux reconcile 後)
- [ ] `kubectl get pods -n karpenter` で Karpenter pod replicas=2 Running
- [ ] `kubectl get pod -n karpenter -o wide` で **bootstrap MNG 上に配置** (`eks.amazonaws.com/nodegroup=karpenter-bootstrap` label の node)
- [ ] `kubectl logs -n karpenter deploy/karpenter --tail=20 | grep -iE "(error|fail)"` でエラーなし
- [ ] `kubectl get ec2nodeclass system-components` で Ready=True
- [ ] `kubectl get nodepool system-components` で Ready=True
- [ ] `kubectl get nodeclaim` で空 (まだ要求 pending pod 無し)

### USER GATE 2 完了後 (drain + migration 後)
- [ ] system MNG node × 2 が `SchedulingDisabled` + pod 数 = 0 (DaemonSet 以外)
- [ ] Karpenter NodePool が起動した `m8g/c8g/r8g.*` instance × N で全 system pod (CoreDNS / Cilium / Flux / addons / etc.) が Running
- [ ] `flux get all -A | grep -v True` が空 (全 reconciliation Ready)
- [ ] `cilium status` で Cluster Pods managed by Cilium が steady state
- [ ] Smoke Ingress (Plan 1c-β verification と同じ) を再実行して ALB + Route53 + HTTPS が動作

### PR 3 後 (system MNG destroy 後)
- [ ] `kubectl get nodes -L eks.amazonaws.com/nodegroup` で `system` group node が存在しない
- [ ] `aws eks list-nodegroups --cluster-name eks-production` で `system` が無い
- [ ] cluster 状態が steady (全 pod Ready, Karpenter NodePool 上で安定稼働)
- [ ] AWS billing console で日次 EC2 cost が `m6g.large × 2` 分減少していることを翌日確認

## Trade-offs (accepted explicitly)

| 項目 | Trade-off | 緩和策 |
|---|---|---|
| Bootstrap MNG burstable CPU (`t4g.small`) | Karpenter scale event 連発時に CPU credit 枯渇のリスク | 通常 Karpenter は idle 90% 以上、credit 蓄積 > 消費。t4g.small は 30 credit + 12/hour で daily 動作には十分 |
| Single NodePool | workload 種別 (system / batch / GPU / 等) 別の最適化不可 | 当面 critical pod のみ。差別化必要時に別 spec で NodePool 分割 |
| Graviton 4 only (gen 8) | Capacity 不足 region では provisioning 失敗 | ap-northeast-1 では現状問題なし。発生時は NodePool requirements を一時的に gen 7 (m7g) も許可で復旧 |
| Critical addon on Karpenter-managed node | Consolidation で CoreDNS pod が evict されるリスク | PDB (chart デフォルトで `maxUnavailable: 1` + replicas≥2) を Karpenter consolidation が尊重 |
| 3-PR + 2 USER GATE で migration | Plan 1c-β より workflow が長い | 各 PR 独立 testable / rollback 可能、migration 中の事故影響を最小化 |
| Karpenter pod 自身が落ちると新規 node 起動不可 | Bootstrap MNG が冗長化 (replica 2)、両 node 同時落ちは AZ 障害級 | replicas=2 で AZ 分散 + bootstrap MNG min/max=2 で常時 2 nodes |

## Rollback strategy (per stage)

| Stage | Rollback 手順 | リスク |
|---|---|---|
| PR 1 merged → revert | `terragrunt destroy` (karpenter-bootstrap + Karpenter sub-module)。system MNG 影響なし | 低 |
| PR 2 merged → revert | Flux reconcile で Karpenter Helm release / NodePool / EC2NodeClass 撤去。Bootstrap MNG は idle で残るが pod 影響なし。system MNG 上の pod は引き続き稼働 | 低 |
| USER GATE 2 中で問題発生 | `kubectl uncordon` で system MNG 復活。Karpenter-provisioned node は consolidation で 30s 後に auto-delete (NodeClaim TTL) | 中 (drain 中に PDB ロックで悩む可能性) |
| PR 3 merged → revert | `aws/eks/modules/node_groups.tf` に `system` block を再追加 → `terragrunt apply` で **新規** system MNG (新 EC2、IP 違う) が作成。Pod は Karpenter 上のままなので migration やり直しは不要 | 中 (新 MNG なので state ID は異なるが運用影響なし) |

**Point of no return**: PR 3 merge。それ以前は full rollback 可能。

## Future Specs (本 spec の Out of scope)

| 項目 | いつ取り組むか | 概要 |
|---|---|---|
| **Spot NodePool** (workload 用) | Phase 5 (nginx) 直前 / monorepo migration 直前 | `workload-spot` NodePool 追加。toleration / nodeSelector で application pod のみ spot に配置。SQS interruption queue (本 spec で provision 済) を実用化 |
| **GPU NodePool** | ML workload 投入時 | g5g (ARM64 GPU) 等の専用 NodePool。NodePool taint で GPU 必要 pod のみ schedule |
| **Mixed architecture (x86 fallback)** | ARM64 image 不在の OSS 採用時 | `kubernetes.io/arch: [arm64, amd64]` の hybrid NodePool。bin-packing が悪化するので慎重に |
| **Older generation 許可** | Graviton 4 capacity 制約発覚時 | NodePool requirements 緩和 (`Gt 5`) |
| **Plan 1c-β IRSA 全体の Pod Identity 移行** | 別 spec | 本 spec で Karpenter のみ Pod Identity 化済。残りの ALB Controller / ExternalDNS (Plan 1c-β で IRSA 採用) を Pod Identity に揃える spec |
| **Karpenter consolidation 詳細 tuning** | observability 整備後 (Phase 3 後) | per-workload disruption budget、scheduled disruption window 等 |
| **Custom node images (Bottlerocket)** | Security hardening 専用 spec | 現状 AL2023 で十分 |
| **Multi-region / DR NodePool** | Multi-region cluster 構築時 | 別 region 用 NodePool / EC2NodeClass |
