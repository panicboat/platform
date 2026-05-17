# EKS Production Recreate — Manual Bootstrap Runbook

> **Status**: 運用 runbook (= 2026-05-16 live run validated、 PR #401-#407 merge 後の構成に対応)。
>
> **Scope**: `eks-production` cluster を **clean slate (= 全 stack destroy + orphan zero)** から **operator が手作業で 2 terminal 並行で sequentially bootstrap** する手順。
>
> **Source-of-truth**: 本 runbook は実 live run 経験を反映した手順を提供する。 設計判断 (= chicken-and-egg の理由 / Pod Identity 採用根拠 等) は `docs/superpowers/specs/` の design spec を参照。

## 1. Purpose

EKS cluster cold-start は cilium native CNI ENI mode (= PR #393) との chicken-and-egg があり、 単一 sequence の自動化では完走できない:

- `aws/eks` apply で cluster + addon (= coredns / aws-ebs-csi-driver) を install 試行
- addon は `system_critical` MNG (= `aws/karpenter` stack が作る) に schedule 必要だが MNG 未作成で **DEGRADED**
- 順序入れ替えても `system_critical` MNG node は **cilium agent 不在で NotReady のまま** → MNG `CREATE_FAILED`

本 runbook は **2 terminal 並行** で `aws/eks` apply の addon wait 期間中に cilium install + karpenter apply を進める clean path を 10 Phase で明文化する。

## 2. Pre-conditions

### 2.1 Cluster state

- `eks-production` cluster + 周辺 EKS stack が完全 destroy 済
- VPC stack も destroy 済
- `make eks-teardown ENV=production` 完走 + `make eks-teardown-verify ENV=production` で `No orphan resources detected` 確認済

### 2.2 Operator environment

- panicboat IAM user 直接 (= `AdministratorAccess` policy attach 済)
- shell env clean: `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` 後 `aws sts get-caller-identity --query Arn --output text` で `arn:aws:iam::559744160976:user/panicboat` が返ること (= `eks-login` 等で事前 role assume していない状態)
- 2 terminal を同時に使える (= IDE の split terminal / tmux 等)

### 2.3 CLI tools

`tofu` `terragrunt` `kubectl` `helm` `helmfile` `flux` `jq` `aws` `cilium` (= cilium-cli v0.19.2+) `make` `bash`

### 2.4 PR workflow consideration

bootstrap 中は terraform / kubernetes manifest を **local から直接 apply** することが推奨 (= CI auto-apply と race しない、 試行錯誤が速い)。 PR は state-tracking 用に分けて出す (= local apply 後に commit + PR で記録)。

CI auto-apply を抑止する label scheme (= `skip-deploy` 等) は別途検討中 (= `docs/superpowers/specs/2026-05-16-eks-bootstrap-local-first-workflow-design.md` 参照)。

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
# → 出力空であること
```

### Phase 1: VPC + ALB stack (= Terminal A、 sequential)

```bash
( cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
( cd aws/alb/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
```

期待結果: VPC + subnet + NAT gateway + ACM wildcard cert 作成。 5-10 分 (= ACM の DNS validation 込)。

### Phase 2: EKS cluster apply 開始 (= Terminal A、 background)

```bash
( cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve ) 2>&1 | tee /tmp/eks-apply.log
```

挙動:

1. cluster 作成 (= ~10 分で `ACTIVE`)
2. addon install 試行 (= `coredns` / `aws-ebs-csi-driver` / `eks-pod-identity-agent`)
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
  NEW_EKS_EP=$(cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw cluster_endpoint_hostname 2>/dev/null \
               || aws eks describe-cluster --region ap-northeast-1 --name eks-production --query 'cluster.endpoint' --output text | sed 's|https://||')
  NEW_VPC_ID=$(cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt output -raw vpc_id)
  echo "NEW_EKS_EP=$NEW_EKS_EP"
  echo "NEW_VPC_ID=$NEW_VPC_ID"
)
# Phase 2 が完走前なら eks の terragrunt output が空。 aws eks describe-cluster で代替取得。

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
  --set prometheus.serviceMonitor.enabled=false

# 確認: cilium DS / cilium-operator が deploy される、 node がまだ無いため Pending で待機
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium
```

### bootstrap override の rationale

| Override | 理由 |
|---|---|
| `hubble.tls.auto.method=helm` | default `certmanager` は cert-manager CRD を要求するが、 cert-manager は Flux で後段 install。 helm 内で self-signed 生成に切り替え。 cert-manager 配備後は Phase 9 の Flux apply で `certmanager` に戻る |
| `hubble.metrics.serviceMonitor.enabled=false` | default `true` は `monitoring.coreos.com/v1::ServiceMonitor` CRD を要求するが、 prometheus-operator は Flux で後段。 Phase 9 で `true` に戻る |
| `operator.prometheus.serviceMonitor.enabled=false` | 同上 |
| `prometheus.serviceMonitor.enabled=false` | 同上 |

> **NOTE**: `operator.dnsPolicy=Default` は **PR #401 (= Pod Identity 移行) で不要化** された (= IRSA timeout 問題が Pod Identity で解消)。 旧版 runbook (= 2026-05-16 初版) では必要だったが現在は不要。

### Phase 5: Karpenter terragrunt apply (= Terminal A、 Phase 2 と並行)

Phase 4 の cilium install 完了後、 Terminal A の Phase 2 がまだ addon wait 中の間に **別 sub-terminal で**:

```bash
( cd aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
```

挙動:

1. `system_critical` MNG 作成 → 2x t4g.small EC2 boot
2. kubelet 起動 → cilium DS が schedule (= Pending → Running)
3. **cilium-operator (= Pod Identity 経由で EC2 API call、 PR #401)** が ENI allocation → CiliumNode IP populate → CNI 提供
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

`aws-ebs-csi-driver` の controller pod は tainted system_critical MNG に schedule できないため、 **Karpenter が system-components NodePool で worker node を provision する** (= Phase 8 の NodePool kustomize apply 後)。 Phase 6 で `aws-ebs-csi-driver` が DEGRADED 継続なら Phase 7 / 8 を先に進めて worker node を出す。

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
# karpenter chart を local install (= Pending pod が schedule できる worker provision に必要)
( cd kubernetes/components/karpenter/production && helmfile -e production sync )

# EC2NodeClass + NodePool kustomize apply
kubectl apply -k kubernetes/components/karpenter/production/kustomization/

# 確認:
kubectl get ec2nodeclasses.karpenter.k8s.aws,nodepools.karpenter.sh
```

Karpenter が NodePool 観測 → Pending pod (= ebs-csi-controller / hubble-relay / hubble-ui 等) を見て worker node provision を開始。

### Phase 9: Flux bootstrap

#### 9.1 Flux core install

PR #407 で `gotk-components.yaml` (= Flux core + image-reflector / image-automation controllers) が source 化されているため、 1 コマンドで install:

```bash
kubectl apply -k kubernetes/clusters/production/flux-system/ --server-side --force-conflicts
```

`--server-side` は CRD の annotation size limit (= 262KB) 回避に必須。

#### 9.2 hydrate + commit + push

```bash
# RECREATE marker は Phase 4 で edit 済 (= 再 edit 不要)
# hydrate-component で全 component を新 cluster ID で再生成
for comp in $(find kubernetes/components -mindepth 1 -maxdepth 1 -type d -exec basename {} \;); do
  if [ -d "kubernetes/components/${comp}/production" ]; then
    echo "Hydrating ${comp}..."
    bash scripts/kubernetes-hydrate/hydrate-component.sh "$comp" production
  fi
done
bash scripts/kubernetes-hydrate/hydrate-index.sh production

# commit + push (= main 直接 push は branch protection で blocked のため PR 経由)
git checkout -b chore/hydrate-after-recreate-$(date +%Y%m%d)
git add kubernetes/
git commit -s -m "chore(kubernetes): refresh helmfile + manifests after cluster recreate

eksApiEndpoint + vpcId を新 cluster の値に更新 + 全 component re-hydrate."
git push -u origin HEAD

gh pr create --title "chore(kubernetes): refresh helmfile + manifests after cluster recreate" --body "..."
# review + merge
```

merge 後 main から:

```bash
git checkout main && git pull --ff-only
```

#### 9.3 cluster manifests apply (= 2-step bootstrap、 webhook chicken-and-egg 回避)

##### 9.3a bootstrap-webhooks apply (= webhook 提供 HelmRelease を先 install)

```bash
kubectl apply -k kubernetes/clusters/production/bootstrap-webhooks/ --server-side --force-conflicts
```

含まれる component (= validating / mutating webhook 提供):
- `00-namespaces` / `cert-manager` / `external-secrets` / `prometheus-operator` / `opentelemetry` / `aws-load-balancer-controller` / `keda`

各 webhook deployment の起動 wait:

```bash
for ns in cert-manager external-secrets opentelemetry-operator-system monitoring kube-system keda; do
  kubectl wait --for=condition=Available deployment --all -n "$ns" --timeout=300s 2>/dev/null || true
done
```

##### 9.3b cluster manifests full apply (= 全 component、 webhook 応答するため成功)

```bash
kubectl apply -k kubernetes/clusters/production/ --server-side --force-conflicts
```

> **NOTE**: 9.3a の `bootstrap-webhooks/` kustomize root は initial bootstrap のみで使用 (= PR #410 で追加)。 steady state の Flux reconcile は `clusters/production/` root が引き続き全 manifest を管理する (= 両者 overlap するが server-side apply の field manager 共存で OK)。 9.3a を skip して 9.3b 直接実行も可能 (= 旧 runbook の挙動、 初回 apply 部分 fail → Flux reconcile loop で self-heal)、 ただし operator が "WARNING: 部分 fail だが想定挙動" を見て焦らないために 9.3a 経路を推奨。

#### 9.4 Flux reconcile force trigger (= 必要に応じて)

```bash
flux reconcile source git flux-system
flux reconcile kustomization flux-system
kubectl get kustomizations -A
# → flux-system Ready=True 確認
```

### Phase 10: 全 component Ready 化を待つ

```bash
# 全 namespace の pod 状態確認
kubectl get pods -A | grep -vE 'Running|Completed' | head
# → 出力が空 (= 全 Running) になるまで wait

# stateful pod の PVC 状態確認
kubectl get pvc -A | grep -v Bound
# → 出力が空 (= 全 Bound) なら gp3 SC (= PR #406) で provisioning 完了
```

`flux-system` Kustomization が True、 全 pod Running なら bootstrap 完了。

> **NOTE on cilium upgrade**: Phase 4 で渡した bootstrap override (= `hubble.tls.auto.method=helm` 等) は、 Phase 9 の Flux Kustomization apply で **cilium 通常 values (= cert-manager + ServiceMonitor 有効)** が apply されて自動的に解除される。 別途 `cilium upgrade` 不要。

## 4. Verification

```bash
# nodes
kubectl get nodes -L node-role/system-critical,karpenter.sh/nodepool
# → system_critical 2台 + Karpenter-provisioned 数台、 全 Ready

# cilium status
cilium status
# → Healthy + agent/operator 全 Ready

# Kustomizations
kubectl get kustomizations -A
# → flux-system Ready=True、 monorepo-cluster は monorepo 側 manifests 依存

# CiliumNode IP allocate
kubectl get ciliumnodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.ipam.pool}{"\n"}{end}'
# → 全 node に IP 範囲 allocate 済

# addon
for a in coredns aws-ebs-csi-driver eks-pod-identity-agent; do
  echo "$a: $(aws eks describe-addon --region ap-northeast-1 --cluster-name eks-production --addon-name $a --query addon.status --output text)"
done
# → 3 addon 全 ACTIVE
```

## 5. Failure handling

| Symptom | Likely cause | Recovery |
|---|---|---|
| `Module version requirements have changed` | `.terragrunt-cache/` stale | 該当 stack で `terragrunt init -upgrade` |
| `UnauthorizedOperation: ec2:DescribeNetworkInterfaces` from eks-admin assumed-role | env に admin role creds が leak | `unset AWS_*_KEY` で operator IAM user に戻す |
| `system_critical` MNG `CREATE_FAILED: Unhealthy nodes` | Phase 4 (= cilium install) が Phase 5 (= karpenter apply) より前に完了していない | Phase 5 を中断、 Phase 4 を完了させてから Phase 5 を再 apply |
| cilium-operator `Failed initial EC2 API limits update` | **PR #401 で Pod Identity 化済のため通常発生しない**。 発生する場合は IRSA fallback path に陥っている可能性 → SA annotation `eks.amazonaws.com/role-arn` の有無を確認、 Pod Identity Association が provision されているか `aws eks list-pod-identity-associations` で確認 | Pod Identity Association 不在なら `aws eks create-pod-identity-association ...` で manual provision |
| terragrunt apply で `ACM Certificate ... is in use` | 過去 destroy で ALB が取り残された | `aws elbv2 delete-load-balancer` で手動削除後 retry (= teardown 側は PR #398 で fixed) |
| stale terragrunt state lock (= `Error acquiring the state lock`) | 前 session の lock release 漏れ OR CI run が異常終了 | `aws dynamodb scan --table-name terragrunt-state-locks --query "Items[?Info != \`null\`]"` で active lock 確認 → `terragrunt force-unlock -force <ID>` |
| `flux-system` Kustomization `False` で webhook validation error | webhook 提供 HelmRelease (= cert-manager / external-secrets / opentelemetry-operator) が未起動 | **Phase 9.3a の bootstrap-webhooks apply (= PR #410) を実行済か確認**。 9.3a を skip した場合は数分待って Flux reconcile loop で self-heal 期待、 起動済なのに stuck なら `flux reconcile kustomization flux-system` で force trigger |
| Pending pods が `pod has unbound immediate PersistentVolumeClaims` | gp3 StorageClass 未作成 | **PR #406 merge 後は不要**。 旧 cluster recreate で pre-PR #406 commit から始める場合のみ手動作成 |
| post-merge CI が apply 中に operator local apply 試行で衝突 | CI が state lock 保持 | CI 完走待ち、 OR CI cancel + force-unlock。 将来は `skip-deploy` label scheme (= PR #404 design Phase B) で防止 |

## 6. Future improvements

- **CI label-based guard** — `skip-deploy` / `plan-only` label で bootstrap PR の CI auto-apply を抑止 (= `docs/superpowers/specs/2026-05-16-eks-bootstrap-local-first-workflow-design.md` Phase B)。 panicboat 個人運用 + bootstrap 月 1 未満では nice-to-have、 共有運用化 / bootstrap 高頻度化で priority 上昇
- **Atomic apply chicken-and-egg fix** — ~~Flux Kustomization を `bootstrap-webhooks` → `applications` 2-tier に分割~~ → **PR #410 + Phase 9.3 の 2-step 化で実質解消済**。 完全な Flux Kustomization 2-tier (= `dependsOn` + `healthChecks`) は将来の改善余地
- ~~**gp2 default class 撤去**~~ → **PR #409 で完了済**
- **runbook 自動化** — Phase 1-9 を 1 つの shell script に集約。 ただし Phase 4 の operator 手動 edit は plan A 設計 (= sed 自動置換は PR #326 incident 反省で却下) のため operator-prompted のまま

## 7. References

- `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md` — Phase 3 lifecycle script design
- `docs/superpowers/plans/2026-05-10-eks-production-teardown-recreate.md` — Phase 3 plan
- `docs/superpowers/specs/2026-05-16-eks-bootstrap-local-first-workflow-design.md` — workflow 改善 design
- `scripts/eks-lifecycle/README.md` — operator-prompted RECREATE marker convention
- PR #393 — Cilium native CNI (ENI mode) 化
- PR #397 — 10-k8s-cleanup.sh Karpenter foreground cascade + AWS-tag fallback
- PR #398 — 10-k8s-cleanup.sh ALB/NLB foreground cascade + AWS-tag fallback
- PR #401 — cilium-operator IRSA → Pod Identity Association
- PR #402 — cilium-operator IAM policy に DescribeRouteTables 追加
- PR #405 — 00-auth.sh kubectl reachability check inside admin subshell
- PR #406 — gp3 StorageClass for production cluster
- PR #407 — Flux gotk-components + image-reflector/automation controllers
- Cilium ENI IPAM docs: https://docs.cilium.io/en/v1.19/network/concepts/ipam/eni/
- AWS EKS Pod Identity docs: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
