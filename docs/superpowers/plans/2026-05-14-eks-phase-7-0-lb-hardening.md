# Phase 7-0 LB Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 6 closure で identify した 引き継ぎ事項 #37 / #39 を 1 sub-project で systematic 解消、 cluster LB architecture を panicboat 設計 spec ("north-south は ALB Controller、 east-west は cilium-gateway") に re-align、 monthly cost ~$79 削減 + Gateway 層 JWT validation 採用余地確保。

**Architecture:** 3 components sequential (= #37 → Cilium upgrade → #39) + fallback (= #39 fail 時 #40 bridge revival)。 4 PRs (= platform 3 + monorepo 1) for strict completion、 fallback path で +1 PR。 panicboat の "Flux suspend + ローカル apply + 試行錯誤" pattern 採用、 user 許容 cluster downtime で trial-and-error 進む。

**Tech Stack:** AWS EKS + terraform-aws-modules/eks/aws v21.20.0 + terragrunt + OpenTofu + Cilium 1.18.6 → 1.x.y + helmfile + kustomize + AWS Load Balancer Controller + ExternalDNS + AWS ACM + Route53 + Flux CD

---

## Phase 7-0 deploy 順序

```
PR 1: #37 fix (= terragrunt eks module node SG tag 除去)
  ↓ apply + verify AWS LB Controller panic loop 停止
PR 2: Cilium upgrade (= 1.18.6 → 1.x.y)
  ↓ apply + verify 既 fix forward regression なし
PR 3: #39 platform side (= cilium hostNetwork + Gateway port 8080 + ALB Ingress)
  ↓ apply + verify ALB provision + 旧 NLB auto-delete
PR 4: #39 monorepo side (= reverse-proxy 削除 + frontend HTTPRoute)
  ↓ apply + verify develop.panicboat.net 200 OK
[Fallback PR F1 (= #39 fail 時): cilium revert + #40 bridge]
```

各 PR は **前 PR の cluster apply + verify 完了後** に着手。 panicboat の "Flux suspend + ローカル apply で試行確認 → 確証後 PR 作成 → merge → Flux resume" pattern 適用。

---

## Task 1: #37 fix (= terragrunt eks module node SG cluster tag 除去)

**Files:**
- Modify: `aws/eks/modules/main.tf`
- 必要時 Modify: `aws/eks/modules/variables.tf`
- 必要時 Modify: `aws/eks/envs/production/terragrunt.hcl`

**Test:** `terragrunt plan` で diff = node SG の cluster tag 1 個除去のみ (= no resource recreation、 in-place tag update)。 apply 後 AWS LB Controller log で panic loop 停止。

- [ ] **Step 1: 現状確認 (= node SG の cluster tag 確認)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
source /tmp/awsenv.sh  # = eks-admin-production role credentials (= expire 時は assume-role 再取得)

# AWS LB Controller log で panic loop 確認 (= 現状再現)
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=20 | grep "expected exactly one securityGroup" | head -3
```

Expected: 直近で panic message が repeat 出力。

```bash
# IAM user で switch (= EC2 describe-security-groups 必要)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# 2 SG の cluster tag 確認
for sg in sg-06a911469ce77dc76 sg-0c5888ca990469b88; do
  echo "--- $sg ---"
  aws ec2 describe-security-groups --region ap-northeast-1 --group-ids $sg --output text \
    --query 'SecurityGroups[*].[GroupName,Tags[?Key==`kubernetes.io/cluster/eks-production`].Value|[0]]'
done
```

Expected: 両 SG で cluster tag `owned` 確認。

- [ ] **Step 2: terragrunt module の actual structure 確認**

```bash
cat aws/eks/modules/main.tf | head -80
cat aws/eks/modules/variables.tf
```

確認 point:
- `module "eks"` block の `node_security_group_tags` variable 設定有無
- terraform-aws-modules/eks/aws v21.20.0 で `node_security_group_tags` variable が cluster tag を上書きできる仕様か

terraform-aws-modules/eks/aws docs (= v21.20.0): https://github.com/terraform-aws-modules/terraform-aws-eks/tree/v21.20.0
- `node_security_group_tags` = node SG に attach する additional tag、 default `{}`
- ただし module-internal で `kubernetes.io/cluster/<cluster-name>` tag が auto-attach される実装の可能性

→ Step 3 で実 module source code 確認 (= go to https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.20.0/main.tf で `kubernetes.io/cluster` grep)

- [ ] **Step 3: module の cluster tag attach 箇所 特定 + override path 決定**

terraform-aws-modules/eks/aws v21.20.0 source 確認:

```bash
# WebFetch で module source の relevant section 取得
# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.20.0/main.tf
# `kubernetes.io/cluster` grep
```

判定:
- (a) cluster tag が `node_security_group_tags` で override 可能なら panicboat 側 main.tf で `tags = {}` or 同 key で null 設定で除去
- (b) module-internal hardcoded で override 不可なら module fork 必要 (= panicboat 側で copy + 修正、 もしくは `aws_ec2_tag` resource で delete tag、 ただし terraform-driven cleanup は不確実)

panicboat の preferred path: (a)、 ただし module で対応していない場合 (b) で workaround。

- [ ] **Step 4: aws/eks/modules/main.tf で cluster tag override 設定追加**

option (a) の場合 (= module variable 経由):

```terraform
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.20"
  # ... 既存 settings ...

  # node SG から cluster tag 除去 (= AWS LB Controller "1 SG expectation" 確保、
  # cluster SG (= eks-cluster-sg-*) のみが cluster tag を保持する状態にする)
  node_security_group_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = null
  }
}
```

option (b) の場合 (= module fork OR aws_ec2_tag resource):

```terraform
# 既 module から auto-attached の cluster tag を override で removal
resource "aws_ec2_tag" "node_sg_remove_cluster_tag" {
  resource_id = module.eks.node_security_group_id
  key         = "kubernetes.io/cluster/${var.cluster_name}"

  # null value は AWS API で tag 削除に変換される (= delete tag mechanism)
  # ただし terraform behavior は version 依存、 Step 5 で plan で確認
  value = null

  lifecycle {
    create_before_destroy = true
  }
}
```

注意: actual module variable structure / behavior は Step 3 で確定、 ここでは proposed code。

- [ ] **Step 5: terragrunt plan で diff 確認**

```bash
source /tmp/awsenv.sh  # = eks-admin-production role 必要
# あるいは IAM user default profile で実行 (= eks-admin role に terraform state S3 access ない場合):
# unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

cd aws/eks/envs/production
terragrunt plan 2>&1 | tee /tmp/eks-plan.txt
```

Expected output keywords:
- `Plan: 0 to add, 1 to change, 0 to destroy` (= in-place tag update のみ)
- `~ tags = {`
- `~ "kubernetes.io/cluster/eks-production" = "owned" -> null` (or removed)

NOT expected:
- `resource recreation` (= -/+ symbol)
- 他 resource への変更

万一 resource recreation が出る場合: Step 4 の implementation を見直し、 別 approach (= aws_ec2_tag for delete) で再試行。

- [ ] **Step 6: terragrunt apply (= ローカル試行、 panicboat の試行錯誤 pattern)**

```bash
cd aws/eks/envs/production
terragrunt apply -auto-approve 2>&1 | tee /tmp/eks-apply.txt
```

Expected: `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.`

- [ ] **Step 7: AWS LB Controller panic loop 停止確認**

```bash
source /tmp/awsenv.sh
sleep 60  # = AWS LB Controller の reconcile interval 待ち
kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=2m 2>&1 | grep -c "expected exactly one securityGroup"
```

Expected: `0` (= panic loop 停止)

- [ ] **Step 8: 新規 LB provision テスト (= 既 fail していた pattern が解消されているか)**

```bash
# AWS LB Controller の TargetGroupBinding reconcile が success するか確認
kubectl get targetgroupbinding -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[?(@.type=="Synced")].status}{"\n"}{end}'
```

Expected: 全 TargetGroupBinding が `Status: True` (= Synced 成立)

- [ ] **Step 9: commit + push + PR 作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
git add aws/eks/modules/main.tf
# 必要時: git add aws/eks/modules/variables.tf aws/eks/envs/production/terragrunt.hcl

git commit -s -m "fix(aws/eks): remove kubernetes.io/cluster/X tag from node SG

Phase 6-3 で発覚した AWS LB Controller の SG 重複 panic loop 解消。
直近 terraform-aws-modules/eks/aws v21.20.0 + aws v6.44.0 update (= PR
#355-#358) で node SG に kubernetes.io/cluster/eks-production: owned tag
が追加され、 EKS cluster SG (= eks-cluster-sg-*) と 2 重に同 tag を持つ状態
になっていた。 AWS LB Controller は ENI に attach される SG のうち cluster
tag を持つ SG を 1 つ pick up する仕様で、 2 SG ある場合 reconcile fail
(= 'expected exactly one securityGroup, got: [sg-A, sg-B]' panic loop)、
新規 LoadBalancer / Ingress provision が blocking。

node_security_group_tags で cluster tag override 除去、 cluster SG のみが
cluster tag を保持する状態に。 node identification は module の他 tag
(= aws:eks:cluster-name 等) で代替、 EBS CSI / VPC CNI / Karpenter は別経路
(= IRSA / Pod Identity) で IAM、 cluster tag に依存しない。

Validation: terragrunt plan で in-place tag update のみ (= no resource
recreation)、 apply 後 AWS LB Controller log で panic loop 停止、 全
TargetGroupBinding Synced=True 確認。"

git push -u origin HEAD

gh pr create --draft --base main --head claude/eks-phase-7-0-lb-hardening \
  --title "fix(aws/eks): remove kubernetes.io/cluster/X tag from node SG (= AWS LB Controller SG 重複解消)" \
  --body "## Summary

Phase 6-3 で発覚した AWS LB Controller SG 重複 reconcile error (= 引き継ぎ #37) を解消。 multi-env active 化 (= Phase 7 #29 / #33) の LB provision blocking 解消 + Phase 7-0 LB hardening の prerequisite。

## Root cause

terraform-aws-modules/eks/aws v21.20.0 + aws v6.44.0 update (= PR #355-#358) で node SG に \`kubernetes.io/cluster/eks-production: owned\` tag が追加、 EKS cluster SG と 2 重 tag、 AWS LB Controller の '1 SG expectation' で panic loop。

## Fix

\`aws/eks/modules/main.tf\` で \`node_security_group_tags\` 経由で cluster tag override 除去。 cluster SG (= eks-cluster-sg-*) のみが cluster tag を保持。

## Validation

- terragrunt plan で in-place tag update のみ (= no resource recreation)
- apply 後 AWS LB Controller log で panic loop 停止
- 全 TargetGroupBinding Synced=True 確認

## Related

- Phase 6 closure 引き継ぎ #37 (= 解消対象)
- Phase 7-0 LB hardening spec: \`docs/superpowers/specs/2026-05-14-eks-phase-7-0-lb-hardening-design.md\`"
```

Expected: PR URL 表示

---

## Task 2: Cilium upgrade (= 1.18.6 → 1.x.y)

**Files:**
- Modify: `kubernetes/components/cilium/production/helmfile.yaml`
- 必要時 Modify: `kubernetes/components/cilium/production/values.yaml.gotmpl`
- Hydrate: `kubernetes/manifests/production/cilium/manifest.yaml`

**Test:** `cilium-cli` で upgrade status 確認 + 既 fix forward (= Beyla / Prometheus / Theme B 全般) regression なし。 Mimir reject 0 件維持、 application traffic continue。

**Dependency:** Task 1 完了 + PR 1 merge + Flux reconcile (= AWS LB Controller panic loop 停止状態が前提)。

- [ ] **Step 1: Cilium 公式 release notes 確認 + upgrade target version 確定**

WebFetch で 公式 docs から hostNetwork mode に関する CHANGELOG / known issues fix を確認:

```
https://docs.cilium.io/en/v1.19/operations/upgrade/
https://docs.cilium.io/en/v1.20/operations/upgrade/
https://github.com/cilium/cilium/releases (= release notes 全)
```

確認 point:
- "Gateway API host network mode" の改善が含まれた earliest version
- CiliumEnvoyConfig CR の listener port migration logic 改善

判定:
- (a) 1.19.x で hostNetwork mode 完全動作 → target = 最新 1.19.x patch
- (b) 1.20.x で必要 → target = 最新 1.20.x patch
- (c) どちらも未対応 → target = 最新 stable (= 1.21+ 等)、 ただし Component C fail 確実視

panicboat の "minimal change" 原則: 1.19.x → 1.20.x の順で試行、 1.19.x で hostNetwork OK なら 1.19.x で fix。 plan では暫定 **1.20.x** (= 最新 stable で safer)、 Step 2 で actual version 確定。

- [ ] **Step 2: actual upgrade target version 確定 (= 例 1.20.5 等の specific patch)**

```bash
# helm repo update + 最新 patch version 確認
helm repo add cilium https://helm.cilium.io/
helm repo update
helm search repo cilium/cilium --versions 2>&1 | head -10
```

Expected: 1.20.x の specific patch version (= 例 1.20.5)

→ TARGET_VERSION 変数として 以降 Step で参照 (= 例: `TARGET_VERSION=1.20.5`)

- [ ] **Step 3: cluster state pre-flight snapshot**

```bash
source /tmp/awsenv.sh
mkdir -p /tmp/cilium-upgrade-snapshot
kubectl get pod -A -o yaml > /tmp/cilium-upgrade-snapshot/pods-pre.yaml
kubectl get svc -A -o yaml > /tmp/cilium-upgrade-snapshot/services-pre.yaml
kubectl get gateway,httproute,gatewayclass -A -o yaml > /tmp/cilium-upgrade-snapshot/gateway-api-pre.yaml
kubectl get ciliumenvoyconfig -A -o yaml > /tmp/cilium-upgrade-snapshot/cec-pre.yaml
kubectl get cm -n kube-system cilium-config -o yaml > /tmp/cilium-upgrade-snapshot/cilium-config-pre.yaml

# Theme B fix forward state confirm (= Mimir reject 0 件、 Beyla labels 等)
kubectl logs -n monitoring deploy/mimir-distributed-distributor --since=1m 2>&1 | grep -c "level=error"
```

Expected: error count 0 (= Theme B fix forward 動作中)

- [ ] **Step 4: helmfile.yaml で chart version bump**

`kubernetes/components/cilium/production/helmfile.yaml` を edit:

```yaml
# Before:
releases:
  - name: cilium
    namespace: kube-system
    chart: cilium/cilium
    version: "1.18.6"

# After (= actual target version):
releases:
  - name: cilium
    namespace: kube-system
    chart: cilium/cilium
    version: "1.20.5"  # = TARGET_VERSION 確定値
```

- [ ] **Step 5: values.yaml.gotmpl で deprecated values 確認 + migration**

公式 upgrade guide (= 1.18 → 1.20 の path) で deprecated values を確認:

```bash
# 公式 upgrade guide WebFetch:
# https://docs.cilium.io/en/v1.20/operations/upgrade/#step-by-step-upgrade-procedure
# https://docs.cilium.io/en/v1.20/operations/upgrade/#deprecated-options
```

確認すべき panicboat current values の関連 fields:
- `gatewayAPI.enabled: true`
- `gatewayAPI.hostNetwork.enabled` (= 1.20 で structure 変更可能性)
- `socketLB.enabled: true`
- `envoy.enabled: true` (= L7 Proxy 独立 DaemonSet)
- `hubble.tls.auto.method: certmanager`

migration 必要なら `kubernetes/components/cilium/production/values.yaml.gotmpl` を edit (= 1.20 syntax に変更)。

- [ ] **Step 6: hydrate + diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
bash scripts/kubernetes-hydrate/hydrate-component.sh cilium production 2>&1 | tail -5
git diff --stat kubernetes/manifests/production/cilium/
git diff kubernetes/manifests/production/cilium/manifest.yaml | head -40
```

Expected: chart version 反映 + CRD update + 関連 manifest 変更 (= 内容は version 依存)

- [ ] **Step 7: Flux suspend + ローカル apply 試行**

```bash
source /tmp/awsenv.sh
flux suspend kustomization flux-system -n flux-system
kubectl apply -k kubernetes/manifests/production/cilium/ --server-side --force-conflicts 2>&1 | tail -10
```

Expected: 全 resource serverside-applied (= CRD / Cilium / cilium-envoy / cilium-operator / Hubble 等)

- [ ] **Step 8: cilium DaemonSet rollout + status 確認**

```bash
kubectl rollout status -n kube-system ds/cilium --timeout=300s
kubectl rollout status -n kube-system ds/cilium-envoy --timeout=300s
kubectl rollout status -n kube-system deploy/cilium-operator --timeout=180s
```

Expected: 全 rollout success

```bash
# cilium-cli で post-upgrade status 確認
cilium status --wait 2>&1 | head -20
```

Expected: `Cilium: 1.20.5` (= TARGET_VERSION 反映)、 全 component OK

- [ ] **Step 9: 既 fix forward regression 確認 (= Theme B 全般)**

```bash
# Mimir reject 直近 2min
sleep 60
kubectl logs -n monitoring deploy/mimir-distributed-distributor --since=2m 2>&1 | grep -E "max-label-names|label-invalid" | wc -l
```

Expected: `0` (= reject 持続的 0、 Theme B 維持)

```bash
# Beyla labels 確認 (= attributes.select exclude 動作中?)
beyla_pod_ip=$(kubectl get po -n monitoring -l app.kubernetes.io/name=beyla -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- "http://${beyla_pod_ip}:9090/metrics" 2>&1 | grep "^http_server_request_duration_seconds_bucket{" | head -1 | grep -oE '[a-z_]+=' | wc -l
```

Expected: ~20 labels (= Phase 6-3 Theme B 設定済)

```bash
# Prometheus name validation 確認
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- http://localhost:9090/api/v1/status/config 2>&1 | jq -r .data.yaml | grep "name_validation_scheme" | head -1
```

Expected: `metric_name_validation_scheme: legacy`

- [ ] **Step 10: application traffic continue 確認 (= regression なし)**

```bash
curl -sI --max-time 10 --resolve develop.panicboat.net:443:$(dig +short k8s-default-reversep-4c0b605be5-41367d3702a18720.elb.ap-northeast-1.amazonaws.com @1.1.1.1 | head -1) https://develop.panicboat.net/ 2>&1 | head -3
```

Expected: `HTTP/1.1 200 OK`

万一 regression / fail 発見: helmfile revert + Step 6-8 で 1.18.6 に downgrade、 cluster state recovery 確認後 issue 別 PR で fix forward。

- [ ] **Step 11: Flux resume + commit + push + PR 作成**

```bash
source /tmp/awsenv.sh
flux resume kustomization flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system

cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
git add kubernetes/components/cilium/production/helmfile.yaml \
        kubernetes/components/cilium/production/values.yaml.gotmpl \
        kubernetes/manifests/production/cilium/

git commit -s -m "chore(eks/cilium): upgrade Cilium 1.18.6 → 1.20.5

Phase 7-0 Component B。 Cilium upgrade で hostNetwork mode の CEC CR migration
logic 改善 (= Phase 6-3 (γ-a) failed の root cause、 chart 1.18.6 で listener
port migration 不完全) + chaining mode / socketLB / Hubble / dnsProxy / L7
Proxy 独立 DaemonSet stable 維持。

deprecated values migration: (= 必要時 specify)
- (なし、 1.18 → 1.20 で panicboat values 互換性確認済)

Validation:
- cilium-cli status で 1.20.5 確認 + 全 component OK
- 既 Theme B fix forward regression なし (= Mimir reject 0 件、 Beyla
  attributes.select 動作、 Prometheus name_validation_scheme: legacy)
- application traffic (= develop.panicboat.net) HTTP 200 継続"

git push origin HEAD

gh pr create --draft --base main --head claude/eks-phase-7-0-lb-hardening \
  --title "chore(eks/cilium): upgrade Cilium 1.18.6 → 1.20.5 (= hostNetwork mode 改善)" \
  --body "## Summary

Phase 7-0 Component B = Cilium upgrade 1.18.6 → 1.20.5。 hostNetwork mode の CEC CR migration logic 改善 + Phase 6-3 (γ-a) failed の root cause 解消、 Component C (= #39) migration の前提。

## Validation

- cilium-cli \`cilium status\` で 1.20.5 確認 + 全 component OK
- Theme B fix forward 全 regression なし (= Mimir reject 0 件 + Beyla attributes.select + Prometheus name_validation_scheme: legacy)
- application traffic 継続 (= develop.panicboat.net 200 OK)

## Pre-flight snapshot

\`/tmp/cilium-upgrade-snapshot/\` に cluster state full backup (= pods / services / gateway-api / CEC / cilium-config)

## Related

- Phase 7-0 spec Component B
- Phase 6-3 Theme B fix forward への regression test 含む"
```

---

## Task 3: #39 platform side (= cilium hostNetwork + Gateway port 8080 + ALB Ingress)

**Files:**
- Modify: `kubernetes/components/cilium/production/values.yaml.gotmpl` (= `gatewayAPI.hostNetwork.enabled: true`)
- Modify: `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml` (= listener port 80 → 8080)
- Create: `kubernetes/components/cilium/production/kustomization/application-ingress.yaml`
- Modify: `kubernetes/components/cilium/production/kustomization/kustomization.yaml` (= application-ingress.yaml 追加)
- Hydrate: `kubernetes/manifests/production/cilium/manifest.yaml`

**Test:** Cilium DaemonSet rollout + cilium-gateway-cilium-gateway Service が ClusterIP に変化 (= LoadBalancer auto-create disable) + 旧 NLB auto-delete + ALB provision active + cilium-envoy が host port 8080 で listen。

**Dependency:** Task 2 完了 + PR 2 merge + Cilium 1.20.5 動作確認。

- [ ] **Step 1: values.yaml.gotmpl で hostNetwork.enabled: true 追加**

`kubernetes/components/cilium/production/values.yaml.gotmpl` の `gatewayAPI:` block を edit:

```yaml
# Before:
gatewayAPI:
  enabled: true

# After:
# =============================================================================
# Gateway API（北南: ALB Controller 経由で hostNetwork mode の Cilium Gateway を expose、
# 東西: 同 Cilium Gateway で internal routing。 北南統一で reverse-proxy 不要、
# Cilium Gateway + CiliumEnvoyConfig で JWT validation 余地確保）
# =============================================================================
# hostNetwork.enabled: true は LoadBalancer Service auto-create を disable
# (= 公式 mutual exclusive)、 cilium-gateway-cilium-gateway Service が ClusterIP に。
# eks-pod-identity-agent が hostNetwork で port 80 占有のため Gateway listener は
# port 8080 (= cilium-gateway.yaml)、 1024 未満特権 port 回避で NET_BIND_SERVICE
# capability 不要。
# https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/host-network-mode/
gatewayAPI:
  enabled: true
  hostNetwork:
    enabled: true
```

- [ ] **Step 2: cilium-gateway.yaml で listener port 80 → 8080**

`kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml` を edit:

```yaml
# Before:
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      port: 80
      protocol: HTTP

# After:
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      port: 8080  # = hostNetwork mode、 eks-pod-identity-agent の port 80 と collision 回避
      protocol: HTTP
```

- [ ] **Step 3: application-ingress.yaml 新規作成**

Create `kubernetes/components/cilium/production/kustomization/application-ingress.yaml`:

```yaml
# =============================================================================
# Ingress: application IngressGroup (= cilium-gateway hostNetwork backend)
# =============================================================================
# Cilium Gateway hostNetwork mode (= values.yaml.gotmpl gatewayAPI.hostNetwork.enabled)
# で 全 node の host port 8080 に cilium-envoy が listen、 ALB がそれを backend
# として target-type=ip で Pod IP (= node IP) に register。
#
# ACM cert auto-discovery: ALB Controller が wildcard cert *.panicboat.net を
# 自動 attach (= Ingress.host が SAN match)。explicit certificate-arn annotation
# 不要。
#
# external-dns annotation: hostname を Route53 record として auto-create
# (= aws-load-balancer-controller / external-dns 連携)。
# =============================================================================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: application
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: application
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: develop.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: develop.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cilium-gateway-cilium-gateway
                port:
                  number: 8080
```

- [ ] **Step 4: kustomization.yaml に application-ingress.yaml 追加**

`kubernetes/components/cilium/production/kustomization/kustomization.yaml` を edit:

```yaml
# Before:
resources:
  - gateway-class.yaml
  - cilium-gateway.yaml

# After:
resources:
  - gateway-class.yaml
  - cilium-gateway.yaml
  - application-ingress.yaml
```

- [ ] **Step 5: hydrate + diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
bash scripts/kubernetes-hydrate/hydrate-component.sh cilium production 2>&1 | tail -3
git diff kubernetes/manifests/production/cilium/manifest.yaml 2>&1 | grep -B1 -A3 -E "hostNetwork|port:|application" | head -30
```

Expected:
- `gateway-api-hostnetwork-enabled: "true"` 反映
- Gateway CR の listener port 8080
- 新 Ingress application 追加

- [ ] **Step 6: Flux suspend + ローカル apply**

```bash
source /tmp/awsenv.sh
flux suspend kustomization flux-system -n flux-system
kubectl apply -k kubernetes/manifests/production/cilium/ --server-side --force-conflicts 2>&1 | tail -10
```

- [ ] **Step 7: Cilium operator restart + cilium-gateway Service ClusterIP 化観測**

```bash
kubectl rollout restart -n kube-system deploy/cilium-operator ds/cilium ds/cilium-envoy
kubectl rollout status -n kube-system deploy/cilium-operator --timeout=180s
kubectl rollout status -n kube-system ds/cilium-envoy --timeout=300s
kubectl rollout status -n kube-system ds/cilium --timeout=300s

sleep 60

# cilium-gateway-cilium-gateway Service の type 確認 (= LoadBalancer → ClusterIP に変化期待)
kubectl get svc -n default cilium-gateway-cilium-gateway
```

Expected: `TYPE: ClusterIP` (= hostNetwork mode で LoadBalancer auto-create disable、 Cilium 1.20 で正常動作期待)

万一 LoadBalancer 維持 + EXTERNAL-IP <pending> なら #39 fail trigger → Step 14 fallback path:

```bash
# 失敗 detect、 fallback path に進む (= Task 5 へ skip)
echo "Component C fail detected, switching to fallback (Task 5)"
```

- [ ] **Step 8: cilium-envoy host port 8080 listen 確認**

```bash
NODE=$(kubectl get po -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].spec.nodeName}')
kubectl debug node/$NODE -it --image=nicolaka/netshoot --profile=netadmin -- ss -tlnp 2>&1 | grep -E ":8080" | head -5
```

Expected: `LISTEN 0 ... 0.0.0.0:8080 ... users:(("cilium-envoy",...))`

- [ ] **Step 9: 旧 cilium-gateway NLB auto-delete 観測**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
sleep 60
aws elbv2 describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancers[?contains(LoadBalancerName, `ciliumga`)].[LoadBalancerName,State.Code]'
```

Expected: empty (= 旧 NLB auto-delete 完了)

- [ ] **Step 10: ALB application 新規 provision 観測**

```bash
sleep 120  # = ALB provision 通常 ~5-10 min
source /tmp/awsenv.sh
kubectl get ingress -n default application 2>&1

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws elbv2 describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancers[?contains(LoadBalancerName, `application`) || contains(LoadBalancerName, `applicat`)].[LoadBalancerName,Type,State.Code,DNSName]'
```

Expected:
- Ingress `application` で ADDRESS field に ALB hostname 表示
- ALB type=application、 State=active

- [ ] **Step 11: ALB target group health 確認**

```bash
LB_ARN=$(aws elbv2 describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancers[?contains(LoadBalancerName, `application`)].LoadBalancerArn' | head -1)
TG_ARNS=$(aws elbv2 describe-target-groups --load-balancer-arn "$LB_ARN" --region ap-northeast-1 --output text --query 'TargetGroups[*].TargetGroupArn')
for tg in $TG_ARNS; do
  echo "--- $(echo $tg | awk -F/ '{print $(NF-1)}') ---"
  aws elbv2 describe-target-health --target-group-arn "$tg" --region ap-northeast-1 --output text \
    --query 'TargetHealthDescriptions[*].[Target.Id,Target.Port,TargetHealth.State]'
done
```

Expected: 全 target が `healthy` (= cilium-envoy hostNetwork :8080 が responding)

- [ ] **Step 12: ExternalDNS が新 ALB hostname を Route53 に register 観測**

```bash
source /tmp/awsenv.sh
kubectl logs -n external-dns deploy/external-dns --tail=30 2>&1 | grep -i "develop.panicboat" | tail -10

# DNS resolve 確認 (= cloudflare resolver 経由)
sleep 60
dig +short develop.panicboat.net @1.1.1.1 | head -3
```

Expected:
- ExternalDNS log で `CREATE develop.panicboat.net A` 等の record action
- DNS resolve で ALB IPs 取得 (= 旧 reverse-proxy NLB IPs から switch)

- [ ] **Step 13: curl https で 200 OK 確認 (= 旧経路依然 active、 新経路は monorepo PR merge 後)**

```bash
# 旧経路 (= reverse-proxy NLB) で 動作確認 (= Component C platform side では旧経路 依然 active)
curl -sI --max-time 10 --resolve develop.panicboat.net:443:54.95.222.148 https://develop.panicboat.net/ 2>&1 | head -3
```

Expected: `HTTP/1.1 200 OK` (= 旧経路 reverse-proxy NLB 経由 functional、 ALB 経路は monorepo PR merge 後 verify)

注意: ExternalDNS が新 ALB hostname に Route53 record 切替で **default DNS resolve は ALB 経由になる**、 ただし旧 reverse-proxy NLB target 経由 traffic は monorepo PR (= Task 4) merge まで functional 維持。

- [ ] **Step 14: success or fallback judgment**

判定:
- Step 7 で Service が ClusterIP + Step 8 で port 8080 listen + Step 11 で target healthy → **success** → Step 15 (commit + push + PR) へ
- いずれか fail → **fallback** → Task 5 (#40 bridge) へ skip + Task 4 monorepo 着手なし

- [ ] **Step 15: Flux resume + commit + push + PR 作成**

```bash
source /tmp/awsenv.sh
flux resume kustomization flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system

cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
git add kubernetes/components/cilium/production/values.yaml.gotmpl \
        kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml \
        kubernetes/components/cilium/production/kustomization/application-ingress.yaml \
        kubernetes/components/cilium/production/kustomization/kustomization.yaml \
        kubernetes/manifests/production/cilium/

git commit -s -m "feat(eks): Cilium Gateway hostNetwork mode + application ALB IngressGroup

Phase 7-0 Component C platform side。 panicboat architecture spec ('north-south
は ALB Controller、 east-west は cilium-gateway') への re-align、 internet
公開経路を ALB IngressGroup 経由 cilium-gateway hostNetwork に統一。

Changes:
- gatewayAPI.hostNetwork.enabled: true で LoadBalancer Service auto-create
  disable (= cilium-gateway-cilium-gateway が ClusterIP 化)
- Gateway listener port 80 → 8080 (= eks-pod-identity-agent の port 80 と
  collision 回避、 1024 未満特権 port 回避で NET_BIND_SERVICE capability 不要)
- 新 ALB Ingress application (= IngressGroup application、 ACM cert
  auto-discovery、 TLS 1.3、 HTTP → HTTPS redirect、 ExternalDNS で
  develop.panicboat.net Route53 record auto-create、 backend は
  cilium-gateway-cilium-gateway Service:8080)

Validation:
- cilium-gateway-cilium-gateway Service type=ClusterIP 確認
- cilium-envoy host port 8080 listen 確認 (= ss output)
- 旧 cilium-gateway NLB auto-delete 確認 (= ELB list で消失)
- 新 ALB provision active + target healthy 確認
- ExternalDNS で Route53 record auto-create 確認 + DNS resolve 切替
- 旧 reverse-proxy 経路継続 functional (= curl HTTPS 200、 monorepo PR
  merge 前は旧経路維持)

Architecture impact:
- monthly cost ~\$48 削減 (= cilium-gateway NLB 削除)
- ingress L7 visibility 復活 (= Hubble flow observe で cilium-gateway 経由
  HTTP method / path / status 観測可能化)
- Gateway 層 JWT validation 採用余地確保 (= Phase 8+ で
  CiliumEnvoyConfig 経由)"

git push origin HEAD

gh pr create --draft --base main --head claude/eks-phase-7-0-lb-hardening \
  --title "feat(eks): Cilium Gateway hostNetwork mode + application ALB IngressGroup (= #39 platform 側)" \
  --body "## Summary

Phase 7-0 Component C platform side = Cilium Gateway hostNetwork mode + 新 ALB IngressGroup 'application'。 panicboat architecture spec への re-align、 cilium-gateway NLB 削除 + ALB IngressGroup 経由 internet 公開。

## Changes

- \`kubernetes/components/cilium/production/values.yaml.gotmpl\`: \`gatewayAPI.hostNetwork.enabled: true\`
- \`kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml\`: listener port 80 → 8080
- 新 \`kubernetes/components/cilium/production/kustomization/application-ingress.yaml\`: ALB Ingress、 IngressGroup application、 backend cilium-gateway:8080
- \`kubernetes/components/cilium/production/kustomization/kustomization.yaml\`: application-ingress.yaml 追加

## Validation

- cilium-gateway-cilium-gateway Service ClusterIP 化
- cilium-envoy host port 8080 listen
- 旧 cilium-gateway NLB auto-delete
- 新 ALB provision active + target healthy
- ExternalDNS で develop.panicboat.net Route53 record auto-create
- application traffic 継続 (= curl HTTPS 200、 旧 reverse-proxy 経路は monorepo PR merge 後に廃止)

## Post-merge

monorepo PR (= reverse-proxy 廃止 + frontend HTTPRoute) と並行 merge で旧経路廃止 + 新経路 (= ALB → Cilium Gateway → frontend) 確立。

## Related

- Phase 7-0 spec Component C
- 引き継ぎ #39 / #40 解消"
```

---

## Task 4: #39 monorepo side (= reverse-proxy 削除 + frontend HTTPRoute)

**Files:**
- Delete: `services/reverse-proxy/` (= 全 directory recursive)
- Create: `services/frontend/kubernetes/base/httproute.yaml`
- Modify: `services/frontend/kubernetes/base/kustomization.yaml` (= httproute.yaml 追加)

**Test:** Flux reconcile で reverse-proxy Pod / Service / NLB auto-delete + frontend HTTPRoute provision + Cilium Gateway → frontend routing 確立 + curl https で 200 OK。

**Dependency:** Task 3 完了 + PR 3 merge + cluster で ALB IngressGroup + Cilium Gateway hostNetwork 動作確認済。

- [ ] **Step 1: monorepo worktree setup (= 別 repo)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git fetch origin main
git checkout main
git pull origin main
git checkout -b claude/eks-phase-7-0-reverse-proxy-removal
```

- [ ] **Step 2: reverse-proxy directory 削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
rm -rf services/reverse-proxy/
```

- [ ] **Step 3: frontend HTTPRoute 新規作成**

Create `services/frontend/kubernetes/base/httproute.yaml`:

```yaml
# =============================================================================
# Frontend HTTPRoute (= Cilium Gateway 経由 develop.panicboat.net routing)
# =============================================================================
# Cilium Gateway (= namespace default、 listener http:8080) を parentRef、
# host develop.panicboat.net への traffic を frontend Service:80 に backend
# する。 ingress 経路: client → ALB (= application IngressGroup、 platform 側
# kubernetes/components/cilium/) → cilium-gateway hostNetwork :8080 → 本
# HTTPRoute → frontend。
# =============================================================================
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: frontend
  namespace: default
spec:
  parentRefs:
    - name: cilium-gateway
      namespace: default
  hostnames:
    - develop.panicboat.net
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
```

- [ ] **Step 4: frontend kustomization.yaml に httproute.yaml 追加**

`services/frontend/kubernetes/base/kustomization.yaml` を edit:

```yaml
# Before (例):
resources:
  - service.yaml
  - deployment.yaml
  # ... 他 frontend resources ...

# After (= httproute.yaml 追加):
resources:
  - service.yaml
  - deployment.yaml
  - httproute.yaml  # 追加
  # ... 他 frontend resources ...
```

- [ ] **Step 5: local kustomize build で確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
kustomize build services/frontend/kubernetes/overlays/develop 2>&1 | grep -B2 -A20 "kind: HTTPRoute" | head -30
```

Expected: HTTPRoute frontend が render される (= hostname develop.panicboat.net、 backend frontend:80)

```bash
# reverse-proxy 関連 reference が monorepo に残存していないか確認
grep -rn "reverse-proxy" services/ 2>&1 | grep -v "\.kustomization-cache" | head -10
```

Expected: 0 hits (= 全 reference 削除済)

- [ ] **Step 6: commit + push + PR 作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git add -A services/reverse-proxy/ services/frontend/kubernetes/base/

git commit -s -m "feat: reverse-proxy 廃止 + frontend HTTPRoute (= Cilium Gateway 経由 direct routing)

Phase 7-0 Component C monorepo side。 platform 側 PR (= Cilium Gateway
hostNetwork mode + ALB IngressGroup) と並行で reverse-proxy nginx を廃止、
frontend を Cilium Gateway HTTPRoute backend に直接 register。

Architecture (= after this PR + platform PR):
  client (internet)
    → ALB (= application IngressGroup、 ACM TLS termination 443)
    → cilium-gateway hostNetwork :8080
    → Cilium Gateway (= Envoy)
    → HTTPRoute frontend (= 本 PR)
    → frontend Service:80

Changes:
- services/reverse-proxy/ 全 directory 削除 (= service / deployment /
  configmap / httproute / kustomization)
- services/frontend/kubernetes/base/httproute.yaml 新規作成 (= parentRef
  cilium-gateway、 hostname develop.panicboat.net、 backend frontend:80)

Architecture impact:
- monthly cost ~\$31 削減 (= reverse-proxy NLB 削除)
- nginx custom config maintenance 不要
- ingress L7 visibility 復活 (= Hubble flow observe で Gateway 経由
  HTTP traffic 観測可能化)

Validation (= post-merge):
- reverse-proxy Pod / Service auto-delete (= Flux prune)
- 旧 reverse-proxy NLB auto-delete
- ExternalDNS で 旧 NLB hostname の Route53 record cleanup
- curl https://develop.panicboat.net/ HTTP 200 (= ALB 経由 routing)"

git push -u origin HEAD

gh pr create --draft --base main --head claude/eks-phase-7-0-reverse-proxy-removal \
  --title "feat: reverse-proxy 廃止 + frontend HTTPRoute (= Phase 7-0 #39 monorepo 側)" \
  --body "## Summary

Phase 7-0 Component C monorepo side = reverse-proxy nginx 廃止 + frontend HTTPRoute 新規追加 (= Cilium Gateway 経由 direct routing)。

## Changes

- \`services/reverse-proxy/\` 全 directory 削除
- \`services/frontend/kubernetes/base/httproute.yaml\` 新規 (= parentRef cilium-gateway、 hostname develop.panicboat.net、 backend frontend:80)
- \`services/frontend/kubernetes/base/kustomization.yaml\`: httproute.yaml 追加

## Architecture (= after merge)

\`\`\`
client (= internet)
  → ALB (= application IngressGroup、 ACM TLS termination 443、 platform PR で deploy)
  → cilium-gateway hostNetwork :8080
  → Cilium Gateway (= Envoy)
  → HTTPRoute frontend (= 本 PR)
  → frontend Service:80
\`\`\`

## Cost / impact

- monthly cost ~\$31 削減 (= reverse-proxy NLB 削除)
- nginx custom config maintenance 不要
- ingress L7 hubble visibility 復活

## Post-merge validation

- reverse-proxy resources auto-delete (= Flux prune)
- 旧 reverse-proxy NLB auto-delete
- ExternalDNS で旧 NLB hostname Route53 record cleanup
- curl https://develop.panicboat.net/ 200 OK (= ALB 経由 routing)

## Related

- Phase 7-0 spec Component C
- companion PR: panicboat/platform Phase 7-0 platform 側 (= ALB IngressGroup + Cilium Gateway hostNetwork)"
```

- [ ] **Step 7: post-merge cluster validate (= user merge 後)**

```bash
source /tmp/awsenv.sh
# Flux reconcile (= 必要時 trigger)
flux reconcile source git monorepo -n flux-system
flux reconcile kustomization frontend -n flux-system

sleep 60

# reverse-proxy 削除確認
kubectl get all -n default -l app=reverse-proxy
# Expected: No resources found

# frontend HTTPRoute provision 確認
kubectl get httproute -n default frontend -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True

# DNS 切替確認
dig +short develop.panicboat.net @1.1.1.1 | head -3
# Expected: ALB IPs (= 旧 reverse-proxy NLB IPs から switch)

# HTTPS access 確認
curl -sI --max-time 15 https://develop.panicboat.net/ 2>&1 | head -3
# Expected: HTTP/1.1 200 OK (= ALB → Cilium Gateway → frontend で routing 成功)
```

- [ ] **Step 8: 旧 reverse-proxy NLB auto-delete 確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
sleep 120  # = AWS LB Controller の finalizer cleanup 待ち
aws elbv2 describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancers[?contains(LoadBalancerName, `reversep`) || contains(LoadBalancerName, `reverse`)].[LoadBalancerName,State.Code]'
```

Expected: empty (= 旧 reverse-proxy NLB auto-delete 完了)

```bash
# cost ~$79 削減 verify (= cilium-gateway NLB + reverse-proxy NLB 両方削除)
aws elbv2 describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancers[*].[LoadBalancerName,Type,Scheme]'
```

Expected output: monitoring-uis ALB + application ALB のみ (= 2 LB)、 NLB は 0 件 (= classic ELB / cilium-gateway NLB / reverse-proxy NLB すべて削除済)

---

## Task 5 (= fallback、 #39 fail 時のみ): cilium revert + #40 bridge revival

**Trigger:** Task 3 Step 7 / 8 / 10 / 11 のいずれかで fail (= Service が LoadBalancer 維持 / cilium-envoy port 8080 未 listen / 旧 NLB delete 失敗 / ALB target unhealthy)。

**Files:**
- Revert: `kubernetes/components/cilium/production/values.yaml.gotmpl` (= hostNetwork.enabled false)
- Revert: `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml` (= port 80)
- Delete: `kubernetes/components/cilium/production/kustomization/application-ingress.yaml`
- Modify: `kubernetes/components/cilium/production/kustomization/kustomization.yaml` (= application-ingress.yaml 削除)
- Modify: `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` (= `loadBalancerClass: service.k8s.aws/nlb` default 設定)
- Hydrate: `kubernetes/manifests/production/cilium/` + `kubernetes/manifests/production/aws-load-balancer-controller/`

**Test:** cluster recover (= cilium-gateway-cilium-gateway Service が type=LoadBalancer に復活 + NLB provision + 旧 reverse-proxy 経路 functional) + classic ELB recreate cycle 防止 (= #40 effect)。

- [ ] **Step 1: cilium revert (= Component C platform side 取り消し)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
git checkout kubernetes/components/cilium/production/values.yaml.gotmpl
git checkout kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml
rm kubernetes/components/cilium/production/kustomization/application-ingress.yaml
git checkout kubernetes/components/cilium/production/kustomization/kustomization.yaml
```

- [ ] **Step 2: AWS LB Controller values で `loadBalancerClass` default 設定**

`kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` を edit:

```yaml
# 追加 (= 既 values に append):
# =============================================================================
# Default loadBalancerClass for type=LoadBalancer Services without annotation
# =============================================================================
# loadBalancerClass annotation 不在の Service (= Cilium operator auto-create
# 等) を in-tree Cloud Provider が pick up + classic ELB recreate する drift
# を防止。 全 type=LoadBalancer Service が AWS LB Controller 経由 NLB 化、
# Cloud Provider 経路を closed。
# https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.8/deploy/configurations/#loadbalancerclass
loadBalancerClass: service.k8s.aws/nlb
```

- [ ] **Step 3: hydrate**

```bash
bash scripts/kubernetes-hydrate/hydrate-component.sh cilium production 2>&1 | tail -3
bash scripts/kubernetes-hydrate/hydrate-component.sh aws-load-balancer-controller production 2>&1 | tail -3
```

- [ ] **Step 4: Flux suspend + ローカル apply (= cilium revert + AWS LB Controller config update)**

```bash
source /tmp/awsenv.sh
flux suspend kustomization flux-system -n flux-system

# cilium revert apply
kubectl apply -k kubernetes/manifests/production/cilium/ --server-side --force-conflicts 2>&1 | tail -10

# AWS LB Controller values 反映 (= helm chart 経由)
kubectl apply -k kubernetes/manifests/production/aws-load-balancer-controller/ --server-side --force-conflicts 2>&1 | tail -10

# cilium / cilium-envoy / cilium-operator restart (= hostNetwork OFF + LoadBalancer mode 復活 trigger)
kubectl rollout restart -n kube-system deploy/cilium-operator ds/cilium ds/cilium-envoy
kubectl rollout status -n kube-system ds/cilium-envoy --timeout=180s
kubectl rollout status -n kube-system ds/cilium --timeout=180s
kubectl rollout status -n kube-system deploy/cilium-operator --timeout=120s

# AWS LB Controller restart (= default loadBalancerClass 設定反映)
kubectl rollout restart -n kube-system deploy/aws-load-balancer-controller
kubectl rollout status -n kube-system deploy/aws-load-balancer-controller --timeout=180s
```

- [ ] **Step 5: 既 orphan classic ELB delete**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# classic ELB list 確認
aws elb describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancerDescriptions[*].[LoadBalancerName,CreatedTime]'

# 該当 classic ELB delete (= cluster prefix 含むもの)
CLASSIC_ELB=$(aws elb describe-load-balancers --region ap-northeast-1 --output text --query 'LoadBalancerDescriptions[*].LoadBalancerName' | head -1)
if [ -n "$CLASSIC_ELB" ]; then
  aws elb delete-load-balancer --region ap-northeast-1 --load-balancer-name "$CLASSIC_ELB"
  sleep 60
  echo "verify after delete:"
  aws elb describe-load-balancers --region ap-northeast-1 --output text --query 'LoadBalancerDescriptions[*].[LoadBalancerName]'
fi
```

Expected (= verify after delete): empty (= classic ELB 削除完了 + default loadBalancerClass で 再 provision 防止)

- [ ] **Step 6: cilium-gateway-cilium-gateway Service が type=LoadBalancer に復活 + 新 NLB provision 観測**

```bash
source /tmp/awsenv.sh
sleep 120  # = AWS LB Controller の NLB provision 通常 ~5-10 min
kubectl get svc -n default cilium-gateway-cilium-gateway
```

Expected: `TYPE: LoadBalancer`、 `EXTERNAL-IP: <NLB hostname>`、 `PORT(S): 80:XXXX/TCP`

- [ ] **Step 7: 旧 reverse-proxy 経路 functional 維持確認**

```bash
curl -sI --max-time 10 --resolve develop.panicboat.net:443:$(dig +short k8s-default-reversep-4c0b605be5-41367d3702a18720.elb.ap-northeast-1.amazonaws.com @1.1.1.1 | head -1) https://develop.panicboat.net/ 2>&1 | head -3
```

Expected: `HTTP/1.1 200 OK` (= 旧 reverse-proxy NLB 経由 internet 公開維持)

- [ ] **Step 8: Flux resume + commit + push + PR 作成 (= fallback PR)**

```bash
source /tmp/awsenv.sh
flux resume kustomization flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system

cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-phase-7-0-lb-hardening
git add kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl \
        kubernetes/manifests/production/aws-load-balancer-controller/
# 注: cilium revert は git restore で working tree が clean (= commit 対象外)

git commit -s -m "fix(eks/aws-load-balancer-controller): default loadBalancerClass to service.k8s.aws/nlb (= classic ELB recreate 防止、 #40 bridge)

Phase 7-0 Component C (= #39 Cilium Gateway hostNetwork mode + ALB IngressGroup
migration) で Cilium 1.20 でも hostNetwork mode の CEC CR migration logic /
LoadBalancer Service disable 動作が完遂しなかった、 cilium revert で 1.18.6
LoadBalancer mode 復活。 #39 を Phase 8+ 引き継ぎ persist + partial completion
として #40 bridge (= AWS LB Controller default loadBalancerClass 設定) を採用。

Changes:
- aws-load-balancer-controller values.yaml.gotmpl: loadBalancerClass:
  service.k8s.aws/nlb default 設定追加
- 効果: loadBalancerClass annotation 不在の Service (= Cilium operator
  auto-create cilium-gateway-cilium-gateway 等) が AWS LB Controller 経由
  NLB 化、 in-tree Cloud Provider が skip、 classic ELB recreate cycle 防止

Architecture impact:
- monthly cost ~\$10-20 削減 (= classic ELB のみ防止、 cilium-gateway NLB +
  reverse-proxy NLB ~\$79 削減は Phase 8+ 再試行で持ち越し)
- panicboat architecture spec ('north-south は ALB Controller、 east-west は
  cilium-gateway') の partial 達成、 classic ELB drift のみ解消

Validation:
- 既 orphan classic ELB delete + 再 provision 防止確認
- cilium-gateway-cilium-gateway Service LoadBalancer mode 復活確認
- 旧 reverse-proxy 経路 functional 維持 (= curl HTTPS 200)"

git push origin HEAD

gh pr create --draft --base main --head claude/eks-phase-7-0-lb-hardening \
  --title "fix(eks): AWS LB Controller default loadBalancerClass (= Phase 7-0 #40 bridge fallback)" \
  --body "## Summary

Phase 7-0 Component C (= #39 migration) が Cilium 1.20 upgrade 後も hostNetwork mode で fail、 cilium revert + partial completion path として #40 bridge (= AWS LB Controller default loadBalancerClass 設定) を採用。

## Changes

\`kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl\` に \`loadBalancerClass: service.k8s.aws/nlb\` default 追加。

## Effect

- loadBalancerClass annotation 不在 Service (= cilium-gateway 等) が AWS LB Controller 経由 NLB 化、 in-tree Cloud Provider skip → classic ELB recreate cycle 防止
- cost ~\$10-20 削減 (= classic ELB のみ防止)
- cilium-gateway NLB + reverse-proxy NLB ~\$79 削減は Phase 8+ 引き継ぎ持ち越し (= 別 Cilium version or 別 approach で #39 再試行)

## Validation

- 既 orphan classic ELB delete 完了 + 再 provision されない確認
- cilium-gateway-cilium-gateway Service LoadBalancer mode 復活
- application traffic 維持 (= 旧 reverse-proxy NLB 経由 curl HTTPS 200)

## Phase 7-0 partial completion

#37 fix + Cilium upgrade + #40 bridge で 7-0 closure。 #39 は Phase 8+ 引き継ぎ。"
```

---

## Task 6: cluster validate + closure

**Files:** (= none、 documentation + observation のみ)

**Test:** spec Section 9 Validation checklist の全 item pass。

- [ ] **Step 1: spec validation checklist 全 verify (= success / fallback いずれの path も)**

success path (= #39 success、 Task 4 まで完了):

```bash
source /tmp/awsenv.sh

# #37 fix verify
kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=2m 2>&1 | grep -c "expected exactly one securityGroup"
# Expected: 0

# Cilium upgrade verify
cilium status 2>&1 | grep -i version
# Expected: 1.20.5

# #39 migration verify
dig +short develop.panicboat.net @1.1.1.1 | head -3
curl -sI --max-time 10 https://develop.panicboat.net/ 2>&1 | head -3
# Expected: ALB IPs + HTTP 200 OK

# 旧 NLB auto-delete verify
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws elbv2 describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancers[?Type==`network`].[LoadBalancerName,State.Code]'
# Expected: empty (= NLB 0 件)

# Hubble L7 ingress flow visualize (= 新規 functionality)
source /tmp/awsenv.sh
CILIUM_POD=$(kubectl get po -n kube-system -l k8s-app=cilium -o name | head -1 | sed 's|pod/||')
kubectl exec -n kube-system $CILIUM_POD -- hubble observe --to-port 8080 --since 5m --output compact 2>&1 | head -5
# Expected: HTTP flow observation (= cilium-gateway 経由 traffic 可視化)
```

fallback path (= #39 fail、 Task 5 まで):

```bash
# classic ELB recreate 防止 verify
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws elb describe-load-balancers --region ap-northeast-1 --output text \
  --query 'LoadBalancerDescriptions[*].[LoadBalancerName]'
# Expected: empty (= classic ELB 0 件、 default loadBalancerClass で再 provision 防止)

# 旧 reverse-proxy 経路 functional 維持
source /tmp/awsenv.sh
curl -sI --max-time 10 https://develop.panicboat.net/ 2>&1 | head -3
# Expected: HTTP 200 OK
```

- [ ] **Step 2: 引き継ぎ事項 update (= 別 PR で Phase 6 closure doc に反映)**

success path: #37 / #39 / #40 全 解消 (= Phase 7-0 で完了)
fallback path: #37 解消 / #40 解消 / **#39 を Phase 8+ 引き継ぎ persist** (= 別 Cilium version or 別 approach で再試行)

Phase 6 closure doc の Section 4 を update する別 PR (= docs only PR):
```bash
# 別 worktree で進める (= 別 PR scope)
# 内容:
# - #37 解消 (= Phase 7-0 PR 1)
# - #39 解消 (= Phase 7-0 PR 3+4) OR Phase 8+ 持ち越し (= fallback path)
# - #40 内包解消 OR 独立解消 (= fallback path で別 PR 採用)
# - 7-0 で確立した patterns + lessons aggregate
```

注: docs update は Phase 7-0 closure 一環、 ただし plan の scope を 4 PR + fallback に絞るため Task 6 では別 PR 化を指示のみ。

- [ ] **Step 3: Phase 7-1 OTel Operator upgrade brainstorming に進む**

7-0 closure 後、 Phase 7-1 (= OTel Operator chart 0.155+ upgrade + monolith env vars hardcode 撤去 + inject-ruby annotation 復活) brainstorming session 起動。

---

## Plan summary

| Task | PR | Cluster impact | Estimated time |
|---|---|---|---|
| 1. #37 fix (= terragrunt eks node SG tag) | platform PR 1 | 0 (= in-place tag update) | 30-60 min |
| 2. Cilium upgrade (= 1.18.6 → 1.20.5) | platform PR 2 | ~5-10 min DaemonSet rollout | 1-2 h (= 公式 docs 確認含む) |
| 3. #39 platform side (= hostNetwork + Gateway port 8080 + ALB Ingress) | platform PR 3 | ~5-10 min (= Cilium rollout + 旧 NLB delete + ALB provision) | 1-2 h |
| 4. #39 monorepo side (= reverse-proxy 削除 + frontend HTTPRoute) | monorepo PR 4 | ~2-5 min (= Flux prune + Route53 切替) | 30 min |
| 5. fallback (= #39 fail 時) | platform PR F1 | ~5 min (= cilium revert + AWS LB Controller restart) | 1 h |
| 6. cluster validate + closure | - (= docs only 別 PR) | 0 | 30 min |

**Total**: 3-5 h (= strict completion 成功 case)、 fallback 含む と 4-6 h

**Critical path**: Task 1 → Task 2 → Task 3 sequential、 Task 4 は Task 3 cluster validate 後。 fallback (= Task 5) は Task 3 fail 時のみ trigger。

**PR merge 順序**:
1. PR 1 merge (= #37 fix) → cluster で AWS LB Controller panic loop 停止確認
2. PR 2 merge (= Cilium upgrade) → Theme B fix forward regression なし確認
3. PR 3 merge (= #39 platform) → ALB provision active + 旧 cilium-gateway NLB auto-delete 確認
4. PR 4 merge (= #39 monorepo) → reverse-proxy 削除 + 旧 reverse-proxy NLB auto-delete + curl HTTPS 200 確認
5. (= 必要時) PR F1 merge (= fallback path)

---

## Closure (= 2026-05-16)

Phase 7-0 strict completion 達成。 上記 task-by-task plan は **そのままの形では実行されず**、 別 phase の cluster teardown + recreate (= 2026-05-10 design 由来) の実施過程で Task 2 (Cilium upgrade) + Task 3 / 4 (#39 migration platform + monorepo) が inline 完了、 Task 1 (#37 fix) のみ 2026-05-16 で worktree `fix/eks-37-sg-tag-cleanup-apply` から terragrunt apply。

実態の詳細 + Residuals (= Gateway PROGRAMMED=False の hostNetwork mode trade-off 等) は spec doc (`docs/superpowers/specs/2026-05-14-eks-phase-7-0-lb-hardening-design.md`) の `## 10. Retrospective` section を参照。
