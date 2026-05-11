# kubernetes/README.md Cleanup & Restructure Design

> **Goal**: `kubernetes/README.md` から historical noise (`Plan N で導入` / `Sub-project N で` / `Phase N で予定` / `(撤去済 in PR N)` 等の累積 annotation) を全面除去し、Production Operations section の Cluster overview tables を current state ベースで完成させ、section 全体を Local / Production / Architecture / 設計思想 / 障害調査例 の流れに再編する。併せて Main architecture diagram の Mermaid parse error と PR-B 由来の minor 指摘を修正する。

---

## Context

### 現状の問題点

`kubernetes/README.md` (536 行) は phase ごとに加筆を重ねた結果、3 つの問題を抱えている。

**1. Historical commentary が累積している (= "when は git history" 原則違反):**

| L | パターン |
|---|---|
| 358 | `### Cluster overview (post Plan 2)` |
| 373 | `加えて Plan 1c-α で以下の foundation addons を導入：` |
| 381 | `さらに Plan 1c-β で以下を導入：` |
| 391 | `加えて Plan 2 で以下を導入：` |
| 400 | `` | `system` MNG | (撤去済 in PR 3) | Plan 2 PR 3 で削除... | `` |
| 402 | `加えて Plan 3 Sub-project 2 (Metrics stack) で以下を導入：` |
| 406 | `Alertmanager (receiver は Phase 4 で追加)`、`Loki / Tempo は Sub-project 3 / 4 で追加` |
| 408 | `Sub-project 1 で provision、Sub-project 2 Task 1 で rename` |
| 410 | `Phase 3 全 sub-projects 共有。Sub-project 3 (Loki) / Sub-project 4 ... も同 namespace を利用予定` |
| 460 | `# Hubble UI（Phase 4 で外部公開予定、現状は port-forward only）` |
| 494 | `# Ingress / ALB / Route53 record の確認 (Phase 5 nginx 投入後)` |

**2. Cluster overview tables が中途半端 (= Metrics stack までしか無く Observability 全体像が見えない):**

現状の Cluster overview には以下の table がある:
- 層 table (Cilium / CNI / NetworkPolicy / Gateway 等)
- Foundation addons (Gateway API / Metrics Server / KEDA)
- Edge layer (ALB Controller / ExternalDNS / ACM / IRSA / VPC subnet tags)
- Compute (Karpenter 一式)
- Metrics stack (Prometheus / Mimir + S3 + Pod Identity)

Logs (Loki) / Traces (Tempo) / Application Telemetry (Beyla + OTel Collector) の table は欠落。Backend role separation section (PR-B で追加) には文章で書かれているが、Cluster overview の table layout には未反映。

**3. Section 構成が local / production 混在で navigability が低い:**

現状の section 順序:
1. 🏗️ アーキテクチャ
2. 🚀 セットアップ (local k3d phase1-4)
3. 🌐 サービスアクセス (local URLs)
4. 🔧 主要コマンド (local make targets)
5. 💡 設計思想 (Hydration Pattern)
6. 🔍 監視・オブザーバビリティ (1-line list、Architecture + Backend role separation と重複)
7. 🛠️ トラブルシューティング (local)
8. 🤝 開発ワークフロー (local make up)
9. 障害調査例 (環境共通)
10. Production Operations

設計思想 と 監視・オブザーバビリティ が local の中央に挟まり、Production Operations は最後に bolt on された印象。Production 用 URL section も無く、`grafana.panicboat.net` 等の存在は readme 上で発見不可。

### 加えて Main architecture diagram の Mermaid parse error

L51 の `App -.->|stdout (file tail)| OTelCol` で `(file tail)` の括弧を Mermaid parser が node-shape 開始 `(` と誤認し、parse error で render に失敗する。`mmdc` でローカル検証済。

### 加えて PR-B 由来の minor 指摘 2 件

PR-B (#345) の code review で挙がった非 blocking の指摘:
- L162: `local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)、production-specific な storage choice。` の `、` 接続が読みづらい
- L163-164: section 区切りの空行が 2 行連続 (他 section は 1 行で統一)

---

## Architecture

### Section 構成 (after)

```
# Title + 概要

## 🏗️ アーキテクチャ
  - Mermaid: architecture diagram (LR layout、EKS Cluster wrapper 除去、Beyla / OTel Collector を別 subgraph で funnel 強調)
  - 役割分離
  - Backend role separation

## 💡 設計思想
  - Hydration Pattern
  - Components / Manifests

## 🚀 Local Development
  - Phase 1-4 setup (make phase1-4)
  - Local access URLs (grafana.local 等)
  - 主要コマンド (make targets)
  - 開発ワークフロー (make up / make down)
  - Local troubleshooting

## 🏢 Production Operations (EKS eks-production)
  - Cluster overview (= 全 tables、historical noise 除去、Observability 3 tables 追加)
  - Production access URLs (= 4 hostname)
  - Initial Bootstrap
  - Daily Operations
  - Cilium-specific operations
  - Foundation addon operations
  - Production troubleshooting
  - GitOps 原則

## 障害調査例
  - Mermaid: Alert → Metrics → Traces → Logs → Root cause
```

旧 `🔍 監視・オブザーバビリティ` section は削除 (Backend role separation + 拡充 Cluster overview と完全重複)。旧 `🛠️ トラブルシューティング` (local) と `🤝 開発ワークフロー` は Local Development の中に統合。

---

## Design Decisions

### Cluster overview tables の rewrite 方針

既存 tables の **column 数 / column 順序 / 情報密度** は維持。section header だけ neutral に書き換え、historical 行 (= `system` MNG) は削除、forward refs は current state 表現に置換。

| 旧 section header | 新 section header |
|---|---|
| `Cluster overview (post Plan 2)` | `Cluster overview` |
| `加えて Plan 1c-α で以下の foundation addons を導入:` | `Foundation layer (Gateway API / autoscaling)` |
| `さらに Plan 1c-β で以下を導入:` | `Edge layer (ingress / DNS / TLS)` |
| `加えて Plan 2 で以下を導入:` | `Compute layer (Karpenter)` |
| `加えて Plan 3 Sub-project 2 (Metrics stack) で以下を導入:` | `Observability — Metrics stack` |
| (新規) | `Observability — Logs stack` |
| (新規) | `Observability — Traces stack` |
| (新規) | `Observability — Application Telemetry` |

### 新規 Observability tables (3 つ)

**Logs stack:**

| Component / Resource | 配置 | 役割 |
|---|---|---|
| `kubernetes/components/loki/production/` | `monitoring` namespace | chart `grafana-community/loki` (SingleBinary mode)。container log の OTLP HTTP ingest (= OTel Collector からの push)、LogQL query、Grafana datasource の primary log backend |
| Loki S3 backend | `loki-<account-id>/production/` | long-term log retention 30 日 (S3 lifecycle policy) |
| Loki Pod Identity | `monitoring:loki` SA → `eks-${env}-loki` IAM role | Loki pod が S3 backend へ access するため |

**Traces stack:**

| Component / Resource | 配置 | 役割 |
|---|---|---|
| `kubernetes/components/tempo/production/` | `monitoring` namespace | chart `grafana/tempo` (monolithic mode)。Beyla 由来 trace の OTLP gRPC ingest (= OTel Collector 経由)、TraceQL query、Grafana datasource の primary trace backend。metrics-generator (service-graphs processor) で service-graph metrics を生成し Mimir へ remote_write |
| Tempo S3 backend | `tempo-<account-id>/production/` | long-term trace retention 7 日 (S3 lifecycle policy) |
| Tempo Pod Identity | `monitoring:tempo` SA → `eks-${env}-tempo` IAM role | Tempo pod が S3 backend へ access するため |

**Application Telemetry:**

| Component / Resource | 配置 | 役割 |
|---|---|---|
| `kubernetes/components/beyla/production/` | `monitoring` namespace | chart `grafana/beyla` (DaemonSet)。eBPF auto-instrumentation で app の HTTP / SQL / gRPC を計装、OTLP gRPC で OTel Collector に traces + RED metrics (= `http_server_*` / `http_client_*` 等) を export |
| `kubernetes/components/opentelemetry-collector/production/` | `monitoring` namespace | chart `opentelemetry/opentelemetry-collector` (DaemonSet、per-node)。Beyla からの OTLP gRPC traces を Tempo に route、chart preset `logsCollection` の filelog receiver で container log を tail し Loki に OTLP HTTP で export、`kubernetesAttributes` preset で k8s resource attribute を enrich |

### 撤去済 row (`system` MNG)

L400 の `system` MNG | (撤去済 in PR 3) | ... 行を **完全削除**。Plan 2 PR 3 で物理的に削除済の MNG を docs に残すと「現在の cluster 状態」の正確性が損なわれる。CLAUDE.md "when (= 撤去履歴) は git history に任せる" 原則に従う。

### Forward refs の rewrite 方針

| L | 旧 | 新 |
|---|---|---|
| 406 | `Alertmanager (receiver は Phase 4 で追加)` | `Alertmanager (receivers 未設定、外部通知 wire up なし)` |
| 406 | `Grafana (data source は Mimir primary、Loki / Tempo は Sub-project 3 / 4 で追加)` | `Grafana (data source: Mimir primary、Prometheus local secondary、Loki、Tempo)` |
| 408 | `Mimir S3 backend ... Sub-project 1 で provision、Sub-project 2 Task 1 で rename。long-term metrics retention 90 日` | `Mimir S3 backend ... long-term metrics retention 90 日 (S3 lifecycle policy)` |
| 410 | `共有 namespace ... Phase 3 全 sub-projects 共有。Sub-project 3 (Loki) / Sub-project 4 (Tempo + OpenTelemetry + Beyla + Hubble OTLP) も同 namespace を利用予定だが、各々別 spec で扱う` | `共有 namespace ... Mimir / Loki / Tempo / OpenTelemetry Collector / Prometheus / Grafana / Alertmanager / Beyla がすべて同 namespace で deploy` |
| 460 | `# Hubble UI（Phase 4 で外部公開予定、現状は port-forward only）` | `# Hubble UI (= https://hubble.panicboat.net/ 、oauth2-proxy 経由で外部公開)` |
| 494 | `# Ingress / ALB / Route53 record の確認 (Phase 5 nginx 投入後)` | `# Ingress / ALB / Route53 record の確認` |

### 新規 Production access URLs section

Production cluster の Web UI は ALB + oauth2-proxy で外部公開済。section "Production access URLs" を **Cluster overview の直後** に挿入し、4 hostname を表形式で記載。

| Service | URL | 認証 |
|---|---|---|
| Grafana | https://grafana.panicboat.net | oauth2-proxy (GitHub OAuth) |
| Prometheus | https://prometheus.panicboat.net | oauth2-proxy (GitHub OAuth) |
| Alertmanager | https://alertmanager.panicboat.net | oauth2-proxy (GitHub OAuth) |
| Hubble UI | https://hubble.panicboat.net | oauth2-proxy (GitHub OAuth) |

4 URL は ALB IngressGroup `panicboat-platform` で 1 ALB 共有、ExternalDNS が Route53 に record 自動生成、ACM wildcard cert `*.panicboat.net` で TLS 終端。

### Mermaid 修正 (L51)

```diff
-    App -.->|stdout (file tail)| OTelCol
+    App -.->|stdout via filelog tail| OTelCol
```

`(file tail)` の `(` を Mermaid parser が node shape の開始と誤認するため括弧を除去。意味は「container stdout を OTel Collector の filelog receiver が tail する」で同じ。

### PR-B minor fix

**L162:**

```diff
-local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)、production-specific な storage choice。
+local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)。production-specific な storage choice。
```

**L163-164:**

```diff
local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)。production-specific な storage choice。

-
## 🚀 セットアップ
```

(= 連続 blank 行を 1 行に統一)

### Section の局所統合方針

- 旧 `🚀 セットアップ` + 旧 `🌐 サービスアクセス` (local URLs) + 旧 `🔧 主要コマンド` + 旧 `🤝 開発ワークフロー` + 旧 `🛠️ トラブルシューティング` を 1 つの **`## 🚀 Local Development`** section にまとめる
- 各 sub-section は内容を保持、見出しレベルを `### Phase 1: Foundation Setup (基盤構築)` 等のまま維持
- 旧 `💡 設計思想` を `🏗️ アーキテクチャ` の直後に移動 (= "what" の次に "why" を読ませる構成)
- 旧 `🔍 監視・オブザーバビリティ` section ごと削除
- 旧 `Production Operations` (## 見出し) を **`## 🏢 Production Operations`** に絵文字付与で他 section と統一
- 旧 `障害調査例` (## 見出し) は最後尾に維持、絵文字は無しのまま (= troubleshooting 系の Mermaid で他 section と性質が違うため)

---

## Changes

### Modified

| File | 変更内容 |
|---|---|
| `kubernetes/README.md` | 上記すべて: Mermaid 修正 / section 再編 / historical noise 除去 / observability tables 3 追加 / production URL section 追加 / PR-B minor fix |

### Untouched

- すべての kubernetes/components/ / kubernetes/manifests/ ファイル (= docs only)
- spec / plan ファイル
- それ以外すべて

---

## Verification

1. **Mermaid syntax**: 3 図すべてが local の mmdc / mermaid.live / GitHub web UI のいずれかで syntax error なく render できる
2. **historical noise 残骸ゼロ**:
   - `grep -n "Plan [0-9]\|Sub-project [0-9]\|Phase [0-9].*予定\|Phase [0-9].*追加\|撤去済 in PR" kubernetes/README.md` の出力が **0 行** (= Phase 1-4 of `make phaseN` setup は当然残る、それ以外の historical pattern が消えていること)
3. **Cluster overview tables 完成度**:
   - 層 table / Foundation layer / Edge layer / Compute layer / Observability — Metrics / Logs / Traces / Application Telemetry の 8 tables がある
   - Mimir / Loki / Tempo / Beyla / OTel Collector / Prometheus / Grafana / Alertmanager 各 component が table のどこかに 1 回は登場
4. **Production access URLs**: 4 hostname (grafana / prometheus / alertmanager / hubble) が記載
5. **PR-B minor fix**: L162 の `、` → `。`、連続 blank 行が 1 行に
6. **Backend role separation**: PR-B で追加した section の内容は無変更で残る

---

## Risks / Open Questions

| リスク | 影響 | 緩和策 |
|---|---|---|
| Mermaid `stdout via filelog tail` の表現が分かりにくい | 読み手が "filelog tail" の意味を即座に把握できない | 役割分離 / Backend role separation で「OTel Collector の filelog receiver が container log を tail」と既に説明済、文脈で理解可能 |
| section 大幅再編で reader が現行 README を覚えていた場合に迷う | 既存 link / bookmark の anchor 変更 | README 内 anchor だけで GitHub の link 切れ等は無し。 PR description に「主要な見出し変更点」を列挙する |
| `(receivers 未設定、外部通知 wire up なし)` 表現が読み手に「これから設定するつもり」と読まれる | 意図と異なる解釈 | "current state" を明示的に書く: `Alertmanager (= receivers 未設定で稼働中、Phase 後で wire up 予定の場合は plan に記録)` も検討。最終的には spec 段階で確認しつつ書き換え |
| Hubble UI の `https://hubble.panicboat.net/` 表記で trailing slash 有無 | リンク切れの心配 | trailing slash は ALB / oauth2-proxy 両方で正規化される、無くてもアクセス可能。表記は trailing slash 無しで統一 |
| `🏢` 絵文字を Production Operations section に付与する選択 | スタイル一貫性 | 既存 section が `🏗️ / 🚀 / 🌐 / 🔧 / 💡 / 🔍 / 🛠️ / 🤝` を使っており、新規絵文字を追加する負担は小さい。代替絵文字 (`☁️` / `🏭` 等) も spec 段階で再検討可能 |

---

## Out of Scope

- すべての kubernetes/components/ / kubernetes/manifests/ ファイル変更 (= docs only PR)
- nginx-sample 関連の文言 (= 無視で確定)
- Alertmanager の receiver wire up (= 別 PR、本 PR は現状を記述するのみ)
- Grafana datasource 設定変更 (= PR-B で完了済)
- 他の `.md` ファイル (CLAUDE.md / aws/README.md 等) の cleanup
- spec / plan ディレクトリの整理
