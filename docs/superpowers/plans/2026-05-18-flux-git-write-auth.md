# Flux Git Write Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `kubernetes/clusters/production/repositories/monorepo.yaml` を修正し、Flux `monorepo` GitRepository に GitHub App credentials を `secretRef` 経由で渡して、ImageUpdateAutomation の main branch への push を成功させる。

**Architecture:** 1 file 変更。GitRepository spec に `provider: github` + `secretRef.name: panicboat-github-app` を追加し、同 file に `panicboat-github-app` ExternalSecret resource を追加する。ExternalSecret が AWS Secrets Manager `panicboat/github-app/panicboat` から App credentials を fetch して flux-system namespace の K8s Secret に sync、Flux source-controller v1.8.4 がそれを使って App token を生成・自動 refresh する。

**Tech Stack:**
- Flux source-controller v1.8.4 (GitHub App provider native support, Flux v2.4+)
- External Secrets Operator (既存 `ClusterSecretStore: aws-secrets-manager`)
- AWS Secrets Manager (`panicboat/github-app/panicboat` を user 手動で put)
- GitHub App (既存 panicboat App を流用、Contents: Read & Write 権限あり)

**Reference:**
- Spec: `docs/superpowers/specs/2026-05-17-flux-git-write-auth-design.md`

---

## File Structure

| File | Action | Role |
|---|---|---|
| `kubernetes/clusters/production/repositories/monorepo.yaml` | Modify | GitRepository spec に `provider: github` + `secretRef.name: panicboat-github-app` 追加 + 同 file に `panicboat-github-app` ExternalSecret resource を追加 |

## Common Conventions

- worktree: `platform/.claude/worktrees/feat-flux-git-write-auth/` (既存、spec の commit が乗っている)
- ブランチ名: `feat/flux-git-write-auth`
- commit メッセージは Conventional Commits + `-s` (sign-off)、`Co-Authored-By` 禁止
- 初回 push は `git push -u origin HEAD`
- PR は `gh pr create --draft`、タイトルは英語

---

## Pre-PR: Manual Prerequisites (User Actions)

本 PR の実装に取り掛かる前に user が手動で完了する必要がある。Implementer はこれらが完了している前提で進む。

- [ ] **PRE-1: 既存 panicboat App credentials の取得**
  - GitHub: Settings → Developer settings → GitHub Apps → 既存 panicboat App
  - **Permission の verify**: General / Permissions セクションで `Repository permissions: Contents: Read & Write` が付与されていることを確認 (release-please / auto-approve が commit を作るので付いている見込みだが念のため verify)
  - **App ID** を控える (App settings ページ top に表示、数字)
  - **Installation ID** を控える: App 画面 → "Install App" or "Installations" → panicboat/monorepo に install されている entry の ID (= `https://github.com/organizations/panicboat/settings/installations/<ID>` の `<ID>` 部分)
  - **Private key** を取得: "Private keys" セクションで既存 key が手元にあればそれを使用、なければ "Generate a private key" で新規生成して `.pem` ファイルを download

- [ ] **PRE-2: AWS Secrets Manager に secret を put**
  - AWS console (or `aws secretsmanager create-secret`) で:
    - Name: `panicboat/github-app/panicboat`
    - Region: `ap-northeast-1` (cluster と同じ)
    - Value (JSON、改行は `\n` で escape):
      ```json
      {
        "appID": "<App ID>",
        "installationID": "<Installation ID>",
        "privateKey": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
      }
      ```
  - **IAM verify**: ESO の IRSA role が `panicboat/*` 配下の secret を読めることを確認 (既存 ExternalSecret = `panicboat/monolith/database` 等が動作しているので、`panicboat/github-app/panicboat` も同 path pattern で読めるはず、念のため `kubectl describe clustersecretstore aws-secrets-manager` の IAM role policy を verify)

両方完了したら以下の Task に進む。

---

## Task 1: `monorepo.yaml` の修正 (GitRepository + ExternalSecret)

**Files:**
- Modify: `platform/.claude/worktrees/feat-flux-git-write-auth/kubernetes/clusters/production/repositories/monorepo.yaml`

### Step 1.1: 現状確認

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-flux-git-write-auth
cat kubernetes/clusters/production/repositories/monorepo.yaml
```
Expected: 既存内容 (GitRepository + Kustomization, 35 行程度)。

### Step 1.2: GitRepository spec に `provider` と `secretRef` を追加

`kubernetes/clusters/production/repositories/monorepo.yaml` の以下の部分:

Before:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: monorepo
  namespace: flux-system
spec:
  interval: 5m
  url: https://github.com/panicboat/monorepo.git
  ref:
    branch: main
```

After (`ref:` block の後に `provider:` と `secretRef:` を追加):
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: monorepo
  namespace: flux-system
spec:
  interval: 5m
  url: https://github.com/panicboat/monorepo.git
  ref:
    branch: main
  provider: github
  secretRef:
    name: panicboat-github-app
```

(Kustomization 部分 = `monorepo-cluster` は変更なし)

### Step 1.3: ExternalSecret resource を同 file の末尾に追加

ファイル末尾 (Kustomization の後) に `---` 区切りで以下を追加:

```yaml
---
# =============================================================================
# ExternalSecret: Sync GitHub App credentials from AWS Secrets Manager
# =============================================================================
# AWS Secrets Manager の `panicboat/github-app/panicboat` から App
# credentials (appID / installationID / privateKey) を flux-system の K8s
# Secret として sync し、GitRepository monorepo の write 認証に使う。
# AWS Secrets Manager 内の secret は user が console で 1 回手動で put した
# 既存 panicboat App の credentials (Contents: Read & Write 権限あり)。
# =============================================================================
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: panicboat-github-app
  namespace: flux-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: panicboat-github-app
    creationPolicy: Owner
  data:
    - secretKey: github-app-id
      remoteRef:
        key: panicboat/github-app/panicboat
        property: appID
    - secretKey: github-installation-id
      remoteRef:
        key: panicboat/github-app/panicboat
        property: installationID
    - secretKey: github-private-key
      remoteRef:
        key: panicboat/github-app/panicboat
        property: privateKey
```

### Step 1.4: diff 確認

Run:
```bash
git diff kubernetes/clusters/production/repositories/monorepo.yaml
```
Expected:
- GitRepository spec に 3 行追加 (`provider: github`, `secretRef:`, `name: panicboat-github-app`)
- ファイル末尾に ExternalSecret resource (約 30 行) 追加
- 他に変更なし

### Step 1.5: YAML 構文の sanity check

Run:
```bash
bash -c '
for doc_index in 0 1 2; do
  echo "--- document $doc_index ---";
  yq eval "select(documentIndex == $doc_index)" kubernetes/clusters/production/repositories/monorepo.yaml | head -5;
done
'
```
Expected: 3 つの YAML document が出力 (GitRepository / Kustomization / ExternalSecret)。

`yq` がなければ:
```bash
bash -c 'python3 -c "import yaml,sys; docs=list(yaml.safe_load_all(open(\"kubernetes/clusters/production/repositories/monorepo.yaml\"))); print([d[\"kind\"] for d in docs])"'
```
Expected: `['GitRepository', 'Kustomization', 'ExternalSecret']`

両方利用不可ならスキップして次へ (CI / cluster apply で検証)。

---

## Task 2: commit + push + draft PR

### Step 2.1: 変更ファイル確認

Run:
```bash
git status --short
```
Expected:
```
 M kubernetes/clusters/production/repositories/monorepo.yaml
```

### Step 2.2: commit (heredoc, `-s` sign-off, NO `Co-Authored-By`)

Run:
```bash
git add kubernetes/clusters/production/repositories/monorepo.yaml
git commit -s -m "$(cat <<'EOF'
feat(flux): grant monorepo GitRepository write access via GitHub App

Flux ImageUpdateAutomation が `services/{monolith,frontend}/kubernetes/
overlays/production/deployment.yaml` の image tag を semver tag (release-
please tag を起点に build される v0.X.Y) に書き換えて main に commit/push
しようとして失敗していた:

  failed to update source: failed to push to remote:
  authentication required: No anonymous write access.

monorepo GitRepository に secretRef が無く anonymous fetch/push になって
いたのが原因。本 PR は:

- GitRepository spec に `provider: github` + `secretRef: panicboat-github-app`
  を追加。Flux source-controller v1.8.4 の GitHub App provider native
  support で App token を生成 + 自動 refresh する。
- 同 file に ExternalSecret resource を追加し、AWS Secrets Manager の
  `panicboat/github-app/panicboat` (既存 panicboat App の credentials)
  を ESO 経由で flux-system の K8s Secret `panicboat-github-app` に sync。

AWS Secrets Manager の secret value (App private key 等) は user 側で
事前に手動 put 済の前提。本 PR の Kubernetes manifest 反映後、source-
controller が secret を読み App token で GitRepository を fetch/push
する。

Spec: docs/superpowers/specs/2026-05-17-flux-git-write-auth-design.md
EOF
)"
```
Expected: 1 file changed, commit が作成される。

### Step 2.3: push と draft PR 作成

Run:
```bash
git push -u origin HEAD
gh pr create --draft --title "feat(flux): grant monorepo GitRepository write access via GitHub App" --body "$(cat <<'EOF'
## Summary

Resolve the \`authentication required: No anonymous write access\` error from Flux ImageUpdateAutomation that has been blocking the Phase 2 monorepo release-driven Flux deploy from rewriting the production deployment manifest.

- \`kubernetes/clusters/production/repositories/monorepo.yaml\`:
  - GitRepository spec に \`provider: github\` + \`secretRef.name: panicboat-github-app\` を追加
  - 同 file に ExternalSecret \`panicboat-github-app\` を追加 (ESO が AWS Secrets Manager \`panicboat/github-app/panicboat\` から App credentials を sync)
- Flux source-controller v1.8.4 が App token を生成 + 自動 refresh、GitRepository が write 認証で fetch / push 可能になる

## Prerequisites (Manual, completed by user)

- 既存 panicboat App の \`Contents: Read & Write\` 権限を verify
- App ID / Installation ID / Private key を控える
- AWS Secrets Manager \`panicboat/github-app/panicboat\` (region: ap-northeast-1) に \`{appID, installationID, privateKey}\` を JSON で put

## What does NOT change

- monorepo リポ (= 変更不要、本 PR は platform リポのみ)
- 他 GitRepository / Kustomization の設定
- 他リポ (= platform / deploy-actions / panicboat-actions) の Flux 関連設定

## Test plan

- [ ] CI (lint-actions / semantic-pull-request / CI Gatekeeper) が通る
- [ ] マージ後、flux-system Kustomization が新 manifest を apply
- [ ] \`kubectl get externalsecret -n flux-system panicboat-github-app\` が SecretSynced True
- [ ] \`kubectl get secret -n flux-system panicboat-github-app\` で 3 keys (\`github-app-id\` / \`github-installation-id\` / \`github-private-key\`) が存在
- [ ] \`kubectl get gitrepository -n flux-system monorepo\` の status が READY True、auth エラーなし
- [ ] \`kubectl get imageupdateautomation -n flux-system\` が READY True
- [ ] 数十分以内に Flux が \`overlays/production/deployment.yaml\` に semver tag (\`:v0.2.0\`) を書き込み、panicboat[bot] author の \"chore(monolith): bump image to ...\" commit が monorepo main に push される
- [ ] \`kubectl rollout status deployment/monolith\` が成功

## Spec

\`docs/superpowers/specs/2026-05-17-flux-git-write-auth-design.md\`
EOF
)"
```
Expected: PR URL が出力される。

---

## Task 3: PR CI + マージ (ユーザー操作)

### Step 3.1: CI 確認

Run:
```bash
sleep 30
cd /Users/takanokenichi/GitHub/panicboat/platform
gh pr checks <PR番号> --json name,state,workflow --jq '.[] | "\(.workflow) / \(.name): \(.state)"'
```
Expected: 各 check が `SUCCESS` または `SKIPPED`。本 PR は kubernetes manifest 1 file 修正のみで Terragrunt 系の job は走らない (= `workflow-config.yaml` の stack_conventions に対応する変更がないため Deploy Terragrunt / Hydrate Kubernetes / Deploy Kubernetes 等は skipped)。

### Step 3.2: ユーザーがマージ

完了の判断: `gh pr view <PR番号> --json state -q .state` が `MERGED`

---

## Task 4: Flux reconcile + verification

PR マージ後、Flux `flux-system` Kustomization (= platform リポを apply している root) の reconcile interval (10m) を待ってから verify する。手動 reconcile を要求するなら `flux reconcile kustomization flux-system -n flux-system --with-source` で短縮可能。

### Step 4.1: ログインしてから手動 reconcile (任意、待ち時間短縮)

Run:
```bash
eks-login production > /dev/null 2>&1 && bash -c '
flux reconcile kustomization flux-system -n flux-system --with-source 2>&1 | tail -5 || true
sleep 5
flux reconcile gitrepository monorepo -n flux-system 2>&1 | tail -3 || true
'
```
Expected: `Kustomization reconciliation completed` 等の出力。`flux` CLI が無ければスキップ、interval で自然 reconcile を待つ。

### Step 4.2: ExternalSecret が同期されたか

Run:
```bash
eks-login production > /dev/null 2>&1 && bash -c '
kubectl get externalsecret -n flux-system panicboat-github-app
echo "--- keys ---";
kubectl get secret -n flux-system panicboat-github-app -o jsonpath="{.data}" | bash -c "python3 -c \"import json,sys; print(list(json.load(sys.stdin).keys()))\""
'
```
Expected: ExternalSecret が `STATUS: SecretSynced`、`READY: True`、`LAST SYNC` がついている。K8s Secret keys が `['github-app-id', 'github-installation-id', 'github-private-key']`。

ExternalSecret が `SecretSyncedError` で fail する場合、`kubectl describe externalsecret -n flux-system panicboat-github-app` で原因確認 (= AWS Secrets Manager の secret 不在、IAM permission 不足、property name mismatch 等)。

### Step 4.3: GitRepository が新 spec で動作するか

Run:
```bash
eks-login production > /dev/null 2>&1 && bash -c '
kubectl get gitrepository -n flux-system monorepo
echo "--- conditions ---";
kubectl get gitrepository -n flux-system monorepo -o jsonpath="{.status.conditions}" | bash -c "python3 -m json.tool"
'
```
Expected: GitRepository READY True、status conditions に auth エラーなし。

auth エラー (例: `authentication required` や `bad credentials`) が出る場合は GitHub App の権限不足 (Contents: Write 抜け) or AWS Secrets Manager の secret 値 format ミス。

### Step 4.4: ImageUpdateAutomation が push 成功するか

Run:
```bash
eks-login production > /dev/null 2>&1 && bash -c '
kubectl get imageupdateautomation -n flux-system
echo "--- monolith status ---";
kubectl describe imageupdateautomation -n flux-system monolith | tail -20
echo "--- recent events ---";
kubectl get events -n flux-system --field-selector involvedObject.kind=ImageUpdateAutomation --sort-by=lastTimestamp 2>&1 | tail -5
'
```
Expected: READY True、最近の events に Warning `GitOperationFailed` が無い (= "authentication required" メッセージが消えている)。

ImageUpdateAutomation の interval は 30m。マージ直後だと未動作の可能性、reconcile を強制したいなら:
```bash
flux reconcile image update monolith -n flux-system
flux reconcile image update frontend -n flux-system
```

### Step 4.5: monorepo main に bump commit が来ているか

Run:
```bash
bash -c '
gh api "repos/panicboat/monorepo/commits?per_page=5" --jq ".[] | \"\(.sha[0:8]) \(.commit.author.name) \(.commit.message | split(\"\n\")[0])\""
'
```
Expected: 上位に `panicboat[bot]` (or panicboat) author の `chore(monolith): bump image to ghcr.io/panicboat/monorepo/monolith:v0.2.0` 形式の commit が含まれる。

まだなら ImageUpdateAutomation の interval 待ち (30m) or `flux reconcile image update monolith` で促進。

### Step 4.6: overlay deployment.yaml が semver tag に書き換わっているか

Run:
```bash
bash -c '
gh api repos/panicboat/monorepo/contents/services/monolith/kubernetes/overlays/production/deployment.yaml --jq ".content" | base64 -d | grep "image:"
gh api repos/panicboat/monorepo/contents/services/frontend/kubernetes/overlays/production/deployment.yaml --jq ".content" | base64 -d | grep "image:"
'
```
Expected:
- `image: ghcr.io/panicboat/monorepo/monolith:v0.2.0` (現時点の最新 release tag)
- `image: ghcr.io/panicboat/monorepo/frontend:v0.2.0`

### Step 4.7: production rollout の確認

Run:
```bash
eks-login production > /dev/null 2>&1 && bash -c '
kubectl rollout status deployment/monolith --timeout=180s
kubectl rollout status deployment/frontend --timeout=180s
'
```
Expected: それぞれ `deployment "X" successfully rolled out`。

`ImagePullBackOff` 等が出たら ghcr の semver image が存在することを確認:
```bash
docker manifest inspect ghcr.io/panicboat/monorepo/monolith:v0.2.0
```

---

## Task 5: worktree cleanup

### Step 5.1: worktree 削除

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-flux-git-write-auth
git worktree prune
```
Expected: no error。

---

## Notes

- Pre-PR (Manual Prerequisites) を user が完了していない状態で Task 1-3 を進めると、Task 4.2 (ExternalSecret 同期) で fail する。Implementer は Task 4 verification の段階で Manual Prerequisites の完了を user に確認すること
- `kubectl` / `flux` / `gh` / `jq` / `python3` のコマンドは ローカル環境に依存。不在ならスキップ (= reconcile 自然待ち + GitHub UI で commit history 確認等で代替)
- Phase 2 monorepo の end-to-end フローはこの PR のマージで初めて完全動作する。本 PR は Phase 2 plan の Task 16 (end-to-end 検証) の最終ピースに相当
- 本 spec / plan は platform リポのみで完結 (= monorepo リポは変更なし、何もしない)
