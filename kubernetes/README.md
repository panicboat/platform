# Kubernetes Platform with Cilium Service Mesh & GitOps

## 概要

**Ciliumサイドカーレスサービスメッシュ**と**FluxCD GitOps**を組み合わせたKubernetesプラットフォーム。**Helmfile Hydration Pattern** により、HelmチャートとKustomizeマニフェストを一元管理し、純粋なYAMLとしてGit管理することで、GitOpsの信頼性と可視性を向上させています。

## 🏗️ アーキテクチャ

```mermaid
graph TB
    subgraph "Local / CI"
        HF[Helmfile / Components]
        HYD[Hydration Process]
        MF[Manifests (YAML)]
        HF --> HYD
        HYD --> MF
    end

    subgraph "k3d Cluster"
        subgraph "Phase 1: Foundation"
            GW[Gateway API CRDs]
            CNI[Cilium CNI + Gateway Controller]
            DNS[CoreDNS]
            GW --> CNI
            CNI --> DNS
        end

        subgraph "Phase 2: GitOps"
            FLUX[FluxCD Controllers]
        end

        subgraph "Phase 3: Hydrated Resources"
            M_APP[Hydrated Manifests]
            PROM[Prometheus Stack]
            OTEL[OpenTelemetry]
            M_APP --> PROM
            M_APP --> OTEL
        end

        subgraph "Service Mesh Layer"
            GC[GatewayClass: cilium]
            GT[Gateway: cilium-gateway]
            HTTP[HTTPRoutes]
            GC --> GT
            GT --> HTTP
        end
    end

    subgraph "External Access"
        BROWSER[Browser]
        LOCALHOST[localhost:80/443]
    end

    MF -.-> FLUX
    FLUX --> M_APP
    CNI -.-> GC
    HTTP --> PROM
    BROWSER --> LOCALHOST
    LOCALHOST --> GT

    classDef foundation fill:#e1f5fe
    classDef gitops fill:#f3e5f5
    classDef infra fill:#e8f5e8
    classDef mesh fill:#fff3e0
    classDef hydration fill:#fffde7

    class GW,CNI,DNS foundation
    class FLUX gitops
    class M_APP,PROM,OTEL infra
    class GC,GT,HTTP mesh
    class HF,HYD,MF hydration
```

## 🚀 セットアップ

```bash
export GITHUB_TOKEN=ghp_... # 必須 (repo権限が必要)
```

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
- FluxCD が `manifests/k3d` を同期
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
export GITHUB_TOKEN=ghp_... # 必須 (repo権限が必要)
make up              # Phase 1-4 全自動実行 (2-3分)
make down            # クラスター完全削除
```

### 個別操作
```bash
make hydrate         # マニフェスト生成 (components -> manifests)
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

**[CI/CD] Reusable Workflow**:
- `reusable--hydrate-manifests.yaml`: 指定環境のマニフェスト生成・コミットを行うリユーザブルワークフロー。
- `auto-label--deploy-trigger.yaml`: 変更を検知し上記を実行します。

## 💡 設計思想

### Hydration Pattern 戦略

**Why Hydration?**
1.  **可視性 (Visibility)**: 実際に適用される YAML が `manifests/` に存在するため、コミットログで変更理由が明確になる。
2.  **安全性 (Safety)**: Helm チャートのレンダリング結果を承認してからデプロイ可能。予期せぬ Breaking Change を防ぐ。
3.  **環境分離 (Isolation)**: `helmfile -e <env>` により環境ごとの差異を吸収しつつ、バージョン管理を厳密化。

### 構成管理

- **Components (`components/`)**: アプリケーションのソース（Helm Values, Kustomize Base/Overlays）。
- **Manifests (`manifests/`)**: 自動生成される最終成果物。
- **Environment**: `env/<env>/version.yaml` によるディレクトリベースのバージョン分離（Renovate対応）。

## 🔍 監視・オブザーバビリティ

### 統合監視スタック
- **Prometheus**: メトリクス収集・アラート
- **Grafana**: 可視化ダッシュボード
- **OpenTelemetry**: 分散トレーシング
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
