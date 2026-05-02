# Kubernetes Platform with Cilium Service Mesh & GitOps

## 概要

**Ciliumサイドカーレスサービスメッシュ**と**FluxCD GitOps**を組み合わせたKubernetesプラットフォーム。**Helmfile Hydration Pattern** により、HelmチャートとKustomizeマニフェストを一元管理し、純粋なYAMLとしてGit管理することで、GitOpsの信頼性と可視性を向上させています。

## 🏗️ アーキテクチャ

```mermaid
flowchart TB
    subgraph EKS["EKS Cluster"]
        subgraph Apps["Application Pods"]
            App["App"]
        end

        subgraph Collection["Collection Layer"]
            Cilium["Cilium CNI<br/>(CNCF Graduated)"]
            Hubble["Hubble"]
            Beyla["Beyla<br/>(eBPF)"]
            OTelCol["OTel Collector<br/>(CNCF Graduated)"]
            FluentBit["Fluent Bit<br/>(CNCF Incubating)"]
        end

        subgraph Storage["Storage Layer"]
            Prometheus["Prometheus<br/>(CNCF Graduated)"]
            Thanos["Thanos Sidecar<br/>(CNCF Incubating)"]
            Tempo["Tempo"]
            Loki["Loki"]
        end
    end

    subgraph S3["S3"]
        S3Thanos[("Metrics")]
        S3Tempo[("Traces")]
        S3Loki[("Logs")]
    end

    Grafana["Grafana"]

    %% Network
    Cilium --> Hubble

    %% All telemetry → OTel Collector
    Hubble -->|OTLP| OTelCol
    App -.->|eBPF| Beyla
    Beyla -->|OTLP| OTelCol

    %% OTel Collector → Backends
    OTelCol -->|remote_write| Prometheus
    OTelCol --> Tempo

    %% Logs
    Apps -.->|stdout| FluentBit
    FluentBit --> |OTLP| OTelCol
    OTelCol --> Loki

    %% Long-term storage
    Prometheus --> Thanos
    Thanos --> S3Thanos
    Tempo --> S3Tempo
    Loki --> S3Loki

    %% Visualization
    Thanos --> Grafana
    Tempo --> Grafana
    Loki --> Grafana
```

### Dataflow

```mermaid
flowchart LR
    subgraph Sources["Data Sources"]
        H["Hubble<br/>(Network L3/L4/L7)"]
        B["Beyla<br/>(App L7)"]
        L["stdout"]
    end

    subgraph Collector["Unified Collector (The Hub)"]
        FB["Fluent Bit"]
        OTel["OTel Collector"]
    end

    subgraph Backends["Backends"]
        P["Prometheus → Thanos"]
        T["Tempo"]
        LO["Loki"]
    end

    H -->|OTLP| OTel
    B -->|OTLP| OTel
    L -->|stdout| FB

    FB -->|OTLP| OTel

    OTel -->|Metrics| P
    OTel -->|Traces| T
    OTel -->|Logs| LO

    P --> Grafana
    T --> Grafana
    LO --> Grafana
```

## 🚀 セットアップ

### Phase 1: Foundation Setup (基盤構築)
```bash
make phase1
```
- k3d クラスター作成
- **Gateway API CRDs** インストール
- **Cilium CNI** + Gateway Controller (kube-proxy置換)
- CoreDNS修正・DNS解決確認

### Phase 2: FluxCD Installation (GitOps基盤)
```bash
make phase2
```
- FluxCD コントローラーインストール
- GitOps基盤構築

### Phase 3: Hydration & Sync (アプリ展開)
```bash
make phase3
```
- FluxCD が `manifests/local`（コンポーネント別サブディレクトリ）を同期
- Hydration 済みマニフェスト（Helm + Kustomize）の一括適用
- Namespace, CRD, アプリケーションの順序制御（Flux Kustomization依存）

### Phase 4: GitOps Complete Migration
```bash
make phase4
```
- リポジトリ全域の GitOps 管理自動化

## 🌐 サービスアクセス

**Gateway API経由でのブラウザアクセス:**

/etc/hosts に以下を設定

```bash
127.0.0.1 grafana.local
127.0.0.1 prometheus.local
127.0.0.1 alertmanager.local
127.0.0.1 hubble.local
```

|  | URL |
| --- | --- |
| Grafana | http://grafana.local |
| Prometheus | http://prometheus.local |
| Alertmanager | http://alertmanager.local |
| Hubble UI | http://hubble.local |

**サイドカーレスサービスメッシュ:**
- Cilium Gateway Controller
- L7負荷分散・トラフィック管理
- eBPFによる高性能通信

## 🔧 主要コマンド

### 完全自動セットアップ
```bash
make up              # Phase 1-4 全自動実行
make down            # クラスター完全削除
```

### 個別操作
```bash
make hydrate                              # 全コンポーネント生成 (components -> manifests)
make hydrate-component COMPONENT=<name> ENV=<env>  # 単一コンポーネントのみ再生成（CI 用）
make hydrate-index ENV=<env>              # 集約ファイル再生成 + orphan 削除（CI 用）
make gateway-install # Gateway API CRDs
make cilium-install  # Cilium Bootstrap
make status          # クラスター状態確認
```

### GitOps管理
```bash
make gitops-setup    # FluxCD GitOps設定
make gitops-enable   # 全コンポーネントGitOps化
make gitops-status   # GitOps状態確認
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

## 🔍 監視・オブザーバビリティ

### 統合監視スタック
- **Prometheus**: メトリクス収集・アラート
- **Thanos**: 長期メトリクスストレージ
- **Grafana**: 可視化ダッシュボード
- **Loki**: ログ集約
- **Tempo**: 分散トレーシングバックエンド
- **Fluent Bit**: ログ収集
- **OpenTelemetry Collector**: テレメトリ統合
- **Beyla**: eBPF自動計装
- **Cilium Hubble**: ネットワーク観測

### アクセス方法
Gateway API経由で上記URLから直接アクセス可能。

## 🛠️ トラブルシューティング

### よくある問題
```bash
# DNS解決失敗
make coredns-update

# Gateway Controller未起動
kubectl -n kube-system rollout restart deployment/cilium-operator

# HelmRelease状態確認
kubectl get helmreleases -A
flux logs
```

### ログ確認
```bash
flux get all -A              # FluxCD状態
cilium status               # Cilium状態
kubectl logs -n kube-system -l k8s-app=cilium
```

## 🤝 開発ワークフロー

### ローカル開発 (高速)
```bash
make up                     # 2-3分で完全環境
# 開発・テスト・実験
make down && make up        # 高速リセット
```

### 本番運用移行
```bash
make phase4                 # Bootstrap → GitOps
# 継続的デプロイメント開始
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

## Production Operations

EKS production cluster `eks-production`（`ap-northeast-1`）の運用手順。

### Initial Bootstrap (one-time)

cluster を新規作成した直後に 1 回だけ実行する。すでに完了済の場合は skip。

```bash
# 1. eks-admin role を assume して kubectl 接続
source eks-login.sh production

# 2. Flux controllers を install
make flux-install ENV=production

# 3. Self-sync 設定を apply（main ブランチからの GitOps 開始）
make gitops-setup ENV=production

# 4. Sync が成功したことを確認
make gitops-status ENV=production
```

### Daily Operations

GitOps が enable されているため、manifests の変更は **常に main ブランチへの merge 経由** で行う。直接 `kubectl apply` は drift を生むので避ける。

```bash
# Flux の sync 状況を確認
make gitops-status ENV=production

# Flux の reconciliation を手動 trigger（main の最新を即座に sync）
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system

# 全 GitOps リソースを一覧
flux get all -A
```

### Troubleshooting

| 症状 | 原因 / 対処 |
|---|---|
| `flux reconcile` が `not ready` で止まる | `kubectl describe gitrepository flux-system -n flux-system` で fetch error を確認。多くは GitHub への egress 失敗か platform repo の private 化 |
| `Kustomization` が `BuildFailed` | `flux logs --kind=Kustomization` で kustomize build エラーを確認。`kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system flux-system -o yaml` で `.status.conditions` も見る |
| Flux が main の最新を sync しない | GitRepository の `interval: 1m` が効いているか確認。OOM / pod restart の可能性なら `kubectl get pods -n flux-system` |
| `kubectl: error: ... credentials` | `eks-login.sh production` を再 source（session 1 時間で expire） |

### GitOps 原則

- **kubectl で直接 apply / edit / delete しない**: Flux と drift して reconciliation で上書きされる
- **緊急 rollback** が必要な場合は `git revert` で main に戻す。main を直接 force-push するのは禁止
- **Flux 自体の障害**で sync が止まった場合は、`flux suspend kustomization flux-system -n flux-system` で一時停止し、原因究明後に `flux resume` で再開
