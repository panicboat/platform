# Terragrunt Production Release Gate Design

> **Goal**: `aws/` 配下の terragrunt stack で、production 以外の環境は「PR で plan、main merge で apply」、production は「サービスごとの release PR の merge（release 公開）で apply」にする。module を修正したときに develop と production へ同時に apply される状態をなくし、develop で確認してから production に出せるようにする。

---

## Context

### Why

- テスト用に `develop` 環境を追加しようとした際に、今の CI では module を修正すると、その module を参照する全環境に同じ main merge で apply されることに気付いた
- develop で module の変更を確かめてから production に出す、という段階を踏めない。develop を作る意味がなくなる

### Current state

- `workflow-config.yaml` の terragrunt stack は `aws/{service}/{environment}` と `github/{service}/{environment}` を対象にし、宣言している環境は `master` だけ（VERIFIED）
- label-dispatcher（`panicboat/deploy-actions` v2.0.1）が付けるラベルは `deploy:<service>` で、環境の情報を持たない（REASONED：`label-dispatcher/use_cases/detect_changed_services.rb`）
- label-resolver は `environments` input が未指定なら、宣言済みの全環境に展開する。PR では全環境で plan、main への push で全環境 apply になる（REASONED：`.github/workflows/auto-label--deploy-trigger.yaml` と resolver の README）
- `modules/` 配下の変更は環境名 `modules` として扱われ、宣言済みの環境と一致しないため**ラベルが付かない**（VERIFIED：#1100 は `github/repository/modules/main.tf` だけの変更で、dispatcher のログは `SERVICES_DETECTED: []`。`deploy:repository` は手動で付けられていた）
  - 今は module を変えた PR にラベルを手動で付けて apply している
- `release.yml` はリポジトリ全体で 1 本の release-please（`release-type: simple`、non-manifest）を動かしている。release PR #890（`chore(main): release 1.0.0`）が open のまま残っている
- `monorepo` リポジトリでは、ディレクトリごとに `release-please-config.json` / `release-please-manifest.json` を置き、`release.yml` がそれを `git ls-files` で見つけて matrix で release-please を回している。release 公開を `auto-release--trigger.yaml` が受けて、tag 名 `<service>-vX.Y.Z` から対象ディレクトリを決めている

### Prior attempt (#886)

- 2026-09-06 に #886「release-please phase 2 — production deploy trigger」を merge し、約 3 時間後に #889 で revert した。spec は #886 の commit（`7870e23`）の `docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md` にある
- 内容は今回と近い。aws の production を持つ 12 サービスを release-please の component にし、release 公開で production に apply する。加えて kubernetes を 1 component にし、Flux の追従先を `main` から `kubernetes-production` tag に切り替えていた
- revert の理由は記録がなく、ユーザーも覚えていない。ログから分かっていることは次のとおり
  - merge 直後に作られた release PR は `kubernetes 0.2.0`（#887）だけで、aws の release → apply の経路は一度も動いていない
  - サービス一覧のハードコードをやめる修正（#888）を作ったが、merge せずに close した
- 今回の設計は、そこから次の点を変えている
  - kubernetes / Flux は対象外にする
  - サービス一覧をハードコードせず、ディレクトリの存在から求める
  - release-please の設定を monorepo と同じディレクトリごとの方式にする
  - `chore` を CHANGELOG に表示し、`chore` だけの変更でも release PR ができるようにする（#886 の spec は「`chore` も patch bump されるので release PR に積まれる」としていたが、release-please は CHANGELOG に載る commit がなければ release PR を作らない。VERIFIED：`googleapis/release-please` `src/strategies/base.ts` の `changelogEmpty` で `No user facing commits found ... - skipping`）

---

## Goals

- module・`root.hcl` など、サービスの全環境に効くファイルの変更を自動で検出し、ラベルを手動で付けなくても plan / apply が走る
- production 以外の環境は、PR で plan、main merge で apply する
- production は main merge では apply しない。サービスごとの release PR を merge（release 公開）したときに、そのサービスの production だけを apply する
- 元の変更 PR でも production の plan を出す（apply はしない）。develop に入れる前に、production で何が起きるかを確認できる
- release PR でも production の plan を出し、merge の直前に確認できる
- release 時の apply が失敗したら、tag を指定して手動で再実行できる

## Non-goals

- kubernetes（`kubernetes/components/` と Flux）。apply の経路が terragrunt と違うため対象外
- `github/` 配下。環境が `master` しかないため対象外
- `master` 環境の扱いの変更。今までどおり PR で plan、main merge で apply する
- サービスをまたぐ依存の検出。例えば `aws/eks/modules/lookups.tf` は `../../vpc/lookup` を参照しているが、`aws/vpc/lookup` を変えても検出されるのは `vpc` だけで、`eks` は検出しない
- `develop` 環境の stack ディレクトリ（`aws/<service>/develop/`）の作成。この設計は CI の仕組みだけを扱う
- production apply の順序（vpc → eks など）の自動制御。どの release PR から merge するかで人が決める。今の main merge でも順序は保証されていない

## Anti-goals

- main merge で production に apply が走ること。どんな経路でも起きてはいけない
- 変更していない production に apply が走ること（plan だけなら許容する）
- release PR を merge しても、どのサービスの production にも apply されないこと
- `chore`・`refactor`・Renovate の変更など、main に入った変更が production に出る手段を持たないこと

---

## Decisions

ユーザーと合意した事項。

- **production 以外は PR で plan、merge で apply**: 現行の仕組みを維持する
- **production は release PR の merge で apply**: release PR の単位は `aws/<service>` ごと
- **release PR の確認場所**: production の plan は release PR に出す
- **元の変更 PR でも production の plan を出す**: module の変更が production でだけ失敗するケースを develop に merge する前に見つけるため。release PR で初めて気付くと、問題のある変更がすでに main に入り、そのサービスの他の変更も production に出せなくなる
- **`chore` も release 対象にする**: `feat` / `fix` だけを対象にすると、Renovate の version bump（`chore(...)`）が production に出る手段を持たなくなる。人の PR も Renovate の PR もタイトルを変えずに使える代わりに、Renovate の version bump もすべて CHANGELOG とリリースに載る
- **`refactor` も release 対象にする**: このリポジトリでは module の変更に `refactor` も使う（例：#909）。`chore` と同じ理由で CHANGELOG に表示する
- **release 公開時の apply に承認（required reviewers）を付けない**: release PR の merge がすでに人の判断なので、承認を二重にしない
- **対象は `aws/` だけ**: `github/` は `master` しかなく、kubernetes は経路が違う

---

## Design

### Environments

| 環境 | PR | main merge | release 公開 |
|---|---|---|---|
| `master` | plan | apply | なし |
| `develop` | plan | apply | なし |
| `production` | plan | なし | apply |

- `workflow-config.yaml` の terragrunt stack に `develop` と `production` を宣言する
  - `production`：`337169763788`、role は `github-oidc-auth-production-github-actions-{plan,apply}-role`（#886 の spec と過去のコメントアウトから。実装時に実在を確認する）
  - `develop`：`270242382571`、role 名は同じ命名規則とし、実装時に実在を確認する。`aws/github-oidc-auth/develop/env.hcl` の `aws_region` は `us-east-1` なので、環境属性の `aws_region` をどうするかも実装時に確認する
- `production` しかないサービス（`aws/eks` など）も同じ扱いにする。どんな変更も release PR を通る

### Change detection

- サービスの全環境に効くファイル（`modules/`・`lookup/`・`root.hcl`・`Makefile` など、環境ディレクトリの外にあるもの）の変更で `deploy:<service>` が付くようにする
- 環境ディレクトリ内の変更（`aws/vpc/develop/...`）は、今までどおり `deploy:<service>` になる
- ラベルはサービス単位のままなので、どちらの変更でも、そのサービスの全環境が plan の対象になる。環境ディレクトリだけの変更で他環境に no-op の plan が出るのは許容する
- 実装方法は builder に任せる。`workflow-config.yaml` だけで実現する案と、`deploy-actions` を変更する案がある
  - config だけの案：例えば `aws/{service}` を `attributes: {}` を持つ別 stack として宣言すると、dispatcher はその配下の変更で `deploy:<service>` を付ける（REASONED：dispatcher は `attributes` を持つ stack を `environment: null` で評価する）。ただし resolver がその stack の target（`environment: null`、`working_directory: aws/<service>`）も出力するので、terragrunt の job から除外する必要がある
  - release-please が書き込む `aws/<service>/CHANGELOG.md` やマニフェストの変更でも、`aws/{service}` 配下として検出されてしまう。release PR では通常のラベル付与を走らせない、または除外する必要がある

### Pull request

- 元の変更 PR では、ラベルの付いたサービスについて `master`・`develop`・`production` のうちディレクトリが存在する全環境で plan を出す（現行の resolver の挙動のまま）
- production の plan には今までどおり `iam_role_plan` を使う

### Main merge

- main への push では、label-resolver に production を除いた環境を渡し、`master` と `develop` だけを apply する
- 除外する環境のリストを `workflow-config.yaml` から求めるか、workflow に書くかは builder に任せる。ただし production が混入しないことをテストで確かめる

### Release PR

- `aws/` 配下で `production/` ディレクトリを持つサービスごとに、`aws/<service>/release-please-config.json` と `aws/<service>/release-please-manifest.json` を置く（monorepo の `dystopia/monolith/` と同じ形）
  - 2026-10-24 時点の対象は `alb`・`eks`・`eks-holmesgpt`・`eks-karpenter`・`eks-logs`・`eks-metrics`・`eks-secrets`・`eks-traces`・`github-oidc-auth`・`iam-service-linked-roles`・`secrets-manager`・`vpc` の 12 サービス。実装時に `aws/*/production/` の存在で確認し直す
  - `separate-pull-requests: true`、`include-component-in-tag: true`、`component: <service>`。tag は `<service>-vX.Y.Z`
  - `changelog-sections` で `chore` と `refactor` を表示する。`feat` / `fix` / `perf` を上に、`refactor` と `chore` を下の別見出しに並べる
- `release.yml` を monorepo と同じ「設定ファイルを探して matrix で回す」形に置き換える。今のリポジトリ全体の release-please はやめる
- release PR が開かれた・更新されたときに、そのサービスの `aws/<service>/production` だけで plan を出す
- release PR の plan を merge の直前に出し直す手段を用意する（ラベル・コメントなど、方式は builder に任せる）。release PR を作った後に手動変更（drift）があると、plan に出ていない差分も apply されるため

### Release published

- apply job は GitHub environment `production` を宣言する。production の apply role の trust が `main` への push か `environment:production` しか許可していないため、tag ref で動く release 公開の job はこの宣言がないと role を assume できない（VERIFIED：`aws/github-oidc-auth/modules/main.tf` の `apply_conditions`）
  - environment `production` に required reviewers は付けない
  - platform には GitHub environment がまだない。job が宣言すると GitHub が自動で作るが、Terraform（`github/repository`）で管理するかは builder に任せる
- release 公開で、tag 名から `<service>` を取り出し、`aws/<service>/production` が存在すれば、その commit で production に apply する。`iam_role_apply` と `aws_region` は `workflow-config.yaml` の `production` から取る
- tag を指定して手動で再実行できる `workflow_dispatch` を用意する（monorepo の `auto-release--trigger.yaml` と同じ）
- tag の形式に合わない、またはディレクトリがない場合は失敗させる

### Renovate

- `renovate.json` は変更しない
- Renovate の PR は `chore(...)` のまま release PR に入る。`**/production/**` の PR は既に automerge が無効になっている

---

## Constraints

- `deploy-actions` は v2.0.1（SHA `1ab520e`）に固定されている。`deploy-actions` を変更する場合は別リポジトリでのリリースと、platform 側の SHA 更新が必要になる
- GitHub Actions はすべて SHA 固定（`lint-actions.yml` の `ensure-sha-pinned-actions` が検査する）
- release-please が release PR を作るのは GitHub App token なので、release PR でも `pull_request` workflow が起動する（monorepo と同じ）
- production の apply role の trust は `repo:panicboat/{monorepo,platform}:ref:refs/heads/main` と `environment:production` を許可し、plan role は `pull_request` と `main` を許可している。release PR の plan は `pull_request` なので今の plan role で通る
- tag `kubernetes-production` と `v0.1.0` が残っている。今回の tag（`<service>-vX.Y.Z`）とは衝突しない

---

## Left to the builder

- 全環境に効くファイルの変更を検出する方法（config だけか、`deploy-actions` の変更か）
- release PR で通常のラベル付与・plan を走らせない方法
- release PR の plan を出し直す手段の方式
- main merge で production を除外する環境リストの求め方
- 各サービスの初期バージョンと `bootstrap-sha`（最初の release PR に過去の全履歴が載らないようにする）
- open のまま残っている release PR #890 の close（実装時にユーザーに確認してから行う）

---

## Calls made without the user

ユーザーに確認せず私が決めたこと。

- CHANGELOG で `chore` を `feat` / `fix` の下の別見出しに分ける（「本当の変更を見逃しそう」という懸念への対策）
- release 時の apply が失敗したときに tag 指定で再実行できるようにする
- 環境ディレクトリだけの変更でも、そのサービスの全環境に plan を出す（no-op の plan は許容する）
- develop の `aws_region`、アカウント、plan/apply role の実在は、実装時に builder が AWS 側で確認する（`aws/github-oidc-auth/develop/env.hcl` は `us-east-1`）
- `github-oidc-auth` も release 対象に含める。この pipeline 自身が使う role を変えるリスクは今の main merge でも同じなので、扱いを変えない
- production の apply role の trust から `main` を外す強化は範囲に入れない。「main merge で production に apply しない」ことは workflow の分岐とテストで守る
- `docs` / `ci` など `feat` / `fix` / `perf` / `refactor` / `chore` 以外の type は、今までどおりリリースを作らず次のリリースに相乗りする

---

## Verification

- [ ] `aws/<service>/modules/` だけを変更した PR に、自動で `deploy:<service>` が付く
- [ ] その PR で `master`・`develop`・`production` のうち存在する全環境の plan が出る
- [ ] その PR を merge すると、`master` と `develop` だけが apply され、production の apply job が起動しない
- [ ] merge 後に `aws/<service>` の release PR が作られる、または更新される。`chore` だけ、`refactor` だけの変更でも作られる
- [ ] release PR に、そのサービスの production の plan だけが出る。他サービス・他環境の plan は出ない
- [ ] release PR を merge すると、承認待ちなしで、そのサービスの production だけが apply される
- [ ] tag を指定した手動実行で、同じ apply を再実行できる
- [ ] `master` だけのサービス（`route53`・`cost-management`）と `github/` は、今までどおり動く
