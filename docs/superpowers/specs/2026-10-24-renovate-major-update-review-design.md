# Renovate Major Update AI Review Design

## Context

### 現状

Renovate のメジャー更新 PR（`📈 major-update` ラベル）は automerge 対象外で、人がリリースノートを読み、現在の定義と突き合わせて安全性を判断してからマージしている。
この調査が重く、2026-09-29 に作られた #1018（kube-prometheus-stack `88.6.5` → `91.8.1`）・#1019（tempo `2.4.0` → `3.0.0`）が約1ヶ月滞留している。

過去のメジャー更新 PR の内訳は Helm chart（kube-prometheus-stack・loki・tempo）が大半で、残りは GitHub Actions（`actions/checkout` 等）。
Terraform provider のメジャー更新は実績がない。

### なぜ PR 本文と既存ツールだけでは足りないか

- Renovate が PR 本文に載せるリリースノートは信用できない
  - #1019 は `grafana-community/tempo` chart の更新なのに、本文には別 chart `tempo-distributed-3.0.0` のノートが載っている
  - #1018 はメジャーを3つ跨ぐが、本文は直近のリリースしか載っておらず v89・v90 の破壊的変更が欠落している
- CodeRabbit は org に導入済みだが Bot 作成 PR を `Review skipped: Bot user detected` でスキップする
- hydrator が投稿する Kustomize Diff コメントは「何が変わったか」を示すが「現在の定義が新バージョンで壊れないか」は示さない
- chart のメジャー更新は values だけでなく、同 component の `kustomization/` 配下にある CR（ExternalSecret・Karpenter NodePool・cert-manager Issuer 等）の apiVersion / フィールドを壊しうる

## Goals

- `📈 major-update` ラベルの Renovate PR に対し、AI が安全に更新できるかを判定したレビューコメントを自動投稿する
- 判定根拠を upstream の一次情報（正しいパッケージの、現バージョンから新バージョンまでの全リリースノート / upgrade guide）から取る
- 指摘を自リポジトリの定義（`helmfile.yaml`・`values.yaml.gotmpl`・`kustomization/` 配下・workflow ファイル）の該当箇所に紐付ける

## Non-Goals

- minor / patch / digest 更新のレビュー（production 向け minor も対象外）
- 修正コミットの push・approve・マージ（レビューコメントの投稿だけを行う）
- Renovate 以外の PR のレビュー

## Anti-Goals

- 根拠 URL のない判定。PR 本文のリリースノートだけを根拠に ✅ を出すこと
- 現バージョンから新バージョンの間のメジャーを読み飛ばすこと
- 該当しない破壊的変更を「影響あり」に混ぜて、判断材料を埋もれさせること

## Architecture

```
Renovate PR (labels: 🤖 renovate, 📈 major-update, deploy:<svc>)
  │
  ├─ (既存・変更なし) auto-label--deploy-trigger.yaml → hydrate → Kustomize Diff コメント
  │
  └─ (新規・独立 workflow) `📈 major-update` ラベル付与で即発火し、hydrate と並行実行
        1. AWS OIDC → master account の Bedrock 専用 role を assume
        2. claude-code-action (Bedrock, sonnet-4-6) を起動
        3. Claude が upstream のリリースノート / upgrade guide を取得
        4. リポジトリの定義と突き合わせ
        5. レビューコメントを1件 upsert
```

### Decided

- **対象**: Renovate が作成し `📈 major-update` ラベルが付いた PR のみ
- **出力**: PR へのレビューコメント1件の upsert のみ。push・approve・マージ・ラベル変更はしない
- **AI 実行基盤**: GitHub Actions 上の `claude-code-action`
  - `aws/ai-assistant` と `claude-code-action` は #648 で削除済みだが、削除理由は「当時使い道がなかった」だけで、技術的な問題ではない
- **認証**: Amazon Bedrock + GitHub OIDC
  - IAM role は `aws/github-oidc-auth` の `master`（account `559744160976`）に追加する
- **model**: `sonnet-4-6`（Global cross-region inference profile）
  - この account では Sonnet 5 / Opus 5 の Bedrock quota が 0 で、self-service 増枠ができないため
- **起動タイミング**: `📈 major-update` ラベルが付与された `pull_request: labeled` イベントで即発火する独立 workflow とし、hydrate の完了は待たない
  - Renovate は PR 作成時にラベルを複数付け、ラベルごとに `labeled` が発火する。`github.event.label.name` で `📈 major-update` に絞れば1回だけ起動する
  - `auto-label--deploy-trigger.yaml` に job を足すと、同 workflow の `cancel-in-progress` で Claude が途中キャンセル・再起動され Bedrock 消費が無駄になるうえ、デプロイの中核 workflow に手が入る
- **レビュー材料**: 次の3つを使う。Kustomize Diff コメントは使わない
  - upstream の一次情報（PR 本文のノートは参考扱い）
  - 対象 component の `helmfile.yaml`・`values.yaml.gotmpl`（または `values.yaml`）・`kustomization/` 配下
  - GitHub Actions 更新の場合は、その action を使っている workflow ファイル
  - Kustomize Diff は hydrate と並行実行のため取得できない。加えて #1018 では 7,636 行・120 ファイルの大半が CRD 差分で、材料としてはノイズが多い

### Builder's Call (decided by Claude, not the user)

- **IAM role の形**: `aws/github-oidc-auth/modules` に Bedrock 呼び出し専用 role を追加し、変数で有効化して `master` だけで作る
  - 既存の plan role（`ReadOnlyAccess`）には `bedrock:InvokeModel` が含まれない。Terraform plan 用 role に Bedrock 権限を混ぜないため、別 role にする
  - 信頼条件は `repo:panicboat/platform:pull_request` に限定する
  - 権限は `bedrock:InvokeModel`・`bedrock:InvokeModelWithResponseStream` を、`sonnet-4-6` の inference profile とそのルーティング先 foundation model に限定する
  - Resource ARN の組み立ては `aws/eks-holmesgpt/modules/main.tf` の `bedrock_invoke_resources` を参考にする
- **再レビュー**: Renovate による PR 更新を起点にした自動再レビューは作らない
  - hydrate のコミット後は Renovate が自動 rebase を止める（"Edited/Blocked Notification"）ため、PR が自動で更新されることがほぼない
  - 再レビューは手動起動（`workflow_dispatch` で PR 番号を指定、など）で行えるようにする
- **テンプレート側の変化の補完**: StatefulSet の selector 変更・PVC 再作成など、values に現れないテンプレートの変化が疑われる場合、Claude が新旧 chart を `helm template` で描画して該当リソースだけを比較する
  - Kustomize Diff を使わない代わりの手段。常時実行するか、疑わしい場合だけ実行するかは実装時に決める
- **書き込み権限の分離**: Claude を動かす step には GitHub への書き込み権限を持つ token を渡さない
  - upstream のリリースノートは外部入力で prompt injection の経路になるため
  - Claude はコメント本文をファイルに出力するだけにする。投稿は後続の別 step が `pull-requests: write` だけを持つ token で行う
  - Claude に許可するツールは、リポジトリの読み取り、Web 取得、`gh` の読み取り系、`helm show` 等の読み取り系コマンドに限定する
- **対象パッケージの種別**: `📈 major-update` の PR はすべてレビューする
  - Helm chart・GitHub Actions 以外（container image・Terraform provider 等）も、Renovate が変更したファイルと、その依存を参照している定義を材料にして、同じ形式でレビューする
- **根拠が一部しか取れなかった場合**: 判定は ✅ にせず ⚠️ にし、取得できなかったバージョン範囲・情報源を「影響のある変更」の先頭に明記する
- **失敗時**: Bedrock の障害・quota 超過・タイムアウトでは job を失敗させるだけで、PR にコメントは残さない
  - このレビューは必須チェック（merge gate）にしない
- **追加の判断材料**: Helm chart の場合、`helm show values` で新旧の default values を取り、その差分も材料にする
  - リリースノートに書かれない default 値の変更を拾うため

## Review Comment Format

1. **判定**: 冒頭に次のいずれか1つを表示する
   - ✅ そのままマージ可
   - ⚠️ 修正が必要
   - 🛑 手動作業が必要（CRD 適用・データ移行など）
2. **対象範囲**: 調べたバージョン範囲と、参照した一次情報の URL
   - PR 本文のリリースノートが別パッケージのものだった場合や、途中のバージョンが欠けていた場合は、その旨を明記する
3. **影響のある変更**: 自リポジトリの定義に該当する破壊的変更・deprecated・default 値変更だけを列挙する
   - 各項目にファイル:行番号と、具体的な修正案（コードブロック）を付ける
4. **影響のない変更**: 該当しなかった主要な破壊的変更を `<details>` で折りたたんで列挙する（調べ漏れでないことを示すため）
5. **描画結果の注目点**: `helm template` の新旧比較で見つかった、挙動が変わりうる箇所（StatefulSet の selector 変更、PVC 再作成など）。比較を実行しなかった場合は省略する

## Constraints

- `auto-label--deploy-trigger.yaml` と hydrator は変更しない
- hydrate は並行して PR ブランチにコミットする。レビューは起動時点の PR head を checkout し、hydrate 後の `kubernetes/manifests/` には依存しない
- Renovate の PR は同一リポジトリの `renovate/` ブランチから作られるため、OIDC の `sub` は `repo:panicboat/platform:pull_request` になる
- `claude-code-action` は Bot が起こしたイベントで動かない既定があるため、Renovate 起点で起動できる設定にする（実バージョンの入力名を確認する）
- Claude が upstream 情報を取得できるよう、Web 取得や `gh` の利用をツール許可に含める
- 既存 workflow と同様に、third-party action は commit SHA で pin する（`helpers:pinGitHubActionDigests`）
- hydrator は GitHub App token で PR ブランチに push する。既存の App token は `contents: write` を持つため、Claude を動かす step に渡してはいけない

## Left to the Builder

- prompt の置き場所と構成（workflow 内のインライン、または repo 内ファイル）
- コメント upsert の実現方法（既存の `thollander/actions-comment-pull-request` の `comment-tag` 方式など）
- `claude-code-action` の version・入力名・Bedrock 用 model ID の具体値（実物を確認して決める）

## Verification

- `aws/github-oidc-auth/master` の terragrunt plan で、Bedrock role の追加だけが差分として出ること
- 滞留中の #1018・#1019 に対してレビューを実行し、実際にコメントを投稿して次の3点を確認する（投稿前にユーザーに確認を取る）
  - #1019: `tempo-distributed` ではなく `grafana-community/tempo` chart の 2.4.0 → 3.0.0 を対象にしていること
  - #1018: v89・v90・v91 の全メジャーの変更を対象範囲に含めていること
  - 各指摘にファイル:行番号と一次情報の URL が付いていること
- PR に push・approve・ラベル変更が一切行われていないこと

## Risks / Open Questions

- `sonnet-4-6` の調査精度が、メジャーを複数跨ぐ大きな chart（kube-prometheus-stack）で十分かは実測するまで分からない
- upstream の upgrade guide がリポジトリ内のドキュメントにしかない chart では、取得先の特定に失敗しうる。取得できなかった範囲はコメントに明記させる
