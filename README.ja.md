# minikube環境でのArgo CDセットアップ手順

[English](README.md) | **日本語**

このドキュメントでは、minikube環境でArgo CDを使用してHelmチャートを管理する方法を説明します。

## 前提条件

- minikubeがインストールされていること
- kubectlがインストールされていること
- Gitリポジトリに以下の構成でファイルが配置されていること

```
kubernetes-manifests/
├── applications/
│   └── minikube/
│       ├── argo-cd.yaml
│       └── ingress-nginx.yaml
├── argo-cd/
│   ├── Chart.yaml
│   └── values/
│       ├── common.yaml
│       └── minikube.yaml
└── ingress-nginx/
    ├── Chart.yaml
    └── values/
        ├── common.yaml
        └── minikube.yaml
```

## セットアップ手順

### 1. minikubeの起動

```bash
# minikubeを起動
minikube start
```

**注意**: minikubeのingressアドオンは使用しません。独自のingress-nginxをHelmチャートで管理するためです。

### 2. Argo CDの初期インストール

```bash
# Argo CD用のnamespaceを作成
kubectl create namespace argocd

# Argo CDの基本版をインストール（公式マニフェスト使用）
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Argo CDのサーバーが起動するまで待機
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

### 3. Argo CDへの初回アクセス

```bash
# 管理者パスワードを取得
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# ポートフォワードでアクセス（別ターミナルで実行）
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

ブラウザで `https://localhost:8080` にアクセスし、以下の認証情報でログインします：
- ユーザー名: `admin`
- パスワード: 上記で取得したパスワード

### 4. GitOpsによる管理開始

ここからが重要なポイントです。Argo CD自身もGitOpsで管理します。

```bash
# Argo CD Application（自分自身の設定）をデプロイ
kubectl apply -f applications/minikube/argo-cd.yaml

# ingress-nginx Applicationをデプロイ
kubectl apply -f applications/minikube/ingress-nginx.yaml
```

### 5. 動作確認

```bash
# Applicationsの状態を確認
kubectl get applications -n argocd

# 期待される出力例：
# NAME            SYNC STATUS   HEALTH STATUS   AGE
# argo-cd         Synced        Healthy         2m
# ingress-nginx   Synced        Healthy         1m

# すべてのPodが正常に動作しているか確認
kubectl get pods -n argocd
kubectl get pods -n ingress-nginx
```

### 6. NodePort経由でのアクセス

minikube環境では、NodePortを使用してArgo CDにアクセスします：

```bash
# minikubeのIPアドレスを取得
minikube ip

# 出力されたIPアドレスを使用して以下のURLにアクセス
# https://<minikube-ip>:30443
```

または、minikubeのserviceコマンドを使用：

```bash
# ブラウザで自動的に開く
minikube service argocd-server -n argocd
```

## 理解しておくべきポイント

### なぜ段階的セットアップが必要なのか

これは「鶏と卵問題」を解決するためです：

1. **初期状態**: Argo CDが存在しない
2. **手動インストール**: 基本設定のArgo CDをインストール
3. **GitOps移行**: Argo CD自身をGitOpsで管理するように設定
4. **完全自動化**: すべてのアプリケーションがGitOpsで管理される

```
最初の状態：
┌─────────────────┐
│ 手動インストール  │  ← 基本設定のArgo CD
│ Argo CD         │
└─────────────────┘

↓ applications/minikube/argo-cd.yaml を適用

最終状態：
┌─────────────────┐
│ Helm管理の      │  ← あなたのカスタム設定
│ Argo CD         │  ← GitOpsで管理される
└─────────────────┘
┌─────────────────┐
│ ingress-nginx   │  ← Argo CDが管理
└─────────────────┘
```

### なぜminikubeアドオンを使わないのか

- **一貫性**: 他の環境（develop/staging/production）と同じ管理方法
- **バージョン管理**: Helmチャートでバージョンを明示的に管理
- **カスタマイズ**: 詳細な設定が可能
- **GitOps**: すべてがGitで管理される

## トラブルシューティング

### Applicationが同期されない場合

```bash
# Applicationの詳細を確認
kubectl describe application argo-cd -n argocd
kubectl describe application ingress-nginx -n argocd

# Argo CDサーバーのログを確認
kubectl logs -n argocd deployment/argocd-server
```

### 手動で同期を実行する場合

```bash
# CLI経由で同期
kubectl patch application argo-cd -n argocd --type merge -p '{"operation":{"sync":{}}}'

# または、Web UIから「SYNC」ボタンをクリック
```

### パスワードを忘れた場合

```bash
# 管理者パスワードを再取得
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## 次のステップ

1. **他のアプリケーション追加**: 新しいHelmチャートをリポジトリに追加
2. **環境切り替え**: develop/staging/production環境への展開
3. **監視設定**: Prometheus/Grafanaの追加
4. **セキュリティ強化**: RBAC、OIDC設定の追加

## 参考リンク

- [Argo CD公式ドキュメント](https://argo-cd.readthedocs.io/)
- [Argo CD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
- [minikube公式ドキュメント](https://minikube.sigs.k8s.io/docs/)
