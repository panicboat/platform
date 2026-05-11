# kubernetes/README.md Cleanup & Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `kubernetes/README.md` から historical noise を全面除去、Cluster overview に Observability 3 tables (Logs / Traces / Application Telemetry) を追加、Production access URLs section を新設、section 構成を Architecture → 設計思想 → Local Development → Production Operations → 障害調査例 に再編。併せて Main architecture diagram の Mermaid parse error と PR-B 由来の minor 指摘 2 件を修正。

**Architecture:** docs only PR。`kubernetes/README.md` のみを編集する。Flux suspend / cluster apply は不要。Mermaid syntax は local mmdc で render check、historical noise は grep で 0 件確認、新規 section / table の存在は grep で確認。

**Tech Stack:** Markdown / Mermaid (= flowchart syntax) / mmdc (= mermaid-cli for local syntax validation) / kustomize は不使用 / kubectl も不使用

**Working directory:** `.claude/worktrees/feat-readme-cleanup/` (worktree on branch `feat/eks-production-readme-cleanup`)

**Spec:** `docs/superpowers/specs/2026-05-11-eks-production-readme-cleanup-design.md`

---

## File Structure

### Modified

| Path | 変更内容 |
|---|---|
| `kubernetes/README.md` | Main architecture Mermaid 修正、L162 syntax / L163-164 blank line 修正、Cluster overview section headers neutral 化、forward refs 現状記述化、`system` MNG row 削除、Observability 3 tables 追加、Production access URLs section 新設、`🔍 監視・オブザーバビリティ` section 削除、section 再編 (Architecture → 設計思想 → Local Development → Production Operations → 障害調査例)、code block の Hubble UI / nginx コメント rewrite |

### Untouched

- すべての `kubernetes/components/` / `kubernetes/manifests/` ファイル (= docs only PR)
- 他の `.md` (CLAUDE.md / aws/README.md 等)
- spec / plan 自身

---

## Workflow Overview

docs only のため Flux suspend / kubectl apply は不要。シンプルな edit → verify → commit → PR の流れ:

```
Task 1-7   README 編集 (= mechanical edits + restructure)
Task 8     Verification (= mmdc render + grep noise + structure check)
Task 9     Git diff inspect + commit
Task 10    Push + Draft PR
   ↓ (user が merge)
Task 11    Worktree cleanup (= post-merge)
```

各 Task は subagent 単独で完結する単位。Task 1-8 は同一 subagent で連続実行可能 (= 全 edits + verify を 1 subagent で)。Task 9-10 は別 subagent (= commit / PR 操作)、Task 11 は post-merge 別 subagent。

---

## Task 1: Mermaid parse error と PR-B minor を修正

**Files:**
- Modify: `kubernetes/README.md`

**目的:** 機械的な小修正をまず片付ける。Mermaid syntax fix (1 行) + PR-B 由来 minor 2 件。

- [ ] **Step 1: Mermaid Main architecture diagram の括弧を除去 (L51)**

`kubernetes/README.md` の以下を:

```
    %% Logs: OTel Collector が container log file を直接 tail (filelog receiver)
    App -.->|stdout (file tail)| OTelCol
```

以下に変更:

```
    %% Logs: OTel Collector が container log file を直接 tail (filelog receiver)
    App -.->|stdout via filelog tail| OTelCol
```

Edit tool で `App -.->|stdout (file tail)| OTelCol` → `App -.->|stdout via filelog tail| OTelCol` を replace。

- [ ] **Step 2: PR-B minor #1 — L162 の文末 syntax を改善**

以下を:

```
local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)、production-specific な storage choice。
```

以下に変更:

```
local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)。production-specific な storage choice。
```

Edit tool で `S3 不要)、production-specific` → `S3 不要)。production-specific` を replace。

- [ ] **Step 3: PR-B minor #2 — L163-164 の連続 blank 行を 1 行に統一**

`production-specific な storage choice。\n\n\n## 🚀 セットアップ` を `production-specific な storage choice。\n\n## 🚀 セットアップ` に変更。

Edit tool で:
- old_string:
  ```
  production-specific な storage choice。


  ## 🚀 セットアップ
  ```
- new_string:
  ```
  production-specific な storage choice。

  ## 🚀 セットアップ
  ```

(= 末尾の blank 行を 1 つ削減)

- [ ] **Step 4: 編集結果を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git diff kubernetes/README.md | head -40
```

期待: 3 spot の小さな修正が見える。`stdout (file tail)` が消えて `stdout via filelog tail` に。`、production-specific` が `。production-specific` に。連続 blank 行が 1 つ減っている。

---

## Task 2: Cluster overview の section headers を neutral 化、forward refs を現状記述化

**Files:**
- Modify: `kubernetes/README.md`

**目的:** Production Operations section の "Cluster overview" 内 historical 表現を全部除去。

- [ ] **Step 1: "Cluster overview (post Plan 2)" header を rewrite**

`### Cluster overview (post Plan 2)` → `### Cluster overview`

- [ ] **Step 2: "加えて Plan 1c-α で以下の foundation addons を導入：" を rewrite**

以下を:

```
加えて Plan 1c-α で以下の foundation addons を導入：
```

以下に置換:

```
#### Foundation layer (Gateway API / autoscaling)
```

(= 段落書きの "加えて..." を section heading に格上げして neutral 化、各 table がどの層かを直感的に表示)

- [ ] **Step 3: "さらに Plan 1c-β で以下を導入：" を rewrite**

以下を:

```
さらに Plan 1c-β で以下を導入：
```

以下に置換:

```
#### Edge layer (ingress / DNS / TLS)
```

- [ ] **Step 4: "加えて Plan 2 で以下を導入：" を rewrite**

以下を:

```
加えて Plan 2 で以下を導入：
```

以下に置換:

```
#### Compute layer (Karpenter)
```

- [ ] **Step 5: "加えて Plan 3 Sub-project 2 (Metrics stack) で以下を導入：" を rewrite**

以下を:

```
加えて Plan 3 Sub-project 2 (Metrics stack) で以下を導入：
```

以下に置換:

```
#### Observability — Metrics stack
```

- [ ] **Step 6: Compute layer table 内の `system` MNG row (撤去済) を行ごと削除**

以下の行 (L400 付近) を完全削除:

```
| `system` MNG | (撤去済 in PR 3) | Plan 2 PR 3 で削除。CoreDNS / Cilium operator / Flux / addons は全部 Karpenter NodePool に移行 |
```

Edit tool で old_string をこの行全体 + 前後の `\n` を含めて指定、new_string は空 (= 行削除)。具体的には:

- old_string:
  ```
  | Karpenter sub-module (aws/karpenter stack) | (AWS) | SQS interruption queue + EventBridge rules + Controller IAM role + Pod Identity Association + Node IAM role + EC2 Instance Profile を独立 stack で集約 |
  | `system` MNG | (撤去済 in PR 3) | Plan 2 PR 3 で削除。CoreDNS / Cilium operator / Flux / addons は全部 Karpenter NodePool に移行 |
  ```
- new_string:
  ```
  | Karpenter sub-module (aws/karpenter stack) | (AWS) | SQS interruption queue + EventBridge rules + Controller IAM role + Pod Identity Association + Node IAM role + EC2 Instance Profile を独立 stack で集約 |
  ```

(= 前行を残し、撤去済 row だけを削除)

- [ ] **Step 7: Metrics stack table の Alertmanager / Grafana 行 (L406) の forward ref を rewrite**

以下を:

```
| `kubernetes/components/prometheus-operator/production/` | `monitoring` namespace | chart `prometheus-community/kube-prometheus-stack` v84.5.0。Prometheus が cluster の metrics を scrape し Mimir に remote write、Alertmanager (receiver は Phase 4 で追加)、Grafana (data source は Mimir primary、Loki / Tempo は Sub-project 3 / 4 で追加)、node-exporter / kube-state-metrics / prometheus-operator を bundle |
```

以下に置換:

```
| `kubernetes/components/prometheus-operator/production/` | `monitoring` namespace | chart `prometheus-community/kube-prometheus-stack` v84.5.0。Prometheus が cluster の metrics を scrape し Mimir に remote write、Alertmanager (receivers 未設定、外部通知 wire up なし)、Grafana (data source: Mimir primary / Prometheus local secondary / Loki / Tempo)、node-exporter / kube-state-metrics / prometheus-operator を bundle |
```

- [ ] **Step 8: Mimir S3 backend 行 (L408) の "Sub-project 1 で provision、Sub-project 2 Task 1 で rename" を rewrite**

以下を:

```
| Mimir S3 backend | `mimir-559744160976/production/` | Sub-project 1 で provision、Sub-project 2 Task 1 で rename。long-term metrics retention 90 日 (S3 lifecycle policy) |
```

以下に置換:

```
| Mimir S3 backend | `mimir-559744160976/production/` | long-term metrics retention 90 日 (S3 lifecycle policy) |
```

- [ ] **Step 9: 共有 namespace 行 (L410) の forward ref を rewrite**

以下を:

```
| 共有 namespace | `monitoring` (= `kubernetes/components/prometheus-operator/namespace.yaml` で定義) | Phase 3 全 sub-projects 共有。Sub-project 3 (Loki) / Sub-project 4 (Tempo + OpenTelemetry + Beyla + Hubble OTLP) も同 namespace を利用予定だが、各々別 spec で扱う |
```

以下に置換:

```
| 共有 namespace | `monitoring` (= `kubernetes/components/prometheus-operator/namespace.yaml` で定義) | Mimir / Loki / Tempo / OpenTelemetry Collector / Prometheus / Grafana / Alertmanager が同 namespace で deploy。Beyla は別 namespace (`beyla`) |
```

- [ ] **Step 10: Foundation addon operations code block の Hubble UI コメント (L460) を rewrite**

以下を:

```
# Hubble UI（Phase 4 で外部公開予定、現状は port-forward only）
cilium hubble ui
```

以下に置換:

```
# Hubble UI (= https://hubble.panicboat.net/ 、oauth2-proxy 経由で外部公開)
cilium hubble ui
```

- [ ] **Step 11: Foundation addon operations code block の Ingress / Route53 コメント (L494) を rewrite**

以下を:

```
# Ingress / ALB / Route53 record の確認 (Phase 5 nginx 投入後)
```

以下に置換:

```
# Ingress / ALB / Route53 record の確認
```

- [ ] **Step 12: 編集結果を grep で確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "Plan [0-9]|Sub-project [0-9]|Phase [0-9].*予定|Phase [0-9].*追加|撤去済 in PR|post Plan" kubernetes/README.md
```

期待: 出力 0 行 (= historical noise 完全消滅)。Phase 1-4 of `make phaseN` setup は `## 🚀 セットアップ` の `### Phase 1: Foundation Setup` 等の見出しに残るが、これは Makefile target に対応する legitimate な workflow 表記なので OK。grep pattern が "Phase N.*予定/追加" / "Plan N" / "Sub-project N" 等の historical pattern にマッチするかが重要。

念のため Phase の見出しが意図通り残っていることも確認:

```bash
grep -nE "^### Phase [0-9]" kubernetes/README.md
```

期待:
```
167:### Phase 1: Foundation Setup (基盤構築)
176:### Phase 2: FluxCD Installation (GitOps基盤)
183:### Phase 3: Hydration & Sync (アプリ展開)
191:### Phase 4: GitOps Complete Migration
```

(L 番号は subsequent task の編集で前後する可能性あり、本質は 4 つの見出しがあること)

---

## Task 3: Observability 3 tables を Cluster overview に追加

**Files:**
- Modify: `kubernetes/README.md`

**目的:** Logs / Traces / Application Telemetry の現状を table 形式で文書化。Metrics stack table の直後に挿入。

- [ ] **Step 1: Metrics stack table の直後 (= `### Initial Bootstrap (one-time)` の直前) に 3 新規 table を挿入**

挿入位置を特定する unique 文字列 (= Metrics stack table の最後の行):

```
| 共有 namespace | `monitoring` (= `kubernetes/components/prometheus-operator/namespace.yaml` で定義) | Mimir / Loki / Tempo / OpenTelemetry Collector / Prometheus / Grafana / Alertmanager が同 namespace で deploy。Beyla は別 namespace (`beyla`) |
```

(= Task 2 Step 9 で rewrite した結果)

その後に空行 + 3 つの table を挿入。Edit tool で:

- old_string:
  ```
  | 共有 namespace | `monitoring` (= `kubernetes/components/prometheus-operator/namespace.yaml` で定義) | Mimir / Loki / Tempo / OpenTelemetry Collector / Prometheus / Grafana / Alertmanager が同 namespace で deploy。Beyla は別 namespace (`beyla`) |

  ### Initial Bootstrap (one-time)
  ```
- new_string:
  ```
  | 共有 namespace | `monitoring` (= `kubernetes/components/prometheus-operator/namespace.yaml` で定義) | Mimir / Loki / Tempo / OpenTelemetry Collector / Prometheus / Grafana / Alertmanager が同 namespace で deploy。Beyla は別 namespace (`beyla`) |

  #### Observability — Logs stack

  | Component / Resource | 配置 | 役割 |
  |---|---|---|
  | `kubernetes/components/loki/production/` | `monitoring` namespace | chart `grafana/loki` (SingleBinary mode)。container log の OTLP HTTP ingest (= OTel Collector からの push)、LogQL query、Grafana datasource の primary log backend |
  | Loki S3 backend | `loki-559744160976/production/` | long-term log retention 30 日 (S3 lifecycle policy) |
  | Loki Pod Identity | `monitoring:loki` SA → `eks-production-loki` IAM role | Loki pod が S3 backend へ access するため |

  #### Observability — Traces stack

  | Component / Resource | 配置 | 役割 |
  |---|---|---|
  | `kubernetes/components/tempo/production/` | `monitoring` namespace | chart `grafana/tempo` v1.24.4 (monolithic mode)。Beyla 由来 trace の OTLP gRPC ingest (= OTel Collector 経由)、TraceQL query、Grafana datasource の primary trace backend。metrics-generator (service-graphs processor) で service-graph metrics を生成し Mimir に remote_write |
  | Tempo S3 backend | `tempo-559744160976/production/` | long-term trace retention 7 日 (S3 lifecycle policy) |
  | Tempo Pod Identity | `monitoring:tempo` SA → `eks-production-tempo` IAM role | Tempo pod が S3 backend へ access するため |

  #### Observability — Application Telemetry

  | Component / Resource | 配置 | 役割 |
  |---|---|---|
  | `kubernetes/components/beyla/production/` | `beyla` namespace | chart `grafana/beyla` (DaemonSet)。eBPF auto-instrumentation で app の HTTP / SQL / gRPC を計装、OTLP gRPC で OTel Collector に traces + RED metrics (= `http_server_*` / `http_client_*` 等) を export |
  | `kubernetes/components/opentelemetry-collector/production/` | `monitoring` namespace | chart `open-telemetry/opentelemetry-collector` (DaemonSet、per-node)。Beyla からの OTLP gRPC traces を Tempo に route、chart preset `logsCollection` の filelog receiver で container log を tail し Loki に OTLP HTTP で export、`kubernetesAttributes` preset で k8s resource attribute を enrich |

  ### Initial Bootstrap (one-time)
  ```

- [ ] **Step 2: 挿入結果を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^#### Observability —|^#### Foundation|^#### Edge|^#### Compute" kubernetes/README.md
```

期待: 6 つの section heading (Foundation / Edge / Compute / Observability — Metrics / Logs / Traces / Application Telemetry) が表示される (= Task 2 で作った 4 つ + 本 Task で作った 3 つ、計 7 つ。実際の grep 結果は #### で始まる行を全部取り、その中に各 layer 名があれば OK)。実出力例:
```
375:#### Foundation layer (Gateway API / autoscaling)
383:#### Edge layer (ingress / DNS / TLS)
393:#### Compute layer (Karpenter)
404:#### Observability — Metrics stack
412:#### Observability — Logs stack
420:#### Observability — Traces stack
428:#### Observability — Application Telemetry
```

(L 番号は subsequent task で前後する可能性あり)

---

## Task 4: Production access URLs section を新設

**Files:**
- Modify: `kubernetes/README.md`

**目的:** `grafana.panicboat.net` 等 4 hostname を README で発見可能にする。Cluster overview の直後 (= `### Initial Bootstrap (one-time)` の直前) に新規 section を挿入。

- [ ] **Step 1: Cluster overview の終端 (= Observability — Application Telemetry table の直後) と Initial Bootstrap の間に新規 section を挿入**

unique 文字列 (= Application Telemetry table の最終行):

```
| `kubernetes/components/opentelemetry-collector/production/` | `monitoring` namespace | chart `open-telemetry/opentelemetry-collector` (DaemonSet、per-node)。Beyla からの OTLP gRPC traces を Tempo に route、chart preset `logsCollection` の filelog receiver で container log を tail し Loki に OTLP HTTP で export、`kubernetesAttributes` preset で k8s resource attribute を enrich |
```

Edit tool で:

- old_string:
  ```
  | `kubernetes/components/opentelemetry-collector/production/` | `monitoring` namespace | chart `open-telemetry/opentelemetry-collector` (DaemonSet、per-node)。Beyla からの OTLP gRPC traces を Tempo に route、chart preset `logsCollection` の filelog receiver で container log を tail し Loki に OTLP HTTP で export、`kubernetesAttributes` preset で k8s resource attribute を enrich |

  ### Initial Bootstrap (one-time)
  ```

- new_string:
  ```
  | `kubernetes/components/opentelemetry-collector/production/` | `monitoring` namespace | chart `open-telemetry/opentelemetry-collector` (DaemonSet、per-node)。Beyla からの OTLP gRPC traces を Tempo に route、chart preset `logsCollection` の filelog receiver で container log を tail し Loki に OTLP HTTP で export、`kubernetesAttributes` preset で k8s resource attribute を enrich |

  ### Production access URLs

  Web UI は ALB IngressGroup `panicboat-platform` で 1 ALB を共有、ExternalDNS が Route53 record を自動生成、ACM wildcard cert `*.panicboat.net` で TLS 終端、oauth2-proxy (GitHub OAuth) で認証。

  | Service | URL | 認証 |
  |---|---|---|
  | Grafana | https://grafana.panicboat.net | oauth2-proxy (GitHub OAuth) |
  | Prometheus | https://prometheus.panicboat.net | oauth2-proxy (GitHub OAuth) |
  | Alertmanager | https://alertmanager.panicboat.net | oauth2-proxy (GitHub OAuth) |
  | Hubble UI | https://hubble.panicboat.net | oauth2-proxy (GitHub OAuth) |

  ### Initial Bootstrap (one-time)
  ```

- [ ] **Step 2: 挿入結果を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^### Production access URLs|panicboat\.net" kubernetes/README.md
```

期待: `### Production access URLs` の見出し 1 行 + 4 hostname (grafana / prometheus / alertmanager / hubble) の各 URL 行が表示される。

---

## Task 5: 旧 `🔍 監視・オブザーバビリティ` section を削除

**Files:**
- Modify: `kubernetes/README.md`

**目的:** Backend role separation + 拡充 Cluster overview と完全重複の 1-line list を削除して DRY 化。

- [ ] **Step 1: section ごと削除**

以下のブロックを削除 (= `## 🔍 監視・オブザーバビリティ` から `## 🛠️ トラブルシューティング` の直前まで、空行 1 つ残す):

- old_string:
  ```
  ## 🔍 監視・オブザーバビリティ

  ### 統合監視スタック
  - **Prometheus**: メトリクス収集・アラート (kube-prometheus-stack v84.5.0、Mimir に remote write)
  - **Mimir**: 長期メトリクスストレージ (mimir-distributed v6.0.6、Microservices mode、S3 backend / retention 90 日)
  - **Grafana**: 可視化ダッシュボード
  - **Loki**: ログ集約
  - **Tempo**: 分散トレーシングバックエンド
  - **OpenTelemetry Collector**: テレメトリ統合 (traces / logs を per-node DaemonSet で集約)
  - **Beyla**: eBPF自動計装
  - **Cilium Hubble**: ネットワーク観測

  ### アクセス方法
  Gateway API経由で上記URLから直接アクセス可能。

  ## 🛠️ トラブルシューティング
  ```

- new_string:
  ```
  ## 🛠️ トラブルシューティング
  ```

- [ ] **Step 2: 削除を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^## 🔍|^### 統合監視スタック" kubernetes/README.md
```

期待: 出力 0 行 (= section ごと削除済)。

---

## Task 6: Section 大局再編 (= Local Development 統合 + 設計思想を Architecture 直後に移動 + 障害調査例を最後尾に)

**Files:**
- Modify: `kubernetes/README.md`

**目的:** 現状の local-content 散在を 1 つの `## 🚀 Local Development` に統合、`## 💡 設計思想` を `## 🏗️ アーキテクチャ` の直後に移動、`## 障害調査例` を最後尾に移動 (= 現状は Production Operations の直前)、`Production Operations` を `## 🏢 Production Operations` に絵文字統一。

このタスクは複数 section の H2 / H3 移動を含むため、step を細かく分けて実行する。

**重要:** Task 1-5 までの編集により README の line 番号は既存値からずれている可能性が高い。各 Edit は unique 文字列 (= section heading + 内容) で identify するため、line 番号には依存しない。

- [ ] **Step 1: `## 🚀 セットアップ` を `## 🚀 Local Development` に rename + `### Phase 1` 以降を sub-heading のままで保つ**

`## 🚀 セットアップ` → `## 🚀 Local Development`

(= 既存の "セットアップ" は local の k3d setup なので Local Development の同義として置換。配下の `### Phase 1: ...` 等は変更しない)

- [ ] **Step 2: `## 🌐 サービスアクセス` section を `## 🚀 Local Development` の subsection に降格**

現状の `## 🌐 サービスアクセス` (L197 付近) の H2 を `### Local access (Web UI via Gateway API)` に降格する。section 内の content (URLs / etc/hosts) は保持。

- old_string:
  ```
  ## 🌐 サービスアクセス

  **Gateway API経由でのブラウザアクセス:**

  /etc/hosts に以下を設定
  ```

- new_string:
  ```
  ### Local access (Web UI via Gateway API)

  **Gateway API経由でのブラウザアクセス:**

  /etc/hosts に以下を設定
  ```

加えて、section 末尾の `**サイドカーレスサービスメッシュ:**` リストは local 環境の特徴説明なので残す:

(= 内容変更不要、heading だけ降格すれば subsection としてつながる)

- [ ] **Step 3: `## 🔧 主要コマンド` を `### Make commands` に降格**

- old_string: `## 🔧 主要コマンド`
- new_string: `### Make commands`

- [ ] **Step 4: `## 🤝 開発ワークフロー` を `### 開発ワークフロー` に降格**

- old_string: `## 🤝 開発ワークフロー`
- new_string: `### 開発ワークフロー`

- [ ] **Step 5: `## 🛠️ トラブルシューティング` を `### Local troubleshooting` に降格**

- old_string: `## 🛠️ トラブルシューティング`
- new_string: `### Local troubleshooting`

- [ ] **Step 6: `## 💡 設計思想` を移動 (= 現状 L247 付近 → `## 🏗️ アーキテクチャ` 末尾の Backend role separation の直後)**

まず現状の `## 💡 設計思想` ブロック (= `## 💡 設計思想` から次の `## ` 見出しの直前まで) を **特定**:

```
## 💡 設計思想

### Hydration Pattern 戦略

**Why Hydration?**
1.  **可視性 (Visibility)**: 実際に適用される YAML が `manifests/` に存在するため、コミットログで変更理由が明確になる。
2.  **安全性 (Safety)**: Helm チャートのレンダリング結果を承認してからデプロイ可能。予期せぬ Breaking Change を防ぐ。
3.  **環境分離 (Isolation)**: `helmfile -e <env>` により環境ごとの差異を吸収しつつ、バージョン管理を厳密化。

### 構成管理

- **Components (`components/`)**: アプリケーションのソース（Helm Values, Kustomize Base/Overlays）。
- **Manifests (`manifests/`)**: 自動生成される最終成果物。
```

この段落を旧位置から削除し、新位置 (= Backend role separation section の直後、`## 🚀 Local Development` の直前) に挿入する。

**6.1 削除:**

- old_string (元の位置、`## 💡 設計思想` ブロック全体 + 末尾の空行):
  ```

  ## 💡 設計思想

  ### Hydration Pattern 戦略

  **Why Hydration?**
  1.  **可視性 (Visibility)**: 実際に適用される YAML が `manifests/` に存在するため、コミットログで変更理由が明確になる。
  2.  **安全性 (Safety)**: Helm チャートのレンダリング結果を承認してからデプロイ可能。予期せぬ Breaking Change を防ぐ。
  3.  **環境分離 (Isolation)**: `helmfile -e <env>` により環境ごとの差異を吸収しつつ、バージョン管理を厳密化。

  ### 構成管理

  - **Components (`components/`)**: アプリケーションのソース（Helm Values, Kustomize Base/Overlays）。
  - **Manifests (`manifests/`)**: 自動生成される最終成果物。

  ```

- new_string (= 段落ごと削除):
  ```

  ```

(= 元の位置に空行 1 つだけ残す)

**6.2 挿入:**

新位置は `## 🚀 Local Development` の直前 (= `## 🚀 セットアップ` から rename した heading の上)。Edit tool で:

- old_string:
  ```
  local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)。production-specific な storage choice。

  ## 🚀 Local Development
  ```

- new_string:
  ```
  local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)。production-specific な storage choice。

  ## 💡 設計思想

  ### Hydration Pattern 戦略

  **Why Hydration?**
  1.  **可視性 (Visibility)**: 実際に適用される YAML が `manifests/` に存在するため、コミットログで変更理由が明確になる。
  2.  **安全性 (Safety)**: Helm チャートのレンダリング結果を承認してからデプロイ可能。予期せぬ Breaking Change を防ぐ。
  3.  **環境分離 (Isolation)**: `helmfile -e <env>` により環境ごとの差異を吸収しつつ、バージョン管理を厳密化。

  ### 構成管理

  - **Components (`components/`)**: アプリケーションのソース（Helm Values, Kustomize Base/Overlays）。
  - **Manifests (`manifests/`)**: 自動生成される最終成果物。

  ## 🚀 Local Development
  ```

- [ ] **Step 7: `## Production Operations` を `## 🏢 Production Operations` に rename**

- old_string: `## Production Operations`
- new_string: `## 🏢 Production Operations`

- [ ] **Step 8: `## 障害調査例` を最後尾に移動 (= 現状 Production Operations の直前 → README 末尾)**

まず現状の `## 障害調査例` ブロックを抽出:

```
## 障害調査例

```mermaid
flowchart LR
    subgraph Problem["問題発生"]
        Alert["🚨 アラート発火<br/>Error Rate > 1%"]
    end
    [...]
    style Alert fill:#ef4444
    style RC fill:#22c55e,color:#fff
```
```

(= 38 行程度の Mermaid block)

**8.1 削除 (旧位置):**

- old_string: `## 障害調査例\n\n` から ` ``` \n\n## 🏢 Production Operations` まで (Edit tool で section 全体を 1 つの old_string とする、`## 🏢 Production Operations` は new_string にも含める)

具体的に:

- old_string: (現状の `## 障害調査例` ブロック全文 + 末尾の `## 🏢 Production Operations` の直前まで)
  ```
  ## 障害調査例

  ```mermaid
  flowchart LR
      subgraph Problem["問題発生"]
          Alert["🚨 アラート発火<br/>Error Rate > 1%"]
      end

      subgraph Metrics["Metrics (Prometheus)"]
          M1["http_requests_total<br/>status=500 増加"]
          M2["Exemplar リンク付き"]
      end

      subgraph Traces["Traces (Tempo)"]
          T1["Trace ID: abc123"]
          T2["Span: POST /api/users<br/>500ms, error=true"]
          T3["Span: DB Query<br/>480ms"]
      end

      subgraph Logs["Logs (Loki)"]
          L1["{trace_id=abc123}"]
          L2["ERROR: Connection timeout<br/>to database:5432"]
      end

      subgraph RootCause["根本原因"]
          RC["DB コネクション枯渇"]
      end

      Alert --> M1
      M1 --> M2
      M2 -->|"Exemplar Click"| T1
      T1 --> T2
      T2 --> T3
      T3 -->|"TraceID で検索"| L1
      L1 --> L2
      L2 --> RC

      style Alert fill:#ef4444
      style RC fill:#22c55e,color:#fff
  ```

  ## 🏢 Production Operations
  ```

- new_string:
  ```
  ## 🏢 Production Operations
  ```

(= 障害調査例 section を旧位置から削除して `## 🏢 Production Operations` だけを残す)

**8.2 挿入 (新位置 = README 末尾):**

README 末尾の最終 section は Production Operations 内の `### GitOps 原則`。その末尾の 3 つの bullet 直後に挿入する。

unique 文字列を最終行付近で identify:

```
- **Flux 自体の障害**で sync が止まった場合は、`flux suspend kustomization flux-system -n flux-system` で一時停止し、原因究明後に `flux resume` で再開
```

- old_string:
  ```
  - **Flux 自体の障害**で sync が止まった場合は、`flux suspend kustomization flux-system -n flux-system` で一時停止し、原因究明後に `flux resume` で再開
  ```

- new_string:
  ```
  - **Flux 自体の障害**で sync が止まった場合は、`flux suspend kustomization flux-system -n flux-system` で一時停止し、原因究明後に `flux resume` で再開

  ## 障害調査例

  ```mermaid
  flowchart LR
      subgraph Problem["問題発生"]
          Alert["🚨 アラート発火<br/>Error Rate > 1%"]
      end

      subgraph Metrics["Metrics (Prometheus)"]
          M1["http_requests_total<br/>status=500 増加"]
          M2["Exemplar リンク付き"]
      end

      subgraph Traces["Traces (Tempo)"]
          T1["Trace ID: abc123"]
          T2["Span: POST /api/users<br/>500ms, error=true"]
          T3["Span: DB Query<br/>480ms"]
      end

      subgraph Logs["Logs (Loki)"]
          L1["{trace_id=abc123}"]
          L2["ERROR: Connection timeout<br/>to database:5432"]
      end

      subgraph RootCause["根本原因"]
          RC["DB コネクション枯渇"]
      end

      Alert --> M1
      M1 --> M2
      M2 -->|"Exemplar Click"| T1
      T1 --> T2
      T2 --> T3
      T3 -->|"TraceID で検索"| L1
      L1 --> L2
      L2 --> RC

      style Alert fill:#ef4444
      style RC fill:#22c55e,color:#fff
  ```
  ```

- [ ] **Step 9: section 順序を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^## " kubernetes/README.md
```

期待 (順序):
```
## 🏗️ アーキテクチャ
## 💡 設計思想
## 🚀 Local Development
## 🏢 Production Operations
## 障害調査例
```

5 つの H2 が上記順序で並んでいることを確認。`## 🔍 監視・オブザーバビリティ` / `## 🌐 サービスアクセス` / `## 🔧 主要コマンド` / `## 🤝 開発ワークフロー` / `## 🛠️ トラブルシューティング` / `## 🚀 セットアップ` / `## Production Operations` (絵文字無し) は存在しない。

---

## Task 7: Backend role separation 内の subsection heading の整合性確認 (任意修正)

**Files:**
- Modify: `kubernetes/README.md` (= 必要な場合のみ)

**目的:** Backend role separation section 内に `### ` heading があるが、これは `## 🏗️ アーキテクチャ` 内の subsection として整合性を取る (= L129 の `### Backend role separation` heading は残す)。

- [ ] **Step 1: heading 階層を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^### " kubernetes/README.md | head -30
```

期待: アーキテクチャ section 内の `### 役割分離` / `### Dataflow` / `### Backend role separation` がそれぞれ独立した sub-heading として並ぶ。Local Development section 内の `### Phase 1: ...` / `### Phase 2: ...` 等が並ぶ。Production Operations 内の `### Cluster overview` / `### Production access URLs` / `### Initial Bootstrap (one-time)` 等が並ぶ。`#### Foundation layer` 等の 4 階級 heading が Cluster overview 内に並ぶ。

不整合 (例: `## ` のはずが `### ` のまま残っている、または逆) が見つかったら Edit tool で修正。なければ無変更で次へ。

---

## Task 8: Verification (= mmdc render + grep noise + structure check)

**Files:** なし (read-only checks)

- [ ] **Step 1: Mermaid 3 図を mmdc で render check**

```bash
cd /tmp && mkdir -p mermaid-prc && cd mermaid-prc
awk '/^```mermaid$/,/^```$/' /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup/kubernetes/README.md \
  | awk '/^```mermaid$/{n++; out="diag" n ".mmd"; next} /^```$/{out=""; next} out{print > out}'
ls *.mmd

npx --yes -p @mermaid-js/mermaid-cli mmdc -i diag1.mmd -o diag1.svg 2>&1 | tail -5
npx --yes -p @mermaid-js/mermaid-cli mmdc -i diag2.mmd -o diag2.svg 2>&1 | tail -5
npx --yes -p @mermaid-js/mermaid-cli mmdc -i diag3.mmd -o diag3.svg 2>&1 | tail -5
```

期待: 3 つの diag*.svg が生成され、`Parse error` 出力が無いこと。各 mmdc 実行の最終行は `Generating single mermaid chart` 等の正常完了メッセージ。

- [ ] **Step 2: historical noise が完全消滅していることを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "Plan [0-9]|Sub-project [0-9]|Phase [0-9].*予定|Phase [0-9].*追加|撤去済 in PR|post Plan" kubernetes/README.md
```

期待: 出力 0 行。

- [ ] **Step 3: H2 section 順序を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^## " kubernetes/README.md
```

期待 (5 行、順序通り):
```
## 🏗️ アーキテクチャ
## 💡 設計思想
## 🚀 Local Development
## 🏢 Production Operations
## 障害調査例
```

- [ ] **Step 4: Cluster overview の 7 sub-tables の見出しを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^#### " kubernetes/README.md
```

期待 (7 行):
```
#### Foundation layer (Gateway API / autoscaling)
#### Edge layer (ingress / DNS / TLS)
#### Compute layer (Karpenter)
#### Observability — Metrics stack
#### Observability — Logs stack
#### Observability — Traces stack
#### Observability — Application Telemetry
```

- [ ] **Step 5: Production access URLs section の存在を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -nE "^### Production access URLs|hubble\.panicboat|grafana\.panicboat|prometheus\.panicboat|alertmanager\.panicboat" kubernetes/README.md
```

期待: 5 行 (見出し + 4 hostname URL)。

- [ ] **Step 6: `system` MNG row が消えていることを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -n "system.*MNG.*撤去" kubernetes/README.md
```

期待: 出力 0 行。

- [ ] **Step 7: PR-B minor fix 2 件の確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -n "S3 不要)、production-specific" kubernetes/README.md
```

期待: 出力 0 行 (= 旧 syntax が無い)。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
grep -n "S3 不要)。production-specific" kubernetes/README.md
```

期待: 1 行出現 (= 新 syntax が存在)。

- [ ] **Step 8: 連続 blank 行が無いことを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
awk 'NR>1 && prev=="" && $0=="" { print NR-1, NR }; { prev=$0 }' kubernetes/README.md
```

期待: 出力 0 行 (= どこにも連続 blank 行が無い)。

---

## Task 9: Git diff inspect + commit

**Files:**
- `kubernetes/README.md` (= Task 1-7 で modify 済)

- [ ] **Step 1: 変更 file を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git status
```

期待: `kubernetes/README.md` のみ modified、untracked 無し。

- [ ] **Step 2: diff size 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git diff --stat kubernetes/README.md
```

期待: 大きめの差分 (= 100+ 行の insertions / deletions が想定)。

- [ ] **Step 3: 全 diff を eyeball check**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git diff kubernetes/README.md | head -200
git diff kubernetes/README.md | tail -200
```

期待: section 移動 + table 追加 + heading rename + 削除行 (`system` MNG / `🔍 監視・オブザーバビリティ` block) が見える。Mermaid 修正の 1 行差分が含まれる。

- [ ] **Step 4: staged に登録**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git add kubernetes/README.md
git status
```

期待: `kubernetes/README.md` が staged 状態。

- [ ] **Step 5: signoff 付きで commit (Co-Authored-By 禁止)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git -c commit.gpgsign=false commit -s -m "docs(kubernetes): README cleanup and restructure

kubernetes/README.md から累積した historical commentary を全面除去し、
Cluster overview に Observability 3 tables を追加、Production access URLs
section を新設、section 構成を Architecture → 設計思想 → Local Development
→ Production Operations → 障害調査例 の流れに再編する。

主な変更:
- Mermaid Main architecture diagram: 'stdout (file tail)' の括弧が parser を
  壊していたため 'stdout via filelog tail' に変更 (= 機能不変)
- Cluster overview: section headers を 'Plan 1c-α で導入' 等から
  neutral 表現 ('Foundation layer' 等) に rewrite、forward refs を
  current state 表現に置換、撤去済 'system' MNG row を削除
- 新規 tables: Observability — Logs stack / Traces stack /
  Application Telemetry (= Mimir / Loki / Tempo / Beyla / OTel Collector
  / Pod Identity / S3 backend の完全な現状記述)
- 新規 section: Production access URLs (= grafana / prometheus /
  alertmanager / hubble の 4 panicboat.net hostname を発見可能に)
- 旧 '🔍 監視・オブザーバビリティ' section 削除 (= Backend role
  separation + 拡充 Cluster overview と完全重複)
- Section reorder: 設計思想 を Architecture 直後に、障害調査例 を末尾に、
  local 関連 sub-sections を 'Local Development' 配下に集約、絵文字統一
- L162 syntax / L163-164 blank line の PR-B minor fix 同梱

Spec: docs/superpowers/specs/2026-05-11-eks-production-readme-cleanup-design.md"
```

- [ ] **Step 6: commit footer を検証**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git log -1 --format=%B | tail -3
```

期待: 末尾に `Spec:` 行 + `Signed-off-by: panicboat <panicboat@gmail.com>` 行。`Co-Authored-By` 行が無いこと。

---

## Task 10: branch を push して Draft PR を作成

**Files:** なし (git remote 操作のみ)

- [ ] **Step 1: branch を upstream tracking 付きで push**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
git push -u origin HEAD
```

期待: `feat/eks-production-readme-cleanup` が origin に push される。

- [ ] **Step 2: Draft PR を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
gh pr create --draft \
  --base main \
  --title "docs(kubernetes): README cleanup and restructure" \
  --body "$(cat <<'EOF'
## Summary

`kubernetes/README.md` を historical noise 完全除去 + Observability tables 補完 + Production access URLs section 新設 + section 構成再編で全面 cleanup する。併せて Mermaid parse error と PR-B 由来 minor 指摘 2 件を修正。

## Why

PR #331 → PR-A (#342) → PR-B (#345) の 3 連 PR を経て、`kubernetes/README.md` には phase 単位の加筆痕跡が累積していた:
- 'Plan 1c-α で導入' / 'Plan 2 PR 3 で削除' / 'Sub-project 3 で追加予定' 等の historical / forward annotation
- `system` MNG (撤去済) row が table に残存
- 'Phase 4 で外部公開予定、現状は port-forward only' (= 既に hubble.panicboat.net で公開済)
- Main architecture diagram の Mermaid parse error (\`(file tail)\` の括弧)
- Cluster overview tables が Metrics stack までしか無く Logs / Traces / Application Telemetry の現状が未文書化
- '🔍 監視・オブザーバビリティ' section が PR-B で追加した 'Backend role separation' と完全重複

CLAUDE.md "Documentation: what (現在の状態・動作) と why (その状態を選んだ理由) を書く。when (変更履歴) は書かない" 原則に沿って全面 cleanup する。

## Changes

- **Mermaid 修正**: Main architecture diagram L51 \`stdout (file tail)\` → \`stdout via filelog tail\` (= 括弧排除、意味不変、parser が通る)
- **Cluster overview 改訂**:
  - section headers: 'Plan 1c-α で導入' → 'Foundation layer (Gateway API / autoscaling)' 等の neutral 表現
  - forward refs: '(receiver は Phase 4 で追加)' → '(receivers 未設定、外部通知 wire up なし)'、'Sub-project 3 / 4 で追加' → 'data source: Mimir / Prometheus local / Loki / Tempo' 等
  - 撤去済 \`system\` MNG row を完全削除
- **新規 tables (3)**: Observability — Logs stack / Traces stack / Application Telemetry (= Loki / Tempo / Beyla / OTel Collector + S3 backend + Pod Identity)
- **新規 section**: Production access URLs (= grafana / prometheus / alertmanager / hubble の 4 \`panicboat.net\` hostname)
- **旧 section 削除**: '🔍 監視・オブザーバビリティ' (= Backend role separation と完全重複)
- **Section reorder**: 設計思想 を Architecture 直後に、障害調査例 を末尾に、local sub-sections を 'Local Development' に統合、Production Operations に 🏢 絵文字付与
- **PR-B minor fix**: L162 文末 syntax (\`、\` → \`。\`)、L163-164 連続 blank 行を 1 行に統一

## Verification

- ✅ Mermaid 3 図すべて mmdc で render error 無く生成 (= Main architecture が pre-PR では parse error、本 PR で fix)
- ✅ \`grep -E "Plan [0-9]|Sub-project [0-9]|Phase [0-9].*予定|Phase [0-9].*追加|撤去済 in PR|post Plan"\` が 0 件
- ✅ H2 section 順序: アーキテクチャ → 設計思想 → Local Development → Production Operations → 障害調査例
- ✅ Cluster overview に 7 sub-tables (Foundation / Edge / Compute / Observability × 4 stack)
- ✅ Production access URLs に 4 hostname
- ✅ \`system\` MNG row が消滅
- ✅ PR-B minor 2 件解消

## Out of Scope

- すべての \`kubernetes/components/\` / \`kubernetes/manifests/\` ファイル (= docs only PR)
- nginx-sample 関連の言及 (= ignore で確定)
- Alertmanager の receiver wire up (= 別 PR、本 PR は現状記述のみ)
- 他の \`.md\` (CLAUDE.md / aws/README.md 等) cleanup
- spec / plan ディレクトリ整理

## Spec / Plan

- Spec: \`docs/superpowers/specs/2026-05-11-eks-production-readme-cleanup-design.md\`
- Plan: \`docs/superpowers/plans/2026-05-12-eks-production-readme-cleanup.md\`

EOF
)"
```

期待: gh コマンドが PR URL を返す。Draft 状態。

- [ ] **Step 3: PR URL を保存**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-readme-cleanup
gh pr view --json url -q .url
```

PR URL を controller に報告。user は web UI から merge する。

---

## Task 11: 後始末 (post-merge cleanup)

**Files:** なし (worktree / branch cleanup)

**Pre-condition:** user が PR を main に merge 済。

- [ ] **Step 1: main を local に fetch**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git fetch origin main
git rev-parse origin/main
```

期待: PR がマージされた SHA が表示される。

- [ ] **Step 2: worktree を削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-readme-cleanup
git worktree prune
git worktree list
```

期待: `feat-readme-cleanup` 行が消えている。

- [ ] **Step 3: local branch を削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git branch -D feat/eks-production-readme-cleanup 2>/dev/null || true
git fetch -p origin
```

期待: local branch 削除完了。

- [ ] **Step 4: GitHub web UI で renderd README を目視確認**

URL: https://github.com/panicboat/platform/blob/main/kubernetes/README.md

期待:
- Mermaid 3 図すべて正常 render (parse error なし)
- H2 section 順序が design 通り
- Production access URLs に 4 URL clickable
- 各 table が正しく render

---

## Failure Modes

| 症状 | 推定原因 | リカバリ |
|---|---|---|
| Edit tool の old_string が unique でない (= 複数マッチ) | section 移動の途中で既に変更された string が他にも同じパターンで存在 | より広い context を old_string に含める (例: 前後 1-2 行を追加)、または `replace_all` の意図確認 |
| Task 6 Step 6.2 で挿入位置が見つからない | Task 1 Step 3 で blank 行を 1 行に減らした結果、unique pattern が変化 | 現在の README を `Read` で確認、`Local Development` 直前の正確な行を確認して old_string 更新 |
| Task 8 Step 1 で mmdc が `Parse error` を出力 | Task 1 Step 1 の Mermaid 修正以外に何か破壊された | git diff で Mermaid 部分の変更を確認、不要な変更があれば revert |
| Task 8 Step 2 で historical noise grep が 0 行にならない | Task 2 のどこかが漏れている | grep 出力の line を見て Task 2 の該当 Step を確認、Edit で修正 |
| Task 8 Step 3 で H2 順序が design 通りでない | Task 6 の section 移動が完了していない or 順序間違い | grep 出力を見て不足 / 余剰 / 順序を特定、Task 6 を再実行 |
| Task 9 Step 5 commit で signoff 行が無い | git config user.signingkey 周りの問題、または -s 抜け | `-s` を明示、`git config user.name` / `user.email` を確認 |
| Task 10 Step 2 で PR body の backtick エスケープが破綻 | heredoc の \\$ エスケープミス | heredoc を見直して \\\` で literal backtick を渡す or single-quote heredoc (\`EOF\`) を使う |

---

## Notes

- 本 plan は docs only。cluster 操作なし。Flux suspend 不要。
- Task 1-8 は同一 subagent で連続実行可能 (= 全 edits + verify)。Task 9-10 は別 subagent (= commit / push / PR)。Task 11 は post-merge。
- Edit tool は unique 文字列で identify するため line 番号には依存しない。task 順序で line 番号がずれても問題ない。
- Mermaid render check は mmdc を使うため node.js / npx 環境前提 (= 既に worktree で利用可能)。
- worktree path は `.claude/worktrees/feat-readme-cleanup/`、branch は `feat/eks-production-readme-cleanup`。
