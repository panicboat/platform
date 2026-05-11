# CLAUDE.md Documentation Compliance Cleanup

## Background

CLAUDE.md (user 全体設定) の **Documentation** セクションおよび **Language** セクション (ドキュメント見出し部分) が指示する原則:

**Documentation:**

- "what" (現在の状態・動作) と "why" (その状態を選んだ理由) を書く
- "when" (変更履歴) と "future" (未来予定) は書かない
- "why" には非自明な技術制約・bug 回避・互換性・パフォーマンス特性を含める
- "when" は git history、"future" は plan / spec ドキュメントに任せる
- README / design doc / コードコメント全般に適用
- source-of-truth (helmfile / lockfile / Terraform / cluster config 等) で取得できる値は書かない
- 設計意図に基づく安定値 (retention / mode / 識別子等) は書く

**Language (ドキュメント関連のみ、本 spec のスコープ):**

- ドキュメントの **見出しは英語**、本文は日本語
- コード内コメントの英語化 (Language ルールのコード側) は本 spec のスコープ外、別 follow-up PR で扱う (= 既存日本語コメントの大量翻訳は独立した翻訳プロジェクトとして分離)
- ただし本 PR で **新規に書く or 既存を書き換えるコメントは英語** にして、W7 違反を新規に増やさない

リポジトリ全体で本原則からの逸脱が散見されるため、一括是正を実施する。

## Scope

### In-scope

- ルート / サブディレクトリの `README*.md`
- `*.tf` / `*.hcl` ファイル内コメント
- `kubernetes/components/**/*.yaml` (Helm values / Kustomize manifests のコメント)
- `kubernetes/clusters/**/*.yaml` (Flux 設定のコメント)
- `.github/workflows/**/*.yaml` (workflow コメント)
- `Makefile` コメント
- `*.sh` コメント

### Out-of-scope

- `docs/superpowers/{plans,specs}/**` — CLAUDE.md が "future" の置き場として明示的に exempt
- `manifests/**` — `make hydrate` で生成される成果物。component 側 (`components/`) の修正で再生成される
- `.terragrunt-cache/**` / `.terraform/**` / `node_modules/**` — 外部依存
- `.claude/**` / `.git/**`

## Violation Categories

| ID | カテゴリ | 検出シグナル | 修正方針 |
|---|---|---|---|
| **W1** | when (変更履歴) | "Phase N で deploy 済", "削除済", "移行済", "以前は", "PR #N で" | 現在の状態のみを書く。理由が伝わらなくなる場合は inline で "why" を補う |
| **W2** | future (未来予定) | "Phase N で投入", "将来", "今後", "投入予定", "TBD", "→ spec/plan へ" | コメントごと削除。plan/spec doc に任せる |
| **W3** | why の欠落 | `enabled: false` / `disable: true` / 例外的構成にコメントなし | inline で非自明な制約・bug 回避を補う。chart default 上書きは特に対象 |
| **W4** | source-of-truth duplication | README 等に書かれた chart version / instance type / replica 数等 | source 側 (helmfile / Terraform) に任せ、README からは削除。設計意図 (mode / retention / 識別子) は残す |
| **W5** | spec/plan ID references | `docs/superpowers/specs/...md` への link、"spec の Errata E-N 参照"、"roadmap #N"、"Decision references:" block と D1/D2/... 形式の Decision 番号参照 | 削除。why を inline で書き直す (= 現在の README/コードだけで閉じる) |
| **W6** | local-vs-production TODO | `local/**` の `# TODO: (production) ...` narrative | 削除。production 設定は production sibling ファイルが speak for itself。`local/` は local 向け設定の現在状態だけ書く |
| **W8** | doc headings in Japanese | `kubernetes/README.md` / `aws/eks/README.md` の `## 概要`, `### 役割分離`, `## terragrunt 操作` 等の日本語見出し、および code block 内 shell コメントの日本語 | 見出しは英語に書き換え、本文は日本語のまま維持。code block 内 shell コメントも英語化 |

### Decision rubric (gray cases)

| ケース | 判断 |
|---|---|
| `kubernetes/Makefile` の `phase1` / `phase2` / ... target 名と `## Complete Phase N` help string | **残す** (現在の make target identifier) |
| `kubernetes/README.md` の `### Phase N` セクション (make target の説明) | **残す** |
| `// TODO:` 単独の code marker (作業中の一時的実装に貼る印) | **残す** (CLAUDE.md の Code Markers で許容) |
| `// TODO: Phase N で X` のような narrative TODO | **修正** (現在状態 + why に書き換える、または削除) |
| chart version (例: "Cilium 1.18.x") | helmfile 等から取得可能なため **削除** または major 系列の "why" (例: "EKS は 1 minor ずつしか上げられない") を残す |
| instance type (例: "m6g.large × 2-4") | Terraform から取得可能なため **削除**。設計意図 (Graviton ARM64 採用理由など) は残す |
| retention 値 (7d, 30d, 90d) | 設計意図に基づく安定値、**残す** |
| mode 識別子 (Microservices / Monolithic / SingleBinary) | 設計意図、**残す** |
| spec ID 参照 ("spec の Errata E-2 参照" 等) | **削除**。why を README/コード内に inline で展開 |

## Audit Results

### W1: when violations

| File:Line | Current | Proposed Fix |
|---|---|---|
| `kubernetes/README.md:274` | `EKS managed addon としては \`kube-proxy\` を削除済（KPR で代替）。残存 addon: ...` | `EKS managed addons: \`vpc-cni\` / \`coredns\` / \`aws-ebs-csi-driver\` / \`eks-pod-identity-agent\`。\`kube-proxy\` は Cilium KPR で代替するため不要。` |
| `kubernetes/clusters/production/repositories/monorepo.yaml:9` | `# 各 service deploy 開始。並行 monorepo PR で services/nginx を削除済。` | (削除、コンテキストブロック全体を縮約) |
| `kubernetes/clusters/production/repositories/monorepo.yaml:34` | `suspend: false  # Phase 6-2 で resume (= 6-1 で suspend deploy 済)` | `suspend: false  # monorepo の Flux Kustomization を稼働させる` |
| `kubernetes/components/nginx-sample/production/kustomization/deployment.yaml:20` | `# Phase 4-2 で deploy 済 Reloader が監視。` | `# Reloader が ConfigMap/Secret 変更を検出して rollout する。` |
| `kubernetes/components/nginx-sample/production/kustomization/ingress.yaml:4` | `# Phase 4-3 で deploy 済の ALB (= IngressGroup monitoring-uis) を共有、` | `# IngressGroup \`monitoring-uis\` の ALB を共有 (cost optimal)、` |
| `kubernetes/components/nginx-sample/production/kustomization/ingress.yaml:17` | `# Phase 4-3 既 ALB 共有 (= cost optimal、+$0/month)` | `# 既存 ALB を共有 (cost optimal、+$0/month)` |
| `kubernetes/components/nginx-sample/production/kustomization/external-secret.yaml:5` | `# nginx Deployment が env DEMO_MESSAGE 経由で参照。Phase 4-2 で deploy 済の` | `# nginx Deployment が env DEMO_MESSAGE 経由で参照。` |
| `kubernetes/components/opentelemetry/production/helmfile.yaml:6` | `# Phase 6-1 で deploy、Instrumentation CR は 6-2 で application namespace に追加。` | `# OTel Operator が Instrumentation CR を application namespace に配布する。` |
| `kubernetes/components/loki/local/helmfile.yaml:9` | `# grafana-community/loki に移行。本 sub-project (Phase 3 Sub-project 3) で` | `# chart は grafana-community/loki を使う。` (周辺コンテキストも reword) |
| `kubernetes/components/prometheus-operator/production/helmfile.yaml:6` | `#   - Alertmanager (alerting hub、receiver は Phase 4 で追加)` | `#   - Alertmanager (alerting hub、receiver は別 component で wire up)` または受信者が未設定であることだけ書く |

### W2: future violations

| File:Line | Current | Proposed Fix |
|---|---|---|
| `aws/karpenter/modules/main.tf:148` | `# Side effect: fixed IAM role name は immutable なので、将来この MNG ...` | "将来" を削除し、現在の制約 (immutable な fixed name の理由) だけ書く |
| `aws/eks/README.md:42` | `source ~/Workspace/eks-login.sh develop  # → eks-develop / us-east-1 (将来 cluster 追加時)` | "将来 cluster 追加時" を削除。`develop` 行ごと削除するか、未稼働である現状を別の方法で記述 |
| `aws/eks/README.md:12` | `\| develop \| us-east-1 \| eks-develop \| 未作成（必要時に envs/production/ を複製して envs/develop/ を新設）\|` | 行を削除 (= 現在稼働している環境のみ載せる) |
| `kubernetes/components/nginx-sample/production/kustomization/deployment.yaml:4` | `# Phase 1-4 全 component を nginx 投入で end-to-end validate するための demo` | `# 全 component を end-to-end validate するための demo application` |
| `kubernetes/components/nginx-sample/production/kustomization/{deployment,external-secret,ingress,kustomization,scaled-object,service}.yaml:2` | `# ... (Phase 5-2)` | `(Phase 5-2)` 部を削除 |
| `kubernetes/components/karpenter/production/kustomization/nodepool.yaml:12,47` | `... 将来 m9g+。` | "将来 m9g+" を削除。`Gt 5` の規約だけで意図は伝わる |
| `kubernetes/components/beyla/production/helmfile.yaml:7` | `# Phase 5-2 で nginx 投入時に即時 instrumentation 開始する基盤。` | `# eBPF DaemonSet として application Pod を auto-instrument する。` |
| `kubernetes/components/cilium/production/kustomization/kustomization.yaml:13` | `# 共有 Gateway を採用。将来 multi-application 化時に per-service Gateway` | `# 共有 Gateway を採用 (現状 application は単一)。` 程度に短縮 |
| `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml:10` | `# 将来 multi-application 化時に per-service Gateway 設計を再評価。` | (削除) |
| `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml:6` | `# email_domains に切替予定 (= Phase 6+ 引き継ぎ #11)。` | (削除) |
| `kubernetes/components/tempo/production/helmfile.yaml:11` | `# - D3: Monolithic mode (HA upgrade path 保持、Phase 4 で grafana/tempo-distributed への切替検討)` | `# - D3: Monolithic mode (現状は HA 不要、必要になれば grafana/tempo-distributed に切替可能)` |
| `kubernetes/components/keda/production/values.yaml:7` | `# Phase 1 では chart デフォルトを採用。HA 化や resource tuning は ...` | `# chart デフォルトを採用 (HA 化や resource tuning は現状不要)` |
| `kubernetes/components/nginx-sample/production/kustomization/external-secret.yaml:9` | `# 検知して Secret 変更時に auto-rollout (= roadmap #14)。` | `# 検知して Secret 変更時に auto-rollout する。` |
| `kubernetes/components/nginx-sample/production/kustomization/scaled-object.yaml:5,6,7` | roadmap 参照を含む narrative | roadmap 参照を削除、現在の trigger 設定の意図のみ残す |
| `kubernetes/components/loki/production/helmfile.yaml:4` | `# Phase 3 Sub-project 3 で deploy する Logs stack の Loki 本体。` | `# Logs stack の Loki 本体。` |
| `kubernetes/components/tempo/production/helmfile.yaml:4` | `# Phase 3 Sub-project 4a で deploy する Traces stack の Tempo 本体。` | `# Traces stack の Tempo 本体。` |
| `kubernetes/components/karpenter/production/kustomization/nodepool.yaml:20` | `# - limits.cpu: 200 (cluster 暴走時の上限、Phase 5 nginx + monorepo 想定)` | `# - limits.cpu: 200 (cluster 暴走時の上限)` |
| `kubernetes/clusters/production/kustomization.yaml:10` | `#     GitRepository + Kustomization (= Phase 6-1 で追加)` | `(= Phase 6-1 で追加)` を削除 |
| `kubernetes/clusters/production/repositories/monorepo.yaml:4` | `# Phase 6-1 (= monorepo migration foundation) で追加。monorepo は` | "Phase 6-1 で追加" を削除し、現在の関係性だけ書く |
| `kubernetes/clusters/production/repositories/kustomization.yaml:4` | `# Phase 6-1 で新規作成。platform 外 repository (= panicboat monorepo) の` | "Phase 6-1 で新規作成" を削除 |
| `kubernetes/components/cilium/production/kustomization/kustomization.yaml:8` | `# routing entry point. Phase 6-1 (= monorepo migration foundation) で` | Phase 参照を削除 |
| `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml:4` | `# Phase 6-1 (= monorepo migration foundation) で application 共有 Gateway として` | Phase 参照を削除 |

### W5: spec/plan ID references in non-spec/plan files

| File:Line | Current | Proposed Fix |
|---|---|---|
| `aws/eks/README.md:95-97` | "設計詳細: docs/superpowers/specs/..." の 3 行 list | セクションごと削除 |
| `aws/eks/README.md:113` | `spec の Errata E-2 を参照（before_compute = true で対処済）` | Errata 参照を削除。「`before_compute = true` で IRSA registration を node 作成より前に完了させる」のように why を inline で書く |
| `aws/karpenter/modules/main.tf:146` | `# は spec の物理名規約に反するため不採用。` | "spec の物理名規約" 参照を削除。命名理由を inline で書く |
| `aws/eks/envs/production/terragrunt.hcl:18` | `# docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md for the` | spec link を削除し、参照規約自体を inline コメントに展開 |
| `kubernetes/components/metrics-server/production/values.yaml:2` | `# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md` | (削除) |
| `kubernetes/components/keda/production/values.yaml:2` | `# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md` | (削除) |
| `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml:5` | `# is used to share one ALB across multiple Ingresses (see spec for the` | "see spec for the …" を削除、why を inline で完結させる |
| `kubernetes/components/loki/production/helmfile.yaml:10-14` | `# Decision references:` ヘッダーと `# - D2: SingleBinary mode...` / `# - D3: tenancy=anonymous...` / `# - D5: chart = grafana-community/loki v13.6.0...` / `# - D11: HA upgrade path...` の 4 行 | ブロックごと削除。各 D 行の現在の design intent は周辺コメントで inline 表現 (例: SingleBinary mode の why、anonymous tenancy の why) |
| `kubernetes/components/tempo/production/helmfile.yaml:10-16` | `# Decision references:` ヘッダーと `# - D3: Monolithic mode...` / `# - D5: application retention OFF...` / `# - D7: bucket-wide IAM...` / `# - D8: multitenancy OFF...` / `# - D12: PVC 10Gi gp3...` の 5 行 | ブロックごと削除。各 D 行の現在の design intent は周辺コメントで inline 表現 |

### W4: source-of-truth duplication

| File:Line | Current | Proposed Fix |
|---|---|---|
| `aws/eks/README.md:25` | `\| Compute \| Managed Node Group system (m6g.large × 2-4, AL2023 ARM64, gp3 50 GiB) \|` | "Managed Node Group `system` (Graviton ARM64 / EBS gp3)" のように、具体的な instance type と数量を Terraform に委ね、設計意図 (Graviton / gp3) のみ残す |
| `kubernetes/README.md:263` | `Cilium 1.18.x が chaining mode` | `Cilium が chaining mode` (version は helmfile が source-of-truth、"1.18.x" は why を運ばないため完全削除) |
| `kubernetes/README.md:300` | `EBS gp3 30 GiB / IMDSv2` の "30 GiB" | EC2NodeClass YAML が source-of-truth、数字は削除して "EBS gp3 / IMDSv2" |
| `kubernetes/README.md:298-303` | "NodePool requirements: arm64 + spot + on-demand + general-purpose (category `m`) + size medium-4xlarge。WhenEmptyOrUnderutilized consolidation + 30d expireAfter" | requirements 一覧の具体値は NodePool YAML 側に任せ、README は「どの軸で絞っているか + その軸を選んだ why」に縮約 |

### W6: local-vs-production TODO comments (`local/**`)

`kubernetes/components/**/local/**` 配下に `# TODO: (production) ...` 形式のコメントが多数存在。
これらは多くの場合 1 コメントブロック内に「local の current state + why」と「production ではこうすべき」が混在しているため、**行単位の keep/delete ではなく、コメントブロック内を surgical に編集** する。

修正ルール:

- "production ではこうすべき" / "(production) ..." を語る行 → **削除** (production sibling ファイルが source-of-truth)
- "local k3d で X が必要" / "k3d 制約のため Y" 等の local 固有の current state + why の行 → **残す** (W6 では触らず、ただし `TODO:` prefix は外して通常コメントにする)
- 結果として "local why + production cross-reference" 混在ブロックは、production cross-reference 部分のみ削除して local why は残る

該当箇所と編集方針:

| File:Line | 現在の内容 (要点) | 編集方針 |
|---|---|---|
| `kubernetes/Makefile:23` | `# TODO: (production) For EKS deployment, create separate environment configs` | 全削除 (production cross-reference のみ) |
| `kubernetes/clusters/local/flux-system/gotk-sync.yaml:6, 17` | `# TODO: (production) Configure different branches for different environments` / `# TODO: (local) Change branch for different environments` | 6 行目は production cross-reference のため削除。17 行目は環境間切替の汎用 note のため削除可 (内容は branch 変更操作の説明であり current state を語っていない) |
| `kubernetes/clusters/local/repositories/monorepo.yaml:16` | `# TODO: (local) Change branch for different environments` | 削除 (汎用操作 note) |
| `kubernetes/components/opentelemetry-collector/local/values.yaml:57` | `# TODO: (local) Change to actual cluster name in production` | 削除 (production cross-reference) |
| `kubernetes/components/opentelemetry-collector/local/kustomization/hostport-patch.yaml:4-6` | local why 2 行 + `In production (EKS), this patch is not needed - use ClusterIP with DNS.` | "In production" 行のみ削除。残りは `TODO:` を外して通常コメントに |
| `kubernetes/components/loki/local/values.yaml:7, 16, 23, 30, 79, 83` | すべて `# TODO: (production) Use X in production` | 全削除 (production cross-reference のみ) |
| `kubernetes/components/opentelemetry/local/values.yaml:16` | `# TODO: (production) Use cert-manager for production TLS certificates` | 全削除 |
| `kubernetes/components/prometheus-operator/local/values.yaml:12, 94, 123` | すべて `# TODO: (production) ...` | 全削除 |
| `kubernetes/components/beyla/local/values.yaml:46` | `# TODO: If the namespaces to be traced increases, additional entries are required.` | 削除 (= 「条件付き future の操作 note」で current state を語っていない) |
| `kubernetes/components/tempo/local/values.yaml:12, 31, 61, 85` | すべて `# TODO: (production) ...` または `# TODO: (local) ... in production` | 全削除 |
| `kubernetes/components/coredns/local/kustomization/configmap.yaml:6-9, 29-30` | local why + production cross-reference 混在 | production cross-reference 行のみ削除 (= "In production (EKS), CoreDNS uses..." / "In production, this would use...") 。残りは `TODO:` を外して通常コメントに |
| `kubernetes/components/cilium/local/values.yaml:7-9, 12-13, 22, 29` | line 7-9 は local why 単独 (production 言及なし)、12-13 は混在、22 と 29 は production cross-reference 単独 | 7-9 は `TODO:` を外して通常コメント化。12-13 は 2 行目のみ削除して 1 行目を `TODO:` 外して残す。22 と 29 は全削除 |
| `kubernetes/components/cilium/local/kustomization/gateway.yaml:15, 39` | すべて `# TODO: (production) ...` | 全削除 |
| `kubernetes/components/gateway-api/local/kustomization/kustomization.yaml:9` | `# TODO: (production) Consider using the experimental channel ...` | 全削除 |
| `kubernetes/components/fluent-bit/local/values.yaml:29-30` | local why 1 行 + production cross-reference 1 行 | 30 行目のみ削除、29 行目は `TODO:` を外して通常コメント化 |

### W8: doc headings in Japanese

`README.md` ルート版 と `README-ja.md` は既に英語見出し (= clean)。違反は以下 2 ファイル。

`aws/eks/README.md` の日本語見出し:

| Line | Current | Proposed Fix |
|---|---|---|
| 35 | `### Quick start (推奨: login script)` | `### Quick start (recommended: login script)` |
| 58 | `### Manual login (script なし)` | `### Manual login (without script)` |
| 80 | `## terragrunt 操作` | `## terragrunt operations` |

`kubernetes/README.md` の日本語 / mixed 見出し (順):

| Line | Current | Proposed Fix |
|---|---|---|
| 3 | `## 概要` | `## Overview` |
| 7 | `## 🏗️ アーキテクチャ` | `## 🏗️ Architecture` |
| 76 | `### 役割分離` | `### Role separation` |
| 124 | `## 💡 設計思想` | `## 💡 Design principles` |
| 126 | `### Hydration Pattern 戦略` | `### Hydration pattern strategy` |
| 133 | `### 構成管理` | `### Configuration management` |
| 140 | `### Phase 1: Foundation Setup (基盤構築)` | `### Phase 1: Foundation Setup` |
| 149 | `### Phase 2: FluxCD Installation (GitOps基盤)` | `### Phase 2: FluxCD Installation` |
| 156 | `### Phase 3: Hydration & Sync (アプリ展開)` | `### Phase 3: Hydration & Sync` |
| 197 | `### 完全自動セットアップ` | `### Full automatic setup` |
| 203 | `### 個別操作` | `### Individual operations` |
| 213 | `### GitOps管理` | `### GitOps operations` |
| 222 | `### よくある問題` | `### Common issues` |
| 235 | `### ログ確認` | `### Log inspection` |
| 242 | `### 開発ワークフロー` | `### Development workflow` |
| 244 | `### ローカル開発 (高速)` | `### Local development (fast)` |
| 251 | `### 本番運用移行` | `### Production handover` |
| 468 | `### GitOps 原則` | `### GitOps principles` |
| 474 | `## 障害調査例` | `## Incident investigation example` |

`kubernetes/README.md` の bash code block 内 shell コメント (日本語):

| Line | Current | Proposed Fix |
|---|---|---|
| 224 | `# DNS解決失敗` | `# DNS resolution failure` |
| 227 | `# Gateway Controller未起動` | `# Gateway Controller not running` |
| 230 | `# HelmRelease状態確認` | `# HelmRelease status check` |
| 247 | `# 開発・テスト・実験` | `# develop / test / experiment` |
| 254 | `# 継続的デプロイメント開始` | `# start continuous deployment` |
| 353 | `# 1. eks-admin role を assume して kubectl 接続` | `# 1. Assume eks-admin role and connect via kubectl` |
| 356 | `# 2. Flux controllers を install` | `# 2. Install Flux controllers` |
| 359 | `# 3. Self-sync 設定を apply（main ブランチからの GitOps 開始）` | `# 3. Apply self-sync config (start GitOps from main branch)` |
| 362 | `# 4. Sync が成功したことを確認` | `# 4. Verify sync succeeded` |
| 371 | `# Flux の sync 状況を確認` | `# Check Flux sync status` |
| 374 | `# Flux の reconciliation を手動 trigger（main の最新を即座に sync）` | `# Manually trigger Flux reconciliation (sync latest main immediately)` |
| 378 | `# 全 GitOps リソースを一覧` | `# List all GitOps resources` |
| 385 | `# Cilium 全体ヘルスチェック` | `# Cilium overall health check` |
| 388 | `# 接続性テスト（test namespace を作る、数分かかる）` | `# Connectivity test (creates test namespace, takes a few minutes)` |
| 390 | `# 完了後の test namespace 手動削除` | `# Manually delete test namespace after completion` |
| 393 | `# Hubble flow 観測` | `# Observe Hubble flows` |
| 396 | `# Hubble UI (= https://hubble.panicboat.net/ 、oauth2-proxy 経由で外部公開)` | `# Hubble UI (= https://hubble.panicboat.net/, exposed via oauth2-proxy)` |
| 426 | `# ACM cert (terragrunt 管理、ALB Controller が auto-discovery)` | `# ACM cert (managed by terragrunt, ALB Controller auto-discovers)` |
| 430 | `# Ingress / ALB / Route53 record の確認` | `# Inspect Ingress / ALB / Route53 records` |

### W3: why-missing violations (manual review required)

grep で機械的に列挙できないため、execution フェーズで以下を file-by-file レビューする:

- `kubernetes/components/**/production/values.yaml*` の `enabled: false` / `disabled: true` で chart default を上書きしている箇所
- `kubernetes/components/**/production/values.yaml*` の `replicas` / `resources` で「なぜこの値か」が読み取れない箇所
- `*.tf` で `count = 0` / `enable_X = false` / 例外的 attribute 設定で why コメントがない箇所

具体例 (sample):

| File:Line | Current state | Action |
|---|---|---|
| `kubernetes/components/loki/production/values.yaml.gotmpl:148` | `podDisruptionBudget: enabled: false` (コメントなし) | SingleBinary mode で PDB が無意味な why をコメント追記 |
| `kubernetes/components/loki/production/values.yaml.gotmpl:179,181` | `chunksCache: enabled: false` / `resultsCache: enabled: false` | memcached を抱えない why を inline で書く |
| `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl:88-94` | `jaeger-*: enabled: false` / `zipkin: enabled: false` | OTLP 経路のみ採用する why を inline で書く |

## Implementation Approach

### Execution structure

監査ドキュメント (本 spec) で確定した違反一覧をベースに、`writing-plans` フェーズで以下の 5 commit に分割する。1 PR で出す。

1. **commit 1: README cleanup** — W1/W2/W4/W5 を README ファイル群 (`kubernetes/README.md` / `aws/eks/README.md` 中心、ルート 2 ファイルは clean) に適用
2. **commit 2: README heading + code-block-comment English rewrite (W8)** — README の日本語見出し + code block 内 shell コメントを英語化
3. **commit 3: Terraform / hcl comments** — W1/W2/W5 を `*.tf` / `*.hcl` 内コメントに適用
4. **commit 4: Kubernetes manifests/clusters/values comments** — W1/W2/W5/W6 を `kubernetes/components/**` / `kubernetes/clusters/**` の YAML コメントに適用
5. **commit 5: W3 why-missing additions** — production values の disable/skip annotation に why を inline で追加 (manual review)

各 commit は独立して reviewable な単位とし、PR としては「Documentation 一括是正」の単一の意図にまとめる。

### Language rule alignment

本 PR で **新規に書く or 既存を書き換える** コード/YAML コメントはすべて **英語**で書く。既存の日本語コメントを「触らない」ものはそのまま残す (W7 follow-up PR で別途扱う)。
README 本文は日本語維持、見出しは英語化 (W8)。

### Verification

各単位完了後に以下を確認:

- 修正後の grep で当該カテゴリの hit が 0 になる (W1/W2/W5/W6/W8)
- W4 修正後、各 README が「source-of-truth に書かれた値」を再記載していない
- W3 修正後、production values の disable 行に why コメントが付いている
- W8 修正後、README 見出しが英語化されている (`grep -nE "^#{1,6} .*[ぁ-んァ-ヶ一-龯]"` で hit 0)
- 本 PR で touch したコメントが英語で書かれている (= W7 違反を新規に増やしていない)

### Branch

worktree `.claude/worktrees/claudemd-documentation-cleanup` で作業中。
ブランチ `docs/claudemd-documentation-cleanup` (base: `origin/main`)。

## Resolved Decisions

レビューで確定した判断:

1. **W2 の `aws/eks/README.md` Environments table**: `develop` 行 (= 現在未稼働) を削除。表は稼働中の `production` のみ残す。
2. **W6 の局所的判定**: 行単位 keep/delete ではなく、コメントブロック内を surgical に編集する方針に改訂 (上記 W6 セクション参照)。production cross-reference 部分のみ削除し、local 固有の current state + why は `TODO:` prefix を外して通常コメントとして残す。
3. **W4 の `Cilium 1.18.x` 表記**: 完全削除 (= "Cilium 1.18.x" → "Cilium")。version は why を運ばないため残す利点なし。EKS minor lockstep の why は `aws/eks/README.md` で別途語られている。
4. **修正範囲の構成**: 1 PR / 5 commits (上記 Execution structure 参照)。
5. **Language ルールの扱い**: W8 (doc 見出し英語化) は本 PR に統合。W7 (コードコメント英語化、約 75 ファイル) は別 follow-up PR に分離。本 PR で新規 / 変更するコメントは英語で書き、W7 違反を新規に増やさない。
6. **D-number 参照 (Decision references block)**: W5 として扱い、`kubernetes/components/{loki,tempo}/production/helmfile.yaml` の "Decision references:" block + D1/D2/... 行をブロックごと削除。各 D 行が運んでいた design intent は周辺コメントに inline で展開する。
