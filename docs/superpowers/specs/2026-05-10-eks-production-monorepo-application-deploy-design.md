# EKS Production Phase 6-2: Monorepo Application Deploy (= AWS RDS + 3 services + OTel SDK + Instrumentation CR + Image Update Automation)

> **Phase**: roadmap Phase 6 (= application migration theme) の **第 2 sub-project (= Application deploy)**
>
> **Nature**: application services の actual deploy + AWS RDS provision + OTel L1 (= application code SDK) + L2 (= Operator auto-injection)
>
> **Goal**: panicboat monorepo の **monolith + frontend + reverse-proxy** 3 services を eks-production cluster に actual deploy。 AWS RDS PostgreSQL provision で K8s 内 PostgreSQL から切替、 OTel SDK init で 3-layer observability の foundation 整備、 Image Update Automation で main merge → auto-deploy chain 確立。

---

## 1. Phase 6 overview + 6-2 position

### Phase 6 sub-projects + 6-2 position

| Sub-project | Scope | Status |
|---|---|---|
| 6-1 Foundation | Cilium 共有 Gateway + Flux GitRepository monorepo (= suspend) + OTel Operator chart + 共有 platform 設計コメント update + monorepo nginx 削除 (= 並行) | ✅ **完了** (= PR #323 / #590 / #327 fix forward / #329 learnings) |
| **6-2 Application deploy** | AWS RDS PostgreSQL provision + 3 services deploy + OTel SDK init + Instrumentation CR + Image Update Automation + monorepo Flux Kustomization resume | **本 spec の対象** |
| 6-3 End-to-end validation + post-flight | 3-layer observability (= Beyla + Hubble + OTel) 確認 + DNS / ACM domain 公開 + Phase 5-2 nginx 13 checklist の application 化 + post-flight 5 連続 validate | 6-2 完了後 |

### 6-1 から継承する framework (= 確定済)

- panicboat 個人運用 + 1 application 構成
- 共有 Cilium Gateway (= P3、 namespace `default`、 listener HTTP port 80、 platform 所有)
- mTLS 不採用 (= plain HTTP/2 + Cilium WireGuard で transport encryption)
- OTel SDK L1 (= application code init) + L2 (= Operator auto-injection) 両方採用
- AWS RDS 採用 (= terragrunt provision、 monorepo 側で manage)
- 1 sub-project = 1 PR set pattern (= platform PR + 並行 monorepo PR)

### 6-1 引き継ぎ事項の 6-2 での扱い

| # | 項目 | 6-2 での対応 |
|---|---|---|
| #21 | Mimir max-label-names-per-series 30 → 35 | application 投入時 Beyla histogram reject で再発見 → **post-flight reactive fix forward** |
| #22 | Makefile hydrate-component の kube-version 固定 (= 旧 categorize) | **Re-diagnosed root cause**: 真因は subagent が aqua-pinned helm (= v3.17.3) を利用していないこと (= helm version 差で chart の semverCompare 分岐結果が differ、 noise diff 発生)。 Makefile に `--kube-version` 追加は defensive measure に留まり root cause fix でない。 真の解決 = subagent dispatch instruction で aqua install + aqua's helm / helmfile / kustomize 利用を明示。 Phase 6-2 plan の Task 0 で確立、 各 Task で subagent dispatch 時に明示。 |
| #23 | monorepo README documentation drift | **monorepo PR scope に含めて同 PR で解消** |

---

## 2. 6-2 scope (= 6 components A-F)

### Component A: AWS RDS PostgreSQL provision (= monorepo 側 terragrunt)

#### Goal

monolith application の PostgreSQL backend を AWS RDS で provision。 monorepo の workflow-config.yaml `terragrunt` stack 想定通り、 application 開発者所有の terragrunt stack。

#### Implementation

- Location: `services/monolith/terragrunt/envs/develop/`
- Pattern: monorepo `template/terragrunt/` scaffolding を copy
- Resources:
  - `aws_db_instance` (= RDS PostgreSQL)
  - `aws_db_subnet_group` (= eks-production VPC private subnets を data source 参照)
  - `aws_security_group` (= monolith Pod from 5432 access のみ)
  - `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version` (= master credentials)
  - `random_password` (= initial master password 生成)

#### RDS spec

| 項目 | 値 |
|---|---|
| Engine | PostgreSQL 17.x (= 最新 stable) |
| Instance class | `db.t4g.micro` (= ARM、 1 vCPU / 1 GiB RAM) |
| Multi-AZ | false (= 個人 dev environment) |
| Storage | gp3 20 GiB |
| Backup retention | 7 days (= AWS default) |
| Public access | false (= VPC 内のみ) |
| Subnet group | eks-production VPC private subnets (= data source) |
| Security group | monolith Pod from 5432 access のみ |
| Master credentials | AWS Secrets Manager 管理 (= ESO で取得) |

月額 cost 試算 (= ap-northeast-1): ~$15/month (= db.t4g.micro $11.7 + gp3 20 GiB $2.3 + backup free)

#### AWS Secrets Manager structure

- secret name: `panicboat/monolith/database` (= 既 ESO IAM role の access pattern との整合)
- 内容: JSON object
  - `username`: postgres
  - `password`: random 32 chars
  - `host`: RDS endpoint
  - `port`: 5432
  - `database`: monolith
  - `url`: postgres://username:password@host:5432/database (= 合成 DATABASE_URL)

#### Validation

- `terragrunt apply` 成功 + RDS instance Available
- `aws secretsmanager get-secret-value --secret-id panicboat/monolith/database` で content 取得可
- monolith Pod から `psql $DATABASE_URL -c "SELECT 1"` で接続成功

---

### Component B: monorepo K8s manifests 修正

#### monolith

**develop overlay** (= `services/monolith/kubernetes/overlays/develop/`):
- `postgresql/` directory **削除** (= K8s 内 PostgreSQL Pod + Service + emptyDir 撤去)
- `kustomization.yaml`: `postgresql` resource entry 削除
- `configmap.yaml` patch: `DATABASE_URL` 削除 (= ExternalSecret に migrate)
- `external-secret.yaml` 新規追加: AWS Secrets Manager `panicboat/monolith/database` から K8s Secret `monolith-database` 生成

**base** (= `services/monolith/kubernetes/base/`):
- `deployment.yaml`:
  - `metadata.annotations.reloader.stakater.com/auto: "true"` 追加 (= 既 Reloader pattern)
  - `imagePullPolicy: IfNotPresent` 維持 (= ImageUpdateAutomation で deployment.yaml の image tag が変わるため自動 re-pull)
  - `envFrom` に Secret reference 追加 (= configMapRef + secretRef の 2 source)
  - ImageUpdateAutomation marker comment (= `# {"$imagepolicy": "flux-system:monolith"}` 等の inline comment)
- KEDA ScaledObject: **6-2 では未追加** (= application 投入後の actual load 様子見、 6-3 or 後続で評価)

#### frontend

**base** (= `services/frontend/kubernetes/base/`):
- `deployment.yaml`:
  - `metadata.annotations.reloader.stakater.com/auto: "true"` 追加
  - ImageUpdateAutomation marker comment
- frontend は monolith の DATABASE_URL 不要 (= ConnectRPC で monolith に通信)、 既 configMapRef のみ
- KEDA ScaledObject: 未追加 (= 6-2 では skip)

#### reverse-proxy

- 既 6-1 で deploy 済 (= cilium-gateway parentRef + LoadBalancer Service)
- 6-2 で **追加修正なし**

---

### Component C: OTel SDK init (= L1、 application code 修正)

L2 (= Operator auto-injection) の env vars (= `OTEL_EXPORTER_OTLP_ENDPOINT` 等) を application code が detect、 SDK initialize で auto-config。 custom span は application code 内で `tracer.in_span(...)` 追加。

#### Hanami (= monolith)

**Gemfile** (= `services/monolith/workspace/Gemfile`):

```ruby
gem "opentelemetry-sdk"
gem "opentelemetry-instrumentation-all"
gem "opentelemetry-exporter-otlp"
```

**新規 file** (= `services/monolith/workspace/config/initializers/opentelemetry.rb`):

```ruby
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"
require "opentelemetry/exporter/otlp"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "monolith"
  c.use_all # auto-instrument all installed instrumentation libraries
end
```

resource attributes (= service.name 等) と exporter endpoint は **L2 Operator が env vars で injection** するため code で hardcode 不要。 application code は `OpenTelemetry::SDK.configure` で trigger するだけで auto-config。

#### Next.js (= frontend)

**package.json** (= `services/frontend/workspace/package.json`):

```json
{
  "dependencies": {
    "@opentelemetry/sdk-node": "^0.59.0",
    "@opentelemetry/auto-instrumentations-node": "^0.62.0",
    "@opentelemetry/exporter-trace-otlp-grpc": "^0.59.0"
  }
}
```

**新規 file** (= `services/frontend/workspace/instrumentation.ts`):

```typescript
import { NodeSDK } from "@opentelemetry/sdk-node";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-grpc";

export function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const sdk = new NodeSDK({
      traceExporter: new OTLPTraceExporter(),
      instrumentations: [getNodeAutoInstrumentations()],
    });
    sdk.start();
  }
}
```

**next.config.ts**: `experimental.instrumentationHook: true` (= Next.js 16+ では default、 確認後固定)

---

### Component D: Instrumentation CR (= L2、 platform 側 deploy)

#### Goal

Phase 6-1 で deploy 済 OTel Operator が application Pod を auto-instrument するための設定 resource。 namespace `default` に 1 つ deploy で全 application Pod が auto-injection 受ける。

#### Implementation

- Location: `kubernetes/components/opentelemetry/production/kustomization/instrumentation.yaml` (= 既 OTel Operator chart と同 component 内)
- 既 `kustomization.yaml` の `resources` に `instrumentation.yaml` 追加

#### Instrumentation CR content

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: panicboat-application
  namespace: default
spec:
  exporter:
    endpoint: http://opentelemetry-collector.monitoring.svc.cluster.local:4317  # 既 OTel Collector deploy 済
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"  # 全 trace 採取 (= 個人 dev、 production 投入時に 0.1-0.01 に絞る)
  ruby:
    image: ghcr.io/open-telemetry/opentelemetry-ruby-instrumentation:<plan 段階で latest stable version pin>
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:<plan 段階で latest stable version pin>
```

注: auto-instrumentation image の version pin は **5-1 L1 chart binary verify systematic step** 適用、 plan 段階で specific version (= 例: ruby `0.59.0`、 nodejs `0.62.0` 等) を確認 + sha256 verify。 `:latest` tag 使用は禁止 (= reproducibility 確保)。

#### application Pod auto-injection

application deployment.yaml に annotation 追加で auto-injection trigger:

- monolith: `instrumentation.opentelemetry.io/inject-ruby: "default/panicboat-application"`
- frontend: `instrumentation.opentelemetry.io/inject-nodejs: "default/panicboat-application"`

(= これらは monorepo の K8s manifests 修正で含める)

#### Validation

- `kubectl get instrumentation -n default panicboat-application` → resource exists
- application Pod の init container (= `opentelemetry-auto-instrumentation`) が完了
- application Pod env に `OTEL_EXPORTER_OTLP_ENDPOINT` `OTEL_RESOURCE_ATTRIBUTES` 等 inject されている

---

### Component E: Flux Image Update Automation (= sha tag auto-bump)

#### Goal

monorepo main merge → container-builder GHCR push → ImageUpdateAutomation deployment.yaml の image tag を auto-bump → Flux Reconcile → Pod rolling update の **fully automated chain** 確立。

#### Implementation (= monorepo PR で追加)

削除済 nginx pattern を template として monolith / frontend に re-introduce。

**Location**:
- `clusters/develop/services/monolith/`
  - `image-repository.yaml` (= `ImageRepository`)
  - `image-policy.yaml` (= `ImagePolicy`)
  - `image-automation.yaml` (= `ImageUpdateAutomation`)
- `clusters/develop/services/frontend/`
  - 同 3 files
- `clusters/develop/services/{monolith,frontend}/kustomization.yaml`: `resources` に上記 3 file 追加

#### ImageRepository

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: monolith
  namespace: flux-system
spec:
  image: ghcr.io/panicboat/monorepo/monolith
  interval: 5m
```

#### ImagePolicy

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: monolith
  namespace: flux-system
  labels:
    service: monolith
spec:
  imageRepositoryRef:
    name: monolith
  filterTags:
    pattern: '^[a-f0-9]{7,40}$'  # git sha tag (= deploy-actions container-builder の standard pattern を想定、 plan 段階で確認)
  policy:
    alphabetical:
      order: asc  # chronological order (= sha は random だが container-builder の `created` time annotation 利用も option)
```

注: deploy-actions container-builder の actual tagging pattern (= sha7 / sha40 / `<branch>-<sha>` / semver / 等) は plan 段階で確認、 ImagePolicy filterTags pattern を adjust。

#### ImageUpdateAutomation

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: monolith
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: monorepo
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        email: panicboat@gmail.com
        name: panicboat
      messageTemplate: |
        chore(monolith): bump image to {{range .Updated.Images}}{{println .}}{{end}}
    push:
      branch: main
  update:
    path: ./services/monolith/kubernetes
    strategy: Setters  # ImagePolicy Setters で deployment.yaml の image marker を update
```

#### deployment.yaml marker comment

```yaml
# services/monolith/kubernetes/base/deployment.yaml の image 行
spec:
  template:
    spec:
      containers:
        - name: monolith
          image: ghcr.io/panicboat/monorepo/monolith:latest # {"$imagepolicy": "flux-system:monolith"}
```

ImageUpdateAutomation が `:latest` 部分を ImagePolicy で picked tag (= 最新 sha) に書き換え + commit + push。

#### Validation

- ImageRepository / ImagePolicy / ImageUpdateAutomation 全 Ready
- main merge → 30m 以内に GHCR poll + deployment.yaml の image tag を sha に bump する commit が main に push されている

---

### Component F: Flux Kustomization resume + Post-flight regression check

#### F-1: monorepo Flux Kustomization の resume

Phase 6-1 で `kubernetes/clusters/production/repositories/monorepo.yaml` の `Kustomization monorepo-cluster` を `spec.suspend: true` で deploy。 6-2 で `suspend: true → false` に変更。

resume 後、 monorepo の `clusters/develop/services/{monolith,frontend,reverse-proxy}/service.yaml` (= Flux Kustomization 内蔵) が cascading で reconcile 開始、 各 service の K8s manifests が deploy 状態になる。

#### F-2: Post-flight regression check (= 5-1 L2 / 5-2 L1 pattern 5 連続 validate)

##### Section 1: 既 deploy 済 component health (= Phase 1-5 + 6-1)

- ALB Ingress / Cilium / Hubble / Monitoring / ESO + Reloader / cert-manager / OTel Operator (= chart 0.112.1 + metrics auth 無効化済) / Cilium 共有 Gateway / GitRepository monorepo
- 全 healthy + restart 数増加 0

##### Section 2: 既 deploy 済 application 継続動作

- demo nginx (= Phase 5-2): nginx.panicboat.net 200 + DEMO_MESSAGE 維持

##### Section 3: 6-2 追加 component 自体の health

- AWS RDS instance Available + monolith Pod 接続成功 (= `psql -c "SELECT 1"`)
- monolith / frontend / reverse-proxy Pod Ready + ConfigMap / Secret reference resolved
- Instrumentation CR `panicboat-application` exists
- application Pod の OTel auto-instrumentation init container 完了 + env vars injected
- ImageRepository / ImagePolicy / ImageUpdateAutomation 全 Ready
- monolith → AWS RDS gRPC server 動作 (= internal port 9001)
- frontend → monolith ConnectRPC 通信成功 (= ClusterIP DNS 経由)
- reverse-proxy → cilium-gateway HTTPRoute 動作 (= 既 6-1 で deploy 済)

##### Section 4: latent issue 検出 (= 5 連続 validate 機会)

- **引き継ぎ #21 Mimir max-label-names-per-series**: Beyla histogram で reject 発生確率高 → 検出時 fix forward PR (= Mimir chart values で `validation.max-label-names-per-series: 35`)
- application 投入で OTel Operator auto-injection の latent issue (= 5-1 L1 chart binary verify 系)
- AWS RDS provision で security group / subnet group の latent 設定 issue
- Image Update Automation の actual deploy-actions container-builder tagging pattern mismatch

#### Validation

- 全 check section PASS
- latent issue 検出時は fix forward PR で resolve

---

## 3. 並行 PR structure (= 2 PRs)

注: 旧 spec 案で "Pre-merge fix forward PR for Makefile #22" を 3 PR structure に含めていたが、 真因 re-diagnosis (= subagent aqua 未利用) で Makefile 修正不要と判断、 PR structure は 2 PRs に simplify。 引き継ぎ #22 の解消は Phase 6-2 plan Task 0 の subagent aqua install step で対応。

### Platform PR

**Title**: `feat(eks): Phase 6-2 — application platform components`

**Scope**:
- `kubernetes/components/opentelemetry/production/kustomization/instrumentation.yaml` 新規 + `kustomization.yaml` の resources に追加
- `kubernetes/clusters/production/repositories/monorepo.yaml` の `Kustomization monorepo-cluster` を `suspend: true → false`
- hydrate (= `make hydrate-component COMPONENT=opentelemetry ENV=production`)
- 必要時: Mimir #21 fix forward (= 別 PR or 同 PR の判断は post-flight 結果次第)

### 並行 monorepo PR

**Title**: `feat: Phase 6-2 application deploy (= RDS + OTel SDK + auto-bump)`

**Scope**:

#### terragrunt
- `services/monolith/terragrunt/envs/develop/` 新規 directory + RDS provision file
- AWS Secrets Manager secret + IAM role 設定 (= 既 ESO IAM の更新も検討)

#### application code
- `services/monolith/workspace/Gemfile` + `config/initializers/opentelemetry.rb`
- `services/frontend/workspace/package.json` + `instrumentation.ts` + `next.config.ts` 確認

#### K8s manifests
- `services/monolith/kubernetes/`: develop overlay の K8s 内 PostgreSQL 削除 + ExternalSecret 追加 + Reloader annotation + ImageUpdateAutomation marker
- `services/frontend/kubernetes/`: Reloader annotation + ImageUpdateAutomation marker

#### Flux config
- `clusters/develop/services/{monolith,frontend}/`: ImageRepository + ImagePolicy + ImageUpdateAutomation の 3 resource 追加 (= 削除済 nginx pattern を template)

#### documentation (= 引き継ぎ #23 解消)
- `README.md` / `README-ja.md`: getting-started + mermaid + service 説明 update (= nginx 言及削除 + RDS 追記 + Image Update Automation 説明)

---

## 4. Phase 5 + 6-1 lessons applied

### Lessons applied

| Lesson | 適用箇所 |
|---|---|
| 5-1 L1 (= chart binary verify) | OTel auto-instrumentation image (= ruby / nodejs) の image digest 確認 |
| 5-1 L2 / 5-2 L1 (= post-flight regression check) | Component F-2 で 5 連続 validate |
| 5-2 L4 (= kustomization-only pattern) | Instrumentation CR を既 OTel Operator kustomization に追加 |
| 6-1 L1 (= chart actual structure verify) | OTel auto-instrumentation image の chart values structure 確認 (= `kubectl explain instrumentation.spec` 等) |
| 6-1 L3 (= post-flight issue category 整理) | Component F-2 で issue category 別記録 (= 過去 dormant / 現 sub-project chart default 起因) |
| 6-1 L4 (= parallel PR scope に documentation 同期) | monorepo PR scope に README update を含める (= 引き継ぎ #23 解消) |

### New lesson 候補 (= 6-2 deploy で観察対象)

- **AWS RDS provision の monorepo terragrunt pattern** (= application 開発者所有の terragrunt stack の establishment)
- **OTel SDK L1 + L2 共存 pattern** (= Operator auto-injection と application code init の順序 / 重複処理 / env vars 受渡し)
- **Image Update Automation の sha tag auto-bump pattern** (= main merge → 30m 以内 deploy の actual timing 観察)
- **post-flight 5 連続 validate** (= 4-3 / 5-1 / 5-2 / 6-1 / 6-2 の pattern 完全機能 confirmation)

---

## 5. 引き継ぎ事項解消

| # | 項目 | 6-2 での対応 |
|---|---|---|
| #21 | Mimir max-label-names-per-series 30 → 35 | post-flight reactive fix forward (= 検出時) |
| #22 | Makefile hydrate-component の kube-version 固定 (= 旧 categorize) | **Re-diagnosed root cause = subagent aqua 未利用、 Phase 6-2 plan の subagent dispatch instruction で解消** (= aqua install + aqua-pinned helm / helmfile / kustomize 利用を明示)。 Makefile 修正不要。 |
| #23 | monorepo README documentation drift | **monorepo PR scope で解消** |
| #4 | OTel Operator deploy + Hanami / Next.js OTel SDK + Instrumentation CR | **完全解消** (= 6-1 で Operator deploy + 6-2 で SDK init + Instrumentation CR) |

---

## 6. Out of scope

以下は 6-3 で対応:

- DNS / ACM の application domain 公開 (= reverse-proxy 用 domain、 monolith / frontend は internal のため不要)
- 3-layer observability validation (= Beyla + Hubble + OTel 同 trace_id 結合の actual end-to-end 確認)
- Phase 5-2 nginx 13 checklist の application 化 (= 13 items を application context で再 validate)
- post-flight 5 連続 validate established の formal documentation

以下は対応しない (= 引き継ぎ事項に明示記録、 incremental 対応):

- KEDA ScaledObject (= application 投入後の actual load 様子見、 traffic profile 確定後に 6-3 or 後続)
- mTLS chain verify (= mTLS 不採用、 引き継ぎ #19 skip)
- post-flight automation framework 化 (= 引き継ぎ #5)
- multi-tenant + retention (= 引き継ぎ #2 / #3)
- security hardening framework (= 引き継ぎ #11 / #12 等)
- application image release tag pattern (= semver release、 sha tag auto-bump で十分)

---

## 7. Risks + mitigations

| Risk | Mitigation |
|---|---|
| AWS RDS provision で VPC / subnet group 設定 mismatch (= eks-production VPC との integration) | platform aws/vpc/ outputs の terragrunt data source 参照、 plan 段階で endpoint hostname 検証 |
| AWS Secrets Manager IAM role の ESO access 権限不足 | wildcard prefix (= `panicboat/*`) で許可済なら 6-2 で `aws/` 修正不要。 制限 prefix なら **platform PR scope に `aws/eks-secrets/` terragrunt update を追加**。 plan 段階で IAM policy 確認 (= Phase 4-2 ESO 設定の re-read) |
| OTel Operator auto-injection の application code 競合 (= L1 + L2 同時適用) | env vars (= `OTEL_EXPORTER_OTLP_ENDPOINT`) は Operator が injection、 application code は detect + use する pattern を documentation で明記 |
| Image Update Automation の deploy-actions container-builder tagging pattern mismatch | plan 段階で actual tag pattern 確認 (= deploy-actions repo or 既 GHCR image list)、 ImagePolicy filterTags pattern を adjust |
| AWS RDS への initial migration (= Hanami db:migrate) の trigger | Hanami の `bin/start` script で migration 実行 or Job resource 別途 deploy (= plan 段階で確定) |
| Mimir #21 fix forward の timing (= 同 PR / 別 PR / 後続 PR) | post-flight 検出時に 5-1 L2 / 5-2 L1 pattern 通り別 fix forward PR、 検出されなければ skip |
| reverse-proxy の monolith.local / frontend.local DNS resolution (= cluster 内 ClusterIP Service との name 解決) | monorepo reverse-proxy の nginx config で upstream 設定確認、 必要時 monorepo PR で adjust |

---

## 8. Validation checklist (= 6-2 完了条件)

### Platform PR + 並行 monorepo PR (= 同日 merge)
- [ ] AWS RDS instance Available + Secrets Manager secret 登録
- [ ] monolith Pod Ready + RDS 接続成功 (= application log で SQL execution 確認)
- [ ] frontend Pod Ready + monolith ConnectRPC 接続成功
- [ ] reverse-proxy Pod 継続動作 (= 既 6-1 deploy)
- [ ] OTel Instrumentation CR `panicboat-application` exists (= namespace default)
- [ ] application Pod auto-injection (= init container 完了 + OTel env vars injected)
- [ ] ImageRepository / ImagePolicy / ImageUpdateAutomation 全 Ready (= monolith / frontend)
- [ ] monorepo Flux Kustomization `monorepo-cluster` resume + 各 service Kustomization Ready
- [ ] Phase 1-5 + 6-1 既存 component regression なし
- [ ] post-flight 5 連続 validate 確認 (= 5-1 L2 / 5-2 L1 pattern)
- [ ] latent issue 検出時 fix forward PR で resolve (= #21 Mimir reject / その他)
- [ ] post-execution learnings doc 作成 (= 別 PR、 plan に section 追加)

---

## References

### Phase 6 sub-project specs / plans / learnings

- Phase 5 closure doc: `docs/superpowers/specs/2026-05-10-eks-production-phase-5-closure-design.md`
- Phase 6-1 spec: `docs/superpowers/specs/2026-05-10-eks-production-monorepo-migration-foundation-design.md`
- Phase 6-1 plan + learnings: `docs/superpowers/plans/2026-05-10-eks-production-monorepo-migration-foundation.md`

### platform roadmap

- `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`

### Phase 5 sub-project specs / plans

- Phase 5-1 spec: `docs/superpowers/specs/2026-05-09-eks-production-beyla-foundation-design.md`
- Phase 5-2 spec: `docs/superpowers/specs/2026-05-10-eks-production-nginx-end-to-end-validation-design.md`

### Component reference

- monorepo: https://github.com/panicboat/monorepo
- monorepo template/terragrunt scaffolding: `template/terragrunt/{root.hcl, modules/, envs/develop/}`
- AWS RDS for PostgreSQL doc: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html
- OTel Operator Instrumentation CR: https://github.com/open-telemetry/opentelemetry-operator/blob/main/docs/api.md#instrumentation
- OTel Ruby SDK: https://github.com/open-telemetry/opentelemetry-ruby
- OTel Node.js SDK: https://github.com/open-telemetry/opentelemetry-js-contrib
- Flux Image Update Automation: https://fluxcd.io/flux/guides/image-update/

### Related (= 削除済 nginx pattern を template として活用)

- 削除済 monorepo nginx の Image Update Automation 設定 (= 6-1 削除前の git history 参照): ImageRepository + ImagePolicy + ImageUpdateAutomation の 3 resource
