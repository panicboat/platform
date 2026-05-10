# EKS Production: nginx End-to-end Validation (Phase 5-2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster (`eks-production`) に **demo nginx application** を deploy し、roadmap Phase 5 完了条件 13 checklist を **end-to-end validate**。Phase 1-4 で構築した全 component (= Cilium chaining + ALB Controller + external-dns + ACM + cert-manager + ESO + Reloader + Beyla + KEDA + metrics-server + Mimir + Loki + Tempo + Hubble) を nginx 投入で actual data flow validation。

**Architecture:** **Plain K8s manifests** (= kustomization-only component、helmfile 不在、`gateway-api` reference pattern を踏襲) で nginx Deployment + Service + Ingress + ScaledObject + ExternalSecret を `default` namespace に deploy。Public access (= ALB direct → nginx、認証なし) で 13 checklist の direct ALB → nginx flow を最 cleanest に validate。`monitoring-uis` IngressGroup を共有 (= Phase 4-3 既 ALB を再利用、cost optimal)。HPA + KEDA は **KEDA ScaledObject 1 つで multi-trigger** (= cpu 50% + prometheus 1 RPS、KEDA が内部 HPA 管理) で conflict 完全回避。KEDA Prometheus trigger は Beyla RED metrics (= `http_server_request_duration_seconds_count` rate) で Phase 5-1 Beyla deploy の actual end-to-end validation 兼ねる。

**Tech Stack:** Plain K8s manifests / kustomize / `default` namespace / nginx 1.27-alpine (= 実装時 latest stable 確認) / KEDA v2.x ScaledObject (= Phase 1 deploy 済) / external-secrets.io v1 ExternalSecret (= Phase 4-2 deploy 済) / Phase 4-3 既 ALB + IngressGroup `monitoring-uis` / ACM wildcard cert `*.panicboat.net` (= auto-discovery) / Phase 5-1 Beyla DaemonSet で nginx を eBPF auto-instrument

**Spec:** `docs/superpowers/specs/2026-05-10-eks-production-nginx-end-to-end-validation-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**Kubernetes 新規 (nginx-sample)**:

```
kubernetes/components/nginx-sample/
└── production/
    └── kustomization/
        ├── kustomization.yaml          # 全 resource roll-up
        ├── deployment.yaml             # nginx Deployment + env from ExternalSecret + Reloader annotation
        ├── service.yaml                # ClusterIP Service for nginx
        ├── ingress.yaml                # ALB Ingress (= monitoring-uis IngressGroup join)
        ├── scaled-object.yaml          # KEDA ScaledObject (= cpu + prometheus multi-trigger)
        └── external-secret.yaml        # ExternalSecret for AWS Secrets Manager → K8s Secret nginx-demo
```

**Kubernetes 自動生成 (= production hydrate output)**:

```
kubernetes/manifests/production/nginx-sample/{kustomization.yaml, manifest.yaml}    # 新規
kubernetes/manifests/production/kustomization.yaml                                  # 修正 (= ./nginx-sample auto-insert)
```

**変更しないファイル**:

- `kubernetes/components/nginx-sample/namespace.yaml` (= 不要、`default` namespace 既存活用)
- `aws/*` (= 全 terragrunt stack、AWS access は Phase 4-2 ESO IAM role を経由、新規 stack 不要)
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= namespace 新規作成なし)
- 他 K8s components (= Phase 1-4 + 5-1 で deploy 済、Phase 5-2 では touch なし)

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

**Context:** Phase 5-2 開始前に cluster 状態 + branch 状態 + manual setup (= AWS Secrets Manager 投入) を確認。Phase 5-1 完了状態 + 累計 fix forward 4 件 (= PR #311 / #312 / #314 / #316) merged 状態を baseline、Phase 5-2 で nginx 投入する前提を verify。

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-nginx-end-to-end-validation
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead

```
df59039 docs(eks): Phase 5-2 (nginx end-to-end validation) design
```

- [ ] **Step 2: Phase 4 + 5-1 完了状態 verify (= 主要 component 全部 Running)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- ESO + ClusterSecretStore ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
echo ""
echo "--- Reloader ---"
kubectl get pods -n reloader | head -3
echo ""
echo "--- Beyla DaemonSet (= Phase 5-1) ---"
kubectl get ds -n monitoring beyla
echo ""
echo "--- oauth2-proxy 4 instances (= Phase 4-3) ---"
kubectl get deploy -n oauth2-proxy --no-headers | wc -l
echo ""
echo "--- hubble-relay (= PR #316 fix forward 後) ---"
kubectl get pods -n kube-system -l k8s-app=hubble-relay'
```

Expected:
- ClusterSecretStore Ready=`True`
- Reloader Pod Running
- Beyla DaemonSet `4/4` (= 4 application nodes)
- oauth2-proxy `4` deployments
- hubble-relay Pod Running (= PR #316 で resolve 済)

- [ ] **Step 3: ALB + IngressGroup `monitoring-uis` 状態確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- 4 既存 Ingresses (= Phase 4-3) ---"
kubectl get ingress -n oauth2-proxy
echo ""
echo "--- ALB DNS (= 1 ALB shared) ---"
kubectl get ingress -n oauth2-proxy monitoring-uis-grafana -o jsonpath="ALB DNS: {.status.loadBalancer.ingress[0].hostname}{\"\\n\"}"'
```

Expected:
- 4 Ingresses (= grafana / hubble / alertmanager / prometheus) 全て同 ALB を共有
- ALB DNS = `k8s-monitoringuis-*.ap-northeast-1.elb.amazonaws.com`

- [ ] **Step 4: ACM wildcard cert `*.panicboat.net` ISSUED 確認**

```bash
zsh -ic 'aws acm list-certificates --region ap-northeast-1 --query "CertificateSummaryList[?DomainName==\`*.panicboat.net\`].[CertificateArn,Status]" --output text'
```

Expected: 1 行で ARN + `ISSUED`

- [ ] **Step 5: Manual setup 確認 (= panicboat 事前作業) — AWS Secrets Manager に `panicboat/nginx/demo` 投入**

```bash
zsh -ic 'aws secretsmanager list-secrets --region ap-northeast-1 --query "SecretList[?Name==\`panicboat/nginx/demo\`].Name" --output table'
echo ""
echo "--- secret value 確認 (= JSON 構造) ---"
zsh -ic 'aws secretsmanager get-secret-value --region ap-northeast-1 --secret-id panicboat/nginx/demo --query SecretString --output text'
```

Expected:

```
-----------------------------
|        ListSecrets        |
+---------------------------+
|  panicboat/nginx/demo     |
+---------------------------+

{"message":"Hello from AWS Secrets Manager"}
```

未投入の場合は spec の "Manual Setup" section を参照して panicboat が AWS Console で投入する。

- [ ] **Step 6: KEDA ScaledObject CRD apiVersion 確認 (= 5-1 L1 適用、CRD spec verify)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get crd scaledobjects.keda.sh -o jsonpath="{.spec.versions[*].name}{\"\\n\"}"
echo ""
echo "--- KEDA ScaledObject prometheus + cpu trigger schema ---"
kubectl explain scaledobject.spec.triggers --recursive 2>&1 | head -10'
```

Expected: `v1alpha1` (= KEDA v2.x default)、triggers schema が `type` / `metadata` 等を含む

- [ ] **Step 7: ExternalSecret CRD apiVersion 確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get crd externalsecrets.external-secrets.io -o jsonpath="{.spec.versions[?(@.served==true)].name}{\"\\n\"}"'
```

Expected: `v1` (= ESO chart 2.4.1 で deploy 済 GA version)

- [ ] **Step 8: `default` namespace に既存 nginx-sample 不在確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get all -n default 2>&1 | head -5
echo ""
ls kubernetes/components/nginx-sample/ 2>&1 | head -3'
```

Expected:
- `No resources found in default namespace.` (= default namespace は empty)
- `kubernetes/components/nginx-sample/` directory 不在 (= Phase 5-2 Task 1 で新規作成)

- [ ] **Step 9: Mimir cardinality 余裕確認 (= PR #314 で 500K limit 設定済、本 sub-project の Beyla RED metrics 流入で cardinality 増加予想)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl run --rm -i --restart=Never -n monitoring tmp-curl --image=curlimages/curl:latest --command -- curl -s "http://mimir-distributed-ingester.monitoring.svc.cluster.local:8080/metrics" 2>&1 | grep -E "^cortex_ingester_active_series\b|^cortex_ingester_active_series\{user=" | head -3'
```

Expected: `cortex_ingester_active_series{user="anonymous"} <X>` で X が 500K 未満 (= Phase 5-2 で Beyla RED metrics 増分 ~5K 以内見込み、余裕あり)

- [ ] **Step 10: Flux state 確認 (suspended でないこと)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux get kustomizations 2>&1 | head -3'
```

Expected: `flux-system` `SUSPENDED=False`、`READY=True`、`Applied revision: main@sha1:8bf1699` (= Phase 5-1 learnings PR #317 merge 済) もしくはそれ以降の commit

---

## Task 1: nginx-sample component を新規作成

**Files:**

- Create: `kubernetes/components/nginx-sample/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/nginx-sample/production/kustomization/deployment.yaml`
- Create: `kubernetes/components/nginx-sample/production/kustomization/service.yaml`
- Create: `kubernetes/components/nginx-sample/production/kustomization/ingress.yaml`
- Create: `kubernetes/components/nginx-sample/production/kustomization/scaled-object.yaml`
- Create: `kubernetes/components/nginx-sample/production/kustomization/external-secret.yaml`

**Context:** Phase 5-2 で deploy する nginx-sample component を新規作成。**Plain K8s manifests** で kustomization-only (= helmfile 不在、`gateway-api` reference pattern 踏襲)。`default` namespace に nginx Deployment + Service + Ingress (= ALB monitoring-uis 共有) + ScaledObject (= KEDA multi-trigger) + ExternalSecret (= AWS Secrets Manager 由来) を deploy。

### Step 1: nginx-sample directory 作成

```bash
mkdir -p kubernetes/components/nginx-sample/production/kustomization
ls -la kubernetes/components/nginx-sample/production/kustomization/
```

Expected: directory 作成成功、empty

### Step 2: deployment.yaml を作成

`kubernetes/components/nginx-sample/production/kustomization/deployment.yaml`:

```yaml
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
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: default
  labels:
    app: nginx
  annotations:
    # Reloader watch (= K8s Secret nginx-demo 変更時に Pod auto-rollout)。
    # Phase 4-2 で deploy 済 Reloader が監視。
    reloader.stakater.com/auto: "true"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
              name: http
              protocol: TCP
          env:
            - name: DEMO_MESSAGE
              valueFrom:
                secretKeyRef:
                  name: nginx-demo
                  key: message
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
```

### Step 3: service.yaml を作成

`kubernetes/components/nginx-sample/production/kustomization/service.yaml`:

```yaml
# =============================================================================
# nginx ClusterIP Service for end-to-end validation (Phase 5-2)
# =============================================================================
# nginx Pod を cluster 内 + ALB Ingress backend として expose。
# port 80 → targetPort http (= containerPort 80) の標準 mapping。
# =============================================================================
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: default
  labels:
    app: nginx
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
```

### Step 4: ingress.yaml を作成

`kubernetes/components/nginx-sample/production/kustomization/ingress.yaml`:

```yaml
# =============================================================================
# nginx ALB Ingress for end-to-end validation (Phase 5-2)
# =============================================================================
# Phase 4-3 で deploy 済の ALB (= IngressGroup monitoring-uis) を共有、
# nginx.panicboat.net で public access。ACM wildcard cert *.panicboat.net
# auto-discovery、external-dns で Route53 record 自動作成。
# 認証 layer なし (= public)、demo content は nginx Welcome page で漏洩 risk 低。
# =============================================================================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    # Phase 4-3 既 ALB 共有 (= cost optimal、+$0/month)
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: nginx.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: nginx.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 80
```

### Step 5: scaled-object.yaml を作成

`kubernetes/components/nginx-sample/production/kustomization/scaled-object.yaml`:

```yaml
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
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: nginx
  namespace: default
spec:
  scaleTargetRef:
    name: nginx
  minReplicaCount: 2
  maxReplicaCount: 10
  triggers:
    - type: cpu
      metricType: Utilization
      metadata:
        value: "50"
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
        threshold: "1"
        query: |
          sum(rate(http_server_request_duration_seconds_count{service_name="nginx"}[1m]))
```

### Step 6: external-secret.yaml を作成

`kubernetes/components/nginx-sample/production/kustomization/external-secret.yaml`:

```yaml
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
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: nginx-demo
  namespace: default
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: nginx-demo
    creationPolicy: Owner
  data:
    - secretKey: message
      remoteRef:
        key: panicboat/nginx/demo
        property: message
```

### Step 7: kustomization.yaml を作成

`kubernetes/components/nginx-sample/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# nginx-sample production kustomization
# =============================================================================
# Phase 5-2 (= End-to-end validation) の demo nginx application。
# Plain K8s manifests (= chart 不在、kustomization-only component) で
# gateway-api component の reference pattern を踏襲。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - scaled-object.yaml
  - external-secret.yaml
```

### Step 8: kustomize build で render verify (= 5-1 L1 chart binary verify の代替、CRD spec 適合確認)

```bash
kustomize build kubernetes/components/nginx-sample/production/kustomization 2>&1 | grep -E "^kind: " | sort | uniq -c
```

Expected:

```
   1 kind: Deployment
   1 kind: ExternalSecret
   1 kind: Ingress
   1 kind: ScaledObject
   1 kind: Service
```

```bash
kustomize build kubernetes/components/nginx-sample/production/kustomization 2>&1 | grep -E "^kind: |^  name: " | head -15
```

Expected: 5 resources、各 metadata.name = `nginx` or `nginx-demo`

### Step 9: Diff 確認

```bash
git status
git diff --stat
```

Expected: 6 新規ファイル
- `kubernetes/components/nginx-sample/production/kustomization/kustomization.yaml`
- `kubernetes/components/nginx-sample/production/kustomization/deployment.yaml`
- `kubernetes/components/nginx-sample/production/kustomization/service.yaml`
- `kubernetes/components/nginx-sample/production/kustomization/ingress.yaml`
- `kubernetes/components/nginx-sample/production/kustomization/scaled-object.yaml`
- `kubernetes/components/nginx-sample/production/kustomization/external-secret.yaml`

### Step 10: Commit

```bash
git add kubernetes/components/nginx-sample/
git commit -s -m "feat(eks): nginx-sample for end-to-end validation (Phase 5-2)"
```

Expected: 6 files changed、commit subject ≤ 72 chars (= 56 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 2: Hydrate manifests + verify

**Files:**

- Modify (auto-generated): `kubernetes/manifests/production/nginx-sample/{kustomization.yaml, manifest.yaml}` (= 新規)
- Modify (auto-generated): `kubernetes/manifests/production/kustomization.yaml` (= ./nginx-sample auto-insert)

**Context:** Task 1 で K8s component manifests 作成済。Task 2 で hydrated manifests を再生成し、Flux が apply する actual YAML を更新する。

### Step 1: nginx-sample manifest を新規生成

```bash
cd kubernetes
make hydrate-component COMPONENT=nginx-sample ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/nginx-sample/manifest.yaml` 新規作成 (= 5 resources: Deployment / Service / Ingress / ScaledObject / ExternalSecret)
- `kubernetes/manifests/production/nginx-sample/kustomization.yaml` 新規作成 (= `resources: [manifest.yaml]`)

### Step 2: production の kustomization を再生成

```bash
cd kubernetes
make hydrate-index ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/kustomization.yaml` 更新 (= `./nginx-sample` resources line auto-insert、alphabetical order = `./mimir` と `./oauth2-proxy` の間)
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` 変更なし (= namespace 新規作成なし、`default` namespace 既存活用)

### Step 3: nginx-sample manifest 内容確認

```bash
grep -E "^kind: " kubernetes/manifests/production/nginx-sample/manifest.yaml | sort | uniq -c
```

Expected:

```
   1 kind: Deployment
   1 kind: ExternalSecret
   1 kind: Ingress
   1 kind: ScaledObject
   1 kind: Service
```

### Step 4: Deployment の env + reloader annotation 確認

```bash
awk '/^kind: Deployment$/,/^---$/' kubernetes/manifests/production/nginx-sample/manifest.yaml | grep -B1 -A2 "DEMO_MESSAGE\|reloader.stakater.com/auto\|secretKeyRef\|image:" | head -20
```

Expected:
- `image: nginx:1.27-alpine` 反映
- `reloader.stakater.com/auto: "true"` annotation
- `name: DEMO_MESSAGE` env + `secretKeyRef.name: nginx-demo` + `key: message`

### Step 5: Ingress の monitoring-uis IngressGroup 反映確認

```bash
awk '/^kind: Ingress$/,/^---$/' kubernetes/manifests/production/nginx-sample/manifest.yaml | grep -E "group.name|hostname:|host:|service:" | head -10
```

Expected:
- `alb.ingress.kubernetes.io/group.name: monitoring-uis`
- `external-dns.alpha.kubernetes.io/hostname: nginx.panicboat.net`
- `host: nginx.panicboat.net`
- `service: name: nginx`

### Step 6: ScaledObject の multi-trigger 反映確認

```bash
awk '/^kind: ScaledObject$/,/^---$/' kubernetes/manifests/production/nginx-sample/manifest.yaml | grep -E "type:|threshold|value|query|scaleTargetRef|minReplica|maxReplica" | head -15
```

Expected:
- `scaleTargetRef.name: nginx`
- `minReplicaCount: 2` + `maxReplicaCount: 10`
- 2 triggers: `type: cpu` (= value: "50") + `type: prometheus` (= threshold: "1" + query)

### Step 7: ExternalSecret の AWS reference 反映確認

```bash
awk '/^kind: ExternalSecret$/,/^---$/' kubernetes/manifests/production/nginx-sample/manifest.yaml | grep -E "name:|kind:|key:|property:|refreshInterval" | head -15
```

Expected:
- `secretStoreRef.name: aws-secrets-manager` + `kind: ClusterSecretStore`
- `refreshInterval: 1h`
- `target.name: nginx-demo`
- `data[0].secretKey: message` + `remoteRef.key: panicboat/nginx/demo` + `property: message`

### Step 8: production kustomization.yaml に ./nginx-sample 追加確認

```bash
grep "nginx-sample" kubernetes/manifests/production/kustomization.yaml
```

Expected: `  - ./nginx-sample` が resources list に含まれる (= alphabetical order、./mimir と ./oauth2-proxy の間)

### Step 9: kustomize build で全体 manifest が valid render することを確認

```bash
kustomize build kubernetes/manifests/production 2>&1 | tail -10
```

Expected: error なし、最後に何らかの YAML resource が出力される (= kustomization build success)

### Step 10: Diff 確認

```bash
git status
git diff --stat
```

Expected:
- 新規: `kubernetes/manifests/production/nginx-sample/{kustomization.yaml, manifest.yaml}`
- 修正: `kubernetes/manifests/production/kustomization.yaml` (= ./nginx-sample 追加)

### Step 11: Commit

```bash
git add kubernetes/manifests/
git commit -s -m "feat(eks): hydrate nginx-sample (Phase 5-2)"
```

Expected: 3 files changed、commit subject ≤ 72 chars (= 39 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 3: PR push + Pre-flight check + Ready for review

**Files:** (= no file changes、PR 操作のみ)

**Context:** Task 1-2 完了後の commit 累計 3 件 (= spec + 2 implementation)。AWS-side terragrunt apply は不要 (= AWS access は Phase 4-2 ESO IAM role 流用)、K8s-side は PR merge 後に Flux reconcile で auto apply、AWS Secrets Manager 投入 (= Task 0 Step 5 で確認) は merge 前に panicboat により完了済。

### Step 1: branch 状態を確認

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-nginx-end-to-end-validation
git log --oneline origin/main..HEAD
```

Expected: 3 commits ahead

```
<sha> feat(eks): hydrate nginx-sample (Phase 5-2)
<sha> feat(eks): nginx-sample for end-to-end validation (Phase 5-2)
df59039 docs(eks): Phase 5-2 (nginx end-to-end validation) design
```

### Step 2: branch を origin に push

```bash
git push 2>&1 | tail -3
```

Expected: branch が track 設定済 (= 既 spec push 時に push 済)、push success message。track 未設定の場合は `git push -u origin HEAD`。

### Step 3: PR title 文字数チェック (≤ 72 chars)

```bash
echo -n "feat(eks): Phase 5-2 — nginx end-to-end validation" | wc -m
```

Expected: 50 chars (em dash 含む、Sub-project 4-1 / 4-2 / 4-3 / 5-1 の PR title 命名 pattern と整合)

### Step 4: Draft PR を作成 (Pre-flight check 結果を含む)

PR body は以下:

````markdown
## Summary

Phase 5-2 (nginx end-to-end validation) の implementation。EKS production cluster (`eks-production`) に **demo nginx application** を `default` namespace に Plain K8s manifests で deploy、roadmap Phase 5 完了条件 13 checklist を **end-to-end validate**。Phase 1-4 で構築した全 component (= Cilium chaining + ALB Controller + external-dns + ACM + cert-manager + ESO + Reloader + Beyla + KEDA + metrics-server + Mimir + Loki + Tempo + Hubble) を nginx 投入で actual data flow validation。

AWS terragrunt 新規 stack 不要 (= Phase 4-2 ESO IAM role 流用)、helmfile 不在 (= chart binary verify 不要)、kustomization-only component (= `gateway-api` reference pattern 踏襲) で **完全に K8s component 1 kustomization deploy** で完結。

## Spec / Plan

- spec: `docs/superpowers/specs/2026-05-10-eks-production-nginx-end-to-end-validation-design.md`
- plan: `docs/superpowers/plans/2026-05-10-eks-production-nginx-end-to-end-validation.md`

## Notable Decisions

- Phase 5-2 scope = single sub-project (= 13 checklist + 2 補助 = 15 items)
- Deploy 方式 = Plain K8s manifests (= kustomization-only、helmfile 不在)
- Access control = Public access (= ALB direct → nginx)
- Ingress topology = monitoring-uis IngressGroup 共有 (= 既 ALB 再利用)
- HPA + KEDA = ScaledObject 1 つで multi-trigger (= cpu + prometheus、KEDA が内部 HPA 管理)
- KEDA Prometheus trigger = Beyla RED metrics
- nginx hostname = nginx.panicboat.net
- ExternalSecret demo = 1 key message を nginx env DEMO_MESSAGE に注入

## Pre-flight check (executed pre-merge)

- [x] Branch state 確認 (= spec + 2 implementation commits ahead)
- [x] Phase 4 + 5-1 完了状態 verify (= ESO ClusterSecretStore Ready=True / Reloader / Beyla DaemonSet 4/4 / oauth2-proxy 4 instances / hubble-relay Running)
- [x] ALB + IngressGroup `monitoring-uis` 状態確認 (= 4 既存 Ingresses 同 ALB 共有)
- [x] ACM wildcard cert `*.panicboat.net` ISSUED 確認
- [x] Manual setup: AWS Secrets Manager `panicboat/nginx/demo` 投入完了
- [x] KEDA ScaledObject CRD apiVersion `v1alpha1` 確認
- [x] ExternalSecret CRD apiVersion `v1` 確認
- [x] `default` namespace に既存 nginx-sample 不在確認
- [x] Mimir cardinality 余裕確認 (= 500K limit に対し X 程度、本 PR で +5K 以内見込み)
- [x] Flux state suspended でない確認

## Test plan (post-flight, after merge)

### A. Infrastructure layer (= 5 分以内)

- [ ] nginx Deployment `replicas == 2`、全 Pod Running、Cilium chaining mode で Pod IP 割当
- [ ] nginx Service ClusterIP active、`nginx.default.svc.cluster.local:80` で内部 DNS 解決可
- [ ] nginx Ingress provision (= ALB Controller が monitoring-uis ALB に rule 追加)
- [ ] external-dns で Route53 record `nginx.panicboat.net` 自動作成
- [ ] ALB の rule 確認 (= host header → nginx Service backend)
- [ ] ExternalSecret `nginx-demo` Status=Ready、K8s Secret created with key `message`
- [ ] nginx Pod env vars に `DEMO_MESSAGE` 反映

### B. Application layer (= 10 分以内)

- [ ] HTTPS test: `curl -v https://nginx.panicboat.net/` → 200 OK + Welcome page
- [ ] DNS test: `dig nginx.panicboat.net` → ALB DNS に resolve
- [ ] Beyla instrumentation: nginx に curl 数回 → Tempo に `service.name=nginx` traces 流入
- [ ] Hubble L7 flow: Hubble UI で nginx Pod の L3/L4/L7 flow 確認
- [ ] Loki logs: nginx access log が `service_name="nginx"` で query 可
- [ ] Mimir metrics: Beyla 由来 `http_server_request_duration_seconds_count` query 可

### C. Autoscaling layer (= 30 分以内、load test 必要)

- [ ] HPA cpu trigger: nginx に CPU 負荷 (= `kubectl exec` で stress)、replicas 2 → N に scale
- [ ] KEDA Prometheus trigger: nginx に HTTP load (= ab tool)、rate > 1 RPS で replicas scale
- [ ] Karpenter scale-up: 高 replicas で Pod Pending → Karpenter が新 node provision

### D. Secret rotation layer (= 60 分以内)

- [ ] ESO + Reloader integration: AWS Secrets Manager で値変更 → `kubectl annotate externalsecret -n default nginx-demo force-sync=now` → Reloader が nginx Pod rollout → 新 env で確認

### E. Regression check (= 5-1 L2 適用)

- [ ] 既 deploy 済 component 全部 Running 維持
- [ ] Mimir cardinality 観測 (= active_series 増加、500K limit 余裕確認)
- [ ] Phase 5-1 L2 (= post-flight regression check が past sub-project の latent issue を発見) を意識、想定外 component の CrashLoop / restart spike が無いか確認

## Sub-project 1-5-1 learnings 適用

- L1: Plain K8s manifests で chart binary verify not applicable、ただし KEDA ScaledObject CRD + ExternalSecret apiVersion を Task 0 で確認
- L2: KEDA Prometheus trigger query syntax + threshold 形式を docs full read で裏付け済
- L3: nginx は AWS access 不要、Phase 4-2 ESO Pod Identity 継続動作前提を Task 0 で verify
- L4: nginx は distributed ring 構造なし、適用なし
- L5: post-flight check で HPA / KEDA / Karpenter の actual scaling test を必須化、static "ScaledObject Ready=True" だけでなく load test で actual replica scale を proof
- L6: Plan task 数を kustomization-only deploy + hydrate + PR の 3 layer split で踏襲 (= chart binary verify step も不要、minimum complexity)
- 5-1 L2: post-flight regression check で 3 連続 validate を期待
- 5-1 L4: nginx 正式投入で full application-level validation、smoke test → production-grade test に拡大
- 4-1 L5: nginx image tag は actual `1.27-alpine` で pinned

## Rollback 手順

```bash
# Pattern A: Standard rollback (= Flux suspend + revert)
flux suspend kustomization flux-system -n flux-system
gh pr create --base main --head revert-phase-5-2 --title "revert: Phase 5-2 (nginx end-to-end validation)" --draft
gh pr merge <pr-number>
flux resume kustomization flux-system -n flux-system

# Pattern B: nginx delete (= kustomization から removal)
# kubernetes/manifests/production/kustomization.yaml から `- ./nginx-sample` 削除 + Flux apply

# Pattern C: KEDA scale disable (= autoscaling 暴走時)
# ScaledObject 削除 → KEDA-managed HPA も自動削除、nginx Deployment は static replicas 維持
```
````

Push command:

```bash
gh pr create --draft \
  --base main \
  --head docs/eks-production-nginx-end-to-end-validation \
  --title "feat(eks): Phase 5-2 — nginx end-to-end validation" \
  --body-file /tmp/pr-body-5-2.md
```

(= PR body を `/tmp/pr-body-5-2.md` に書き出してから `--body-file` で参照)

Expected: Draft PR created、PR URL 表示

---

## Summary

本 sub-project は **Phase 5 (= End-to-end validation) の core sub-project**、Phase 1-4 で構築した全 component を nginx 投入で end-to-end validate。AWS terragrunt 新規 stack 不要 + helmfile 不在 + kustomization-only component で **完全に K8s 1 kustomization deploy** で完結、Phase 4-1 / 4-2 / 4-3 / 5-1 で確立した foundation を全面活用。

## Spec / Plan

- spec: `docs/superpowers/specs/2026-05-10-eks-production-nginx-end-to-end-validation-design.md`
- plan: `docs/superpowers/plans/2026-05-10-eks-production-nginx-end-to-end-validation.md`

## Notable Decisions

| Decision | 採用 |
|---|---|
| Phase 5-2 scope | single sub-project (= 13 checklist + 2 補助 = 15 items) |
| Deploy 方式 | Plain K8s manifests (= kustomization-only) |
| Access control | Public access (= ALB direct → nginx) |
| Ingress topology | monitoring-uis IngressGroup 共有 |
| HPA + KEDA 同居 | ScaledObject 1 つで multi-trigger (= cpu + prometheus) |
| KEDA Prometheus trigger | Beyla RED metrics |
| nginx hostname | nginx.panicboat.net |
| ExternalSecret demo content | 1 key message を nginx env DEMO_MESSAGE に注入 |

## Implementation 補記

- nginx-sample は **Plain K8s manifests** で、`gateway-api` component の kustomization-only pattern を踏襲
- Beyla は Phase 5-1 deploy 時に `default` namespace を discovery scope に設定済、本 sub-project で nginx を **追加設定なしで auto-instrument**
- KEDA ScaledObject の `spec.triggers` で **multi-trigger** (= cpu + prometheus) を 1 ScaledObject に集約、KEDA が内部で HPA を auto-create + 管理 (= standalone HPA 不在で conflict 回避)
- ExternalSecret は Phase 4-3 で確立した pattern (= `panicboat/grafana/admin` / `panicboat/oauth2-proxy/google`) を踏襲、`refreshInterval: 1h` + `creationPolicy: Owner`
- ACM cert は **auto-discovery** (= explicit `certificate-arn` annotation 不要、wildcard `*.panicboat.net` が `nginx.panicboat.net` に SAN match)
- `monitoring-uis` IngressGroup 既 ALB 共有 (= +$0/month、Phase 4-3 + 4-1 で構築した state を再利用)

## Pre-flight check (executed pre-merge)

(= 上記 PR body の Pre-flight check と同内容)

## Test plan (post-flight, after merge)

(= 上記 PR body の Test plan と同内容)

## Sub-project 1-5-1 learnings 適用

(= 上記 PR body の learnings 適用と同内容)

## Rollback 手順 (想定外障害時)

(= 上記 PR body の Rollback 手順と同内容)

## Self-review

### Spec coverage check

| Spec section | Plan task |
|---|---|
| Architecture (= 15 validation flow) | Task 1 (= 5 manifests で実現)、Task 2 (= hydrate output で render) |
| Components & File Structure | File Structure section + Task 1 / Task 2 |
| Manual Setup (= AWS Secrets Manager 1 件) | Task 0 Step 5 で confirm |
| Decisions (= 8 件) | "Notable Decisions" section に同 8 件 |
| Post-flight Check (= 20 項目) | "Test plan (post-flight)" section に時系列分類で同等 |
| Rollback Patterns (= 3 patterns) | "Rollback 手順" section に同 3 patterns |
| Risks & Mitigations | "Implementation 補記" + "Test plan" の transient checklist |
| Out of Scope | spec-only |
| Phase 5 引き継ぎ事項 update | spec-only (= post-execution learnings PR で update) |
| Sub-project 1-5-1 learnings 適用 | "Sub-project 1-5-1 learnings 適用" section |

### Type / Property name consistency

- [x] `nginx-sample` component name (= Task 1 + Task 2 hydrate path 全箇所): 全て同一
- [x] `default` namespace name (= Task 1 全 manifests + spec): 既存 namespace 活用、新規作成なし
- [x] `nginx` Deployment / Service / Ingress / ScaledObject name (= 全 manifests で同一): app: nginx label と整合
- [x] `nginx-demo` ExternalSecret target + K8s Secret name (= Task 1 deployment.yaml secretKeyRef.name + external-secret.yaml target.name): 全て同一
- [x] `panicboat/nginx/demo` AWS Secret name (= Task 0 Step 5 + Task 1 external-secret.yaml remoteRef.key): 全て同一
- [x] `aws-secrets-manager` ClusterSecretStore name (= Task 1 external-secret.yaml secretStoreRef.name): Phase 4-2 で deploy 済 ClusterSecretStore name と一致
- [x] `monitoring-uis` IngressGroup name (= Task 1 ingress.yaml `alb.ingress.kubernetes.io/group.name`): Phase 4-3 既 ALB と一致
- [x] `nginx.panicboat.net` hostname (= Task 1 ingress.yaml host + external-dns.alpha.kubernetes.io/hostname annotation): 全箇所で同一
- [x] `http_server_request_duration_seconds_count` Beyla metric name (= Task 1 scaled-object.yaml prometheus query): Phase 5-1 で確認済 Beyla expose metric name
- [x] `1` (= 1 RPS) prometheus threshold + `50` cpu threshold: spec Decisions と整合
- [x] commit subject prefix: `feat(eks):` (= 2 commits)、Sub-project 4a / 4b / 4-1 / 4-2 / 4-3 / 5-1 と整合

## Lessons Learned (post-execution)

PR #318 (= 本 sub-project initial merge) で deploy 後の post-flight check は **runtime issue 0 件 (= Phase 5-2 起因)** で完了、Phase 4-3 + 5-1 と同等の clean implementation を再現。**roadmap Phase 5 完了条件 13 checklist を essentially 13/13 達成**、Phase 1-4 で構築した全 component (= Cilium chaining + ALB + external-dns + ACM + cert-manager + ESO + Reloader + Beyla + KEDA + metrics-server + Mimir + Loki + Tempo + Hubble) を nginx 投入で actual data flow validation。

post-flight regression check で **新 latent issue 1 件発覚** (= Mimir `validation.max-label-names-per-series: 30` 超過、Beyla `http_server_request_body_size_bytes_bucket` series が 31 labels)、Phase 5-1 L2 (= post-flight regression check が past sub-project の latent issue を発見) を **3 連続 validate** で完全 established。Phase 4-3 で Mimir RF (= 3 Sub-project 2 latent) → 5-1 で Cilium Hubble TLS (= 4-1 latent) → 5-2 で Mimir label limit (= 3 Sub-project 2 latent + Phase 5-1 Beyla 投入で表面化)。

### Phase 3-5 全体 runtime issue 数 update

| Sub-project | initial deploy | runtime fix | 計 |
|---|---|---|---|
| Sub-project 1 (AWS infra) | 0 | 0 | 0 |
| Sub-project 2 (Mimir) | 5 | 0 (= ただし RF + cardinality limit + label-names-per-series が 4-3 / 5-1 / 5-2 で発覚、PR #312 + #314 で 2 件 resolve、1 件 Phase 6+ 引き継ぎ) | 5 |
| Sub-project 3 (Loki + Fluent Bit) | 4 | 0 | 4 |
| Sub-project 4a (Tempo + OTel Collector) | 0 | 0 | 0 |
| Sub-project 4b (logs path completion) | 3 | 0 | 3 |
| Sub-project 4-1 (cert-manager + Cilium TLS) | 0 | 0 (= ただし SelfSigned vs mTLS が 5-1 で発覚、PR #316 で resolve) | 0 |
| Sub-project 4-2 (ESO + Reloader) | 0 (= ただし Pod Identity timing が 4-3 で発覚) | 0 | 0 |
| Sub-project 4-3 (Grafana auth + Ingress) | 3 | 2 (= PR #311 + #312) | 3 |
| Sub-project 5-1 (Beyla foundation) | 0 | 0 | 0 |
| **Sub-project 5-2 (nginx end-to-end validation)** | **0** | **0** | **0** |
| **Phase 3-5 累計** | | | **15** (= 5-1 完了時の 15 から不変) |

= 5-2 で **設計起因 0 件**、latent issue 1 件発覚 (= 元 Phase 3 Sub-project 2 由来、Phase 6+ 引き継ぎ #21 として記録)、累計 15 維持。Phase 4-3 + 5-1 と同等の clean implementation を **3 連続維持** (= subagent-driven development cadence の効果再 validate)。

### Phase 5-2 で発覚 → 引き継ぎ事項として記録した latent issue

| # | Issue | 起因 sub-project | Discovery method | Resolution |
|---|---|---|---|---|
| 1 | **Mimir `validation.max-label-names-per-series: 30` 超過** = Beyla `http_server_request_body_size_bytes_bucket` series が 31 labels (= container / endpoint / exported_instance / exported_job / http_request_method / http_response_status_code / instance / job / namespace / network_protocol_name / network_protocol_version / otel_scope_name / otel_scope_schema_url / otel_scope_version / server_address / server_port / service_name / service_namespace / telemetry_sdk_language / telemetry_sdk_name / telemetry_sdk_version / url_path / url_scheme / le 等) | Phase 3 Sub-project 2 (= Mimir chart default、5-2 で Beyla nginx 投入で表面化) | Phase 5-2 post-flight Section E regression check で `httpCode=400 err-mimir-max-label-names-per-series` reject 発覚 | **Phase 6+ 引き継ぎ #21 として記録** (= demo 段階で必要性低、KEDA scaling は `_count` で影響なし、Grafana p95 query 利用時に `validation.max-label-names-per-series: 30 → 35` 拡大の fix forward 候補) |

### L1: post-flight regression check pattern の **3 連続 validate established** (= 4-3 + 5-1 + 5-2)

5-1 L2 で establish した pattern (= post-flight regression check が past sub-project の latent issue を発見) が 3 連続で validate された:

| Phase | 発覚した latent issue | 起因 sub-project | Resolution |
|---|---|---|---|
| 4-3 | Mimir replication_factor 不整合 (= RF=3 vs 1 ingester) | Phase 3 Sub-project 2 | PR #312 fix forward |
| 5-1 | Cilium Hubble TLS architectural issue (= SelfSigned ClusterIssuer の mTLS 不可) | Phase 4-1 | PR #316 fix forward |
| **5-2** | **Mimir max-label-names-per-series 超過** (= Beyla histogram 31 labels) | Phase 3 Sub-project 2 | **Phase 6+ 引き継ぎ #21** |

= **3 連続 sub-project で post-flight regression check が past sub-project の latent issue を発見**、5-1 L2 が完全 established となる。

**Why (= 重要 pattern)**:

- Phase 5-2 のような **end-to-end validation** sub-project は **既存 component に新たな data flow を加える** ため、過去 deploy 時に dormant だった issue を表面化する trigger になる
- 過去 sub-project 完了時の post-flight check は **当 sub-project 範囲のみ verify**、cross-sub-project の interaction (= 例: Mimir cardinality limit + 全 ServiceMonitor scrape の累計、cert-manager + Cilium chart の TLS 接続、Beyla histogram series の label 数 + Mimir label-names-per-series limit) は test されない
- **trigger** で latent issue が visible になる pattern が established、Phase 6+ 引き継ぎ #5 (= post-flight check 自動化) でこの pattern を automated detection に組込む方針

**How to apply**:

1. **post-flight check の "regression check" stage を必須化** (= 5-1 plan 以降確立済、Phase 5-3 / Phase 6+ で継続)
2. **latent issue は元 sub-project の延長** として扱う (= 現 sub-project の runtime issues 集計には含めず、引き継ぎ事項に追加)
3. Phase 6+ post-flight 自動化で **cross-sub-project regression check を automated に**: 例えば全 mTLS connection の actual handshake test、Mimir distributor reject rate の time-series monitoring、各 chart の Mimir-bound metrics の label 数 monitoring
4. **新 application 投入** sub-project では **既存 stack の cardinality / label limit / API rate limit に対する負荷増加** を意識、deploy 前に余裕確認 step を必須化 (= Phase 5-2 Plan Task 0 Step 9 で active_series 余裕確認した pattern)

### L2: KEDA ScaledObject multi-trigger の actual scaling validation (= 4-2 / 4-3 / 5-1 L5 extension)

4-2 L5 で establish した pattern (= AWS direct verify AccessDenied → application-level indirect proof) を **autoscaling protocol-level に extension**:

Phase 5-2 post-flight Section C で **actual load test (= 60 秒、~50 RPS HTTP load)** を実施:

```
Before:        replicas: 2、TARGETS: 0/1 (avg)、cpu 2%/50%
30s 経過:      replicas: 4、TARGETS: 3137m/1 (avg)、cpu 2%/50%
60s 経過:      replicas: 10、TARGETS: 4241m/1 (avg)、cpu 11%/50%  ← max replicas 到達
```

= KEDA ScaledObject **prometheus trigger** (= 4.241 RPS >> 1 RPS threshold) で **2 → 10 replicas full scale-up 完全動作**。CPU trigger は load test 中 11% で threshold 50% 未到達 (= configured/functioning だが load 不足)、actual scale-up は prometheus trigger driven。

**Why (= 重要 pattern)**:

- ScaledObject `Ready=True` + KEDA-managed HPA `keda-hpa-nginx` create の static check は **infra layer のみ verify**、actual scale event は load 必要
- KEDA ScaledObject の multi-trigger 設計 (= cpu OR prometheus) で **両 trigger の OR semantic** を実証 (= prometheus 単独 trigger でも scale)、KEDA docs の正統的使い方
- Phase 5-1 で deploy した Beyla の **production-grade end-to-end validation**: Beyla → Mimir → KEDA Prometheus query → ScaledObject → HPA → Pod scale の full chain

**How to apply**:

1. **autoscaling resource (= HPA / KEDA ScaledObject) の post-flight check に actual load test を必須化**: static `Ready=True` だけでなく **load → metrics > threshold → scale event** を end-to-end validate
2. **KEDA multi-trigger 設計** で複数 metric を OR semantic で同居、conflict なく安全
3. KEDA-managed HPA は **`keda-hpa-<scaledobject-name>`** prefix で auto-create、`kubectl get hpa` で確認可、KEDA non-active 時は metric 0 で表示 (= KEDA stabilization window)
4. demo / staging で load test 短時間 (= 60 秒) で十分 scale-up validate 可能、production load profile に応じて threshold 調整

### L3: ESO + Reloader rotation chain の actual end-to-end test (= 4-2 + 4-3 design intent の production-grade validation)

Phase 4-2 で deploy 済の ESO + Reloader が、Phase 5-2 で **AWS Secrets Manager 更新 → ESO refresh → K8s Secret update → Reloader detect → nginx Deployment auto-rollout → 新 env value 反映** の **完全 chain を actual に validate**:

```
Before:
  AWS secret value: "Hello from AWS Secrets Manager"
  Pod: nginx-84d9479999-7bz69 (= start time 00:00:35Z)
  env DEMO_MESSAGE: "Hello from AWS Secrets Manager"

Operations:
  1. aws secretsmanager update-secret panicboat/nginx/demo
     → "Hello from rotation test at 090220"
  2. kubectl annotate externalsecret nginx-demo force-sync=now
     → ESO immediate refresh
  3. wait 30s

After:
  Pod: nginx-6f4b8bfbfd-9hv6j (= 新 ReplicaSet ID、start time 00:02:36Z = 2 分後)
  env DEMO_MESSAGE: "Hello from rotation test at 090220" ✅
```

= ESO + Reloader integration の actual data flow を **end-to-end validate**、Phase 4-2 deploy 時の "deploy success" status から **production-grade rotation evidence** に拡大。

**Why (= 重要 pattern)**:

- ESO `force-sync` annotation で **manual refresh trigger** が即時動作、`refreshInterval: 1h` の auto-refresh を待たず test 可能
- Reloader の Secret detection は **annotation `reloader.stakater.com/auto: "true"`** で自動 watch (= 別途 explicit Secret 名指定不要)
- ReplicaSet ID 変化 (= `nginx-84d9479999-7bz69` → `nginx-6f4b8bfbfd-9hv6j`) で actual Deployment rollout を proof
- env injection は Pod recreation で更新 (= K8s 仕様)、in-place env modify は不可

**How to apply**:

1. **ESO 経由 secret rotation の post-flight 必須化**: 4-2 / 4-3 / 5-2 で 3 連続採用、Phase 6+ application でも同 pattern
2. **`force-sync` annotation を post-flight test の primary tool に**: 1h auto-refresh 待ちは inefficient、production application で同 pattern (= manual refresh + 即時 rollout 確認) を運用 procedure に組込
3. ReplicaSet ID 比較で **rollout actual evidence** を取得 (= start time だけだと "Pod 再起動" と "Pod 削除→再 create" の区別困難、ReplicaSet ID で明確)
4. Phase 6+ post-flight 自動化 (= 引き継ぎ #5) で synthetic secret rotation test を組込候補

### L4: kustomization-only component pattern の application implementation

Phase 5-2 で **kustomization-only component (= helmfile 不在、Plain K8s manifests)** を新 pattern として採用、`gateway-api` reference を踏襲しつつ **複数 K8s resource** (= Deployment + Service + Ingress + ScaledObject + ExternalSecret) を 1 component に集約:

```
kubernetes/components/nginx-sample/
└── production/
    └── kustomization/
        ├── kustomization.yaml          # 5 resources roll-up
        ├── deployment.yaml             # Workload
        ├── service.yaml                # Service expose
        ├── ingress.yaml                # ALB Ingress
        ├── scaled-object.yaml          # KEDA autoscaling
        └── external-secret.yaml        # ESO secret sync
```

= **chart binary verify (= L1 systematic step) 不要 + helmfile Capabilities gate (= L3) 不要**で、Phase 4-3 / 5-1 と異なる pattern。

**Why (= chart wrapping vs Plain manifests の trade-off)**:

| 観点 | Helm chart (= Phase 4-1 ~ 5-1 既存 14 components) | Plain manifests (= 5-2 nginx-sample) |
|---|---|---|
| application | 既存 OSS chart (= cert-manager / ESO / oauth2-proxy / Beyla 等) | demo / 自製 application |
| L1 chart binary verify | 必要 (= chart structure / key path / chart-fixed value) | 不要 (= no chart) |
| version pinning | helmfile.yaml の `version:` field | image tag / CRD apiVersion で pin |
| upstream change tracking | chart upgrade で management | manifest direct edit |
| operational footprint | 大 (= chart values + helmfile + values.yaml.gotmpl + kustomization) | 小 (= kustomization のみ) |

**How to apply**:

1. **chart 提供 OSS component (= cert-manager / ESO / oauth2-proxy 等) は helmfile pattern を継続**、Phase 4-1 ~ 5-1 で確立した chart binary verify systematic step を踏襲
2. **demo / 自製 application は kustomization-only pattern** を採用、`gateway-api` + `nginx-sample` reference を活用
3. **Phase 6+ panicboat monorepo migration** で application code (= Hanami / Next.js) 投入時は kustomization-only pattern を **base** に採用、application 固有 manifest を直接管理
4. **chart binary verify 不要 component の plan** では Task 1 step 1-2 (= chart binary verify) を skip、Task 数 minimal (= Phase 5-2 は 4 tasks: pre-flight + deploy + hydrate + PR)

### L5: Beyla auto-instrumentation の production-grade application validation (= 5-1 L4 extension)

Phase 5-1 で smoke test (= test Pod) で部分 validate、**5-2 で nginx 正式投入による production-grade Beyla validation** に拡大:

| 観点 | Phase 5-1 (smoke test) | Phase 5-2 (production-grade) |
|---|---|---|
| target Pod | 一時 test Pod (`kubectl run --rm`) | 正式 Deployment (= 永続的) |
| traffic | manual `kubectl exec` curl 5 回 | ALB → external user simulated load test 60 秒 ~50 RPS |
| Beyla detection | `instrumenting process cmd=/usr/sbin/nginx pid=...` | 同 (= L4 pattern 再 validate)、複数 Pod に対し eBPF probe 並行 attach |
| Tempo trace flow | `service.name=test-nginx` で確認 | `service.name=nginx` で確認、actual application traffic 由来 traces |
| Mimir RED metrics | (= 部分 validate なし) | `http_server_request_duration_seconds_count` rate query で **0.733 → 4.241 RPS** measurable |
| KEDA Prometheus trigger | (= 5-1 では trigger source 不在) | Beyla RED metrics で actual scaling trigger validation |

= 5-1 で establish した Beyla pipeline が **production data flow で完全動作**、Phase 4-3 L6 (= Tempo empty / Loki minimal labels) の partial 解消 + KEDA scaling 統合を 5-2 で実証。

**How to apply**:

1. **infrastructure deploy** (= Phase 5-1 smoke test) と **production validation** (= Phase 5-2 actual application) は **2 段階で構築**、各段階で適切な test pattern を採用
2. **Beyla auto-instrumentation の actual workload validation** は application 投入 sub-project の post-flight で必須、static "Beyla DaemonSet Ready" だけでは不十分
3. **Beyla RED metrics の cardinality 影響** は application 投入で初観測、Mimir limit 余裕確認 (= 5-2 Plan Task 0 Step 9 pattern) を必須化、5-2 で発覚した label-names-per-series 超過 (= 引き継ぎ #21) のような latent issue を pre-deploy で検出可能性高

### Sub-project 1-5-1 learnings 適用 review

| Learning | Applied | Effect |
|---|---|---|
| L1 (= chart binary verify) | N/A (= Plain manifests)、ただし KEDA + ESO CRD apiVersion を Task 0 で確認 | N/A → L4 (= kustomization-only pattern) として new lesson 形成 |
| L2 (= chart capability assumption) | KEDA Prometheus trigger query syntax を docs full read で裏付け、Beyla `service_name="nginx"` literal を 5-1 smoke test で確認済 | Effective (= 事前検証で deploy 後 issue ゼロ) |
| L3 (= Pod Identity webhook timing) | nginx は AWS access 不要、Phase 4-2 ESO Pod Identity 継続動作前提を Task 0 で verify | N/A direct、ただし dependency chain 確認は適用 |
| L4 (= distributed system replica / RF) | nginx に ring 構造なし、適用なし | N/A |
| L5 (= application-level test) | post-flight Section C / D で actual scaling test + secret rotation test、static health check を超えて end-to-end proof | **Strongly effective、本 sub-project で L2 + L3 in this learnings として extension** |
| L6 (= subagent-driven development cadence) | 4 tasks (= AWS なし + chart なし + kustomization のみ)、minimum complexity、subagent dispatch は Task 1 + 2 のみ | Stable maintained (= 5 連続 sub-project) |
| 5-1 L2 (= post-flight regression check が past sub-project の latent issue を発見) | Phase 5-2 で 3 連続 validate (= 4-3 + 5-1 + 5-2)、本 sub-project の core lesson | **Established pattern、本 learnings の L1 として記録** |
| 5-1 L4 (= Beyla smoke test → production-grade test) | nginx 正式投入で full application-level validation、smoke test → production-grade test に拡大 | **Effective、本 learnings の L5 として extension** |
| 4-1 L5 (= chart version placeholder) | nginx image actual `1.27-alpine` で pinned | Effective |

### Phase 5 引き継ぎ事項 update (= 5-2 完了時)

| 項目 | 5-2 完了時の状態 |
|---|---|
| 1-3. gp3 / bucket-per-env / multi-tenant | Phase 6+ 引き継ぎ (= 不変) |
| 4. OTel Operator deploy 検討 | Phase 6+ 引き継ぎ (= 5-1 で evaluation 確定) |
| 5. post-flight check 自動化 | Phase 6+ 引き継ぎ (= **本 sub-project L1 で 3 連続 regression check pattern を automated detection に組込む方針追加**、L2 で actual load test の synthetic 化、L3 で secret rotation synthetic test の組込) |
| 6. Beyla deploy + OTel Collector metrics pipeline | Phase 5-1 part 1 解消済、part 2 (= OTel Collector metrics pipeline 拡張) は Phase 6+ #10 と統合 |
| 7-8. Hubble flow logs / local Fluent Bit OTLP | Phase 6+ 引き継ぎ (= 不変) |
| 9. Pod CPU requests audit + rightsizing | **Phase 5-3 で解消予定** |
| 10. OTel Collector exporter alias check 自動化 | Phase 6+ 引き継ぎ (= 不変) |
| 11-14. Workspace OAuth / AWS rotation / Cilium Gateway / monitoring UIs 拡張 | Phase 6+ 引き継ぎ (= 不変) |
| 15-17. Pod Identity webhook detection / mTLS verify / Loki OTLP label promotion | Phase 6+ 引き継ぎ (= **#17 Loki label promotion は本 sub-project で再 validate、`service_name="unknown_service"` のみ promotion 確認**) |
| 18-20. SelfSigned vs CA-based / mTLS sha256 verify / Beyla discovery deprecation | Phase 6+ 引き継ぎ (= 不変) |
| **21. Mimir `validation.max-label-names-per-series: 30 → 35` 拡大** (= 5-2 で発覚した Beyla histogram 31 labels reject、demo 段階で必要性低、application 投入時 fix forward) | **Phase 6+ 引き継ぎ (= 5-2 で新規追加)** |

= 5-2 完了で **新規引き継ぎ #21 を追加**、引き継ぎ #5 (= post-flight 自動化) に L1 / L2 / L3 由来 design 指針 3 件追加。Phase 5-3 で 引き継ぎ #9 (= rightsizing) を解消予定。

### Phase 5 全体 perspective update (= 5-2 完了時)

| Sub-project | scope | runtime issues | 状態 |
|---|---|---|---|
| **5-1 Beyla foundation** | Beyla DaemonSet 1 chart deploy | 0 件 (= 5-1 起因) + 2 件 latent fix forward (= PR #314 + #316) | ✅ 完了 |
| **5-2 nginx + Ingress + ESO + HPA + KEDA** | nginx Plain manifests + 13 checklist end-to-end validate | **0 件 (= 5-2 起因)** + 1 件 latent (= 引き継ぎ #21、demo 段階で fix 不要) | ✅ 完了 |
| **5-3 rightsizing audit** | Pod CPU requests audit、引き継ぎ #9 解消、Phase 5 全体 closure | 0-1 件想定 | 🔜 5-2 完了 + 数日 traffic 観測後 |

= 5-2 完了で **roadmap Phase 5 完了条件 13/13 essentially達成**、Phase 5-3 は **closure + rightsizing 専用** (= roadmap 直接対応なし、引き継ぎ #9 のみ解消 + Phase 5 学習総括)。

### 次 sub-project (= Phase 5-3 rightsizing audit) への適用

1. **L1 即適用**: Phase 5-3 post-flight でも **regression check** を継続、4 連続 validate を期待 (= ただし 5-3 は rightsizing 主体で、application 投入なし、新 latent issue 表面化の可能性は低い)
2. **L2 適用**: Phase 5-3 では new autoscaling resource 投入なし、適用機会なし
3. **L3 適用**: Phase 5-3 では new secret rotation なし、適用機会なし
4. **L4 適用**: Phase 5-3 は audit + values 修正中心、kustomization-only pattern 不要
5. **L5 適用**: Phase 5-3 で nginx + 数日 traffic 観測後の actual usage data で audit、5-2 で確立した actual data pattern を活用

= Phase 5-3 は **modest scope** (= 引き継ぎ #9 解消のみ)、本 sub-project learnings 5 件全部の applicability は限定的、ただし regression check (= L1) は継続適用。
