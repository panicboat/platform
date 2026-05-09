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
