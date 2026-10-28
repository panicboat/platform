# GCP project layout design

## Context

panicboat/monorepo#1774 を扱う。
`gcp/` のパスから、stack がどの GCP project のものかが分からない。

2026-10-28 時点の状態（VERIFIED: `gcloud projects list`・`gcloud services list`・`gcloud projects get-iam-policy`・S3 の state）:

- `gcp/billing`・`gcp/workload-identity` が使っていた project `panicboat-platform-github` は、ユーザーが削除済み。
  - CI が GCP に入るための Workload Identity もその project にあったため、今は CI から GCP に入れない。
  - `gcp/billing` の state には、請求先アカウントの予算が 1 つ残っている。
- 残っている project は `panicboat-platform-auth`（表示名 `google-oauth-production`）だけである。
  - EKS の oauth2-proxy が使う Google OAuth client を置いている（手作業で作成）。
  - 有効な API は、作成時に既定で有効になる 22 個（BigQuery、Cloud Storage、Logging など）。
  - IAM は owner の `iam@panicboat.net` だけ。
- OAuth client と同意画面は Terraform で管理できない。
  - 対応する resource が使う IAP OAuth Admin API は 2026-03-19 に停止した（[Deprecations](https://docs.cloud.google.com/iap/docs/deprecations)）。
- state key は panicboat/platform#1200 で `platform/<unit のパス>/terraform.tfstate` になった。

### Decisions taken before this spec

ユーザーの判断:

- GCP の stack は `gcp/<project の表示名>/<stack>/<environment>` に置く。
  - 表示名は `<service>-<env>` で付ける（Google の enterprise foundations blueprint の `prj-{env}-{workload}` と同じ考え方）。
- CI の Workload Identity は、CI 専用の project に置く。
  - ID・表示名・ディレクトリ名をすべて `github-actions-master` にする。
- project の作成も Terraform で管理する。
  - CI 専用の project は CI 自身では作れないため、最初の 1 回だけ手元から apply する。
  - 以後、新しい project は PR で作る。
- `panicboat-platform-auth` は後で名前を付け直して作り直す予定で、表示名は変えない。
  - 有効な API と IAM を管理し、既定で有効になった API は無効にする。
- 予算アラートはやめる。

## Goals

- `gcp/` 以下のパスの 2 段目を見れば、stack が属する GCP project が分かる。
- CI（PR で plan、merge で apply）が GCP に入れる。
- 新しい project を、`gcp/<表示名>/` に stack を足す PR で作れる。
- 削除済みの project を指す stack と state、残った予算がなくなっている。

## Non-goals

- OAuth client と同意画面の管理（Terraform で扱えない）。
- `panicboat-platform-auth` の作り直し。
- GCP のフォルダや組織ポリシー。
- 予算アラート。

## Anti-goals

- PR から使える plan の credential で、GCP の resource や IAM を変更できること。
- oauth2-proxy のログインが止まること。
- 漏れると GCP を操作できる鍵が、リポジトリや GitHub に置かれること。

## Design

### Layout

```
gcp/
├── credential-configuration.json
├── github-actions-master/
│   ├── project.hcl
│   └── workload-identity/
│       ├── root.hcl
│       ├── master/terragrunt.hcl
│       └── modules/
└── google-oauth-production/
    ├── project.hcl
    └── project/
        ├── root.hcl
        ├── master/terragrunt.hcl
        └── modules/
```

- `<表示名>/project.hcl` に project ID を書く。
  - project ID は変えられず、表示名と一致しないことがある（`google-oauth-production` の ID は `panicboat-platform-auth`）。
- 末尾の `master` は state を置く AWS アカウントと CI のロールで、GCP の stack はすべて `master`。
- `workflow-config.yaml` の terragrunt stack の paths は `gcp/{project}/{service}/{environment}` にする。
  - label-resolver（deploy-actions v2.0.1）は `{service}`・`{environment}` 以外の placeholder も扱う（VERIFIED: `label-resolver/use_cases/generated_matrix.rb`）。
  - `<stack>` は `aws/` のサービス名と重ねない（`deploy:<service>` の label と tfcmt の target が provider を含まないため）。
- 表示名を変えたら、ディレクトリ名と state key も変える（state の移し方は #1200 と同じ）。

### github-actions-master/workload-identity

CI が GCP に入るための入口と、その入口を置く project そのものを 1 つの stack で持つ。

- project（`google_project`）: ID・表示名 `github-actions-master`、組織 `731586494509`、請求先アカウント `01830F-ABC0AE-C3E6D2`。
  - 既定の network は作らない。
    - provider は既定の network を消すために Compute API を有効にするので、作成後に Compute API・OS Login API と Compute の既定の service account を手元から消す。
  - 誤って消さないよう、削除を防ぐ設定にする。
- 有効な API: Workload Identity と IAM の管理に要るもの（IAM、STS、IAM Credentials、Cloud Resource Manager、Service Usage、Cloud Billing）。
- Workload Identity の pool と AWS provider: 今の `gcp/workload-identity` の module と同じ（master のアカウントだけ、assumed role だけを受け付ける）。
- この project での CI の権限: plan ロールは閲覧だけ、apply ロールは owner 相当（今の module と同じ）。
- project と pool を同じ stack に置く。
  - pool の principal の文字列に project 番号が入り、別の stack にすると project と pool が互いに依存するため。

### CI permissions outside projects

組織と請求先アカウントの権限は、Terraform で管理せず、手元から 1 回だけ付ける（Claude の判断）。

| 対象 | plan ロール | apply ロール |
|---|---|---|
| 組織 | project の閲覧（`roles/browser`） | project の作成（`roles/resourcemanager.projectCreator`） |
| 請求先アカウント | 閲覧（`roles/billing.viewer`） | 利用（`roles/billing.user`） |

- Terraform で管理すると、apply ロールに組織と請求先アカウントの IAM を変える権限（組織の管理者相当）が要るため。
- 付け方は README に 1 行で書き、手順の詳細は書かない。

### google-oauth-production/project

- 有効な API（`google_project_service`）: 管理に要る Cloud Resource Manager・Service Usage・IAM だけを残す。
  - 既定で有効になった残りは、手元から 1 回だけ無効にする（Terraform は管理していない API を無効にしないため）。
  - `iam` を有効にすると `iamcredentials` も有効になり、無効にすると `iam` も止まるため、`iamcredentials` は管理外で有効のまま残す。
  - 無効にした後、oauth2-proxy でログインできることを確かめる。
- IAM（`google_project_iam_member`）: owner の `iam@panicboat.net`、CI の plan ロールに閲覧、apply ロールに owner 相当。
  - CI の principal は `github-actions-master/workload-identity` の output から受け取る（terragrunt の dependency）。
- project 自体（`google_project`）は管理しない。
  - 作り直す予定で、表示名も変えないため。

### Credential in CI

- `gcp/credential-configuration.json` を、新しい pool の audience で作り直す。
- 手元では今と同じく gcloud の application default credentials を使う。

### Removed

- `gcp/billing/`・`gcp/workload-identity/`・`gcp/project.hcl` を消す。
- S3 に残っている 2 つの state（`platform/gcp/billing/master`・`platform/gcp/workload-identity/master`）を消す。
  - resource は project ごと消えているため、state を移さない。
- 請求先アカウントに残っている予算を、手元から消す。

## Bootstrap

CI が GCP に入るための権限は CI 自身では作れないので、次の順に手元から行う。

1. `gcloud auth application-default login`（ユーザー）
2. `gcp/github-actions-master/workload-identity/master` を手元から apply する（project、API、pool、provider、project の IAM ができる）。
3. 組織と請求先アカウントで、CI のロールに権限を付ける（上の表）。
4. credential の設定ファイルを作り直す。
5. `gcp/google-oauth-production/project/master` を手元から import して apply する。
6. 既定で有効になった API を無効にし、oauth2-proxy でログインできることを確かめる（本番の EKS が止まっている間は確かめられない）。
7. 予算を消し、古い 2 つの state を消す。
8. PR を出し、CI の plan で 2 つの stack に差分がないことを確かめてから merge する。

## Constraints

- module には、既存の stack と同じく `modules/tests/` に OpenTofu のテストを置く。

## Left to the builder

- `workload-identity` の module の構成（今の `workload-identity` の module を移して project を足すか、作り直すか）。
- `google_project` の削除を防ぐ設定と、既定の network を作らない設定の書き方（provider のバージョンで確かめる）。
