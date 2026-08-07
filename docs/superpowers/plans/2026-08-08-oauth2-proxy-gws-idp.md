# oauth2-proxy GWS IdP Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** monitoring UIs 4 host (grafana / hubble / alertmanager / prometheus) の認証入口を、個人 Google アカウント 1 件の email allowlist から Google Workspace `panicboat.net` のドメイン判定に切り替える。

**Architecture:** `panicboat.net` の GWS に付随する Google Cloud org 配下に Internal user type の OAuth client を発行し、AWS Secrets Manager の既存 secret `panicboat/oauth2-proxy/google` の値を差し替える。oauth2-proxy は `provider = "google"` のまま、許可判定を `authenticated_emails_file` から `email_domains` に移す。新規コンポーネントなし、terragrunt 変更なし。

**Tech Stack:** oauth2-proxy chart 10.7.0 (app 7.15.3) / helmfile / kustomize / External Secrets Operator / Reloader / Flux CD / AWS Secrets Manager

**Design doc:** `docs/superpowers/specs/2026-08-08-oauth2-proxy-gws-idp-design.md`

## Global Constraints

- 作業ブランチは `feat/oauth2-proxy-gws-idp`、worktree は `.claude/worktrees/feat-oauth2-proxy-gws-idp/`。ブランチと worktree を切り直さない
- commit は `git commit -s` (= `--signoff`) を使う。commit message に `Co-Authored-By` を付けない
- PR は `gh pr create --draft` で作成する。Draft 以外で作らない。PR タイトルは英語
- ドキュメントは見出しが英語、本文が日本語
- 依頼範囲外のリファクタ・コメント追加・型注釈追加をしない
- `kubernetes/manifests/production/oauth2-proxy/manifest.yaml` は hydrate 生成物。手で編集しない
- 本番 cutover (Task 4) は break-glass 手順を手元に用意してから開始する
- Grafana の `auto_assign_org_role: Admin` は変更しない (= 本 plan の範囲外)

## Deployment Path (前提知識)

- Flux は `main` ブランチを 1 分間隔で取得し、`./kubernetes/clusters/production` を 10 分間隔で apply する (`kubernetes/clusters/production/flux-system/gotk-sync.yaml`)
- root kustomization が `../../manifests/production` を含むため、**merge して初めて本番に反映される**。PR 段階では apply されない
- PR を開くと label-dispatcher が `deploy:oauth2-proxy` ラベルを自動付与し、hydrator が hydrate 結果を PR ブランチに commit、kustomize-diff が差分を PR コメントに投稿する
- EKS 認証は zsh 関数 `eks-login`。Claude Code のセッションからは `! eks-login` で実行する

## File Structure

| ファイル | 責務 | 変更 |
| --- | --- | --- |
| `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl` | 4 release 共通の oauth2-proxy 設定 | 許可判定を `email_domains` に変更、allowlist mount を削除 |
| `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml` | email allowlist の実体 | 削除 |
| `kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml` | chart 範囲外 resource の overlay | ConfigMap 参照を削除 |
| `kubernetes/components/oauth2-proxy/production/helmfile.yaml` | 4 release の定義 | ヘッダコメントを現在の構成に更新 |
| `kubernetes/manifests/production/oauth2-proxy/manifest.yaml` | hydrate 生成物 | スクリプトで再生成 |

`external-secret.yaml` と `ingress-monitoring-uis.yaml` は変更しない。`aws/` 配下は変更しない。

---

### Task 1: Google Cloud プロジェクトと Internal OAuth client の作成

**実行者:** 人間 (= Google Cloud console と AWS console の手動操作。エージェントは代行できない)

**Files:** なし

**Interfaces:**
- Consumes: なし
- Produces: 新しい `client_id` / `client_secret` (= Task 4 で AWS Secrets Manager に投入)、旧 OAuth client の publishing status (= Task 4 の分岐条件)

- [ ] **Step 1: 旧 OAuth client の publishing status を確認して記録する**

現行の `panicboat/oauth2-proxy/google` が指す OAuth client が属する Google Cloud プロジェクト (= 個人 Google アカウント配下) を開き、Google Auth Platform の Audience 画面で publishing status を確認する。

記録する値: `External / In production` または `External / Testing` または `Internal`

**なぜ必要か:** Task 4 でコード変更を先に merge すると、secret 差し替えまでの間は「新しい `email_domains = panicboat.net`」と「旧 OAuth client」の組み合わせになる。旧 client が `External / In production` なら panicboat.net アカウントはこの間もログインできる。`Testing` なら test users に載っていない限り誰もログインできない窓が生じる。Task 4 の手順がこの値で分岐する。

- [ ] **Step 2: Google Cloud プロジェクトを作成する**

`panicboat.net` の GWS 管理者アカウントで Google Cloud console にサインインし、`panicboat.net` の組織配下にプロジェクトを 1 つ作成する。

- プロジェクト名: `panicboat-platform-auth`
- 組織: `panicboat.net` (= 「組織なし」になっていないことを確認する)

初回サインイン時は Cloud 利用規約の承諾を求められる。課金アカウントの紐付けは不要。

**完了条件:** プロジェクトの「組織」欄に `panicboat.net` が表示されている。

- [ ] **Step 3: Google Auth Platform を Internal user type で構成する**

作成したプロジェクトで Google Auth Platform を開き、以下を設定する。

- User type: **Internal**
- App name: `panicboat monitoring UIs`
- User support email: GWS 管理者のアドレス
- Developer contact email: 同上

**完了条件:** Audience 画面で User type が `Internal` と表示されている。Internal では Google の審査もテストユーザー登録も不要。

- [ ] **Step 4: OAuth 2.0 Client ID を作成する**

Clients 画面で「Create client」を実行する。

- Application type: **Web application**
- Name: `oauth2-proxy`
- Authorized redirect URIs (= 4 件すべて登録する):

```
https://grafana.panicboat.net/oauth2/callback
https://hubble.panicboat.net/oauth2/callback
https://alertmanager.panicboat.net/oauth2/callback
https://prometheus.panicboat.net/oauth2/callback
```

`/oauth2/callback` は oauth2-proxy の default proxy prefix `/oauth2` に対応する callback path。現行 values は `redirect_url` を明示していないため、oauth2-proxy がリクエストの host からこの path で組み立てる。

**完了条件:** 登録済み redirect URI が 4 件、上記と 1 文字も違わずに一致している (= 末尾スラッシュの有無を含む)。

- [ ] **Step 5: client_id / client_secret を控える**

発行された Client ID と Client secret を、シェル履歴に残らない形で控える (= パスワードマネージャ等)。Task 4 で AWS Secrets Manager に投入する。

- [ ] **Step 6: 旧 OAuth client を削除しないことを確認する**

旧 client は Task 4 のロールバック手段。**削除しない。**

**Task 1 完了条件:**
- 新しい client_id / client_secret を保持している
- redirect URI 4 件が登録済み
- 旧 client の publishing status を記録済み
- 旧 client が残っている

---

### Task 2: oauth2-proxy の許可判定をドメイン判定に置き換える

**実行者:** エージェント

**Files:**
- Modify: `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl:55-105`
- Delete: `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml`
- Modify: `kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml`
- Modify: `kubernetes/components/oauth2-proxy/production/helmfile.yaml`
- Regenerate: `kubernetes/manifests/production/oauth2-proxy/manifest.yaml`

**Interfaces:**
- Consumes: なし (= Task 1 の成果物はコードに現れない。client 資格情報は AWS Secrets Manager 経由)
- Produces: hydrate 済み manifest (= Task 3 で PR に載せる)

- [ ] **Step 1: Provider block を書き換える**

`kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl` の Provider block を置き換える。対象は `# Provider: Google OAuth` を含む見出し行の 2 行上の `# ===...` 区切り行から、`authenticated_emails_file = "/etc/oauth2-proxy/emails/allowed"` の行まで (= 変更前の 55-81 行目)。

置換後の内容は以下。変更点は 4 つ: 見出しに Workspace ドメインを明記、二重判定の理由コメントを追加、`email_domains` の値を変更、`authenticated_emails_file` 行を削除。

```yaml
# =============================================================================
# Provider: Google OAuth (= Google Workspace panicboat.net)
# =============================================================================
# config.existingSecret で ESO 由来 K8s Secret `oauth2-proxy-google` を直接参照、
# chart が OAUTH2_PROXY_CLIENT_ID / CLIENT_SECRET / COOKIE_SECRET を deployment 環境変数に
# 自動注入する (= chart template/secret.yaml は existingSecret 設定時に skip)。
# 4 releases が同じ Secret を参照することで cookie_secret 共有 → cookie domain
# `.panicboat.net` 経由で 4 hosts SSO 実現 (= 同じ cookie name `_oauth2_proxy` を
# 4 instances が共通の cookie_secret で encrypt/decrypt)。
#
# email_domains は Google 側の Internal OAuth client 制限と重複しない。Internal が
# 守るのは GWS テナント境界 (= テナントが複数ドメインを持てばその全部を通す)、
# email_domains が守るのは monitoring UIs の利用者境界 (= panicboat.net のみ)。
# テナントに追加ドメインが生えても本 UI の利用者が広がらないようにするのが後者。
config:
  existingSecret: oauth2-proxy-google
  configFile: |-
    provider = "google"
    email_domains = [ "panicboat.net" ]
    upstreams = [ "{{ $upstreamUrl }}" ]
    cookie_domains = [ ".panicboat.net" ]
    whitelist_domains = [ ".panicboat.net" ]
    cookie_secure = true
    cookie_httponly = true
    cookie_samesite = "lax"
    pass_authorization_header = true
    pass_access_token = true
    set_authorization_header = true
    set_xauthrequest = true
    skip_provider_button = true
    reverse_proxy = true
```

- [ ] **Step 2: extraVolumes / extraVolumeMounts block を削除する**

`# Extra Volumes & Volume Mounts (= ConfigMap allowlist)` を含む見出し行の 1 行上の `# ===...` 区切り行から、`    readOnly: true` の行までを block ごと削除する。あわせて直後の空行 1 行も削除し、`# Deployment Annotations` の block が Provider block の直後に来るようにする。

allowlist ファイルを参照しなくなったため mount が不要になる。

**行番号で位置を探さないこと。** Step 1 の置換で Provider block が 4 行伸びており、変更前の行番号 (= 83-98) はずれている。上記の文字列を anchor にして探す。

- [ ] **Step 3: deploymentAnnotations のコメントから ConfigMap への言及を外す**

同ファイルの `# Deployment Annotations (= Reloader watch)` block のコメント 2 行を置き換える。

置換前:

```yaml
# ESO 由来 Secret `oauth2-proxy-google` 変更時 + ConfigMap `oauth2-proxy-allowed-emails`
# 変更時に Reloader が自動 rollout する。
```

置換後:

```yaml
# ESO 由来 Secret `oauth2-proxy-google` の変更 (= OAuth client 差し替え / rotation) を
# Reloader が検知して自動 rollout する。
```

- [ ] **Step 4: allowlist ConfigMap を削除する**

```bash
git rm kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml
```

- [ ] **Step 5: kustomization.yaml から ConfigMap 参照を外す**

`kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml` を以下の全文で置き換える。

```yaml
# =============================================================================
# oauth2-proxy production kustomization
# =============================================================================
# chart 範囲外 resource (= ExternalSecret + 4 Ingresses) を
# helmfile output に上乗せする overlay。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - ingress-monitoring-uis.yaml
```

- [ ] **Step 6: helmfile.yaml のヘッダコメントを更新する**

`kubernetes/components/oauth2-proxy/production/helmfile.yaml` の該当 2 行を置き換える。

置換前:

```yaml
# Google OAuth gate + email allowlist (= ConfigMap allowed-emails) で
# panicboat@gmail.com のみ通過。
```

置換後:

```yaml
# Google Workspace panicboat.net の Internal OAuth client + email_domains で
# 同ドメインの user のみ通過。
```

- [ ] **Step 7: hydrate を実行する**

**`AQUA_CONFIG` を必ず設定すること。**

```bash
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
bash scripts/kubernetes-hydrate/hydrate-component.sh oauth2-proxy production
```

期待: エラーなく終了する。スクリプトは worktree の root で動作する (= 内部で `git rev-parse --show-toplevel` を実行)。

**なぜ `AQUA_CONFIG` が要るか:** version pin は `.github/aqua.yaml` にあり、root に `aqua.yaml` が無いため aqua は自動適用しない。素の PATH で実行すると global に入れた別バージョン (= helm v4 系など) が使われ、CI が使う pin (= helmfile v0.169.2 / helm v3.17.3 / kustomize v5.6.0) と出力がずれる。helm の major version 差は `---` 区切りの直前の空行の有無として現れ、CI hydrator が差分を検出して余分な commit を積む。CI 側は `reusable--kubernetes-hydrator.yaml` で `AQUA_CONFIG: .github/aqua.yaml` を明示している。

設定できているかは version で確認する。

```bash
helm version --template '{{.Version}}'   # v3.17.3
helmfile --version | head -1             # helmfile version 0.169.2
kustomize version                        # v5.6.0
```

- [ ] **Step 8: hydrate 結果を検証する**

```bash
grep -c 'email_domains = \[ "panicboat.net" \]' kubernetes/manifests/production/oauth2-proxy/manifest.yaml
grep -c 'authenticated_emails_file' kubernetes/manifests/production/oauth2-proxy/manifest.yaml || true
grep -c 'oauth2-proxy-allowed-emails' kubernetes/manifests/production/oauth2-proxy/manifest.yaml || true
grep -c 'email_domains = \[ "\*" \]' kubernetes/manifests/production/oauth2-proxy/manifest.yaml || true
```

期待する出力 (上から順に):

```
4
0
0
0
```

`4` は 4 release 分。`0` が 3 つ揃わない場合は Step 1-6 のいずれかが未反映なので、先に戻って直す。

- [ ] **Step 9: 差分の形を確認する**

```bash
git status --short
git diff --stat
```

期待: 変更されるのは以下の 5 ファイルのみ。他のファイルが出た場合は範囲外の変更なので戻す。

```
 kubernetes/components/oauth2-proxy/production/helmfile.yaml
 kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml (削除)
 kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml
 kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl
 kubernetes/manifests/production/oauth2-proxy/manifest.yaml
```

- [ ] **Step 10: commit する**

```bash
git add -A kubernetes/components/oauth2-proxy kubernetes/manifests/production/oauth2-proxy
git commit -s -F - <<'EOF'
feat(kubernetes/components/oauth2-proxy/production): gate monitoring UIs on panicboat.net domain

認可の単位が個人 Google アカウント 1 件の allowlist だったため、GWS の
ユーザー管理と接続しておらず、メンバー追加のたびに ConfigMap 編集と
rollout が必要だった。email_domains によるドメイン判定に移し、許可判定を
GWS のユーザー管理に委ねる。

email_domains は Google 側の Internal OAuth client 制限とは守る対象が異なる。
Internal は GWS テナント境界を守るが、テナントが複数ドメインを持つ場合は
panicboat.net より広くなる。monitoring UIs の利用者境界は email_domains 側で
閉じる。

Grafana の auto_assign_org_role は Admin のまま据え置く。auth.proxy 経由では
group を role に変換する手段がなく (Team Sync は Enterprise 限定)、role 分けは
Grafana native OIDC 化の別サブプロジェクトとして扱う。
EOF
```

**Task 2 完了条件:** Step 8 の grep が `4 / 0 / 0 / 0` を返し、Step 9 の差分が 5 ファイルに収まり、commit が作られている。

---

### Task 3: PR を作成して CI の出力を確認する

**実行者:** エージェント (= push と PR 作成)、人間 (= CI 結果の確認)

**Files:** なし (= リポジトリ操作のみ)

**Interfaces:**
- Consumes: Task 2 の commit
- Produces: Draft PR (= Task 4 で merge する)

- [ ] **Step 1: push してトラッキングを設定する**

```bash
git push -u origin HEAD
```

- [ ] **Step 2: Draft PR を作成する**

```bash
gh pr create --draft \
  --title "feat(kubernetes/components/oauth2-proxy/production): gate monitoring UIs on panicboat.net domain" \
  --body-file - <<'EOF'
## Why

monitoring UIs 4 host の認可単位が個人 Google アカウント 1 件の allowlist に固定されており、Google Workspace のユーザー管理と接続していない。メンバー追加のたびに ConfigMap 編集と rollout が要る状態を解消する。

## What

- 許可判定を `authenticated_emails_file` (= ConfigMap `oauth2-proxy-allowed-emails`) から `email_domains = [ "panicboat.net" ]` に移す
- allowlist ConfigMap と、それを参照する volume mount を削除する

新規コンポーネントなし。terragrunt 変更なし。`external-secret.yaml` はキー構成が変わらないため変更なし。

## Cutover

本 PR の merge だけでは完了しない。AWS Secrets Manager `panicboat/oauth2-proxy/google` の `client_id` / `client_secret` を Google Workspace `panicboat.net` 配下の Internal OAuth client の値に差し替える手順とセットで実施する。

`cookie_secret` は 4 release の SSO 共有鍵なので差し替えない。

Design: `docs/superpowers/specs/2026-08-08-oauth2-proxy-gws-idp-design.md`
Plan: `docs/superpowers/plans/2026-08-08-oauth2-proxy-gws-idp.md`
EOF
```

- [ ] **Step 3: CI の完了を待って出力を確認する**

```bash
gh pr checks --watch
gh pr view --json labels --jq '.labels[].name'
```

確認する内容:

1. ラベルに `deploy:oauth2-proxy` が自動付与されている
2. hydrator が追加 commit を作っていない (= Task 2 Step 7 を `AQUA_CONFIG` 付きで実行していれば差分ゼロが正常)。追加 commit がある場合は `git pull` して内容を確認する。空行だけの差分なら Task 2 Step 7 の toolchain がずれていたので、`AQUA_CONFIG` を設定して再 hydrate し、CI 出力と一致することを確認してから進む。空行以外の差分なら原因を特定するまで進まない
3. kustomize-diff の PR コメントに以下が現れている
   - ConfigMap `oauth2-proxy-allowed-emails` の削除
   - 4 Deployment の `email_domains` 変更と volume / volumeMount 削除

**Task 3 完了条件:** Draft PR が存在し、CI が green で、kustomize-diff の内容が意図と一致している。

---

### Task 4: Cutover と本番検証

**実行者:** 人間 (= AWS console 操作とブラウザでのログイン検証を含む)

**Files:** なし

**Interfaces:**
- Consumes: Task 1 の client_id / client_secret と publishing status、Task 3 の Draft PR
- Produces: 本番稼働中の GWS 認証

**この Task の順序が入れ替え不可である理由:** secret を先に差し替えると、Google 側は Internal client になって `gmail.com` を拒否する一方、oauth2-proxy 側は allowlist に `panicboat@gmail.com` しか持たないため `panicboat.net` も拒否する。**確実に全員ロックアウトする。** コードを先に merge すれば、`email_domains` が `panicboat.net` を通す状態で旧 client (= External) が認証を担うため、ロックアウトを避けられる。

- [ ] **Step 1: break-glass 手順を手元に用意する**

oauth2-proxy が塞がると Grafana のログイン画面にも到達できない (= ALB → oauth2-proxy → Grafana の順で、認証は Grafana の手前)。復旧経路は port-forward。

```bash
# EKS 認証 (Claude Code セッションからは `! eks-login`)
eks-login

# Grafana に直接到達する
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# 別ターミナルで admin 資格情報を取り出す
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**完了条件:** `kubectl -n oauth2-proxy get deploy` が 4 Deployment を返す (= cluster に到達できている)。

- [ ] **Step 2: PR を ready にして merge する**

```bash
gh pr ready
gh pr merge --squash
```

- [ ] **Step 3: Flux の反映を確認する**

```bash
flux reconcile kustomization flux-system --with-source
kubectl -n oauth2-proxy get configmap oauth2-proxy-allowed-emails 2>&1
```

期待: ConfigMap が `NotFound` になっている (= 削除が反映された)。

```bash
kubectl -n oauth2-proxy get configmap oauth2-proxy-grafana -o jsonpath='{.data.oauth2_proxy\.cfg}' | grep email_domains
```

期待: `email_domains = [ "panicboat.net" ]`

- [ ] **Step 4: rollout の完了を確認する**

```bash
for d in grafana hubble alertmanager prometheus; do
  kubectl -n oauth2-proxy rollout status deploy/oauth2-proxy-$d --timeout=180s
done
```

Reloader が自動 rollout するが、進まない場合は明示的に再起動する。

```bash
kubectl -n oauth2-proxy rollout restart deploy/oauth2-proxy-grafana deploy/oauth2-proxy-hubble deploy/oauth2-proxy-alertmanager deploy/oauth2-proxy-prometheus
```

- [ ] **Step 5: 中間状態のログインを確認する (= Task 1 Step 1 の記録で分岐)**

この時点の構成は「旧 OAuth client + `email_domains = panicboat.net`」。

- 記録が **`External / In production`** の場合: `https://grafana.panicboat.net` に `panicboat.net` アカウントでログインできることを確認してから Step 6 に進む。ここで通れば、以降の失敗要因を新 client 側に絞り込める
- 記録が **`External / Testing`** または **`Internal`** の場合: この中間状態では誰もログインできない。確認を飛ばして **すぐに Step 6 に進む** (= 窓を短くする)

- [ ] **Step 6: AWS Secrets Manager の値を差し替える**

AWS console → Secrets Manager → `panicboat/oauth2-proxy/google` → 「シークレットの値を取得する」→ 「編集」。

- `client_id`: Task 1 で発行した Client ID
- `client_secret`: Task 1 で発行した Client secret
- `cookie_secret`: **変更しない** (= 4 release が共有する SSO 鍵。差し替えると全 host のセッションが無効化されるだけで、得るものがない)

console を使うのは、CLI の `put-secret-value` が JSON 全体を置換するため `cookie_secret` を巻き込む事故が起きやすく、かつ secret 値がシェル履歴に残るため。

**完了条件:** console 上で 3 キーが揃っており、`cookie_secret` が変更前と同じ値である。

- [ ] **Step 7: ESO の同期を強制する**

`refreshInterval: 1h` を待たずに反映させる。

```bash
kubectl -n oauth2-proxy annotate externalsecret oauth2-proxy-google \
  force-sync="$(date +%s)" --overwrite

kubectl -n oauth2-proxy get externalsecret oauth2-proxy-google \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

期待: `True`

K8s Secret に新しい client_id が入ったことを確認する。

```bash
kubectl -n oauth2-proxy get secret oauth2-proxy-google \
  -o jsonpath='{.data.client-id}' | base64 -d; echo
```

期待: Task 1 で発行した Client ID と一致する。

- [ ] **Step 8: rollout の完了を確認する**

```bash
for d in grafana hubble alertmanager prometheus; do
  kubectl -n oauth2-proxy rollout status deploy/oauth2-proxy-$d --timeout=180s
done
```

- [ ] **Step 9: 4 host のログインと SSO を検証する**

ブラウザのシークレットウィンドウで実施する (= 既存 cookie の影響を排除する)。

1. `https://grafana.panicboat.net` を開き、`panicboat.net` アカウントでログインする → Grafana が表示される
2. 同じウィンドウで `https://hubble.panicboat.net` を開く → **再認証を求められずに** 表示される
3. 同様に `https://alertmanager.panicboat.net` と `https://prometheus.panicboat.net` を開く → 再認証なしで表示される

2-3 が通れば cookie domain `.panicboat.net` による 4 host SSO が維持されている。

- [ ] **Step 10: gmail.com が拒否されることを確認する**

別のシークレットウィンドウで `https://grafana.panicboat.net` を開き、`gmail.com` アカウントを選ぶ。

期待: Google が `access_denied` を返す。

**この結果の解釈に注意:** ここで拒否しているのは Google 側の Internal 制限であり、oauth2-proxy の `email_domains` には到達していない。`email_domains` 自体を通す検証には同一 GWS テナント内の別ドメイン (= `dystopia.city` が同一テナントである場合) のアカウントが必要。用意できない場合は**未検証項目として記録し、成功報告に含めない。**

- [ ] **Step 11: Grafana のユーザーを確認する**

Grafana の Administration → Users を開く。

期待:
- `@panicboat.net` のユーザーが新規に作成され、role が `Admin` である
- 旧 `panicboat@gmail.com` ユーザーが残っている (= ログイン経路を失っただけで無害)

- [ ] **Step 12: worktree を片付ける**

merge 済みを確認してから実行する。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-oauth2-proxy-gws-idp
git worktree prune
```

**Task 4 完了条件:** Step 9 で 4 host すべてに `panicboat.net` アカウントでログインでき、SSO が維持され、Step 11 で Grafana に `@panicboat.net` の Admin ユーザーが存在する。

---

## Rollback

Step 6 以降で問題が起きた場合。

1. AWS Secrets Manager `panicboat/oauth2-proxy/google` の `client_id` / `client_secret` を旧 OAuth client の値に戻す (= console で編集)
2. ESO を強制同期する

```bash
kubectl -n oauth2-proxy annotate externalsecret oauth2-proxy-google \
  force-sync="$(date +%s)" --overwrite
```

3. `email_domains` も戻す必要がある場合は、merge した commit を revert して push する

```bash
git revert <merge-commit-sha>
git push
flux reconcile kustomization flux-system --with-source
```

旧 OAuth client を残しておく限り、Google 側の再作成なしで戻せる。復旧中の Grafana access は Task 4 Step 1 の port-forward で確保する。
