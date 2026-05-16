# Renovate-driven OpenTofu / Terragrunt version management via aqua

## Background

`panicboat/platform` で 9 件の Renovate PR（#362, #363, #365, #370–#375）が同時に `tofu init` で fail している。原因は cross-repo の version 不整合：

- `gruntwork-io/terragrunt-action` を呼ぶ panicboat-actions の composite action が `tofu_version: '1.11.6'` を hard-code
- platform の `terraform.tf` は `required_version = ">= 1.11.6"` を持ち、Renovate の `overridePackageName: opentofu/opentofu` で OpenTofu の release を tracking している
- OpenTofu v1.12.0 release を受けて Renovate が `required_version` を `>= 1.12.0` に bump
- ランタイム binary は 1.11.6 のまま → unsupported version error

panicboat-actions/.github/renovate.json には `tofu_version` を tracking する custom regex manager が存在するが、`fileMatch` の path が `terragrunt/action.yaml` で、実体 `terragrunt-run/action.yaml` と一致せず、ディレクトリ rename 後の動作確認が漏れていた（commit `bae27a8` の `deploy-actions` からのコピー由来）。

短期 patch（fileMatch typo 修正 + tofu_version 1.12.0 bump）は別 PR で検討したが、cross-repo race は本質的に残るため見送り、本 spec で根本対処を定義する。

## Goal

OpenTofu / Terragrunt の version を「panicboat-actions の SHA pin に紐付かない」状態にし、caller repo（platform / monorepo）が自分の commit に紐付く単一の source of truth で binary 版と `required_version` を整合させる。Renovate の cross-repo merge 順序に依存しない構造にする。

## Architecture

aqua を version manager として採用し、`*/.github/aqua.yaml` を **caller repo ごとの source of truth** にする。panicboat-actions の composite action は caller の aqua.yaml を読み、aqua install で `terragrunt` / `tofu` を PATH に乗せ、shell から直接 invoke する。`gruntwork-io/terragrunt-action` への依存は除去する。

### なぜ aqua か

- panicboat の他 workflow（`reusable--kubernetes-hydrator.yaml`）が aqua を採用済み（helmfile / helm / kustomize / actionlint / act）。揃えると workflow 全体で version manager が一つになる
- `aqua-checksums.json` で binary の SHA256 を固定でき、registry 経由で cosign 署名検証も可能。terragrunt / opentofu は infrastructure 変更を実行する binary なので supply chain 検証は重要
- mise はより広く採用されているが、panicboat 内には既存資産がない。aqua へ統一する方が TCO が低い

### なぜ gruntwork-io/terragrunt-action を捨てるか

- `tofu_version` / `tg_version` を action input として hard-code する設計が、まさに今回の bug の温床
- 同 action は内部で mise を立てて install するため、aqua との重複と version 二系統管理になる
- caller 側で aqua を使う前提なら、`terragrunt` を直接 invoke して `parse-results.js` が読む `tg_action_exit_code` / `tg_action_output` を shell 側で emit する方が一貫性が取れる

## Component changes

### panicboat-actions/terragrunt-run/action.yaml

`Execute Terragrunt` step を以下に差し替える。`gruntwork-io/terragrunt-action` への uses 行は削除する。

```yaml
- name: Setup aqua
  uses: aquaproj/aqua-installer@11dd79b4e498d471a9385aa9fb7f62bb5f52a73c # v4.0.4
  with:
    aqua_version: v2.48.2
  env:
    AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml

- name: Verify required binaries
  shell: bash
  env:
    AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
  run: |
    set -euo pipefail
    missing=()
    command -v terragrunt >/dev/null || missing+=("gruntwork-io/terragrunt")
    command -v tofu       >/dev/null || missing+=("opentofu/opentofu")
    if [ ${#missing[@]} -gt 0 ]; then
      echo "::error::Missing aqua packages: ${missing[*]}. Add them to .github/aqua.yaml."
      exit 1
    fi

- name: Execute Terragrunt
  id: terragrunt
  shell: bash
  working-directory: ${{ inputs.working-directory }}
  env:
    TF_INPUT: 'false'
    GITHUB_TOKEN: ${{ inputs.token }}
    AWS_DEFAULT_REGION: ${{ inputs.aws-region }}
    AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
    ACTION_TYPE: ${{ inputs.action-type }}
  run: |
    set -o pipefail
    out="$RUNNER_TEMP/tg-out.log"
    args=("$ACTION_TYPE" -no-color -input=false)
    [ "$ACTION_TYPE" = apply ] && args+=(-auto-approve)
    terragrunt "${args[@]}" 2>&1 | tee "$out"
    code=${PIPESTATUS[0]}
    delim="__TGEOF_$(openssl rand -hex 8)__"
    {
      echo "tg_action_exit_code=$code"
      echo "tg_action_output<<$delim"
      head -c 200000 "$out"
      echo
      echo "$delim"
    } >> "$GITHUB_OUTPUT"
    exit "$code"
```

`parse-results.js` の input contract（`tg_action_exit_code` / `tg_action_output`）と output（`status` / `is-failed` / `output` / `truncation-notice` / `job-url`）は維持されるため、caller 側 workflow と PR comment 連携には変更が及ばない。

### panicboat-actions/.github/renovate.json

`customManagers` 2 件（`tofu_version` と `tg_version` を tracking していたもの）を削除する。pin 場所が action.yaml から消えるため設定そのものが意味を失う。

### platform/.github/aqua.yaml

既存 packages に 2 行追記する。

```yaml
packages:
  # 既存: helmfile/helmfile, helm/helm, kubernetes-sigs/kustomize, nektos/act, rhysd/actionlint
  - name: opentofu/opentofu@v1.12.0
  - name: gruntwork-io/terragrunt@v1.0.2
```

### monorepo/.github/aqua.yaml

新規作成する。`registries[].ref` は platform に揃える。

```yaml
---
registries:
  - type: standard
    ref: v4.311.0 # renovate: github_release aquaproj/aqua-registry

packages:
  - name: opentofu/opentofu@v1.12.0
  - name: gruntwork-io/terragrunt@v1.0.2
```

### 各 caller workflow

`reusable--terragrunt-executor.yaml` は無変更。composite 側で aqua install / 検証 / 実行が完結する。

## Renovate behavior after change

- `aqua` manager が `aqua.yaml` の `<owner>/<repo>@v<version>` を native に bump 対象として認識
- platform / monorepo の `terraform.tf` の `required_version` は既存の `overridePackageName: opentofu/opentofu` rule（platform に存在、monorepo は 2026-05-16 に PR #608 で追加済み）経由で同じ OpenTofu release stream を tracking
- OpenTofu の新 release が出ると、各 caller repo 内で aqua.yaml と `required_version` が同一 Renovate run で bump される（datasource が一致しているため version も常に揃う）
- panicboat-actions の SHA pin 更新は独立した経路で行われ、OpenTofu / Terragrunt の版とは無関係になる

## Rollout

```
step 1  caller の aqua.yaml 準備（互換性のための先行）
        PR-A  monorepo  → .github/aqua.yaml 新規作成
        PR-B  platform  → 既存 aqua.yaml に opentofu + terragrunt 追記
        どちらも no-op（現 composite は aqua.yaml を見ない）。並列 merge 可。

step 2  panicboat-actions の composite 差し替え
        PR-C  terragrunt-run/action.yaml 全面改修 + renovate.json から customManagers 削除
        PR-A / PR-B 両方の merge を確認してから ready-for-review。

step 3  caller の SHA pin 更新
        Renovate auto-PR が platform / monorepo に来る。
        PR-D  platform/.github/workflows/reusable--terragrunt-executor.yaml の SHA bump
        PR-E  monorepo/.github/workflows/reusable--terragrunt-executor.yaml の SHA bump

[副作用]
        PR-D landing 後、platform の stale な 9 PR (#362-#375) は Renovate auto-rebase で
        新 SHA を取り込み → opentofu 1.12.0 binary → required_version >= 1.12.0 と整合 → CI pass
```

### Safety net for out-of-order merges

step 2 が step 1 より先に landing しても silent breakage は起きない。step 3 の SHA bump PR が新 composite を走らせ、Verify step が「Missing aqua packages: …」で fail-fast する。

## Testing

| 段階 | 検証 |
|------|------|
| PR-A / PR-B | actionlint / yamllint。CI は no-op だが lint pass のこと |
| PR-C | panicboat-actions repo 単独では terragrunt の実 invoke はできない。`lint-actions.yml` workflow で actionlint + shellcheck（inline script）を pass。実行系は PR-D / PR-E で検証 |
| PR-D / PR-E | `Deploy Terragrunt` matrix が全 service / 環境で plan を回す。これが end-to-end test |
| stale 9 PR | rebase 後の CI pass を確認 |

## Verified preconditions

実装着手前に確認済み（2026-05-16 時点）。

- aqua-registry v4.311.0 に `opentofu/opentofu` / `gruntwork-io/terragrunt` 双方が存在、cosign + sha256 verification 設定あり
- OpenTofu v1.12.0 release: 2026-05-14
- Terragrunt v1.0.2 release: 2026-04-21
- `monorepo/services/monolith/terragrunt/modules/terraform.tf` の `required_version = ">= 1.11.0"` は OpenTofu 1.12.0 と整合
- `monorepo/template/terragrunt/` は CI から呼ばれない skeleton（`.github/` 配下に reference なし）

## Known risks

| Risk | 影響 | 対処 |
|------|------|------|
| caller が aqua.yaml の package を書き忘れ | runtime fail | composite の Verify step で fail-fast + 明示メッセージ |
| aqua-registry に package が無い | composite fail | 上記 preconditions で事前 verify |
| aqua_version pin が古く aqua.yaml の新フィールド未対応 | composite fail | aqua-installer SHA と aqua_version は Renovate で定期 bump |
| GITHUB_OUTPUT のサイズ超過 | step fail | 200K で head truncate（parse-results.js が 30K に再 truncate して PR comment 化） |

## Out of scope

- `monorepo/template/terragrunt/modules/terraform.tf` の `required_version = "1.15.2"` の修正。OpenTofu に該当 version は存在しないが template は CI 実行経路にないため defuse 不要。テンプレートから派生するサービスが今後追加された場合の対処は別 issue
- panicboat-actions composite action の単体 test 環境の整備（AWS OIDC を要する構造のため repo 単独では困難）。end-to-end は caller の CI に任せる
- PR #384 (kube-prometheus-stack v85) は merge conflict のみで本件と無関係。Renovate の auto-rebase に委ねる
