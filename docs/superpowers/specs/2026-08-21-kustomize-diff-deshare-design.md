# `kustomize-diff` De-sharing Design

`panicboat/panicboat-actions` の composite action `kustomize-diff/` を廃止し、参照している 2 リポジトリ（`platform`、`monorepo`）の呼び出し元ワークフローへ直接インライン化する。

## 1. Background

### 現状の構成

`kustomize-diff/action.yaml` は 5 ステップの composite action で、Kustomize overlay の head/base をビルドして差分を PR コメントに投稿する。

```
Checkout base ref → Build head manifests → Build base manifests → Diff manifests → Comment PR
```

参照しているのは `platform` と `monorepo` の `reusable--kubernetes-builder.yaml` のみで、両方とも同一 SHA（`fd41cb7fb30ee0b650acedb9f504cbff719844a6`）を pin している。呼び出し方（渡す 5 inputs）は同一だが、周辺のジョブ構造（ジョブ名・実行条件・path の組み立て方）は既に発散している。

| | platform | monorepo |
|---|---|---|
| job 名 | `kustomize-diff` | `kubernetes-diff` |
| 実行条件 | `github.event_name == 'pull_request'` | `inputs.path != ''` |
| path | `kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}`（固定パターンから組み立て） | `${{ inputs.path }}`（呼び出し元がそのまま渡す） |

### 問題

`panicboat-actions` は release-please を単一パッケージ構成で運用しており、`kustomize-diff/` と `terragrunt-run/` が同じバージョン・同じ CHANGELOG を共有する。そのため **`terragrunt-run` だけの変更でも `kustomize-diff` の pin SHA が動き**、Renovate が `platform` と `monorepo` の両方に無関係な pin bump PR を送る。

```
$ git log --oneline -- .github/workflows/reusable--kubernetes-builder.yaml
ab2689f chore(.github/workflows): update panicboat/panicboat-actions digest to fd41cb7 (#649)
56ed446 chore(.github/workflows): update panicboat/panicboat-actions digest to 937ba09 (#601)
...
```

### `has-diff` output の扱い

action の output `has-diff` は composite action 内部の `reactions` 式でのみ使われており、呼び出し元ワークフロー（`platform`・`monorepo` いずれも）はこの output を参照していない（`grep -rn "has-diff" .github` で確認済み、ヒットは `platform` の別ファイル `reusable--kubernetes-hydrator.yaml` の無関係な同名ステップのみ）。インライン化後、job レベルの `outputs:` としては export しない。

## 2. Decision

| 論点 | 決定 | 理由 |
|---|---|---|
| 配置形式 | 呼び出し元 workflow へのインライン化（ローカル composite action化はしない） | 呼び出し元が各リポジトリ 1 箇所のみのため、抽象化を持つ意味が薄い |
| `panicboat-actions` 側の扱い | `kustomize-diff/` を削除 | 参照元が無くなった時点で非参照コードを残す理由が無い |
| 実装順序 | platform → monorepo → 両方の動作確認後に panicboat-actions 削除 | 削除後に元の action へロールバックする手段を、動作確認が済むまで残すため |

## 3. Design

### 3.1 platform: `reusable--kubernetes-builder.yaml`

既存の `Kustomize Diff` ステップ（`uses: panicboat/panicboat-actions/kustomize-diff@...`）を、以下の 5 ステップに置き換える。`inputs.*` への参照は呼び出し元で既に手元にある値に置換する。

```yaml
      - name: Checkout base ref
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          path: base
          token: ${{ steps.app-token.outputs.token }}

      - name: Build head manifests
        id: kustomize-head
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          kustomization: kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}/kustomization.yaml
          write-individual-files: true

      - name: Build base manifests
        id: kustomize-base
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          base-directory: base
          kustomization: kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}/kustomization.yaml
          write-individual-files: true

      - name: Diff manifests
        id: diff
        uses: int128/diff-action@77a301a80335bebb9abb2d28a3dacfa844105395 # v2.28.0
        with:
          base: ${{ steps.kustomize-base.outputs.directory }}
          head: ${{ steps.kustomize-head.outputs.directory }}

      - name: Comment PR
        if: steps.pr-info.outputs.number != ''
        uses: thollander/actions-comment-pull-request@24bffb9b452ba05a4f3f77933840a6a841d1b32b # v3.0.1
        with:
          message: |
            ## Kustomize Diff

            **Service**: `${{ inputs.service-name }}`
            **Environment**: `${{ inputs.environment }}`

            ${{ steps.diff.outputs.comment-body || 'No changes' }}
          comment-tag: "kubernetes-${{ inputs.service-name }}-${{ inputs.environment }}"
          mode: upsert
          pr-number: ${{ steps.pr-info.outputs.number }}
          GITHUB_TOKEN: ${{ steps.app-token.outputs.token }}
          reactions: ${{ steps.diff.outputs.has-diff == 'true' && 'rocket' || '' }}
        continue-on-error: true
```

置換対応表:

| composite action 側 | インライン化後 |
|---|---|
| `inputs.token` | `steps.app-token.outputs.token` |
| `inputs.service-name` | `inputs.service-name`（job input、既存のまま） |
| `inputs.environment` | `inputs.environment`（job input、既存のまま） |
| `inputs.path` | `kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}`（既存の `uses:` 呼び出しで組み立てていた式をそのまま `kustomization:` に埋め込む） |
| `inputs.pr-number` | `steps.pr-info.outputs.number` |
| `if: inputs.pr-number != ''` | `if: steps.pr-info.outputs.number != ''` |

### 3.2 monorepo: `reusable--kubernetes-builder.yaml`

同様の置換。`path` は既存どおり `${{ inputs.path }}` を `kustomization:` にそのまま渡す。

```yaml
      - name: Checkout base ref
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          path: base
          token: ${{ steps.app-token.outputs.token }}

      - name: Build head manifests
        id: kustomize-head
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          kustomization: ${{ inputs.path }}/kustomization.yaml
          write-individual-files: true

      - name: Build base manifests
        id: kustomize-base
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          base-directory: base
          kustomization: ${{ inputs.path }}/kustomization.yaml
          write-individual-files: true

      - name: Diff manifests
        id: diff
        uses: int128/diff-action@77a301a80335bebb9abb2d28a3dacfa844105395 # v2.28.0
        with:
          base: ${{ steps.kustomize-base.outputs.directory }}
          head: ${{ steps.kustomize-head.outputs.directory }}

      - name: Comment PR
        if: steps.pr-info.outputs.number != ''
        uses: thollander/actions-comment-pull-request@24bffb9b452ba05a4f3f77933840a6a841d1b32b # v3.0.1
        with:
          message: |
            ## Kustomize Diff

            **Service**: `${{ inputs.service-name }}`
            **Environment**: `${{ inputs.environment }}`

            ${{ steps.diff.outputs.comment-body || 'No changes' }}
          comment-tag: "kubernetes-${{ inputs.service-name }}-${{ inputs.environment }}"
          mode: upsert
          pr-number: ${{ steps.pr-info.outputs.number }}
          GITHUB_TOKEN: ${{ steps.app-token.outputs.token }}
          reactions: ${{ steps.diff.outputs.has-diff == 'true' && 'rocket' || '' }}
        continue-on-error: true
```

### 3.3 panicboat-actions: `kustomize-diff/` の削除

- `kustomize-diff/` ディレクトリを削除
- `README.md` の `- \`kustomize-diff/\` — Build kustomize overlays and post diff as a PR comment.` の行を削除

## 4. Trade-offs

**得られるもの**
- `terragrunt-run` の変更が `kustomize-diff` の pin bump を誘発する無関係な churn が止まる
- 4 つの upstream action（`checkout` / `kustomize-action` / `diff-action` / `comment-pull-request`）を各リポジトリの Renovate が個別に追跡するようになり、依存関係がリポジトリ内で完結する

**失うもの**
- 実装が 2 リポジトリに重複する。将来どちらかだけを修正して他方を直し忘れるリスクがあるが、周辺のジョブ構造が既に発散している実態を踏まえると、実質的な結合度はさほど高くない

## 5. Execution Order

1. platform をインライン化 → コミット → 検証（actionlint + 実 PR での動作確認）
2. monorepo をインライン化 → コミット → 検証
3. 1・2 の動作確認が完了してから `panicboat-actions` の `kustomize-diff/` を削除

## 6. Validation

- `actionlint` で 2 リポジトリの変更後 workflow ファイルを構文検証
- 各リポジトリで Kubernetes manifest に差分のある PR を実際に作成し、`Kustomize Diff` コメントが従来と同じ形式（`comment-tag` 一致 = 同じコメントスレッドに upsert）で投稿されることを確認する。ローカルでは `int128/kustomize-action` と `int128/diff-action` の実行結果を再現できないため、CI 実行での確認が必須
- panicboat-actions 削除後、`platform` と `monorepo` の `reusable--kubernetes-builder.yaml` に `panicboat/panicboat-actions/kustomize-diff` への参照が残っていないことを `grep` で確認

## 7. Out of Scope

- `terragrunt-run` の扱い。今回は `kustomize-diff` のみが対象で、`terragrunt-run` は引き続き `panicboat-actions` の共有 composite action として運用する
- `panicboat-actions` の release-please 構成（単一パッケージ運用）の見直し
- platform・monorepo 以外のリポジトリへの Kustomize diff 機能の追加
