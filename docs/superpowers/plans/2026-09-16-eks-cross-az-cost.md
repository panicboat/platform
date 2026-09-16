# EKS Cross-AZ Traffic Cost Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the majority of `APN1-DataTransfer-Regional-Bytes` cost (~$4.8/day observed 2026-09-10〜09-14 on production, ~$150/month run-rate) by collapsing Karpenter-managed compute and the `system_critical` MNG onto a single AZ, and add a cluster-wide, self-maintaining default so future multi-replica components never need per-component wiring to stay AZ-aware.

**Architecture:** Two independent, additive changes. (1) Pin the Karpenter `system-components` NodePool and the `system_critical` managed node group to the same single AZ (`ap-northeast-1a`) — this structurally eliminates cross-AZ traffic for anything scheduled on either, regardless of replica count, because there is no second AZ to cross to. (2) Add a Kubernetes `MutatingAdmissionPolicy` that injects `trafficDistribution: PreferClose` onto every `Service` object cluster-wide (including ones created by the separate `panicboat/monorepo` Flux source) unless already set — this is defense-in-depth for the day AZ count is increased again, and removes the need to track which components have >1 replica.

**Tech Stack:** Terraform (OpenTofu via terragrunt, `terraform-aws-modules/eks` v21.25.0), Karpenter v1 CRDs (`karpenter.sh/v1`), Kustomize, Kubernetes `admissionregistration.k8s.io/v1` `MutatingAdmissionPolicy` (GA in 1.36, this cluster's `cluster_version`).

**Spec:** No separate spec document exists. Requirements were established through an extended conversational investigation in this session (AWS Cost Explorer analysis, repo config review, Cilium/Kubernetes source verification). Key evidence this plan depends on:
- Cost Explorer: `APN1-DataTransfer-Regional-Bytes` is ~100% `EC2 - Other`, NAT Gateway and ELB ruled out as causes (NAT-processed bytes were <0.1% of the cross-AZ volume on peak days).
- `aws/eks-karpenter/modules/main.tf`: `system_critical` MNG uses `subnet_ids = module.vpc.subnets.private.ids` (all 3 AZs), hosts CoreDNS + cilium-operator + Karpenter controller.
- `kubernetes/components/karpenter/production/kustomization/nodepool.yaml`: `system-components` NodePool has no `topology.kubernetes.io/zone` requirement.
- Cilium 1.19.4 (pinned in `kubernetes/components/cilium/production/helmfile.yaml`) only recognizes the Service field value `"PreferClose"`, not `"PreferSameZone"` — verified by reading `pkg/loadbalancer/reflectors/conversions.go` at tag `v1.19.4` in `cilium/cilium`. Support for `"PreferSameZone"`/`"PreferSameNode"` landed in PR #44771 (merged 2026-03-27), which shipped in the v1.20 line, not backported to v1.19.4.
- Mimir/Loki/Tempo run `replicas: 1` by deliberate design (`kubernetes/components/mimir/production/values.yaml.gotmpl`); `trafficDistribution` has no effect on a Service with a single endpoint, and Mimir's own replication (when RF>1) is ring-based and bypasses Service-level load balancing entirely (`pkg/loadbalancer/reflectors/conversions.go` ring-resolution vs. `mimir-distributed` chart `ingester-svc.yaml` template — the write path does not go through this Service).

## Global Constraints

- AZ used for pinning: `ap-northeast-1a` (first entry in `aws/vpc/modules/variables.tf` `availability_zones` default list). Must be identical across Task 1 and Task 2 — do not let these drift.
- `trafficDistribution` value: always `"PreferClose"`, never `"PreferSameZone"` (Cilium 1.19.4 constraint, see Spec section above).
- The production EKS cluster and VPC are fully destroyed as of this session (`aws eks describe-cluster` → `ResourceNotFoundException`; `aws ec2 describe-vpcs` for `vpc-production` → empty). No live cluster or live Terraform state exists to plan/apply against. Every task's verification step is therefore static (syntax/render-level) only; live functional verification is deferred to the next `docs/runbooks/eks-production-recreate.md` run and is captured as explicit follow-up items in that runbook (Task 4).
- Do not touch `kubernetes/components/mimir`, `kubernetes/components/loki`, or `kubernetes/components/tempo` — their singleton replica design is intentional and out of scope (see Spec).
- Follow existing repo conventions: Terraform comments explain *why*, not *what* (AGENTS.md); no comments on unrelated/unchanged lines.

---

### Task 1: Pin Karpenter `system-components` NodePool to a single AZ

**Files:**
- Modify: `kubernetes/components/karpenter/production/kustomization/nodepool.yaml`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the AZ constant `ap-northeast-1a`, which Task 2's Terraform variable default must match exactly.

- [ ] **Step 1: Add the zone requirement**

In `kubernetes/components/karpenter/production/kustomization/nodepool.yaml`, the `requirements` list currently ends with the `instance-size` entry immediately before `expireAfter: 720h`. Add a new requirement entry there:

```yaml
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["large", "xlarge", "2xlarge", "4xlarge"]
        # Cross-AZ traffic cost対策 (docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md)。
        # aws/eks-karpenter/modules/variables.tf の compute_availability_zone と同じ値にすること。
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["ap-northeast-1a"]
      expireAfter: 720h  # 30 days
```

- [ ] **Step 2: Render and verify the kustomize overlay**

```bash
kustomize build kubernetes/components/karpenter/production/kustomization | grep -A2 "topology.kubernetes.io/zone"
```

Expected output includes:
```
        - key: topology.kubernetes.io/zone
          operator: In
          values:
          - ap-northeast-1a
```

- [ ] **Step 3: Re-hydrate the component and inspect the diff**

```bash
bash scripts/kubernetes-hydrate/hydrate-component.sh karpenter production
git diff kubernetes/manifests/production/karpenter/manifest.yaml
```

Expected: the diff shows only the new `topology.kubernetes.io/zone` requirement added to the `NodePool` object; no other unrelated churn (if TLS/cert fields appear, they are unrelated to this component and should not occur here since karpenter has no such rendering).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/karpenter/production/kustomization/nodepool.yaml kubernetes/manifests/production/karpenter/manifest.yaml
git commit -s -m "fix(kubernetes/karpenter): pin system-components NodePool to a single AZ

Karpenter was free to spread nodes across all 3 AZs with no
Service-level AZ-affinity anywhere in the cluster, so the bulk of
pod-to-pod traffic crossed AZ boundaries and showed up as a flat
~\$4.8/day APN1-DataTransfer-Regional-Bytes charge (Cost Explorer,
2026-09-10..09-14). Pinning to one AZ removes the cross-AZ path
structurally, independent of any component's replica count."
```

---

### Task 2: Pin `system_critical` MNG to the same AZ

**Files:**
- Modify: `aws/eks-karpenter/modules/variables.tf`
- Modify: `aws/eks-karpenter/modules/main.tf:92` (the `subnet_ids` line inside `module "system_critical"`)

**Interfaces:**
- Consumes: the AZ constant `ap-northeast-1a` from Task 1 (must match).
- Produces: `data.aws_subnets.system_critical_az` (new data source), `var.compute_availability_zone` (new variable) — no other module currently consumes these; this is safe to add without touching `aws/eks-karpenter/production/terragrunt.hcl` (the variable has a default, so no per-env input is required).

- [ ] **Step 1: Add the `compute_availability_zone` variable**

In `aws/eks-karpenter/modules/variables.tf`, add (near the other `system_critical_*` variables):

```hcl
variable "compute_availability_zone" {
  description = "Single AZ that the system_critical MNG is pinned to. Must match the topology.kubernetes.io/zone value in kubernetes/components/karpenter/production/kustomization/nodepool.yaml — see docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md for why both are pinned to the same AZ."
  type        = string
  default     = "ap-northeast-1a"
}
```

- [ ] **Step 2: Add an AZ-filtered subnet lookup and switch `subnet_ids`**

In `aws/eks-karpenter/modules/main.tf`, immediately above the `module "system_critical" {` block, add:

```hcl
# module.vpc.subnets.private はTier=privateの3AZ分をまとめて返し、返り値の
# 順序はAZ順を保証しないため、AZ filterで1AZ分だけ取り出す
# (docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md)。
data "aws_subnets" "system_critical_az" {
  filter {
    name   = "vpc-id"
    values = [module.vpc.vpc.id]
  }
  filter {
    name   = "availability-zone"
    values = [var.compute_availability_zone]
  }
  tags = {
    Tier = "private"
  }
}
```

Then change line 92 from:

```hcl
  subnet_ids = module.vpc.subnets.private.ids
```

to:

```hcl
  subnet_ids = data.aws_subnets.system_critical_az.ids
```

- [ ] **Step 3: Validate syntax (no live state available — see Global Constraints)**

```bash
cd aws/eks-karpenter/modules
tofu init -backend=false -upgrade
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add aws/eks-karpenter/modules/variables.tf aws/eks-karpenter/modules/main.tf
git commit -s -m "fix(aws/eks-karpenter): pin system_critical MNG to a single AZ

CoreDNS, cilium-operator, and the Karpenter controller run on this MNG,
which previously spanned all 3 AZs (module.vpc.subnets.private.ids).
The OTel Collector and Falco DaemonSets tolerate this MNG's taint and
run here too, so any of the 2 nodes landing outside the
system-components NodePool's pinned AZ generated avoidable cross-AZ
traffic to the Mimir/Loki/Tempo singletons. Pinning to the same AZ as
kubernetes/components/karpenter/production/kustomization/nodepool.yaml
removes that path."
```

---

### Task 3: Cluster-wide `trafficDistribution` default via MutatingAdmissionPolicy

**Files:**
- Create: `kubernetes/components/service-traffic-distribution/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/service-traffic-distribution/production/kustomization/mutating-admission-policy.yaml`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing consumed elsewhere. This is a new, independent component following the exact pattern in `kubernetes/components/karpenter/production/kustomization/` and `kubernetes/components/cilium/production/kustomization/` (raw manifests, no `helmfile.yaml`, auto-discovered by `scripts/kubernetes-hydrate/hydrate-index.sh` since it lives under `kubernetes/components/*/production/`).

- [ ] **Step 1: Create the kustomization entrypoint**

`kubernetes/components/service-traffic-distribution/production/kustomization/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - mutating-admission-policy.yaml
```

- [ ] **Step 2: Create the policy**

`kubernetes/components/service-traffic-distribution/production/kustomization/mutating-admission-policy.yaml`:

```yaml
# Service trafficDistributionのデフォルト注入。per-component opt-inだと将来の
# replica増加やmonorepo側Serviceで設定漏れが起きるため cluster-wide化
# (docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md、namespaceSelector
# は意図的に未設定)。
#
# 値は "PreferClose" 固定。Cilium 1.19.4は "PreferSameZone" を認識せず
# "PreferClose" のみ対応 (cilium/cilium PR #44771 はv1.20系のみ反映、
# kubernetes/kubernetes API上は同義のdeprecated alias)。
#
# headless/ExternalName Serviceは対象外。failurePolicy: Ignore はCEL評価
# 失敗でService作成をblockしないための選択。
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: default-traffic-distribution
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["services"]
  matchConditions:
    - name: not-headless
      expression: "object.spec.clusterIP != 'None'"
    - name: not-external-name
      expression: "object.spec.type != 'ExternalName'"
  failurePolicy: Ignore
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: |
          Object{
            spec: Object.spec{
              trafficDistribution: has(object.spec.trafficDistribution) ? object.spec.trafficDistribution : "PreferClose"
            }
          }
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: default-traffic-distribution-binding
spec:
  policyName: default-traffic-distribution
```

- [ ] **Step 3: Render and check for YAML/structural errors**

```bash
kustomize build kubernetes/components/service-traffic-distribution/production/kustomization > /tmp/traffic-distribution-rendered.yaml
```

Expected: succeeds with no errors, output contains both the `MutatingAdmissionPolicy` and `MutatingAdmissionPolicyBinding` documents.

**Known limitation (document, do not attempt to work around):** `kubectl apply --dry-run=client` was tried and does not work offline here — even with `--validate=false`, kubectl still contacts the API server for REST discovery (confirmed: it tries to reach the destroyed cluster's endpoint and fails with a DNS lookup error, not a validation error). There is no live cluster or local kind/k3d cluster running to validate against instead. This means neither the resource schema (field names like `matchConstraints`/`applyConfiguration`) nor the CEL `expression` strings are validated by anything executable in this session — both are deferred to Task 4 / the next recreate, where a real API server exists to check against.

- [ ] **Step 4: Re-hydrate and confirm the new component is picked up**

```bash
bash scripts/kubernetes-hydrate/hydrate-component.sh service-traffic-distribution production
bash scripts/kubernetes-hydrate/hydrate-index.sh production
git status --short kubernetes/manifests/production/
```

Expected: `kubernetes/manifests/production/service-traffic-distribution/{manifest.yaml,kustomization.yaml}` created, and `kubernetes/manifests/production/kustomization.yaml` now lists `./service-traffic-distribution` in sorted order alongside the other components.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/components/service-traffic-distribution kubernetes/manifests/production/service-traffic-distribution kubernetes/manifests/production/kustomization.yaml
git commit -s -m "feat(kubernetes): default Service trafficDistribution to PreferClose cluster-wide

Per-component opt-in (editing each Helm chart's values when it happens
to have >1 replica) is fragile: it silently misses any component whose
replica count changes later, and cannot reach panicboat/monorepo's own
Services since that's a separate Flux-managed repository. A
MutatingAdmissionPolicy bound cluster-wide covers both cases with one
resource. PreferClose (not PreferSameZone) because Cilium 1.19.4 only
recognizes the deprecated alias — see plan doc for the verified
version gap."
```

---

### Task 4: Runbook follow-ups for the next recreate

**Files:**
- Modify: `docs/runbooks/eks-production-recreate.md`

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: nothing.

- [ ] **Step 1: Add a Failure handling row for the admission policy**

In the `## 5. Failure handling` table (`docs/runbooks/eks-production-recreate.md`), add a new row after the existing `karpenter is not compatible` row (matches the table's existing `| Symptom | Likely cause | Recovery |` format):

```markdown
| `kubectl apply -k kubernetes/clusters/production/` (Phase 9.3b) が `default-traffic-distribution` / `default-traffic-distribution-binding` で `no matches for kind "MutatingAdmissionPolicy"` | EKSのAPI serverが `MutatingAdmissionPolicy` (GA in K8s 1.36) admission pluginをdefaultで有効化していない可能性。docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md 作成時点(2026-09-16)では未確認 | `kubectl api-resources \| grep -i mutatingadmissionpolicy` で有無を確認。存在しない場合はこのplanのTask 3コンポーネントをFlux管理から一時除外し(`kubernetes/manifests/production/kustomization.yaml` からservice-traffic-distributionを外す)、Kyverno等の外部admission controller導入を再検討する |
```

- [ ] **Step 2: Add a Failure handling row for single-AZ capacity risk**

Add another row:

```markdown
| Karpenter が worker node を provision できず Pending pod が滞留する (= karpenter controller log に `InsufficientInstanceCapacity` 系のエラー、`ap-northeast-1a` 限定で発生) | 2026-09-16のcross-AZコスト対策 (docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md) で `system-components` NodePool を `topology.kubernetes.io/zone: [ap-northeast-1a]` に固定したため、そのAZでspot/on-demand容量が枯渇すると他AZへのfallbackが効かない (3AZ分散なら回避できていたリスク) | 一時対応: `kubernetes/components/karpenter/production/kustomization/nodepool.yaml` の `topology.kubernetes.io/zone` values に他AZを追加してNodePool再apply。恒久対応が必要なら単一AZ化の costトレードオフを再評価する |
```

- [ ] **Step 3: Add a verification bullet to `## 4. Verification`**

After the existing `addon` verification block in `docs/runbooks/eks-production-recreate.md`, add:

```markdown
# trafficDistribution admission policy (2026-09-16 追加、docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md)
kubectl api-resources | grep -i mutatingadmissionpolicy
# → 存在すること。存在しない場合は §5 Failure handling の該当行を参照

kubectl get service -n cert-manager cert-manager-webhook -o jsonpath='{.spec.trafficDistribution}'
# → "PreferClose" が返ること (= admission policyが実際にServiceへ注入できているかの実地確認)

kubectl get nodes -L topology.kubernetes.io/zone
# → 全node (system_critical + Karpenter-provisioned) が ap-northeast-1a のみであること
```

- [ ] **Step 4: Add a Future improvements bullet for VPC Flow Logs**

In `## 6. Future improvements`, add:

```markdown
- **VPC Flow Logs 有効化** — 2026-09-16のcross-AZコスト調査 (docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md) で、送信元/宛先IPペア単位の内訳がないままteardown後に事後分析を試みて測定不能だった (monorepo由来か platform component由来かを追跡できず)。次回recreateの `aws/vpc` stack apply時にFlow Logsを有効化しておけば、同種の調査が発生した際にCost ExplorerのUsage Type単位の粗い数字だけでなく実際のトラフィックパスで裏付けが取れる
```

- [ ] **Step 5: Add a References entry**

In `## 7. References`, add:

```markdown
- `docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md` — cross-AZ traffic cost 分析 + 単一AZ化 + trafficDistribution admission policy 対応 plan
```

- [ ] **Step 6: Commit**

```bash
git add docs/runbooks/eks-production-recreate.md
git commit -s -m "docs(runbooks): add next-recreate follow-ups for cross-AZ cost changes

Verification steps and failure-handling rows for the single-AZ
NodePool/MNG pinning and the new trafficDistribution admission policy
introduced in docs/superpowers/plans/2026-09-16-eks-cross-az-cost.md,
plus a VPC Flow Logs recommendation driven by this session hitting a
measurement dead-end after the cluster was already torn down."
```

---

## Self-Review

**Spec coverage:**
- Single-AZ NodePool pinning → Task 1. ✓
- Single-AZ `system_critical` pinning → Task 2. ✓
- Cluster-wide `trafficDistribution` default (replacing the per-component list, covering monorepo) → Task 3. ✓
- `PreferClose` (not `PreferSameZone`) value constraint → encoded in Task 3 Step 2 and Global Constraints. ✓
- Next-recreate verification (admission plugin support, single-AZ capacity risk, VPC Flow Logs) → Task 4. ✓
- Mimir/Loki/Tempo explicitly out of scope → Global Constraints. ✓

**Placeholder scan:** No TBD/TODO/"add appropriate" patterns; all code blocks are complete and copy-pasteable.

**Type/value consistency:** `ap-northeast-1a` used identically in Task 1 (NodePool) and Task 2 (Terraform variable default). `PreferClose` used identically in Task 3's CEL expression and comments. Component name `service-traffic-distribution` consistent across Task 3's directory paths and Task 4's runbook references.
