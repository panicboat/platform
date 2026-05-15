# EKS Production Recreate — Manual Bootstrap Runbook

> **Status**: 手動 runbook (= 2026-05-16 作成、 後日 Makefile 自動化検討)。
>
> **Scope**: `eks-production` cluster を **clean slate (= 全 stack destroy + orphan zero)** から **operator が手作業で 2 terminal 並行で sequentially bootstrap** する手順。

## 1. Purpose

Phase 3 lifecycle script (`make eks-recreate ENV=production` / `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md`) は **vpc → alb → eks → karpenter → eks-secrets/logs/metrics/traces** の sequential apply を採用しているが、 cilium native CNI ENI mode (= PR #393) との combinations で chicken-and-egg があり cold-start recreate が完走しない:

1. `aws/eks` apply で cluster 作成 → addons (coredns / aws-ebs-csi-driver) install を試行
2. addons は `node-role/system-critical=true` label + `dedicated=system-critical:NoSchedule` toleration を要求 (= aws/eks/modules/addons.tf)
3. 対応 MNG (`system_critical`) は **`aws/karpenter` stack** が作る (= sequential 上 eks の後)
4. addon が schedule 先なく DEGRADED → 20分 timeout で eks apply fail
5. 仮に karpenter を先に apply しても、 system_critical MNG node は **cilium agent 不在で NotReady のまま** (= BYOCNI 要件、 vpc-cni 撤去済) → MNG が CREATE_FAILED → karpenter apply fail
6. cilium を local helmfile / helm で直接 install するには **operator-prompted RECREATE marker update が事前必要** + cilium-operator が `--cluster-name` 自動推定で EC2 API timeout で crashloop することがあり、 default helmfile values だと bootstrap で詰まる

本 runbook は **2 terminal で `aws/eks` apply の addon-wait 期間中に並行で cilium install + karpenter apply を走らせる** clean path を明文化する。

## 2. Pre-conditions

### Cluster state

- `eks-production` cluster + 周辺 EKS stack (= alb / eks / karpenter / eks-secrets / eks-logs / eks-metrics / eks-traces) が完全 destroy 済
- VPC stack も destroy 済 (= bootstrap で新 VPC 作成)
- `make eks-teardown ENV=production` 完走 + `make eks-teardown-verify ENV=production` で `No orphan resources detected` 確認済

### Operator environment

- panicboat IAM user 直接 (= `AdministratorAccess` policy attach 済)
- shell env clean: `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` 後 `aws sts get-caller-identity --query Arn --output text` で `arn:aws:iam::559744160976:user/panicboat` が返ること (= `eks-login` 等で事前 role assume していない状態)
- 2 terminal を同時に使える (= IDE の split terminal / tmux 等)

### CLI tools

`tofu` `terragrunt` `kubectl` `helm` `helmfile` `flux` `jq` `aws` `cilium` (= `cilium-cli` v0.19.2+) `make` `bash`

## 3. Sequence

### Phase 0: pre-flight (= Terminal A)

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform

# AWS env reset (= eks-login 等の assumed-role state 解除)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity --query Arn --output text
# → arn:aws:iam::559744160976:user/panicboat

# git working tree clean 確認
git status --short
# → 出力空 (= local changes なし) であること。 修正があれば commit / stash
```

### Phase 1: VPC + ALB stack (= Terminal A, sequential)

```bash
( cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
( cd aws/alb/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
```

期待結果: VPC + subnet + NAT gateway + ACM wildcard cert 作成。 5-10 分 (= ACM の DNS validation 込み)。

### Phase 2: EKS cluster apply 開始 (= Terminal A、 background で走らせる)

```bash
( cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve ) 2>&1 | tee /tmp/eks-apply.log
```

挙動:

1. cluster 作成 (= ~10 分で `ACTIVE`)
2. addon (= `coredns` / `aws-ebs-csi-driver` / `eks-pod-identity-agent`) install 試行
3. `eks-pod-identity-agent` は schedule 先不要で ACTIVE 化
4. `coredns` + `aws-ebs-csi-driver` は schedule 不能で **DEGRADED で 20分 wait**

Phase 3 / 4 / 5 を **別 terminal で並行実行** すれば、 wait の間に nodes が Ready 化して addon が ACTIVE に遷移し、 Phase 2 が抜ける。

### Phase 3: kubectl auth (= Terminal B)

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform

# Phase 2 で cluster ACTIVE 化を待つ (= ~10 分)
while ! aws eks describe-cluster --region ap-northeast-1 --name eks-production --query 'cluster.status' --output text 2>/dev/null | grep -q ACTIVE; do
  echo "waiting for eks-production cluster ACTIVE..."
  sleep 30
done
echo "cluster ACTIVE"

# admin role assume + kubeconfig
ADMIN_CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::559744160976:role/eks-admin-production \
  --role-session-name bootstrap \
  --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$ADMIN_CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$ADMIN_CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$ADMIN_CREDS" | jq -r .SessionToken)
aws eks update-kubeconfig --region ap-northeast-1 --name eks-production
kubectl get ns
# → kubectl 接続 OK (= node はまだ無し、 ns 一覧のみ取得)
```

### Phase 4: RECREATE marker update + Cilium install (= Terminal B)

```bash
# 1. 新 cluster_endpoint_hostname + vpc_id 取得 (= operator IAM user の env で terragrunt output)
(
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  NEW_EKS_EP=$(cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw cluster_endpoint_hostname)
  NEW_VPC_ID=$(cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt output -raw vpc_id)
  echo "NEW_EKS_EP=$NEW_EKS_EP"
  echo "NEW_VPC_ID=$NEW_VPC_ID"
)

# 2. operator が editor で 4 marker を手動更新 (= eksApiEndpoint x2 + vpcId x2)
#    Plan A operator-prompted 設計 (= docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md §0 Errata)
#
#    対象 file + 該当行:
#      kubernetes/helmfile.yaml.gotmpl                                            : eksApiEndpoint + vpcId
#      kubernetes/components/cilium/production/helmfile.yaml                      : eksApiEndpoint
#      kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml: vpcId
#
#    grep で位置確認:
grep -n 'RECREATE:' kubernetes/helmfile.yaml.gotmpl \
                    kubernetes/components/cilium/production/helmfile.yaml \
                    kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml

# 3. 編集完了後、 cilium values を render (= helmfile を介して RECREATE marker 値が反映された状態)
helmfile -e production \
  -f kubernetes/components/cilium/production/helmfile.yaml \
  write-values --output-file-template '/tmp/cilium-rendered-{{.Release.Name}}.yaml'

# 4. cilium-cli で install (= bootstrap 用 override 付き)
cilium install --version 1.19.4 \
  -f /tmp/cilium-rendered-cilium.yaml \
  --set hubble.tls.auto.method=helm \
  --set hubble.metrics.serviceMonitor.enabled=false \
  --set operator.prometheus.serviceMonitor.enabled=false \
  --set prometheus.serviceMonitor.enabled=false \
  --set operator.dnsPolicy=Default

# 確認: cilium DS + operator が Pending で待機 (= node がまだ無い)
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium
```

### bootstrap override の rationale

| Override | 理由 |
|---|---|
| `hubble.tls.auto.method=helm` | default `certmanager` は cert-manager CRD を要求するが、 cert-manager は Flux で後段 install。 helm 内で self-signed 生成に切り替え。 cert-manager 配備後は `cilium upgrade` で `certmanager` に戻して整合させる |
| `hubble.metrics.serviceMonitor.enabled=false` | default `true` は `monitoring.coreos.com/v1::ServiceMonitor` CRD を要求するが、 prometheus-operator は Flux で後段。 後段で `cilium upgrade` で `true` に戻す |
| `operator.prometheus.serviceMonitor.enabled=false` | 同上 |
| `prometheus.serviceMonitor.enabled=false` | 同上 |
| `operator.dnsPolicy=Default` | default `ClusterFirst` で hostNetwork pod が cluster DNS (= coredns) を引こうとして coredns 未起動状態で DNS resolve fail → EC2 API call timeout → operator crashloop。 `Default` で host `/etc/resolv.conf` (= VPC default DNS) 直接使用 |

### Phase 5: Karpenter terragrunt apply (= Terminal A、 Phase 2 と並行)

Phase 4 の cilium install 完了後、 Terminal A の Phase 2 がまだ addon wait 中の間に **別 sub-terminal で**:

```bash
( cd aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
```

挙動:

1. `system_critical` MNG 作成 → 2x t4g.small EC2 boot
2. kubelet 起動 → cilium DS が schedule (= Pending → Running)
3. cilium-operator が ENI allocation → CiliumNode IP populate → CNI 提供
4. node が Ready 化 → MNG `ACTIVE` 化 → terragrunt 完了

5-10 分。

### Phase 6: EKS addon ACTIVE 化を見届け Phase 2 完走

```bash
# Terminal B で監視
watch -n 10 'for a in coredns aws-ebs-csi-driver eks-pod-identity-agent; do
  printf "%s: " "$a"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  aws eks describe-addon --region ap-northeast-1 --cluster-name eks-production --addon-name $a --query addon.status --output text 2>&1
done'
# 3 addon すべて ACTIVE になったら Ctrl+C → Phase 2 (= eks terragrunt apply) も完了する
```

Phase 2 の terragrunt apply が成功で抜けたことを `/tmp/eks-apply.log` で確認。

### Phase 7: 残り stack apply (= Terminal A)

```bash
for stack in eks-secrets eks-logs eks-metrics eks-traces; do
  echo "=== apply: $stack ==="
  ( cd aws/$stack/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
done
```

各 stack ~2-3 分。 IRSA / Pod Identity Association + S3 bucket + DynamoDB 等を作成。

### Phase 8: EC2NodeClass + NodePool apply (= Terminal B)

```bash
kubectl apply -k kubernetes/components/karpenter/production/kustomization/
# 確認:
kubectl get ec2nodeclasses.karpenter.k8s.aws,nodepools.karpenter.sh
```

Karpenter が NodePool 観測 → Pending pod (= ebs-csi-controller / hubble-relay / hubble-ui 等) を見て worker node provision を開始。

### Phase 9: hydrate + Flux bootstrap

RECREATE marker は Phase 4 で既に新値に edit 済のため、 Phase 3 lifecycle script の operator-prompted step を **そのまま** 通せる:

```bash
# admin role creds を 70-reconcile-watch.sh に引き継ぐため、 lifecycle script 経由で実行
bash scripts/eks-lifecycle/lib/60-flux-bootstrap.sh
# operator-prompted: marker list が表示されるが既に edit 済 → y で進行
# script は hydrate + git commit + push + kubectl apply -k clusters/production/ を実行

bash scripts/eks-lifecycle/lib/70-reconcile-watch.sh
# 全 HelmRelease が Phase 単位で Ready 化を wait
```

### Phase 10: bootstrap override 解除 (= Flux 同期後)

cert-manager / prometheus-operator が Flux 経由で Ready 化したら、 Phase 4 で cilium に渡した bootstrap override を取り消して **helmfile values と整合** させる:

```bash
# 確認: cert-manager + prom-op が Ready
kubectl get helmrelease -n cert-manager cert-manager
kubectl get helmrelease -n monitoring kube-prometheus-stack

# cilium を override 無しで再 install (= 通常 helmfile values が適用される)
helmfile -e production -f kubernetes/components/cilium/production/helmfile.yaml sync
```

`hubble.tls.auto.method=certmanager` + 各種 `serviceMonitor.enabled=true` が反映される。

## 4. Verification

```bash
# nodes
kubectl get nodes -L node-role/system-critical,karpenter.sh/nodepool
# → system_critical 2台 + Karpenter-provisioned 数台、全 Ready

# cilium status
cilium status
# → Healthy + agent/operator 全 Ready

# HelmReleases
kubectl get helmreleases -A
# → 全 Ready

# CiliumNode IP allocate
kubectl get ciliumnodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.ipam.podCIDRs}{"\n"}{end}'
# → 全 node に IP 範囲 allocate 済
```

## 5. Failure handling

| Symptom | Likely cause | Recovery |
|---|---|---|
| `Module version requirements have changed` | `.terragrunt-cache/` stale | 該当 stack で `terragrunt init -upgrade` |
| `UnauthorizedOperation: ec2:DescribeNetworkInterfaces` from eks-admin assumed-role | env に admin role creds が leak | `unset AWS_*_KEY` で operator IAM user に戻す |
| `system_critical` MNG `CREATE_FAILED: Unhealthy nodes` | Phase 4 (= cilium install) が Phase 5 (= karpenter apply) より前に完了していない | Phase 5 を中断、 Phase 4 を完了させてから Phase 5 を再 apply |
| cilium-operator `Failed initial EC2 API limits update` | `dnsPolicy=ClusterFirst` で coredns 未起動状態の cluster DNS lookup fail | `--set operator.dnsPolicy=Default` で再 install |
| terragrunt apply で `ACM Certificate ... is in use` | 過去 destroy で ALB が取り残された | `aws elbv2 delete-load-balancer` で手動削除後 retry (= teardown 側は PR #398 で fixed) |

## 6. Future automation

本 runbook を Makefile target / script 化する場合の検討事項:

1. **Phase 2 の addon DEGRADED wait をスキップする方法** — terraform module 改造 (= `aws_eks_addon` を `lifecycle.ignore_changes=[status]` 化) or terraform target で cluster のみ apply
2. **Phase 4 の cilium install を script 化** — RECREATE marker auto-substitution (= sed) vs operator-prompted (= 現状) のトレードオフ。 sed は PR #326 incident の audit pass 漏れ反省から避ける方針 (= spec §0 Errata)
3. **Phase 5 を Phase 2 の background wait 中に自動 trigger** — 2 process orchestration を bash で書く or Makefile の parallel target (= `.NOTPARALLEL` の例外)
4. **Phase 10 の override 解除** — cilium-operator が cert-manager CRD 配備後に hubble TLS / ServiceMonitor を取り戻す `cilium upgrade` の自動化。 値の drift を検出する CI check も必要

## 7. References

- `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md` — Phase 3 lifecycle script design
- `docs/superpowers/plans/2026-05-10-eks-production-teardown-recreate.md` — Phase 3 plan
- `scripts/eks-lifecycle/README.md` — operator-prompted RECREATE marker convention
- PR #393 — Cilium native CNI (ENI mode) 化 + system-critical MNG rename
- PR #397 — 10-k8s-cleanup.sh Karpenter foreground cascade + AWS-tag fallback
- PR #398 — 10-k8s-cleanup.sh ALB/NLB foreground cascade + AWS-tag fallback
- Cilium ENI IPAM docs: https://docs.cilium.io/en/v1.19/network/concepts/ipam/eni/
