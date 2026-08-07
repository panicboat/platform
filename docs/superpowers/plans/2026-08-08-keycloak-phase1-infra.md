# Keycloak Phase 1 Infra Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Keycloak + its CloudNativePG-managed PostgreSQL backend onto the `eks-production` cluster (platform repo only), reachable at `https://auth.dystopia.city`, ending in a Draft PR ready for review.

**Architecture:** Two new `kubernetes/components/` entries following the existing helmfile-hydration pattern: `cloudnative-pg` (shared PostgreSQL operator, Helm release only) and `keycloak` (Helm release for `codecentric/keycloakx` + a `kustomization/` overlay for the chart-external resources: CNPG `Cluster` CR, admin-credential `ExternalSecret`, and `Ingress`). No monorepo changes, no realm/client creation, no RDS.

**Tech Stack:** Helm / Helmfile / Kustomize (aqua-pinned), CloudNativePG operator, `codecentric/keycloakx` Helm chart, External Secrets Operator, AWS ALB Ingress Controller, Flux (GitOps apply on merge to `main`).

## Global Constraints

- Chart `codecentric/keycloakx` version `7.2.2` (app Keycloak `26.6.4`), repo `https://codecentric.github.io/helm-charts`
- Chart `cnpg/cloudnative-pg` version `0.29.0` (app CloudNativePG `1.30.0`), repo `https://cloudnative-pg.github.io/charts`
- All `helm`/`helmfile`/`kustomize` invocations MUST use the aqua-pinned toolchain (pins helm `v3.17.3`, helmfile `v0.169.2`, kustomize `v5.6.0`), never an ambient/global install — a prior incident showed version drift causes chart `semverCompare` branches to render different (noisy) output. Run `export AQUA_CONFIG="$(pwd)/.github/aqua.yaml"` (must be an **absolute path**, repo root as cwd) once per shell, then call `helm`/`helmfile`/`kustomize` normally — the aqua shims already on `PATH` read `AQUA_CONFIG` at each invocation. A **relative** `AQUA_CONFIG` breaks under `helmfile template`, which `chdir`s into the component directory before invoking its `helm` sub-process, so the shim resolves the relative path against the wrong directory and fails (verified during Task 1: `open kubernetes/components/cloudnative-pg/production/.github/aqua.yaml: no such file or directory`).
- Namespace name matches the component directory name exactly (`cloudnative-pg`, `keycloak`) — existing repo convention (`cert-manager`, `external-secrets`, `oauth2-proxy` all follow this).
- Public hostname: `auth.dystopia.city` (existing `*.dystopia.city` wildcard ACM cert + `external-dns` auto-attach; no new cert work).
- Explicit out of scope (per `docs/superpowers/specs/2026-08-07-keycloak-phase1-infra-design.md` §2): AWS RDS, monorepo changes, dystopia realm/client creation, Postgres HA/backup.
- Deploy mechanism is GitOps via Flux: this plan authors component source under `kubernetes/components/` and verifies it locally by rendering (`helmfile template`, `kustomize build`, the repo's hydrate scripts). It does **not** run `helmfile apply` / `kubectl apply` against the live cluster — the actual cluster change happens only after this plan's PR is merged to `main` and Flux reconciles.
- CNPG generates a `<cluster-name>-app` Secret with keys `user`, `password`, `dbname`, `host`, `port`, `uri` (+ jdbc/fqdn variants), and a `<cluster-name>-rw` Service (read-write primary) — both verified from CNPG source/docs, not assumed.

---

### Task 1: CloudNativePG operator component

**Files:**
- Create: `kubernetes/components/cloudnative-pg/namespace.yaml`
- Create: `kubernetes/components/cloudnative-pg/production/helmfile.yaml`
- Create: `kubernetes/components/cloudnative-pg/production/values.yaml.gotmpl`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: CNPG operator Deployment running in namespace `cloudnative-pg`, cluster-wide watch (no `WATCH_NAMESPACE` restriction), providing the `postgresql.cnpg.io/v1` `Cluster` CRD that Task 2 instantiates.

- [ ] **Step 1: Confirm there is nothing to render yet**

Run:
```bash
ls kubernetes/components/cloudnative-pg 2>&1
```
Expected: `ls: kubernetes/components/cloudnative-pg: No such file or directory` — confirms the component doesn't exist yet.

- [ ] **Step 2: Write the namespace manifest**

Create `kubernetes/components/cloudnative-pg/namespace.yaml`:

```yaml
# =============================================================================
# CloudNativePG Namespace
# =============================================================================
# CloudNativePG (= PostgreSQL operator, CNCF Sandbox / EDB 主導) の専用
# namespace。cert-manager / external-secrets と同じ「専用 namespace を持つ
# operator」パターン。Keycloak 専用ではなく cluster 共有の operator であり、
# 実際に Postgres を使う側 (Cluster CR) は kubernetes/components/keycloak/
# 側で定義する。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: cloudnative-pg
  labels:
    app.kubernetes.io/name: cloudnative-pg
```

- [ ] **Step 3: Write the helmfile release**

Create `kubernetes/components/cloudnative-pg/production/helmfile.yaml`:

```yaml
# =============================================================================
# CloudNativePG Helmfile for production
# =============================================================================
# PostgreSQL operator 本体のみ。Keycloak が使う Cluster CR は
# kubernetes/components/keycloak/production/kustomization/ 側で定義する
# (= operator 本体と、それを使う側の CR を分離する既存の慣習に合わせる)。
# =============================================================================
environments:
  production:

---
repositories:
  - name: cnpg
    url: https://cloudnative-pg.github.io/charts

releases:
  - name: cloudnative-pg
    namespace: cloudnative-pg
    chart: cnpg/cloudnative-pg
    version: "0.29.0"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 4: Write the values file**

Create `kubernetes/components/cloudnative-pg/production/values.yaml.gotmpl`:

```yaml
# CloudNativePG operator Configuration for production
# Phase 1: 単一の小さな Cluster (Keycloak 用) を動かすだけなので、
# operator 自体は chart 既定のリソース例をそのまま採用する。

resources:
  requests:
    cpu: 100m
    memory: 100Mi
  limits:
    cpu: 100m
    memory: 200Mi
```

- [ ] **Step 5: Render and verify**

Run:
```bash
export AQUA_CONFIG="$(pwd)/.github/aqua.yaml"
helmfile -f kubernetes/components/cloudnative-pg/production/helmfile.yaml -e production template --include-crds --skip-tests > /tmp/cnpg-render.yaml
grep -c "name: clusters.postgresql.cnpg.io" /tmp/cnpg-render.yaml
grep -c "^kind: Deployment$" /tmp/cnpg-render.yaml
grep "name: cloudnative-pg" /tmp/cnpg-render.yaml | head -3
```
Expected: all commands succeed (exit 0); the CNPG `Cluster` CRD (`name: clusters.postgresql.cnpg.io`, from `--include-crds`) count is `1` — note its own `kind` is `CustomResourceDefinition`, "Cluster" only appears as the nested `spec.names.kind`, so do not grep for a top-level `kind: Cluster` here; the `Deployment` count is `1` (the operator itself); at least one line contains `name: cloudnative-pg`.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/components/cloudnative-pg
git commit -s -m "feat(kubernetes/components/cloudnative-pg): add PostgreSQL operator for production"
```

---

### Task 2: Keycloak Postgres Cluster + admin bootstrap secret

**Files:**
- Create: `kubernetes/components/keycloak/namespace.yaml`
- Create: `kubernetes/components/keycloak/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/keycloak/production/kustomization/postgres-cluster.yaml`
- Create: `kubernetes/components/keycloak/production/kustomization/external-secret.yaml`

**Interfaces:**
- Consumes: `postgresql.cnpg.io/v1` `Cluster` CRD (Task 1); existing `ClusterSecretStore` `aws-secrets-manager` (from the already-deployed `external-secrets` component)
- Produces: CNPG `Cluster` named `keycloak-db` in namespace `keycloak` → Service `keycloak-db-rw.keycloak.svc.cluster.local:5432` and Secret `keycloak-db-app` (keys `user`/`password`/`dbname`/`host`/`port`). K8s Secret `keycloak-admin` (namespace `keycloak`, keys `username`/`password`) synced from AWS Secrets Manager `panicboat/keycloak/admin`. Task 3 consumes both secret names and the `-rw` Service host.

- [ ] **Step 1: Confirm there is nothing to render yet**

Run:
```bash
ls kubernetes/components/keycloak 2>&1
```
Expected: `ls: kubernetes/components/keycloak: No such file or directory`

- [ ] **Step 2: Write the namespace manifest**

Create `kubernetes/components/keycloak/namespace.yaml`:

```yaml
# =============================================================================
# Keycloak Namespace
# =============================================================================
# Keycloak 本体 + 専用 Postgres Cluster (CNPG) + admin bootstrap secret を
# まとめて持つ namespace。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
  labels:
    app.kubernetes.io/name: keycloak
```

- [ ] **Step 3: Write the Postgres Cluster CR**

Create `kubernetes/components/keycloak/production/kustomization/postgres-cluster.yaml`:

```yaml
# =============================================================================
# CloudNativePG Cluster: keycloak-db
# =============================================================================
# Keycloak 専用の単一インスタンス Postgres。HA / バックアップは Phase 1 の
# スコープ外 (docs/superpowers/specs/2026-08-07-keycloak-phase1-infra-design.md
# §2, §3.3)。`-app` Secret (keycloak-db-app) と `-rw` Service
# (keycloak-db-rw.keycloak.svc.cluster.local) を operator が自動生成する。
# =============================================================================
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-db
  namespace: keycloak
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    initdb:
      database: keycloak
      owner: keycloak
```

- [ ] **Step 4: Write the admin bootstrap ExternalSecret**

Create `kubernetes/components/keycloak/production/kustomization/external-secret.yaml`:

```yaml
# =============================================================================
# ExternalSecret: Keycloak admin bootstrap credentials
# =============================================================================
# AWS Secrets Manager の panicboat/keycloak/admin を K8s Secret keycloak-admin
# (= username / password) に sync。oauth2-proxy-google と同一パターン。
# AWS 側 secret 本体は本 PR merge 後に手動で put-secret-value する
# (= monolith-database の初期化と同様、platform リポジトリ側に Terraform
# 定義は持たない: oauth2-proxy-google も同じ運用)。
# =============================================================================
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: keycloak-admin
  namespace: keycloak
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: keycloak-admin
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: panicboat/keycloak/admin
        property: username
    - secretKey: password
      remoteRef:
        key: panicboat/keycloak/admin
        property: password
```

- [ ] **Step 5: Write the kustomization**

Create `kubernetes/components/keycloak/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# keycloak production kustomization
# =============================================================================
# chart 範囲外 resource (= Postgres Cluster CR + ExternalSecret) を helmfile
# output に上乗せする overlay。Ingress は Task 4 でここに追加する。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - postgres-cluster.yaml
  - external-secret.yaml
```

- [ ] **Step 6: Render and verify**

Run:
```bash
export AQUA_CONFIG="$(pwd)/.github/aqua.yaml"
kustomize build kubernetes/components/keycloak/production/kustomization > /tmp/keycloak-kustomize.yaml
grep -A2 "^kind: Cluster$" /tmp/keycloak-kustomize.yaml | grep "name: keycloak-db"
grep -A2 "^kind: ExternalSecret$" /tmp/keycloak-kustomize.yaml | grep "name: keycloak-admin"
```
Expected: both commands succeed and print the matching `name:` line — confirms the `Cluster` named `keycloak-db` and the `ExternalSecret` named `keycloak-admin` render correctly.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/components/keycloak/namespace.yaml kubernetes/components/keycloak/production/kustomization
git commit -s -m "feat(kubernetes/components/keycloak): add Postgres cluster and admin bootstrap secret"
```

---

### Task 3: Keycloak Helm release

**Files:**
- Create: `kubernetes/components/keycloak/production/helmfile.yaml`
- Create: `kubernetes/components/keycloak/production/values.yaml.gotmpl`

**Interfaces:**
- Consumes: Secret `keycloak-db-app` (key `password`) and Service host `keycloak-db-rw.keycloak.svc.cluster.local:5432` (Task 2, CNPG); Secret `keycloak-admin` (keys `username`/`password`, Task 2)
- Produces: StatefulSet `keycloak` (1 replica) and Service `keycloak-http` (ports `80`→container `8080` for traffic, `9000` for health/metrics) in namespace `keycloak`. Task 4's Ingress consumes Service `keycloak-http` port `80`.

- [ ] **Step 1: Confirm there is nothing to render yet**

Run:
```bash
ls kubernetes/components/keycloak/production/helmfile.yaml 2>&1
```
Expected: `ls: kubernetes/components/keycloak/production/helmfile.yaml: No such file or directory`

- [ ] **Step 2: Write the helmfile release**

Create `kubernetes/components/keycloak/production/helmfile.yaml`:

```yaml
# =============================================================================
# Keycloak Helmfile for production
# =============================================================================
# Phase 1: Keycloak 本体を動かして管理者コンソールに到達できる状態にする
# ことのみが目的。dystopia 用 realm / client 作成は対象外
# (docs/superpowers/specs/2026-08-07-keycloak-phase1-infra-design.md)。
# =============================================================================
environments:
  production:

---
repositories:
  - name: codecentric
    url: https://codecentric.github.io/helm-charts

releases:
  - name: keycloak
    namespace: keycloak
    chart: codecentric/keycloakx
    version: "7.2.2"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 3: Write the values file**

Create `kubernetes/components/keycloak/production/values.yaml.gotmpl`:

```yaml
# Keycloak Configuration for production (Phase 1: infra deploy のみ)
#
# Postgres backend は CloudNativePG が管理する Cluster keycloak-db
# (kustomization/postgres-cluster.yaml) の -app Secret を直接参照する。
# admin bootstrap credentials は kustomization/external-secret.yaml が
# 同期する Secret keycloak-admin を参照する。

fullnameOverride: keycloak

replicas: 1

# chart はデフォルトで command/args を空にする (= イメージの ENTRYPOINT
# kc.sh を引数なしで実行し、usage を表示して終了するだけになる)。
# 明示的に start する。
args:
  - start

# chart default の relativePath "/auth" は旧 WildFly 版 Keycloak からの
# 移行互換用。今回は新規導入なので現行 Keycloak の標準である "/" に上書き。
http:
  relativePath: "/"

database:
  vendor: postgres
  hostname: keycloak-db-rw.keycloak.svc.cluster.local
  port: "5432"
  database: keycloak
  username: keycloak
  existingSecret: keycloak-db-app
  existingSecretKey: password

extraEnv: |
  - name: KC_HOSTNAME
    value: auth.dystopia.city
  - name: KC_BOOTSTRAP_ADMIN_USERNAME
    valueFrom:
      secretKeyRef:
        name: keycloak-admin
        key: username
  - name: KC_BOOTSTRAP_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: keycloak-admin
        key: password

# start (非 optimized) は起動の都度 build ステップを挟むため、
# 起動時に一時的な CPU/メモリ負荷が上がる。まずは動かすことを優先し、
# 安全側の初期値を設定。実測を見て right-size する。
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: "1500m"
    memory: 1536Mi
```

- [ ] **Step 4: Render and verify**

Run:
```bash
export AQUA_CONFIG="$(pwd)/.github/aqua.yaml"
helmfile -f kubernetes/components/keycloak/production/helmfile.yaml -e production template --skip-tests > /tmp/keycloak-render.yaml
grep -A2 "^kind: StatefulSet$" /tmp/keycloak-render.yaml | grep "name: keycloak$"
grep -A2 "^kind: Service$" /tmp/keycloak-render.yaml | grep "name: keycloak-http$"
grep "KC_HOSTNAME" -A1 /tmp/keycloak-render.yaml
grep "keycloak-db-rw.keycloak.svc.cluster.local" /tmp/keycloak-render.yaml
grep '\- start$' /tmp/keycloak-render.yaml
```
Expected: all commands succeed and print matches — confirms the StatefulSet `keycloak`, Service `keycloak-http`, the `KC_HOSTNAME` env var, the DB hostname, and the `start` arg all render as expected.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/components/keycloak/production/helmfile.yaml kubernetes/components/keycloak/production/values.yaml.gotmpl
git commit -s -m "feat(kubernetes/components/keycloak): add Keycloak Helm release"
```

---

### Task 4: Keycloak Ingress, full hydration, and Draft PR

**Files:**
- Create: `kubernetes/components/keycloak/production/kustomization/ingress.yaml`
- Modify: `kubernetes/components/keycloak/production/kustomization/kustomization.yaml` (add `ingress.yaml` to `resources`)

**Interfaces:**
- Consumes: Service `keycloak-http` port `80` (Task 3); the shared ALB `application` IngressGroup and `*.dystopia.city` wildcard cert (existing platform infra, no changes needed)
- Produces: public route `https://auth.dystopia.city` → `keycloak-http:80`. Terminal task — no further tasks depend on this one.

- [ ] **Step 1: Confirm the Ingress isn't rendered yet**

Run:
```bash
export AQUA_CONFIG="$(pwd)/.github/aqua.yaml"
kustomize build kubernetes/components/keycloak/production/kustomization | grep "kind: Ingress"
```
Expected: no output (Ingress not defined yet).

- [ ] **Step 2: Write the Ingress**

Create `kubernetes/components/keycloak/production/kustomization/ingress.yaml`:

```yaml
# =============================================================================
# Ingress: Keycloak (application IngressGroup)
# =============================================================================
# monolith / frontend / monitoring-uis と同じ共有 ALB (IngressGroup
# `application`) に相乗りする。*.dystopia.city の wildcard ACM cert を ALB
# Controller が自動 attach、external-dns が Route53 record を自動作成する。
#
# healthcheck-port を明示的に 9000 に向けている理由: codecentric/keycloakx
# chart は health/metrics を container port 9000 (Service 上も 9000) の
# 管理用インターフェースに分離しており、traffic-port (= 80) には無い。
# =============================================================================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: application
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health/ready
    alb.ingress.kubernetes.io/healthcheck-port: "9000"
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: auth.dystopia.city
spec:
  ingressClassName: alb
  rules:
    - host: auth.dystopia.city
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak-http
                port:
                  number: 80
```

- [ ] **Step 3: Add it to the kustomization**

Modify `kubernetes/components/keycloak/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# keycloak production kustomization
# =============================================================================
# chart 範囲外 resource (= Postgres Cluster CR + ExternalSecret + Ingress) を
# helmfile output に上乗せする overlay。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - postgres-cluster.yaml
  - external-secret.yaml
  - ingress.yaml
```

- [ ] **Step 4: Render and verify the Ingress**

Run:
```bash
export AQUA_CONFIG="$(pwd)/.github/aqua.yaml"
kustomize build kubernetes/components/keycloak/production/kustomization > /tmp/keycloak-kustomize.yaml
grep -A2 "^kind: Ingress$" /tmp/keycloak-kustomize.yaml | grep "name: keycloak$"
grep "auth.dystopia.city" /tmp/keycloak-kustomize.yaml
grep "name: keycloak-http" /tmp/keycloak-kustomize.yaml
```
Expected: all three commands print a match.

- [ ] **Step 5: Run the full hydration exactly as CI does**

Run:
```bash
export AQUA_CONFIG="$(pwd)/.github/aqua.yaml"
bash scripts/kubernetes-hydrate/hydrate-component.sh cloudnative-pg production
bash scripts/kubernetes-hydrate/hydrate-component.sh keycloak production
bash scripts/kubernetes-hydrate/hydrate-index.sh production
git status --short kubernetes/manifests/production
```
Expected: `kubernetes/manifests/production/cloudnative-pg/manifest.yaml`, `kubernetes/manifests/production/keycloak/manifest.yaml`, and `kubernetes/manifests/production/kustomization.yaml` / `00-namespaces/namespaces.yaml` appear as new/modified in `git status`. Read through `kubernetes/manifests/production/keycloak/manifest.yaml` once to sanity-check there is no leftover Helm template error text (e.g. `<no value>`, `Error:`) anywhere in the file.

- [ ] **Step 6: Commit the hydrated manifests**

```bash
git add kubernetes/components/keycloak/production/kustomization kubernetes/manifests/production
git commit -s -m "feat(kubernetes/components/keycloak): add Ingress and hydrate manifests"
```

- [ ] **Step 7: Push and open a Draft PR**

```bash
git push -u origin feat/keycloak-infra
gh pr create --draft --title "feat(kubernetes): deploy Keycloak Phase 1 infra (CloudNativePG + Keycloak)" --body "$(cat <<'EOF'
## Summary
- Add `cloudnative-pg` component: shared PostgreSQL operator
- Add `keycloak` component: Keycloak (codecentric/keycloakx) backed by a CNPG-managed single-instance Postgres, exposed at `auth.dystopia.city`
- Phase 1 only: no dystopia realm/client, no monorepo changes, no RDS, no Postgres HA/backup (see docs/superpowers/specs/2026-08-07-keycloak-phase1-infra-design.md)

## Test plan
- [x] `helmfile template` verified locally for both components (Tasks 1 and 3)
- [x] `kustomize build` verified locally for the keycloak overlay (Tasks 2 and 4)
- [x] Local hydration run matches what CI's kubernetes-hydrator will produce (Task 4 Step 5)
- [ ] CI hydration workflow re-runs on this PR and the diff matches (verify in PR checks)
- [ ] After merge: populate AWS Secrets Manager secret `panicboat/keycloak/admin` (keys `username`, `password`) — same manual step pattern as `panicboat/oauth2-proxy/google` and `panicboat/monolith/database`
- [ ] After merge: confirm CNPG `Cluster` `keycloak-db` reaches healthy state (`kubectl get cluster -n keycloak`)
- [ ] After merge: confirm `https://auth.dystopia.city` serves the Keycloak login page with valid TLS, and the bootstrap admin credentials work
EOF
)"
```

**Note:** this task stops at opening the Draft PR. Merging to `main`, populating the AWS Secrets Manager secret, and the post-merge cluster verification are follow-up actions for the user (per the design spec's "完了条件"), not part of this plan's automated tasks.

---

## Self-Review

**Spec coverage:** Chart selection (§3.2) → Task 3. DB backend / CNPG (§3.3) → Tasks 1–2. Public exposure (§3.4) → Task 4. Secrets (§3.5) → Task 2 (both DB and admin secrets). Definition of Done (§4) → covered by the PR body's test-plan checklist (last three items are explicitly post-merge, matching that the Done criteria require a live cluster). Phase 2 hand-off (§5) is explicitly out of scope and untouched.

**Placeholder scan:** No TBD/TODO; every code block is complete, verified content (chart values pulled from `helm show values`, CNPG secret/service naming pulled from CNPG source and docs, Keycloak env vars pulled from official bootstrap-admin docs and the chart's rendered templates).

**Type/name consistency:** `keycloak-db` (Cluster name, Task 2) → `keycloak-db-rw.keycloak.svc.cluster.local` / `keycloak-db-app` (Task 3 values) — consistent. `keycloak-admin` (ExternalSecret target, Task 2) → referenced identically in Task 3's `extraEnv` secretKeyRefs — consistent. `keycloak` (Helm release `fullnameOverride`, Task 3) → Service `keycloak-http` → Ingress backend (Task 4) — consistent.
