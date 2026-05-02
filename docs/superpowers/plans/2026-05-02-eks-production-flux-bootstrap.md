# EKS Production Flux Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster `eks-production` 上に FluxCD を bootstrap し、`kubernetes/clusters/production/` および `kubernetes/manifests/production/` の Hydration Pattern scaffold を整備する。Plan 1a として、後続の Plan 1b（Cilium 再構成）/ Plan 1c（Foundation addons）が GitOps で manifests を sync できる状態を作る。

**Architecture:** local 環境（k3d）と同じ FluxCD + Hydration Pattern を production に拡張する。`flux install` で controllers を入れ、`clusters/production/flux-system/gotk-sync.yaml` で platform repo を self-sync させ、`clusters/production/kustomization.yaml` から `manifests/production/` を sync させる。Plan 1a 時点で `manifests/production/` は空 scaffold（Plan 1b/1c で components を追加）。

**Tech Stack:** FluxCD 2.x、kubectl、helmfile、kustomize、make、AWS CLI、`eks-login.sh`（panicboat/ansible 由来の kubectl 認証 helper）

**Spec:** `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `kubernetes/helmfile.yaml.gotmpl` | modify | `production` environment block をコメントアウトから有効化 |
| `kubernetes/manifests/production/kustomization.yaml` | create | 空の Kustomize entry point。Plan 1b/1c で components 追加時に `make hydrate ENV=production` で再生成される |
| `kubernetes/clusters/production/kustomization.yaml` | create | cluster-level top kustomization、`../../manifests/production` を resource として参照 |
| `kubernetes/clusters/production/flux-system/kustomization.yaml` | create | flux-system bootstrap の wrapper |
| `kubernetes/clusters/production/flux-system/gotk-sync.yaml` | create | `GitRepository`（platform repo `main` branch）+ `Kustomization`（path=`./kubernetes/clusters/production`） |
| `kubernetes/README.md` | modify | production 用 runbook セクションを追加 |

> **Out of scope:**
> - `kubernetes/clusters/production/repositories/` は本 plan では作成しない。monorepo の GitOps 統合は別 spec（roadmap の Future Specs: monorepo K8s 移行）で扱う
> - `make hydrate ENV=production` の実行は本 plan では行わない。`hydrate-index` が `find components -maxdepth 2 -name namespace.yaml` で env 非依存に全 component の namespace を集める挙動があり、Plan 1a 時点（components/*/production が存在しない）で実行すると local 用の opentelemetry / prometheus-operator namespace が production manifests に漏れる。Plan 1b で Cilium production component を追加した時点で初めて hydrate を回す
> - Cilium 再構成 / ALB Controller / ExternalDNS / Metrics Server / KEDA / Gateway API CRDs はそれぞれ Plan 1b / 1c で扱う

> **依存 spec の前提（apply 済かつ動作確認済であること）**:
> - `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md` の実装が main にマージ済かつ apply 済（cluster `eks-production` が存在し `kubectl get nodes` が通る）
> - `panicboat/ansible` の `eks-login.sh` が `~/Workspace/eks-login.sh` に deploy 済

---

### Task 0: 前提条件の確認

**Files:** （read only）

実装前に prerequisite が揃っていることを確認する。判断揺れを避けるため、Plan 1a では **既存 cluster にも Flux にも触れず、確認だけ行う**。

- [ ] **Step 1: worktree とブランチを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-platform-roadmap
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/eks-production-platform-roadmap`

以後すべてのコマンドはこの worktree で実行する。

- [ ] **Step 2: 必須 CLI が install 済であることを確認**

```bash
flux --version
kubectl version --client | head -1
helmfile --version
kustomize version
```

Expected: 各 CLI が version を返す（`flux: 2.x`, `kubectl: any`, `helmfile: any`, `kustomize: any`）。

未 install の CLI があれば以下で install してから再開：
- flux: `brew install fluxcd/tap/flux` または `https://fluxcd.io/flux/installation/`
- helmfile: `brew install helmfile`
- kustomize: `brew install kustomize`

- [ ] **Step 3: production cluster へ kubectl 接続できることを確認**

```bash
source ~/Workspace/eks-login.sh production
kubectl cluster-info
```

Expected:
```
Kubernetes control plane is running at https://<cluster-id>.gr7.ap-northeast-1.eks.amazonaws.com
CoreDNS is running at https://<cluster-id>.gr7.ap-northeast-1.eks.amazonaws.com/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

`eks-login.sh` は `eks-admin-production` IAM role を assume して kubeconfig を更新する。1 時間後に session が切れるので、長時間作業時は適宜 re-source する。

- [ ] **Step 4: cluster に Flux が未 install であることを確認**

```bash
kubectl get namespace flux-system 2>&1
```

Expected: `Error from server (NotFound): namespaces "flux-system" not found`

すでに `flux-system` namespace が存在する場合は、誰かが先に bootstrap している。Plan 1a を実行する前に状況確認が必要（`kubectl get pods -n flux-system` / `flux get all -A`）。

- [ ] **Step 5: production manifests / clusters ディレクトリが未作成であることを確認**

```bash
ls kubernetes/clusters/production 2>&1
ls kubernetes/manifests/production 2>&1
```

Expected: 両方とも `ls: kubernetes/clusters/production: No such file or directory` 系のエラー。

すでに存在する場合は、本 plan の前に scaffold が作られている。差分確認してから進める。

- [ ] **Step 6: helmfile.yaml.gotmpl の現在の内容を確認**

```bash
grep -A 5 "production" kubernetes/helmfile.yaml.gotmpl
```

Expected: `# TODO: (production) Uncomment and configure for production` の TODO コメントが見つかる。

このコメントブロックが Task 1 で有効化する対象。

---

### Task 1: helmfile.yaml.gotmpl に production environment を追加

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`

local と同じパターンで production environment を有効化する。`isLocal: false` を渡すことで、各 component の helmfile が local-only な設定（NodePort / k3d 固有 hostname 等）を分岐できるようにする。

- [ ] **Step 1: 現状を再確認**

```bash
cat kubernetes/helmfile.yaml.gotmpl
```

Expected: `production:` のブロックが `# TODO: (production) Uncomment and configure for production` でコメントアウトされている。

- [ ] **Step 2: production environment ブロックを有効化**

`kubernetes/helmfile.yaml.gotmpl` の `environments:` ブロックを以下に置き換え：

```yaml
environments:
  local:
    values:
      - cluster:
          name: k8s-local
          isLocal: true
  production:
    values:
      - cluster:
          name: eks-production
          isLocal: false
  # TODO: (staging) Uncomment and configure when staging cluster is provisioned
  # staging:
  #   values:
  #     - cluster:
  #         name: eks-staging
  #         isLocal: false
```

差分のポイント：
- `local` ブロックの `# TODO: (local) local-specific settings` コメントは削除（`isLocal` で十分）
- `production` ブロックを **コメント解除 + 有効化**
- `staging` ブロックは TODO のまま残す（develop / staging EKS 構築は別 spec）

- [ ] **Step 3: helmfile が production env を認識することを確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | head -5
```

Expected: 何らかの output（components/*/production/helmfile.yaml が存在しないため列挙される releases は 0 件）。エラーで落ちないこと。

具体的には：
```
NAME    NAMESPACE    ENABLED    INSTALLED    LABELS    CHART    VERSION
```

releases の行は空で、ヘッダーだけが出る、または何も出ない。`Error: environment "production" is not defined` が出ないことが合格条件。

- [ ] **Step 4: 元のディレクトリに戻る**

```bash
cd ..
```

以後の Task は worktree のルートから実行する。

- [ ] **Step 5: Commit**

```bash
git add kubernetes/helmfile.yaml.gotmpl
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): enable production helmfile environment

production cluster eks-production を helmfile environment として認識可能にする。
isLocal=false で local 固有設定との分岐ポイントを用意する。各 component の
production 用 helmfile は後続 plan で追加する。
EOF
)"
```

Expected: 1 file changed, commit が `feat/eks-production-platform-roadmap` に追加される。

---

### Task 2: 空の production manifests scaffold を作成

**Files:**
- Create: `kubernetes/manifests/production/kustomization.yaml`

Plan 1a 時点で manifests/production は空。Flux が sync してもエラーにならない最小限の Kustomize entry point を手動で作成する。`make hydrate ENV=production` は使わない（Out of scope の理由参照）。

- [ ] **Step 1: ディレクトリを作成**

```bash
mkdir -p kubernetes/manifests/production
```

Expected: 静かに成功（既存なら no-op）。

- [ ] **Step 2: 空の kustomization.yaml を作成**

`kubernetes/manifests/production/kustomization.yaml` を以下の内容で作成：

```yaml
# =============================================================================
# Production manifests entry point
# =============================================================================
# 本ファイルは Plan 1a 時点では空。後続 plan で components を追加した際に
# `make hydrate ENV=production` が再生成する。
# 手動で resources を編集するのは避ける（hydrate で上書きされる）。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
```

- [ ] **Step 3: kustomize build で valid であることを確認**

```bash
kustomize build kubernetes/manifests/production
```

Expected: 何も output されない（resources が空のため）。エラーで落ちないこと。

- [ ] **Step 4: Commit**

```bash
git add kubernetes/manifests/production/kustomization.yaml
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): scaffold empty production manifests directory

Flux 1a bootstrap が sync するための空の Kustomize entry point を追加する。
後続 plan で components を追加した際に make hydrate ENV=production が
本ファイルを再生成する。
EOF
)"
```

---

### Task 3: production cluster Flux 設定を作成

**Files:**
- Create: `kubernetes/clusters/production/kustomization.yaml`
- Create: `kubernetes/clusters/production/flux-system/kustomization.yaml`
- Create: `kubernetes/clusters/production/flux-system/gotk-sync.yaml`

local 環境の `kubernetes/clusters/local/` を参考に、production 用の Flux self-management 設定を作成する。`repositories/` ディレクトリは Plan 1a では作らない（Out of scope）。

- [ ] **Step 1: ディレクトリを作成**

```bash
mkdir -p kubernetes/clusters/production/flux-system
```

- [ ] **Step 2: cluster-level top kustomization を作成**

`kubernetes/clusters/production/kustomization.yaml`:

```yaml
# =============================================================================
# Production Cluster Kustomization
# =============================================================================
# このファイルは EKS production cluster (eks-production) で Flux が
# 同期する root kustomization。
#
# 含むリソース:
#   - manifests/production: ハイドレーション済 Kubernetes manifests
#
# Plan 1a 時点では manifests/production が空。Plan 1b / 1c で
# Cilium / Gateway API CRDs / ALB Controller / ExternalDNS /
# Metrics Server / KEDA が追加される。
#
# repositories/ は本 plan では未作成。monorepo の GitOps 統合は
# 別 spec で追加する。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../manifests/production
```

- [ ] **Step 3: flux-system wrapper kustomization を作成**

`kubernetes/clusters/production/flux-system/kustomization.yaml`:

```yaml
# =============================================================================
# FluxCD Kustomization for production
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - gotk-sync.yaml
```

- [ ] **Step 4: gotk-sync.yaml を作成**

`kubernetes/clusters/production/flux-system/gotk-sync.yaml`:

```yaml
# =============================================================================
# FluxCD GitOps Sync Configuration for production
# =============================================================================
# Production cluster eks-production は platform repo の main ブランチを
# 1 分間隔で取得し、./kubernetes/clusters/production を 10 分間隔で apply する。
# =============================================================================
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/panicboat/platform.git
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/clusters/production
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

local の `gotk-sync.yaml` との差分は `path: ./kubernetes/clusters/production` のみ（local は `./kubernetes/clusters/local`）。`branch: main` は production も同じ。

- [ ] **Step 5: kustomize build で valid であることを確認**

```bash
kustomize build kubernetes/clusters/production/flux-system
kustomize build kubernetes/clusters/production
```

Expected:
- 1 つ目: `GitRepository` + `Kustomization` の YAML が出力される
- 2 つ目: `manifests/production` が空のため何も output されない（cluster kustomization は resources を 1 個参照しているが、その先が空）

両方ともエラーなし。

- [ ] **Step 6: Commit**

```bash
git add kubernetes/clusters/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): add production cluster Flux bootstrap manifests

eks-production が platform repo の main ブランチから自身の Flux 設定を
self-sync するための gotk-sync を追加する。path は
./kubernetes/clusters/production を指す。Plan 1b/1c で追加される
manifests/production はこの cluster kustomization 経由で apply される。
EOF
)"
```

---

### Task 4: 本番 cluster に Flux controllers を install

**Files:** （cluster 状態のみ変更、ファイルなし）

`flux install` で source-controller / kustomize-controller / helm-controller / notification-controller を入れる。local と同じく image-reflector / image-automation も含める。

- [ ] **Step 1: production cluster 認証を更新**

```bash
source ~/Workspace/eks-login.sh production
kubectl config current-context
```

Expected: `arn:aws:eks:ap-northeast-1:559744160976:cluster/eks-production`

session が古い場合（1 時間以上経過）は再 source。

- [ ] **Step 2: install 前の cluster 状態を記録**

```bash
kubectl get nodes -o wide
kubectl get namespace
```

Expected:
- nodes: system MNG の m6g.large が 2-4 台 Ready
- namespaces: kube-system / kube-public / kube-node-lease / default のみ（flux-system は無し）

- [ ] **Step 3: flux check --pre で前提条件を確認**

```bash
flux check --pre
```

Expected:
```
► checking prerequisites
✔ kubectl 1.x.x >= 1.30.0-0
✔ Kubernetes 1.35.x >= 1.30.0-0
✔ prerequisites checks passed
```

Kubernetes version は EKS 1.35 系（aws-eks-production spec で確定）。`✔` が全部出ること。失敗する場合は kubectl version / cluster の確認。

- [ ] **Step 4: Flux controllers を install**

```bash
flux install \
  --namespace=flux-system \
  --components-extra=image-reflector-controller,image-automation-controller
```

Expected:
```
► installing components in flux-system namespace
✔ install completed
► verifying installation
✔ source-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ helm-controller: deployment ready
✔ notification-controller: deployment ready
✔ image-reflector-controller: deployment ready
✔ image-automation-controller: deployment ready
✔ install finished
```

local の `Makefile` の `flux-install` ターゲットと同じ引数構成（`Makefile:219`）。

- [ ] **Step 5: Flux 起動を確認**

```bash
kubectl get pods -n flux-system
```

Expected: 6 pods all `Running` status, 1/1 Ready。

```
NAME                                          READY   STATUS    RESTARTS   AGE
helm-controller-xxxx                          1/1     Running   0          1m
image-automation-controller-xxxx              1/1     Running   0          1m
image-reflector-controller-xxxx               1/1     Running   0          1m
kustomize-controller-xxxx                     1/1     Running   0          1m
notification-controller-xxxx                  1/1     Running   0          1m
source-controller-xxxx                        1/1     Running   0          1m
```

- [ ] **Step 6: flux check（post-install）**

```bash
flux check
```

Expected: 全 component が `✔ ... is healthy`。

---

### Task 5: production の Flux self-management 設定を apply

**Files:** （cluster 状態のみ変更、ファイルなし）

Task 3 で作成した `clusters/production/flux-system/` を cluster に apply して、Flux に「自分自身の設定を main ブランチから sync する」ように指示する。

このときに **Task 1-3 で作成したファイルが既に main ブランチに merge されている必要がある**。Plan 1a を 1 PR でまとめて merge してから本 Task を実行する手順を採るか、feature ブランチを直接 GitRepository の `ref.branch` に指定するかの判断が必要。

本 plan では **「Plan 1a の Task 1-3 を Draft PR → review → main merge → Task 4-7 を実行」** を推奨手順とする。これにより self-sync 開始時点で main にすべての必要なファイルが存在する。

ただし開発時の利便性のため、**一時的に feature ブランチを sync 対象に指定して動作確認**することも可能。その場合は Task 5 の Step 2 で `branch: main` を `branch: feat/eks-production-platform-roadmap` に変更し、Step 6 の前に main へ戻す。

- [ ] **Step 1: PR / merge 状態を確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: Task 1, 2, 3 の commit が表示される。

main に未 merge の場合：

選択肢 A（推奨）: ここで一旦中断して PR を作成、review → merge してから Task 5 を再開：

```bash
git push -u origin feat/eks-production-platform-roadmap
gh pr create --draft --base main \
  --title "feat(kubernetes): bootstrap Flux on production EKS (Plan 1a)" \
  --body "$(cat <<'EOF'
## Summary
- helmfile.yaml.gotmpl で production environment を有効化
- kubernetes/manifests/production/ に空の Kustomize scaffold
- kubernetes/clusters/production/ に Flux self-management 設定

Plan: docs/superpowers/plans/2026-05-02-eks-production-flux-bootstrap.md
Spec: docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md

## Test plan
- [ ] kustomize build kubernetes/clusters/production が valid
- [ ] kustomize build kubernetes/manifests/production が valid
- [ ] helmfile -e production list がエラーにならない
EOF
)"
```

review が approve されたら squash merge せず通常 merge（commit history 保持）。merge 後に worktree で `git fetch origin main` して Task 5 を再開。

選択肢 B（短絡）: feature ブランチを直接 sync 対象にして動作確認後、Step 6 で main 切り替え。本番 cluster に対しては推奨しない（PR review が事後になる）。

- [ ] **Step 2: gitops-setup（flux-system 内 GitRepository / Kustomization を作成）**

```bash
make -C kubernetes gitops-setup ENV=production
```

Expected:
```
🔧 Setting up FluxCD GitOps...
gitrepository.source.toolkit.fluxcd.io/flux-system created
kustomization.kustomize.toolkit.fluxcd.io/flux-system created
✅ GitOps setup completed
```

裏では `kubectl apply -k clusters/production/flux-system` が実行される（Makefile:263）。

- [ ] **Step 3: GitRepository が main を取得していることを確認**

```bash
flux get sources git -n flux-system
```

Expected:
```
NAME        REVISION                  SUSPENDED   READY   MESSAGE
flux-system main@sha1:<sha>           False       True    stored artifact for revision 'main@sha1:<sha>'
```

`READY: True` になるまで 30 秒程度かかる。`False` の場合は `flux logs --kind=GitRepository` で原因確認。

- [ ] **Step 4: Kustomization が apply できていることを確認**

```bash
flux get kustomizations -n flux-system
```

Expected:
```
NAME        REVISION                SUSPENDED   READY   MESSAGE
flux-system main@sha1:<sha>         False       True    Applied revision: main@sha1:<sha>
```

`READY: True` で `MESSAGE` に `Applied revision: ...` が出ること。

- [ ] **Step 5: 全体ステータスを確認**

```bash
make -C kubernetes gitops-status ENV=production
```

Expected: GitRepository / Kustomization の表が両方表示される。

- [ ] **Step 6: 選択肢 B を選んだ場合のみ、main へ戻す**

選択肢 A を選んだ場合は何もしない。

選択肢 B を選んだ場合は、feature ブランチでの動作確認が完了したのでここで `gotk-sync.yaml` の `ref.branch` を `main` に戻し、PR を作成して merge する。merge 後 1 分以内に Flux が自動で sync を main に切り替える（`flux get sources git` で確認）。

---

### Task 6: end-to-end Flux sync を検証

**Files:** （read only）

Plan 1a 完了条件のスモークテスト。

- [ ] **Step 1: Flux が manifests/production を sync していることを確認**

```bash
flux get all -A
```

Expected: `flux-system` Kustomization が `Ready: True` で出ること。`manifests/production` を再帰的に apply するが空なので apply されるリソースは 0 個。

- [ ] **Step 2: Flux 内の error event が無いことを確認**

```bash
kubectl get events -n flux-system --sort-by=.lastTimestamp | tail -20
```

Expected: `Warning` タイプの event が無い。`Normal` の reconciliation event のみ。

- [ ] **Step 3: cluster 状態の差分を確認**

```bash
kubectl get all -A | wc -l
```

Expected: `flux-install` 前と比べて、flux-system namespace の 6 deployment + 関連 service / config 分しか増えていない。manifests/production 配下からは何も apply されていない（空 scaffold のため）。

- [ ] **Step 4: Flux の reconciliation interval を強制発火して挙動を確認**

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
```

Expected:
```
► annotating GitRepository flux-system in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:<sha>
► annotating Kustomization flux-system in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:<sha>
```

両方とも `applied revision` が出れば、後続 Plan 1b/1c で manifests/production にコンテンツを追加した際に自動で sync される基盤ができている。

- [ ] **Step 5: bootstrap が冪等であることを確認**

`make gitops-setup ENV=production` を再度実行しても何も壊さないこと：

```bash
make -C kubernetes gitops-setup ENV=production
```

Expected:
```
🔧 Setting up FluxCD GitOps...
gitrepository.source.toolkit.fluxcd.io/flux-system unchanged
kustomization.kustomize.toolkit.fluxcd.io/flux-system unchanged
✅ GitOps setup completed
```

`unchanged` が出れば冪等。`configured` が出る場合は誰かが手で変更したか、Flux 内の resource が drift している（`kubectl describe` で原因確認）。

---

### Task 7: README に production runbook セクションを追加

**Files:**
- Modify: `kubernetes/README.md`

local 用の手順しか書かれていない README に、production 向けの bootstrap / 日常運用手順を追加する。

- [ ] **Step 1: 現在の README 末尾を確認**

```bash
tail -30 kubernetes/README.md
```

Expected: `## 障害調査例` セクションが README の末尾。

- [ ] **Step 2: production runbook セクションを追加**

`kubernetes/README.md` の末尾に以下を append：

```markdown

## Production Operations

EKS production cluster `eks-production`（`ap-northeast-1`）の運用手順。

### Initial Bootstrap (one-time)

cluster を新規作成した直後に 1 回だけ実行する。すでに完了済の場合は skip。

```bash
# 1. eks-admin role を assume して kubectl 接続
source ~/Workspace/eks-login.sh production

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
```

- [ ] **Step 3: README が valid な markdown であることを確認**

```bash
grep -c "^##" kubernetes/README.md
```

Expected: section count が 9 個以上（既存の `## 概要` `## 🏗️ アーキテクチャ` `## 🚀 セットアップ` 等 + 新規の `## Production Operations`）。

- [ ] **Step 4: Commit**

```bash
git add kubernetes/README.md
git commit -s -m "$(cat <<'EOF'
docs(kubernetes): add production runbook to README

eks-production cluster の Flux bootstrap / daily operations /
troubleshooting / GitOps 原則 を README に追加する。
EOF
)"
```

---

### Task 8: PR の draft 化と最終 push

**Files:** （git 操作のみ）

選択肢 A（Task 5 で先行 merge）を採った場合、Task 6/7 は別 PR として出すこともある。選択肢 B または PR 未作成の場合は Plan 1a 全体を 1 PR にまとめる。

- [ ] **Step 1: 全 commit を確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: Task 1-3, 7 の commit が並んでいる（Task 4-6 はファイル変更を伴わない）。

- [ ] **Step 2: ブランチを push（未 push の場合）**

```bash
git push -u origin feat/eks-production-platform-roadmap
```

CLAUDE.md ルール: `-u` で tracking branch を設定する。

- [ ] **Step 3: Draft PR を作成（未作成の場合）**

```bash
gh pr create --draft --base main \
  --title "feat(kubernetes): bootstrap Flux on production EKS (Plan 1a)" \
  --body "$(cat <<'EOF'
## Summary
- `helmfile.yaml.gotmpl` で `production` environment を有効化
- `kubernetes/manifests/production/` に空の Kustomize scaffold
- `kubernetes/clusters/production/` に Flux self-management 設定（main ブランチから ./kubernetes/clusters/production を 10 分間隔で sync）
- `kubernetes/README.md` に production 用 runbook セクションを追加

Plan: `docs/superpowers/plans/2026-05-02-eks-production-flux-bootstrap.md`
Spec: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`

これは Phase 1 (Foundation) の Plan 1a。Plan 1b で Cilium 再構成、Plan 1c で foundation addons (ALB Controller / ExternalDNS / Metrics Server / KEDA / Gateway API CRDs) を追加する。

## Test plan
- [ ] `kustomize build kubernetes/clusters/production` が valid
- [ ] `kustomize build kubernetes/manifests/production` が valid
- [ ] `helmfile -e production list` がエラーにならない
- [ ] cluster で `flux check` が pass
- [ ] `flux get all -A` で `flux-system` Kustomization が `Ready: True`
- [ ] `make gitops-setup ENV=production` が冪等（再実行で `unchanged`）
EOF
)"
```

- [ ] **Step 4: PR URL を user に共有**

```bash
gh pr view --json url --jq .url
```

Expected: `https://github.com/panicboat/platform/pull/<num>` が表示される。

---

## Self-review checklist

このセクションは Plan 完成後に書き手（Claude）が自己 review する項目。実装者は Skip して構わない。

- [x] **Spec coverage**: roadmap spec の Phase 1 の "FluxCD" 完了条件（"FluxCD が `kubernetes/manifests/production/` を sync できる"）に対応する Task が存在するか → Task 5/6 でカバー
- [x] **Placeholder scan**: `TBD` / `TODO` / `implement later` / `add appropriate ...` 等の禁止文言が steps に無いか → 確認済（README 内の TODO コメントは既存ファイルの保持のみ）
- [x] **File path consistency**: Task 内で参照するパスが正しいか → 確認済
- [x] **Type / signature consistency**: 該当なし（YAML / shell コマンドのみで型概念なし）
- [x] **Commit message style**: 既存の Conventional Commits 慣習に従っているか（`feat(kubernetes):` / `docs(kubernetes):`） → 確認済
- [x] **CLAUDE.md ルール**: `-s` signoff、`Co-Authored-By` 不使用、PR は draft、新規ブランチは `-u origin HEAD` → 確認済
- [x] **依存 spec の前提**: aws-eks-production が apply 済 + eks-login.sh が deploy 済 を Step で明示 → 確認済
- [x] **後続 plan への引き継ぎ**: Plan 1b で何が追加されるかを References / Out of scope で明示 → 確認済
