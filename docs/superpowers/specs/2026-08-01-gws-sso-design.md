# GWS (Google Workspace) SSO 導入 Design

> **Goal**: Google Workspace (`panicboat.net`) を IdP として (1) AWS ログインをロールベースアクセス制御付きで SSO 化し、(2) 既存 Grafana SSO を個人 Gmail 依存から Workspace ドメイン依存に切り替える。対象範囲はこの repository が管理する AWS / Kubernetes 基盤のみ。

---

## Context

### 現状

- **AWS**: 人間の kubectl/Console アクセスは `eks-admin-production` IAM role（account root が assume 可能）を経由する 1 本のみ（`aws/eks/modules/iam_admin.tf`、`aws/eks/modules/access_entries.tf`）。IAM Identity Center 等の SSO は未導入。IAM user 側の `sts:AssumeRole` 許可は repo 管理外
- **Grafana**: すでに oauth2-proxy + Google OAuth + Grafana `auth.proxy` mode で SSO 化済み（`docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`）。ただし allowlist は個人 Gmail (`panicboat@gmail.com`) 1 件の ConfigMap、OAuth Client は `External + Testing`、Grafana 側は allowlist 通過者全員が一律 `auto_assign_org_role: Admin`。同 spec の引き継ぎ事項 #11 に「Google Workspace 契約後の OAuth Internal 化 + email_domain allowlist 移行」が明記されており、本 design はその実行にあたる
- **Hubble UI / Alertmanager / Prometheus**: oauth2-proxy 経由で Grafana と同じ SSO cookie を共有するのみ。ロール概念を持たないツールのため、認証ゲート通過の可否のみが意味を持つ

### GWS 導入の前提（brainstorming で確定）

- GWS は未契約。これから契約し、将来の複数メンバー運用に備える（現時点の実利用者は panicboat のみ）
- ドメインは既存 Route53 保有の `panicboat.net` を使用
- panicboat 自身のログインアカウントは契約後 `panicboat@panicboat.net`（Workspace）に一本化し、個人 Gmail (`panicboat@gmail.com`) は引退させる
- AWS 側のロール粒度は Admin / Viewer の 2 区分から開始
- 調査範囲はこの repository が管理する AWS / Kubernetes 基盤に限定（GitHub organization や他 SaaS の SSO は対象外）

---

## Architecture

### AWS 側

```
panicboat@panicboat.net (Google Workspace)
        │ SAML federation（SCIM でグループ同期）
        ▼
AWS IAM Identity Center (account instance)
        │
  ┌─────┴─────┐
  │           │
Permission Set    Permission Set
"Admin"           "Viewer"
(AdministratorAccess)   (ReadOnlyAccess)
  │           │
  ▼           ▼
AWSReservedSSO_Admin_*    AWSReservedSSO_Viewer_*   ← Identity Center が Account Assignment 実行後に発行する IAM role
  │           │
  ▼           ▼
EKS Access Entry          EKS Access Entry
AmazonEKSClusterAdminPolicy   AmazonEKSViewPolicy
```

- Google Group `aws-admins@panicboat.net` / `aws-viewers@panicboat.net` を作成し、SCIM で Identity Center に同期。`panicboat@panicboat.net` は `aws-admins` に所属
- **Console**: Identity Center の Access Portal 経由でログイン → 所属 Group に紐づく Permission Set を選択 → temporary credentials で AWS Console へ
- **CLI/kubectl**: `aws sso login` → 同じ Permission Set の temporary credentials を取得 → `aws eks update-kubeconfig` → kubectl は Access Entry の policy 通りに動作
- 既存の root-trust `eks-admin` role と対応する access entry は削除し、Identity Center 経由に完全移行。AWS account root user によるログイン（repo 管理外）は最終手段として引き続き存在する

### Grafana 側（他 3 UI は現状維持）

- oauth2-proxy + Grafana `auth.proxy` mode の構成自体は変更しない（true SSO・二重ログインなしを継続）
- oauth2-proxy の許可判定を「個別 email の ConfigMap allowlist」から oauth2-proxy 組込みの `email_domains: panicboat.net` に変更
- Grafana 用 Google OAuth Client を `External + Testing` → `Internal` に変更（Workspace ドメインが確立するため未検証アプリ警告も解消）
- Grafana `grafana.ini.users.auto_assign_org_role` を `Admin` → `Viewer` に変更（最小権限デフォルト）。Admin にする対象者は初回ログイン後に Grafana UI 上で手動昇格
- Hubble UI / Alertmanager / Prometheus はロール概念を持たないため変更なし

---

## Components & File Structure

### 新規: `aws/iam-identity-center/`（AWS）

既存の account-wide singleton stack（`aws/iam-service-linked-roles`）と同じ構成パターンを踏襲する。

```
aws/iam-identity-center/
├── root.hcl
├── modules/
│   ├── terraform.tf
│   ├── variables.tf
│   ├── main.tf              # aws_ssoadmin_permission_set × 2 (Admin/Viewer)
│   │                         # + aws_ssoadmin_managed_policy_attachment (AdministratorAccess/ReadOnlyAccess)
│   │                         # + aws_ssoadmin_account_assignment × 2 (Google Group → Permission Set)
│   └── outputs.tf            # Reserved SSO Role ARN (Admin/Viewer)、permission_set_arn 等
└── envs/production/
    ├── env.hcl
    └── terragrunt.hcl
```

- Identity Center instance 自体の有効化と、Google 側 SAML app / SCIM 設定は Terraform 管理対象外（Manual Setup で後述）
- `data "aws_ssoadmin_instances"` で既存 instance を参照する

### 修正: `aws/eks/modules/`（AWS）

- **`access_entries.tf`**: `human_admin` の 1 entry を、Identity Center Reserved Role ARN を参照する `identity_center_admin`（`AmazonEKSClusterAdminPolicy`）/ `identity_center_viewer`（`AmazonEKSViewPolicy`）の 2 entries に置き換え
- **`iam_admin.tf`**: 削除（root-trust `eks-admin` role が不要になるため）
- Reserved Role ARN の解決方法: Permission Set 作成時点では Reserved Role は未発行で、Account Assignment 実行後に初めて発行される。`aws/iam-identity-center` stack 側で `data "aws_iam_roles"`（`name_regex = "AWSReservedSSO_<permission-set-name>_.*"`）により解決し、output として `aws/eks` 側に terragrunt `dependency` block 経由で渡す（既存 `aws/eks/lookup` のクロススタック参照パターンを踏襲）。このため初回投入時は `aws/iam-identity-center` → `aws/eks` の 2 phase apply が必要（Risks 参照）

### 修正: `aws/eks/README.md`

- 「kubectl access」節を Identity Center ベースの手順（`aws sso login` + `update-kubeconfig`）に置き換え
- Troubleshooting 表の `assume-role` 関連の記述を更新

### 修正: `kubernetes/components/oauth2-proxy/production/`

- **`values.yaml.gotmpl`**: `email_domains: - panicboat.net` を追加
- **`kustomization/allowed-emails-configmap.yaml`**: 削除（`email_domains` 設定に置き換えるため不要）
- **`kustomization/kustomization.yaml`**: 上記 ConfigMap の参照を削除

### 修正: `kubernetes/components/prometheus-operator/production/`

- **`values.yaml.gotmpl`**: `grafana.ini` の `users.auto_assign_org_role` を `Admin` → `Viewer` に変更

### 自動生成（production hydrate output）

- `kubernetes/manifests/production/oauth2-proxy/manifest.yaml`
- `kubernetes/manifests/production/prometheus-operator/manifest.yaml`

### 変更しないもの

- `aws/github-oidc-auth/*`（CI 用 machine identity、human SSO とは無関係）
- Hubble UI / Alertmanager / Prometheus の component 定義
- Grafana の `auth.proxy` 自体の仕組み（header 由来の username 認証は継続）

---

## Manual Setup（AWS Console + Google Admin Console）

初回のプロバイダ間ハンドシェイクは GitOps / Terraform で完結しないため手動（既存 Grafana design の Manual Setup と同じ方針）。

1. **AWS IAM Identity Center を account instance として有効化**（AWS Console、AWS Organizations 不要）
2. **Google Admin Console**: 「SAML apps」で AWS IAM Identity Center 用アプリを追加し、Identity Center が提供する SP metadata（ACS URL / Entity ID）を設定、Google 側の IdP metadata を Identity Center にアップロード（相互設定）
3. **SCIM provisioning 設定**: Identity Center が発行する SCIM endpoint URL + bearer token を Google 側の該当 SAML app 設定に投入し、自動プロビジョニングを有効化
4. **Google Workspace 側でグループ作成**: `aws-admins@panicboat.net` / `aws-viewers@panicboat.net` を作成し、`panicboat@panicboat.net` を `aws-admins` に追加
5. **Grafana 用 Google OAuth Client** を Google Cloud Console で `Internal` に変更（承認済みドメイン等は既存のまま）
6. **初回 Grafana ログイン後の手動昇格**: `panicboat@panicboat.net` で Grafana にログイン（初回は Viewer で auto-create）→ 既存 admin/password（ESO 経由の fallback login）でログインし、GUI から `panicboat@panicboat.net` を Admin に昇格

**参照 docs**:
- AWS: [IAM Identity Center - Google Workspace as identity source](https://docs.aws.amazon.com/singlesignon/latest/userguide/gs-gwp.html)
- Google: [SAML apps でカスタムアプリを追加](https://support.google.com/a/answer/6087519)

**実装時 friction の許容**: AWS Console / Google Admin Console の UI 変更により実 navigation は本 spec と異なる場合あり、要件を満たす設定に到達すれば手順は不問（既存 Grafana design と同じ方針）。

---

## Testing / Post-flight Check

1. Identity Center Access Portal から `panicboat@panicboat.net` でログイン → Admin Permission Set が選択可能
2. `aws sso login` → `aws eks update-kubeconfig` → `kubectl get nodes` が通る（ClusterAdmin 権限）
3. （可能であれば）Viewer 想定のテストユーザーで同様に確認 → 書き込み系 kubectl コマンドが `Forbidden` で reject される
4. `https://grafana.panicboat.net` に `@panicboat.net` アカウントでログイン → 初回は Viewer role で auto-create されることを確認
5. 上記アカウントを Grafana UI で Admin に昇格 → 再ログインで Admin 権限が反映されることを確認
6. `panicboat@gmail.com` でのログイン試行 → Internal OAuth Client のため Google 側で拒否されることを確認（意図した挙動）
7. 同一 browser session で Hubble UI / Alertmanager / Prometheus に再ログインなしでアクセスできる（既存 SSO 継続の確認）

---

## Rollback Patterns

| Pattern | 適用条件 | 操作 |
|---|---|---|
| **A. Standard rollback** | 本 design 全体を巻き戻したい | Flux suspend（Grafana 側変更分）→ merge commit を revert PR → resume。AWS 側は `aws/iam-identity-center` と `aws/eks` の変更を revert PR で戻す |
| **B. Grafana のみ rollback** | AWS 側は問題ないが Grafana の domain allowlist / role default に問題がある | `email_domains` / `auto_assign_org_role` の変更のみ revert |
| **C. AWS 側 緊急アクセス** | Identity Center 障害で Console/CLI アクセス不能 | AWS account root user でログインし、Identity Center 設定を修正するか、緊急用の IAM role を一時的に作成 |

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| root-trust `eks-admin` role 削除により Identity Center 障害時の break-glass 手段がなくなる | AWS account root user ログイン（repo 管理外）が最終手段として残る。長期障害時は root user で緊急 IAM role を作成 |
| Reserved SSO Role ARN が Account Assignment 実行後にしか解決できない | `aws/iam-identity-center` → `aws/eks` の 2 phase apply が必要。Plan 側で明示的な実行順序として記載する |
| Google Workspace 側 SAML/SCIM 設定は console 手動のため誤設定リスク | Manual Setup 手順を明文化し、Testing で早期に end-to-end 検証する |
| `panicboat@gmail.com` が Internal 化した瞬間にログイン不能になる | 事前に `panicboat@panicboat.net` を `aws-admins` Google Group に追加し、Grafana Admin 昇格を完了させてから Gmail アカウントの利用を止める（切替順序を Plan に明記） |

---

## Out of Scope

| 項目 | 理由 |
|---|---|
| Google Group → oauth2-proxy → header 経由の Grafana role 完全自動化 | oauth2-proxy に group→role 変換機能がなく、実現には自作コンポーネントが必要。Grafana 自身の RBAC（Approach B）で代替 |
| Grafana 自身の Google OAuth (`auth.google`/generic_oauth) への切替 | Grafana だけ二重ログインが復活し、既存 Grafana design の Decision #3 が避けた問題が再発する |
| GitHub organization の SSO | 調査範囲をこの repository が管理する AWS / Kubernetes 基盤に限定したため対象外 |
| AWS Identity Center Permission Set の 3 区分以上への細分化（Developer 等） | 現時点では Admin / Viewer の 2 区分で十分（YAGNI）。将来必要になった時点で Permission Set を追加 |
| Google Workspace 側の Group 自体の Terraform 管理 | この repo に Google Cloud/Workspace provider が存在せず、Google 側リソースは対象外。Manual Setup で手動運用 |

---

## References

- Grafana SSO 既存 design: `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`
- 既存 kubectl access 実装: `aws/eks/modules/access_entries.tf`, `aws/eks/modules/iam_admin.tf`
- account-wide singleton stack の既存パターン: `aws/iam-service-linked-roles/`
- クロススタック参照の既存パターン: `aws/eks/lookup/`, `docs/superpowers/plans/2026-04-29-aws-vpc-cross-stack-lookup.md`
- AWS IAM Identity Center + Google Workspace: <https://docs.aws.amazon.com/singlesignon/latest/userguide/gs-gwp.html>
- oauth2-proxy `email_domains` config: <https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview>
