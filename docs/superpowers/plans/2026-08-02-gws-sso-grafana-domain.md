# GWS SSO: Grafana Workspace Domain Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grafana（および同じ oauth2-proxy ゲートを共有する Hubble UI / Alertmanager / Prometheus）の Google ログイン許可判定を、個人 Gmail 1 件の ConfigMap allowlist から Google Workspace ドメイン (`panicboat.net`) ベースに切り替える。Grafana の org role デフォルトを `Admin` → `Viewer` に変更し、Admin は Grafana UI での手動昇格に一本化する。

**Architecture:** oauth2-proxy の `config.configFile` を `email_domains = [ "panicboat.net" ]` に変更し、`authenticated_emails_file` と、それが参照する ConfigMap `oauth2-proxy-allowed-emails`（および付随する `extraVolumes`/`extraVolumeMounts`）を削除する。既存の oauth2-proxy + Grafana `auth.proxy` 構成（真の SSO・二重ログインなし）自体は変更しない。Grafana 側は `grafana.ini.users.auto_assign_org_role` を `Admin` → `Viewer` に変更する。両変更とも Google OAuth Client が `Internal` に切り替わっていることを前提とする（Task 0 で確認）。

**Tech Stack:** Helm + helmfile / `oauth2-proxy/oauth2-proxy` chart（既 deploy 済）/ `prometheus-community/kube-prometheus-stack` chart（既 deploy 済、Grafana subchart）

**Spec:** `docs/superpowers/specs/2026-08-01-gws-sso-design.md`

## Global Constraints

- Google Workspace domain: `panicboat.net`
- 既存の cookie 共有 SSO（`cookie_domains = [ ".panicboat.net" ]`）・`auth.proxy` header 連携は変更しない
- Grafana admin/password ログイン（ESO 経由 `grafana-admin` Secret）は緊急時 fallback として維持する（削除しない）
- git commit は `-s`（signoff）を付与、`Co-Authored-By` は付与しない

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl` | modify | `email_domains` をドメイン指定に変更、ConfigMap volume mount 削除 |
| `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml` | delete | 個人 Gmail allowlist が不要になる |
| `kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml` | modify | 削除した ConfigMap の参照を除去 |
| `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` | modify | `auto_assign_org_role` を `Viewer` に変更 |
| `kubernetes/manifests/production/oauth2-proxy/manifest.yaml` | auto-generate | hydrate 出力 |
| `kubernetes/manifests/production/prometheus-operator/manifest.yaml` | auto-generate | hydrate 出力 |

**変更しないもの**: `kubernetes/components/prometheus-operator/production/kustomization/grafana-admin-external-secret.yaml`（admin/password fallback）、Hubble UI / Alertmanager / Prometheus の component 定義、`aws/*`（別 plan `2026-08-02-gws-sso-aws-identity-center.md` で扱う）

---

## Task 0: Pre-flight — worktree/branch 状態 + Google OAuth Client Internal 化の確認

**Files:** (確認のみ、変更なし)

**Context:** Google OAuth Client が `Internal` に切り替わる前に oauth2-proxy 側の `email_domains` を `panicboat.net` に変更すると、Google 側はまだ `panicboat@gmail.com` を認証できてしまう一方で oauth2-proxy 側は `gmail.com` ドメインを拒否するため、**先に手動切り替えが完了していないと個人 Gmail が即座にログインできなくなる**（Grafana admin/password fallback は使えるが、意図しないタイミングでの遮断は避ける）。実行順序を明示的に確認する。

- [ ] **Step 1: worktree/branch 状態確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-gws-sso
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit + （実行済であれば）AWS Identity Center plan の commit 群が ahead

- [ ] **Step 2: Google OAuth Client が Internal であることを確認**

Google Cloud Console → API とサービス → OAuth 同意画面 → 対象クライアントの「公開ステータス」を確認する（spec の Manual Setup Step 5）。

Expected: `Internal` と表示される。`Testing`（External）のままの場合は、本 plan の Task 1〜2 を実行する前に panicboat に Internal 化を依頼する。

- [ ] **Step 3: Grafana admin/password fallback が機能することを確認（切替中の safety net）**

```bash
AWS_PROFILE=platform-admin kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d && echo
```

Expected: `admin` が出力される（Secret が存在し、fallback login に使える状態であることの確認）

---

## Task 1: oauth2-proxy をドメインベース allowlist に変更

**Files:**
- Modify: `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl`
- Delete: `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml`
- Modify: `kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml`

- [ ] **Step 1: `values.yaml.gotmpl` の `config.configFile` を編集**

Old:
```yaml
config:
  existingSecret: oauth2-proxy-google
  configFile: |-
    provider = "google"
    email_domains = [ "*" ]
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
    authenticated_emails_file = "/etc/oauth2-proxy/emails/allowed"
```

New:
```yaml
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

- [ ] **Step 2: `values.yaml.gotmpl` から ConfigMap volume mount を削除**

Old:
```yaml
# =============================================================================
# Extra Volumes & Volume Mounts (= ConfigMap allowlist)
# =============================================================================
# ConfigMap `oauth2-proxy-allowed-emails` (= kustomization で deploy) を 4 releases が
# 共有 mount、config.configFile の `authenticated_emails_file` で参照。
# ConfigMap 変更時は Reloader が 4 Deployments 全部を auto-rollout
# (= deploymentAnnotations 参照、annotation が同じ namespace 内の全 ConfigMap watch を trigger)。
extraVolumes:
  - name: emails
    configMap:
      name: oauth2-proxy-allowed-emails
extraVolumeMounts:
  - name: emails
    mountPath: /etc/oauth2-proxy/emails
    readOnly: true

# =============================================================================
# Deployment Annotations (= Reloader watch)
# =============================================================================
# ESO 由来 Secret `oauth2-proxy-google` 変更時 + ConfigMap `oauth2-proxy-allowed-emails`
# 変更時に Reloader が自動 rollout する。
deploymentAnnotations:
  reloader.stakater.com/auto: "true"
```

New:
```yaml
# =============================================================================
# Deployment Annotations (= Reloader watch)
# =============================================================================
# ESO 由来 Secret `oauth2-proxy-google` 変更時に Reloader が自動 rollout する。
deploymentAnnotations:
  reloader.stakater.com/auto: "true"
```

- [ ] **Step 3: ConfigMap を削除**

```bash
git rm kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml
```

- [ ] **Step 4: `kustomization.yaml` から ConfigMap の参照を削除**

Old:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - allowed-emails-configmap.yaml
  - ingress-monitoring-uis.yaml
```

New:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - ingress-monitoring-uis.yaml
```

- [ ] **Step 5: helmfile template で反映確認（cluster 接続不要）**

```bash
helmfile -f kubernetes/components/oauth2-proxy/production/helmfile.yaml -e production template --skip-tests 2>/dev/null | grep -A2 "email_domains\|authenticated_emails_file"
```

Expected: `email_domains = [ "panicboat.net" ]` が 4 release 分（grafana/hubble/alertmanager/prometheus）出力され、`authenticated_emails_file` は出力に含まれない

- [ ] **Step 6: 生成物を hydrate**

```bash
./scripts/kubernetes-hydrate/hydrate-component.sh oauth2-proxy production
git status --short kubernetes/manifests/production/oauth2-proxy/
```

Expected: `manifest.yaml` に差分（`email_domains` 変更、ConfigMap `oauth2-proxy-allowed-emails` 削除、Deployment の volume/volumeMount 削除）。TLS material 以外の差分がない場合は Step 1〜4 の編集を見直す。

- [ ] **Step 7: Commit**

```bash
git add kubernetes/components/oauth2-proxy/production/ kubernetes/manifests/production/oauth2-proxy/
git commit -s -m "feat(kubernetes/oauth2-proxy): switch to Workspace domain allowlist

個人 Gmail 1 件の ConfigMap allowlist を廃止し、oauth2-proxy 組込みの
email_domains でドメインベースの許可判定に切り替える。Google OAuth
Client が Internal 化済であることが前提 (Task 0 で確認済)。"
```

---

## Task 2: Grafana の org role デフォルトを Viewer に変更

**Files:**
- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`

- [ ] **Step 1: `auto_assign_org_role` を編集**

Old:
```yaml
  grafana.ini:
    auth.proxy:
      enabled: true
      header_name: X-Forwarded-User
      header_property: username
      auto_sign_up: true
      sync_ttl: 60
    users:
      auto_assign_org: true
      auto_assign_org_role: Admin
```

New:
```yaml
  grafana.ini:
    auth.proxy:
      enabled: true
      header_name: X-Forwarded-User
      header_property: username
      auto_sign_up: true
      sync_ttl: 60
    users:
      auto_assign_org: true
      # 新規ログインは最小権限 Viewer で auto-create、Admin は Grafana UI
      # で手動昇格する (= Google Group ベースの自動 role 連携は行わない、
      # spec の Out of Scope 参照)。
      auto_assign_org_role: Viewer
```

- [ ] **Step 2: 生成物を hydrate**

```bash
./scripts/kubernetes-hydrate/hydrate-component.sh prometheus-operator production
git status --short kubernetes/manifests/production/prometheus-operator/
```

Expected: `manifest.yaml` に `auto_assign_org_role` の差分のみ

- [ ] **Step 3: Commit**

```bash
git add kubernetes/components/prometheus-operator/production/ kubernetes/manifests/production/prometheus-operator/
git commit -s -m "feat(kubernetes/grafana): default new SSO logins to Viewer role

複数メンバー運用に備え、auth.proxy 経由の新規ユーザーを一律 Admin では
なく最小権限 Viewer で auto-create する。Admin 昇格は Grafana UI で
手動実施する運用に切り替える。"
```

---

## Task 3: End-to-end 動作確認

**Files:** (確認のみ、変更なし)

**Context:** Flux が Task 1〜2 の変更を reconcile した後に確認する。cluster 側の反映を待つため、`kubectl get pods` で対象 Deployment が新しい Pod に入れ替わっていることを先に確認してからブラウザ確認に進む。

- [ ] **Step 1: Flux reconcile 完了 + Pod rollout 確認**

```bash
AWS_PROFILE=platform-admin kubectl get pods -n oauth2-proxy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
AWS_PROFILE=platform-admin kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
```

Expected: 全 Pod `Running`（Reloader による rollout が完了済であること）

- [ ] **Step 2: `panicboat@panicboat.net` でログイン確認**

ブラウザで `https://grafana.panicboat.net` を開き `panicboat@panicboat.net` でログインする。

Expected: Google 認証画面に遷移し、ログイン後 Grafana に auto-login される（初回は Viewer role で auto-create）

- [ ] **Step 3: Grafana UI で Admin に昇格**

Grafana admin/password（`grafana-admin` Secret 由来）で別途ログインし、Administration → Users で `panicboat@panicboat.net` を Admin に変更する。

- [ ] **Step 4: 再ログインで Admin 反映確認**

`panicboat@panicboat.net` で再度ログインし、Admin 権限（例: Data sources の編集画面が見える）を確認する。

- [ ] **Step 5: 個人 Gmail が拒否されることを確認**

`panicboat@gmail.com` で `https://grafana.panicboat.net` へのログインを試行する。

Expected: Google 側の OAuth 同意画面で拒否される（Internal app のため Workspace ドメイン外のアカウントは選択肢に出ない、または明示的にエラーになる）

- [ ] **Step 6: 他 3 UI への SSO 疎通確認**

同一 browser session のまま `https://hubble.panicboat.net`、`https://alertmanager.panicboat.net`、`https://prometheus.panicboat.net` にアクセスする。

Expected: 再ログインなしでアクセスできる（cookie domain `.panicboat.net` による既存 SSO が継続していることの確認）

---
