# GCP Foundation Design

> **Goal**: platform から GCP の resource を terragrunt で管理できるようにする。PR で plan、main merge で apply という今の AWS・GitHub の stack と同じ流れで、GCP の stack を扱えるようにする。

---

## Context

### Why

- `panicboat/.github` の docs-sync-check と renovate-major-review は、Claude（Sonnet 4.6）を Bedrock 経由で呼んでいる
- 2026-10-24〜25 の 2 日で約 14 USD かかった。ユーザーは月数ドルに下げたい
  - Claude が実際に動いたのは 7 回（docs-sync-check の判定 3 回、renovate-major-review のレビュー 4 回）で、回数ではなく 1 回あたりが高い（VERIFIED：`gh run list` と各 run の job 一覧）
  - docs-sync-check は 1 回 0.49〜0.84 USD（VERIFIED：実行ログ artifact の `total_cost_usd`）。renovate-major-review はログがなく、合計からの逆算で 1 回 3 USD 前後（REASONED）
- Bedrock で新しいモデルの利用を申請したが却下された。新しいモデルほど安いので、古いモデルに留まることがそのまま費用になっている
- そこで Gemini を Vertex AI 経由で使うことにした（ユーザー決定）。その前提として、GCP を platform から provisioning できる状態が要る

### Overall plan

全体は 3 つに分かれ、この spec は 1 だけを扱う。

1. GCP の土台（この spec）
2. Gemini 用の Workload Identity Federation と service account を `gcp/workload-identity` に足す（`aws/github-oidc-auth/modules/bedrock.tf` にあたる）
3. `panicboat/.github` の共通 workflow を Vertex AI + Gemini（`google-github-actions/run-gemini-cli`）に切り替える

### Current state

- GCP のアカウント、請求先アカウント（billing account）、プロジェクトはまだ何もない（ユーザー申告）
- `workflow-config.yaml` の terragrunt stack は `aws/{service}/{environment}` と `github/{service}/{environment}` を対象にしている（VERIFIED）
- `github/` の stack は AWS 以外の provider を扱うが、state は AWS の S3 bucket（`terragrunt-state-${get_aws_account_id()}`）と DynamoDB（`terragrunt-state-locks`）に置いている（VERIFIED：`github/repository/root.hcl`）
- CI の terragrunt は `panicboat/.github` の `reusable--terragrunt-runner.yaml` が動かす。用意する credential は AWS の role（`configure-aws-credentials`）と GitHub App token だけ（VERIFIED）
- master 環境の plan role と apply role は `aws/github-oidc-auth` が作っている（`github-oidc-auth-master-github-actions-{plan,apply}-role`、アカウント `559744160976`）（VERIFIED：`workflow-config.yaml`）
- IaC は OpenTofu（aqua の `opentofu/opentofu`）と terragrunt で動かしている（VERIFIED：`aqua.yaml`）

---

## Goals

- `gcp/{service}/{environment}` の stack が、PR で plan、main merge で apply される
- CI から GCP への認証に、長期の鍵（service account key）も GitHub secret も使わない
- plan の credential では GCP の resource を変更できない
- 請求額が予算を超えそうになったら、ユーザーに通知が届く

## Non-goals

- Gemini 用の認証と、workflow の切り替え（Overall plan の 2 と 3）
- GCP の Organization・フォルダの作成。個人アカウントのまま使う
- develop・production などの環境の分割。GCP は `master` だけにする
- 既存の stack の state key の変更（panicboat/monorepo#1768 で扱う）
- `reusable--terragrunt-runner.yaml` の変更

## Anti-goals

- 漏れると GCP を操作できる鍵が、リポジトリや GitHub に置かれること
- plan の credential（PR から使える）で、GCP の resource や IAM を変更できること
- 予算アラートが届かないまま請求が積み上がること

---

## Decisions

ユーザーと合意した事項。

- **GCP の resource は platform の terragrunt で管理する**
- **stack は 2 つ**
  - `gcp/workload-identity/master`: CI の terragrunt が GCP に入るための Workload Identity Federation と権限。Overall plan の 2 で Gemini 用の resource（`vertex.tf`）もここに足す
  - `gcp/billing/master`: 請求先アカウントの予算アラート。プロジェクトの外の resource なので分ける
- **GCP のサービス名は、`aws/` のサービス名と重ねない**
  - label は `deploy:<service>` で provider を含まないため、同じ名前だと label-resolver が両方の stack を対象にする（REASONED：deploy-actions v2.0.1 `label-resolver/use_cases/generated_matrix.rb`）
  - tfcmt の target も `<service>/<environment>` で同じになり、`TFCMT_PLAN_PATCH` で両方の plan コメントが互いに上書きされる
  - そのため `gcp/github-oidc-auth` ではなく `gcp/workload-identity` にする
- **state は今の S3 bucket に置き、key は `platform/gcp/<service>/<environment>/terraform.tfstate` にする**
  - provider のディレクトリを key に含め、provider をまたいで同じサービス名があっても key がぶつからないようにする
  - 既存の stack も同じ規則に揃える（panicboat/monorepo#1768）
- **CI から GCP への認証は、AWS の role を GCP の Workload Identity Federation に信頼させる**
  - runner はすでに master の plan role か apply role を assume しているので、その credential を GCP の credential に交換する
  - runner と `workflow-config.yaml` の形を変えずに済む
  - GitHub OIDC を GCP に直接信頼させる案は、runner に GCP の認証 step を足し、`workflow-config.yaml` に GCP の属性を持たせる必要があるため採らない
- **plan role は閲覧だけ、apply role は変更できる権限にする**: AWS の plan / apply の分け方と揃える
- **GCP のプロジェクトは 1 つ。プロジェクトと請求先アカウントは手作業で作る**
  - Organization のない個人アカウントでは、Terraform でプロジェクトを作るのに個人の credential が要るため
  - 作業時に Claude が手順を案内する
- **予算アラートを付ける**: 費用を下げるための取り組みなので、超過に気付けるようにする

---

## Design

### Workload Identity Federation（`gcp/workload-identity`）

- Workload Identity Pool に AWS provider を 1 つ作り、アカウント `559744160976` だけを受け付ける
- attribute condition で、assumed role からの credential だけを受け付ける
  - 公式ドキュメントの例: `assertion.arn.startsWith('arn:aws:sts::<account id>:assumed-role/')`
- `attribute.aws_role=assertion.arn.extract('assumed-role/{role_name}/')` で role 名を取り出し、`principalSet://.../attribute.aws_role/<role 名>` に IAM の権限を付ける
  - plan role: プロジェクトの閲覧（IAM policy の読み取りを含む）
  - apply role: プロジェクトの owner 相当（IAM policy の変更を含む）
- **Claude の判断**: apply role に IAM の変更まで許す
  - AWS 側の apply role も `AdministratorAccess` で、自分の権限を広げられる点は同じ（VERIFIED：`aws/github-oidc-auth/modules/main.tf`）
  - apply は main merge でしか動かないので、PR から使える plan role だけを閲覧に絞れば Anti-goals を満たす
- **Claude の判断**: service account を経由せず、federated principal に直接 IAM の権限を付ける
  - credential の設定ファイルが 1 つで済み、plan か apply かで切り替えなくてよい
  - 直接の付与に対応しない API に当たったら、plan 用・apply 用の service account を作り、impersonation する方式に切り替える
- この stack が必要とする API（IAM、STS、IAM Credentials、Cloud Resource Manager、Service Usage、Cloud Billing Budget）の有効化もこの stack に含める
  - **Claude の判断**: Budget API の quota project も、このプロジェクトにする

### Credential in CI

- GCP の Workload Identity Federation は、AWS の metadata server が使えない環境では、環境変数の AWS credential（`AWS_ACCESS_KEY_ID`・`AWS_SECRET_ACCESS_KEY`・`AWS_SESSION_TOKEN`・`AWS_REGION`）を使う（REASONED：[Workload Identity Federation with other clouds](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)）
  - Terraform の google provider は 3.61.0 以降で対応している（同ドキュメント）
  - GitHub の runner には AWS の metadata server がなく、`configure-aws-credentials` がこれらの環境変数を設定する
- credential の設定ファイルは `gcloud iam workload-identity-pools create-cred-config ... --aws` で作る。鍵を含まないので、リポジトリに置く
- **Claude の判断**: GCP の credential の設定ファイルを使うのは CI のときだけにし、手元では `gcloud auth application-default login` の credential を使う。切り替え方は builder に任せる

### Budget（`gcp/billing`）

- 請求先アカウントに予算を 1 つ作り、閾値を超えたら通知する
- **Claude の判断**: 予算額は月 5 USD、通知の閾値は 50%・90%・100% にする（ユーザーの目標が月数ドルのため）
- 通知先は請求先アカウントの管理者（既定のメール通知）にする
- 請求先アカウントはプロジェクトの外にあり、このリポジトリの Terraform では権限を付与できないため、手作業で 1 回付ける
  - plan role: 予算を読む権限（PR の plan で予算を refresh するため）
  - apply role: 予算を管理する権限
  - 請求先アカウントの IAM に federated principal を入れられなければ、service account を経由する方式に切り替える（Workload Identity Federation の節と同じ）

### Bootstrap

CI が GCP に入るための権限は CI 自身では作れないので、初回だけ手元から apply する。

1. GCP を使い始め、請求先アカウントを作る（手作業）
2. プロジェクトを作り、請求先アカウントにひも付ける（手作業）
   - プロジェクト ID は作成後に変えられない。ID と請求先アカウント ID は、この手順でユーザーが決めた値を `env.hcl` などの入力にする
3. `gcp/workload-identity/master` を手元から apply する
4. credential の設定ファイルを作り、リポジトリに置く
5. `workflow-config.yaml` の terragrunt stack の paths に `gcp/{service}/{environment}` を足す
6. CI の plan で `gcp/workload-identity/master` に差分が出ないことを確かめる
7. 請求先アカウントで、plan role の principal に予算を読む権限を、apply role の principal に予算を管理する権限を付ける（手作業）
8. `gcp/billing/master` を CI から apply する

---

## Constraints

- module には、既存の stack と同じく `modules/tests/` に OpenTofu のテストを置く（例：`aws/github-oidc-auth/modules/tests/bedrock_role.tftest.hcl`）
- 手作業の手順（1・2・7）は、ユーザーが作業するときに Claude が案内する。手順そのものは README に残す

## Open Questions For The Builder

- plan role と apply role に付ける GCP の role の具体的な名前（閲覧と owner 相当という範囲は Design で決めた）
- CI と手元で credential を切り替える仕組み（`root.hcl` の環境変数か、provider block の生成か）
- 請求先アカウントの予算を、federated principal から直接管理できるか
