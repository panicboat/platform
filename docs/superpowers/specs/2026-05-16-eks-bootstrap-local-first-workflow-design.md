# EKS Bootstrap Local-First Workflow Design

> **Status**: design spec、 後段 implementation plan + label scheme PR で具体化。
>
> **Scope**: `make eks-recreate` 等 lifecycle script で cluster bootstrap / 復旧 する際の **PR + CI workflow 改善**。 panicboat の通常 PR flow (= merge 後 CI が terragrunt apply / kubernetes deploy を自動実行) は steady state では適切だが、 bootstrap / 復旧時は CI auto-apply が **試行錯誤を妨げる要因** になる事象を 2026-05-16 cold-start recreate live run で複数回踏んだ。

## 1. Problem statement

### 1.1 観測した事象 (= 2026-05-16 live run)

| Issue | 経緯 |
|---|---|
| **PR #401 (= IRSA → Pod Identity) merge → CI 即 apply → live cluster 状態と CI が race** | merge 直後に CI が `aws/eks` apply を開始、 同時に operator が local で karpenter apply を試みると state lock 競合で fail |
| **VPC destroy 済み環境で PR plan が lookup fail** | `aws/vpc` の lookup data source (= `aws_vpc` 等) が destroy 済で 'no matching EC2 VPC found' で plan fail → CI BLOCKED → admin override OR VPC を先に apply で unblock 必要 |
| **stale terragrunt state lock** | 前 session の teardown が lock release 漏れ → 次 session の apply / CI が `Error acquiring the state lock` で fail |
| **manual aws CLI patch で drift** | cilium-operator IAM policy に `ec2:DescribeRouteTables` 不足発覚 → live で `aws iam put-role-policy` で手動 patch → terraform state と drift → 別 PR で terraform 側も更新する 2-step が必要に |
| **CI plan が live cluster 状態に依存** | terragrunt plan が「cluster 存在前提」で組まれており、 cold-start 中 (= partial state) は plan が必ず fail → mergeable=BLOCKED で stuck |

### 1.2 根本原因

panicboat の通常 PR flow は **steady-state operation** (= cluster は alive、 PR diff は marginal change) を前提に設計されている:

- PR open → CI plan (= 期待: 差分小さい、 no-op に近い)
- review → merge
- CI apply (= 期待: 差分小さい、 短時間で完了)

しかし bootstrap / 復旧時は:

- 試行錯誤の中で **incremental に AWS state を変える**
- live cluster の partial state で plan が動かない
- CI auto-apply が **local control loop の妨げ** になる
- IAM permission 等の missing を **runtime で発見 → 即 fix** したい

steady-state と bootstrap の workflow を一律に扱うと bootstrap が窮屈になる。

## 2. Goals

1. bootstrap / 復旧時に operator が **local から terragrunt / helmfile / kubectl を直接 trigger** できる経路を明示的に提供する (= 既存)
2. bootstrap PR は merge 後の CI auto-apply を **skip / 手動 trigger に倒せる** mechanism を持つ
3. terraform state と live AWS の drift を **検出 + 修正する手順** を runbook 化
4. PR plan が cold-start 状態でも fail せず、 plan output に "skipped (= bootstrap pending)" 等の reason を出せる

## 3. Non-goals

- 通常 PR flow の変更 (= steady state では現状維持で十分)
- CI auto-apply を全面 disable (= 通常 PR では引き続き auto-apply が便利)
- bootstrap を CI-only にする (= local trigger 経路は維持)
- 別環境 (= staging 等) への適用 (= production の cold-start に scope 限定)

## 4. Design

### 4.1 PR Label scheme

PR に **`skip-deploy`** label が付与されている時、 後続の CI workflow を skip する:

| Label | Behavior |
|---|---|
| (なし) | 通常 flow: CI plan on open + CI apply on merge |
| `skip-deploy` | CI plan / apply 全 skip (= status check は SUCCESS で gate を通す)、 operator が local で apply 後に label を外して通常 flow に戻す |
| `plan-only` | CI plan は実行、 merge 後 apply は skip (= PR は merge できるが apply は手動 / 別 workflow) |

`.github/workflows/` の各 deploy workflow 冒頭で `if !contains(github.event.pull_request.labels.*.name, 'skip-deploy')` 等の guard を追加。

### 4.2 Bootstrap-pending CI behavior

cold-start で AWS resource lookup が fail する場合、 plan を skip して FAILURE ではなく NEUTRAL conclusion を返す:

- workflow に "plan が `no matching EC2 VPC found` で fail した場合、 SUCCESS に転換" の logic を追加
- 期待: bootstrap pending では plan は no-op で通る (= apply 時点で初めて apply される)

### 4.3 Local-first runbook の正式化

`docs/superpowers/specs/2026-05-16-eks-recreate-manual-bootstrap-runbook.md` (= PR #400) の手順を「**local-first + PR は state-tracking 用**」の前提で書き直す:

| Phase | 現 runbook | 改善版 |
|---|---|---|
| Phase 0 pre-flight | aws sts / kubectl auth 確認 | + `skip-deploy` label の PR を bootstrap branch で先に open (= CI auto-apply 抑止) |
| Phase 1-7 | 各 stack を terragrunt apply | local 完了後、 (該当する場合) git push + PR commit で state-tracking |
| Phase 9 Flux bootstrap | 60-flux-bootstrap.sh で commit + push | 同上、 push 後 CI が hydrate を担当する想定 |
| 完走後 | (現 runbook 終了) | `skip-deploy` label を外す → CI が drift detection (= plan no-op verify) |

### 4.4 Drift detection + recovery snippet

manual patch (例: `aws iam put-role-policy`) を行った場合の drift 認識 + 修正手順を runbook に追加:

```bash
# drift 検出
( cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt plan -lock=false ) 2>&1 | grep -E 'will be (created|destroyed|updated)'

# 修正 path 1: PR で terraform code を実状態に揃える (推奨)
# 修正 path 2: terragrunt apply で terraform state を実状態に上書き (= state 側を更新するが diff が残る場合 import が必要)
```

### 4.5 State lock recovery

stale lock の検出 + force-unlock を runbook に明示:

```bash
# active lock list
aws dynamodb scan --region ap-northeast-1 --table-name terragrunt-state-locks \
  --query 'Items[?Info != `null`]' --output json

# force-unlock
( cd aws/<stack>/envs/<env> && TG_TF_PATH=tofu terragrunt force-unlock -force <LOCK_ID> )
```

## 5. Implementation phases

1. **Phase A**: PR label scheme spec + .github/workflows 改修 plan (= 別 plan PR)
2. **Phase B**: workflows に label-based guard 追加 (= 実装 PR)
3. **Phase C**: 既存 lifecycle script / runbook (PR #400) を local-first 前提に書き直し (= 別 PR)
4. **Phase D**: cold-start plan fail を NEUTRAL 化する CI workflow logic (= optional、 Phase B で十分な可能性高い)

## 6. References

- 2026-05-16 cold-start recreate live run (= 本 spec のトリガー)
- PR #400: docs/superpowers/specs/2026-05-16-eks-recreate-manual-bootstrap-runbook.md
- PR #401: feat(eks): cilium-operator IRSA → Pod Identity Association
- PR #402: fix(eks): add ec2:DescribeRouteTables to cilium-operator policy
- 既存 lifecycle: docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md

## 7. Future

bootstrap 経験を蓄積していくと、 CI workflow 側の guard では足りず、 **「lifecycle script が CI を suspend / resume する API」** が欲しくなる可能性あり (= 例: GitHub Actions の workflow_dispatch で apply を pause/resume)。 本 spec の Phase A-D 完了後に必要性を再評価。
