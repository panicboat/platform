# holmes Source Code Investigation Design

## Background

holmes（`panicboat/monorepo` の `system-components/holmes`）は Slack メンションと Alertmanager critical alert を起点に HolmesGPT へ調査を依頼し、結果を Slack に投稿する relay として v0.4.0 まで稼働している。現在 HolmesGPT に与えられている toolset はクラスタ状態（`kubernetes/core`、`kubernetes/logs`、`prometheus/metrics`）とインターネット参照（`internet`）、限定的な bash（`builtin_allowlist: core`）のみで、根本原因がアプリケーションのソースコードにある場合（バグ・設定ミスの起点がコードそのもの等）は調査できない。

`panicboat/monorepo`・`panicboat/platform` のソースコードを HolmesGPT が読めるようにし、クラスタ状態だけでは説明のつかない根本原因の特定を可能にする。

将来的な拡張として、自然言語での GitHub Issue 作成・修正 PR の自動作成も構想にあるが、本 spec のスコープ外（Issue 作成は別 spec、PR 作成は書き込み権限を伴うため別 bot の可能性も含めて別途検討、memory: `holmes-github-issue-idea.md` に経緯あり）。

## Goal

HolmesGPT が調査中に必要と判断した場合、`panicboat/monorepo`・`panicboat/platform` のソースコードを読み取り専用で調査できるようにする。

## Scope

### 対象

- HolmesGPT の `bash` toolset に読み取り専用の git サブコマンドを許可リストとして追加する（`panicboat/platform` 側の変更）
- holmes が HolmesGPT に送る `additional_system_prompt` に、対象リポジトリの存在とソース調査の使いどころに関する指示を追加する（`panicboat/monorepo` 側の変更）

### 対象外

- 自然言語での GitHub Issue 作成（別 spec）
- 修正 PR の自動作成（書き込み権限を伴うため要別途検討、別 bot の可能性あり）
- 事前 clone・キャッシュ用の永続ストレージ（リポジトリが小さいため不要と判断。根拠は Approach セクション参照）
- GitHub 認証情報の追加（対象リポジトリが public のため読み取りに認証不要）

## Approach

HolmesGPT の `bash` toolset には `allow: [...]`（許可コマンド prefix の追加リスト、既存の allowlist にマージされる）という設定項目が既にある。これに git の読み取り専用サブコマンドを追加するだけで、新しい toolset・新しいインフラを一切作らずに実現できる。

検討した代替案:

- **永続ボリュームへの事前 clone + 定期 sync**: 調査ごとの clone コストを避けられるが、対象2リポジトリは合計 15MB 程度と小さく（`gh api repos/<repo> --jq .size` で実測）、clone 自体が一瞬で終わるためコスト削減効果が薄い。PVC・sync CronJob という運用対象が増えるデメリットの方が大きいと判断し却下。
- **GitHub 公式 MCP server 経由の連携**: HolmesGPT は `mcp` toolset プラグインを持っており将来的な拡張手段として妥当だが、別途 MCP server の用意（自前ホストか GitHub のリモート MCP endpoint 利用か）と認証設定が必要で、bash toolset の設定追加だけで完結する本アプローチに比べて明らかに過剰。将来 GitHub 側の書き込み操作（Issue/PR 作成）まで MCP に寄せる判断をするなら再検討の余地はあるが、今回のスコープ（読み取りのみ）では見送り。

採用: **bash toolset の `allow` リスト拡張**。対象リポジトリは両方 public（`gh repo view --json visibility` で確認済み）のため、認証情報なしで `git clone` 可能。HolmesGPT のコンテナには `git` バイナリが既にあり、github.com への egress も疎通確認済み（`git ls-remote` 実行済み）。

## Architecture

```
holmes (Go relay) ──POST /api/chat (additional_system_prompt に対象 repo と使いどころを明記)──> HolmesGPT
                                                                                                    │
                                                                                                    └─ bash tool 呼び出し（LLM 自身の判断）
                                                                                                         git clone --depth 1 https://github.com/panicboat/<repo>.git /tmp/<repo>
                                                                                                         git grep / find / cat で調査
```

- **配置場所**: 新規ファイルは無い。既存2ファイルの変更のみ
  - `panicboat/platform`: `kubernetes/components/holmesgpt/production/values.yaml.gotmpl`
  - `panicboat/monorepo`: `system-components/holmes/workspace/internal/clients/holmes/client.go`
- **clone のタイミング**: 事前 clone は行わない。HolmesGPT が調査中に「ソースコードを見る必要がある」と判断した時点で、その場で `bash` tool 経由の通常のツール呼び出しとして clone を実行する。clone 先はコンテナのエフェメラルなファイルシステム（`/tmp` 配下）で、永続化・キャッシュはしない。
- **認証**: 不要（public repo、HTTPS 経由の匿名 clone）。

## Components

### 1. HolmesGPT bash toolset の許可リスト拡張（`panicboat/platform`）

`kubernetes/components/holmesgpt/production/values.yaml.gotmpl` の `toolsets.bash` セクションに `config.allow` を追加する。

```yaml
bash:
  enabled: true
  config:
    builtin_allowlist: "core"
    allow:
      - "git clone"
      - "git log"
      - "git show"
      - "git diff"
      - "git blame"
      - "git ls-files"
      - "git grep"
      - "cat"
      - "find"
```

`builtin_allowlist` は既存の `core` を維持する（`extended` への変更は行わない）。`extended` は `ls`/`stat`/`du`/`df`/tar 系まで含むが、ソースコード調査には `cat`（ファイル内容の読み取り）と `find`（ファイル探索）があれば十分なため、必要最小限を `allow` に個別追加する形を取る。`git push`・`git commit`・`git config` 等の書き込み・設定変更系サブコマンドは許可リストに含めない — prefix マッチしないコマンドは HolmesGPT の bash toolset 側で自動的に拒否される（`bash/common/config.py` の allow/deny 機構による、追加のガード実装は不要）。

### 2. holmes の system prompt に対象リポジトリを明記（`panicboat/monorepo`）

`internal/clients/holmes/client.go` の `slackFormattingInstructions` 定数に、ソースコード調査の使いどころを追記する。

```go
const slackFormattingInstructions = `Respond in Japanese.

Format your response using Slack's mrkdwn syntax, not standard Markdown:
- Bold: *text* (single asterisks, not **text**)
- No markdown headings (#, ##, ###) — use *bold* text as a section label instead
- Links: <https://example.com|link text>, not [link text](https://example.com)
- Bullet lists: start each line with "• " (not "- " or "* ")

For root cause investigation, you have read-only access to two source repositories via
git (both public, no authentication needed):
- https://github.com/panicboat/monorepo
- https://github.com/panicboat/platform

Investigate cluster state first (logs, metrics, resource status). Only clone and read
source code when cluster state alone doesn't explain the root cause — for example, when
a bug or misconfiguration appears to originate in application code rather than runtime
state.`
```

既存のフォーマット指示（日本語・Slack mrkdwn）はそのまま残し、末尾に新しい段落を追加する形にする。

## Error Handling

clone 失敗（ネットワーク一時障害、レート制限等）は通常の bash tool 実行エラーとして HolmesGPT 自身が扱う。holmes 側での特別なハンドリングは不要（`Investigate` の呼び出し形式・戻り値は変更しない）。

## Testing

- `panicboat/platform` 側: `hydrate-component.sh holmesgpt production` で `allow` リストがレンダリング結果に反映されることを確認する。
- `panicboat/monorepo` 側: `slackFormattingInstructions` の内容変更のみのため、既存の `TestClient_Investigate` に新しいアサーション（`additional_system_prompt` に対象 repo の URL が含まれること）を追加する。
- 結合テスト: デプロイ後、実際に Slack でコードに起因する調査を依頼し、HolmesGPT が `git clone` を実行して該当ファイルを引用した回答を返すことを手動確認する。

## Open Items（本 spec では解決しない）

- HolmesGPT が同一 investigation 内で同じ repo を複数回 clone しようとした場合の重複処理（ディレクトリ既存エラー等）は、LLM 自身の判断・リトライに委ねる。明示的な排他制御は入れない。
- 自然言語での GitHub Issue 作成、修正 PR の自動作成は別 spec で扱う。
