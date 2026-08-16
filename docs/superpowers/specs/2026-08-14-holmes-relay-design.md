# holmes Design

## Background

HolmesGPT は本番導入済み（`docs/superpowers/specs/2026-08-13-holmesgpt-evaluation-design.md`）だが、実際にインシデント発生時どう調査依頼を出すかの導線が無い。当初4つの経路を検討した:

- **A. k9s plugin**（手動、pod 選択から調査）
- **B. ScheduledHealthCheck**（operator CRD による定期チェック）
- **C. Alertmanager 起点の自動調査**
- **D. Slack からの on-demand 調査依頼**（"Ask Holmes" 的な UX）

検討の結果、A・B は利用頻度が見込めないためスコープ外とした。C と D は実装すると「外部イベントを受けて Holmes の `/api/chat` を呼び、結果を Slack に返す」という同一の中継サービスに帰着することが分かったため、1つのサービス **holmes** として統合設計する。

## Goal

Slack からのメンションと、Alertmanager の critical アラートの両方を起点に HolmesGPT の調査を実行し、結果を Slack に届ける中継サービスを設計する。

## Scope

### 対象 (このドキュメントでカバーする)

- `holmes`: Slack Events API と Alertmanager webhook を受け、HolmesGPT `/api/chat` を呼び出し、結果を Slack に投稿する新規サービス
- Alertmanager 側のルーティング設定（`platform` repo, `prometheus-operator` component）
- Slack app の必要スコープ・設定値（手動セットアップ手順として明記。実施はコードでは自動化できない）

### 対象外

- **A (k9s plugin)**: 利用頻度が低い見込みのため見送り。将来必要になれば別途 spec を起こす。
- **B (ScheduledHealthCheck)**: 既存の Prometheus/Alertmanager による監視と役割が重複するため見送り。
- Holmes 本体の toolset/model 構成変更（既存の `kubernetes/components/holmesgpt/` 設定を前提とし、変更しない）

## Architecture

```
Alertmanager (severity=critical)
  ├──slack_configs (Incoming Webhook, fingerprint 埋め込み)──> Slack 通知
  └──webhook_configs──POST /alertmanager/webhook───────────┐
                                                              │
Slack (app_mention) ──POST /slack/events─────────────────────┼──> holmes ──POST /api/chat──> HolmesGPT
                                                              │       │
                                                              │       ├──conversations.history (fingerprint 検索, backoff)──> Slack
                                                              │       └──chat.postMessage (フォールバック通知 / スレッド返信)──> Slack
```

- **配置場所**: `panicboat/monorepo` の `system-components/holmes/`（`workspace/` にアプリ本体、`kubernetes/` に Deployment/Service/Ingress）。`services/` 配下の toC プロダクト（frontend/monolith）とは異なる非公開の運用ツールという性質から、新設の `system-components/` tier に置く。Deployment/Service/Kustomize/Flux 登録の構成・CI（`reusable--container-builder.yaml`）は既存パターンをそのまま使うが、公開経路（後述）だけは frontend/monolith 用に準備中の Gateway API 経路とは別にする。
- **実装言語**: Go。フレームワーク無し、`net/http` 標準ライブラリのみで実装する単一バイナリ。
- **Holmes API 呼び出し**: `holmesgpt-holmes.holmesgpt.svc.cluster.local`（ClusterIP、クラスタ内到達のため追加公開不要）に `POST /api/chat`、`model: sonnet-4-6` 固定。
  - sonnet-5 は Bedrock 側の service quota が 0 のまま self-service では解消しないため使わない（詳細: 別途トラッキング）。
- **公開エンドポイント**: `panicboat.net` ゾーンの既存 ALB IngressGroup（`group.name: application`）を共有する plain `Ingress`（`holmes.panicboat.net`）。`grafana`/`prometheus`/`alertmanager`/`hubble` の monitoring-uis Ingress と同じパターンだが、oauth2-proxy は挟まない（Slack・Alertmanager は OAuth ログインを完了できないため）。当初は frontend/monolith と同じ Gateway API（`HTTPRoute` + Cilium Gateway、`dystopia.city`）を想定していたが、その host-network 経路は本 spec の実装時点でまだ疎通しておらず（`nodeLabelSelector` 未設定で Gateway が address を持てない、frontend/monolith 自体もまだ未デプロイ）、holmes は運用ツールとして dystopia.city の公開プロダクト経路と分離する意味もあり `panicboat.net` の Ingress 経路に倒した。TLS は ACM `*.panicboat.net` ワイルドカード証明書が ALB Controller により自動アタッチされる（既存 component のまま、追加設定不要）。DNS は同 Ingress の `external-dns.alpha.kubernetes.io/hostname` annotation 経由で external-dns が作成する。

## Slack Integration (D)

- **UX**: メンション方式。任意チャンネルで `@holmes <調査内容>` と mention すると、同じスレッドで返信する。
- **エンドポイント**: `POST /slack/events`（Slack Events API）。
  - `url_verification` challenge に応答（初回セットアップ時の Slack 側ハンドシェイク）。
  - `event_callback` / `event.type == "app_mention"` を処理。mention 部分を取り除いたテキストを調査依頼文として使う。
  - `X-Slack-Signature` / `X-Slack-Request-Timestamp` を signing secret で HMAC-SHA256 検証（Slack 公式の署名検証手順に従う）。
- **スレッドコンテキストの考慮**: mention イベントに `thread_ts` が含まれる場合（= 既存スレッド内での mention）、`conversations.replies` でスレッド内の過去メッセージを取得し、Holmes への調査依頼文の前段に会話履歴として付与する。トップレベルの mention（`thread_ts` 無し）はメンション文のみを使い、その mention の `ts` を新規スレッドのルートとして返信する。
  - holmes 自身の過去の返信もスレッド履歴に含まれるため、同じスレッドで追加の質問をした場合は自然に前回の調査結果を踏まえた文脈で再調査できる。
  - メッセージ内の `<@U12345>` 形式の生ユーザー ID はそのまま Holmes に渡す（表示名への解決はしない。可読性より実装の単純さを優先する初期実装の判断）。
- **非同期処理**: Slack Events API は 3 秒以内の ACK を要求するが、調査には数十秒かかる（評価時実測 43 秒程度）。リクエストを受けたら即座に 200 を返し、`chat.postMessage` で「🔍 調査中です」を即時投稿した上で、goroutine でスレッド履歴取得→Holmes 呼び出し→結果投稿を行う。
- **投稿先**: mention されたチャンネル・スレッド。

### Slack app の手動セットアップ (コードでは自動化できない)

1. api.slack.com で新規 Slack app を作成
2. Event Subscriptions を有効化し、Request URL に `https://holmes.panicboat.net/slack/events` を設定
3. Bot Token Scopes: `app_mentions:read`, `chat:write`, `channels:history`, `groups:history`（スレッド履歴取得のため。後者は private channel での利用に備える）
4. Subscribe to bot events: `app_mention`
5. ワークスペースにインストールし、signing secret と bot token を取得

## Alertmanager Integration (C)

- **エンドポイント**: `POST /alertmanager/webhook`（Alertmanager 標準の webhook payload 形式を受ける）。
- **対象アラート**: `severity: critical` のみ。この絞り込みは **Alertmanager の route 側**で行う（holmes 側では絞り込まない）。理由: kube-prometheus-stack の default rule は既に `severity` ラベルを付与済み（VERIFIED: 2026-08-14 時点で firing 中の 6 アラート中、critical 3 / warning 1 / info 1 / ラベル無し 1）。新たなラベル付け作業が不要で、運用負担がゼロ。
- **通知の責務分離**: 通知は Alertmanager 純正の `slack_configs`（Incoming Webhook 方式）で完結させ、holmes は調査結果の投稿のみを担う。理由: holmes の pod が落ちていても通知だけは届く可用性と、通知対象の severity 範囲を holmes の調査対象（critical のみ）と独立に決められる柔軟性を優先した。
- **スレッド化**: holmes は webhook を受けたら、まず Alertmanager が投稿したはずの通知メッセージを Slack 履歴から検索する。
  - 検索キー: アラートの `fingerprint`（webhook payload の各 alert に含まれる一意識別子）。Alertmanager 側の Slack 通知テンプレートにも同じ `fingerprint` を埋め込み、テキスト一致で厳密に特定する（alertname だけだと同名アラートの再発火で誤検出するため）。
  - リトライ: `slack_configs` と `webhook_configs` は同一 receiver 内で並行送信され、到達順序は保証されない。指数バックオフ（初回 1 秒、以降 x2、合計約 1 分）で `conversations.history` を再検索する。
  - フォールバック: 1 分経っても見つからない場合、holmes 自身が代理で通知メッセージを投稿し、その `ts` を使う。
  - 調査結果は、検索で見つかった `ts` /フォールバックで投稿した `ts` のどちらであっても、その `ts` にスレッド返信する。
- **チャンネル振り分け**: holmes 自体はチャンネルをハードコードしない。Alertmanager の receiver ごとに webhook URL のクエリパラメータでチャンネルを渡す（例: `.../alertmanager/webhook?channel=team-x-incidents`）。holmes は受け取った `channel` にそのまま投稿する汎用実装とする。これにより、チーム/サービスごとのチャンネル分離は Alertmanager の route 定義側だけで完結し、holmes のコード変更を必要としない。
- **`platform` repo 側の変更**: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` に `severity: critical` にマッチする route と、`slack_configs`（Incoming Webhook、fingerprint 埋め込みテンプレート）+ holmes を指す `webhook_configs` を両方持つ receiver を追加する。

## Secrets & Auth

| 経路 | 認証方式 | 保存場所 |
|---|---|---|
| Slack → holmes | Slack 署名検証 (HMAC-SHA256) | AWS Secrets Manager `panicboat/holmes/slack`（`signing_secret`, `bot_token`）を ExternalSecret で sync |
| Alertmanager → holmes | 共有 Bearer トークン | AWS Secrets Manager `panicboat/holmes/alertmanager`（`shared_token`）を ExternalSecret で sync |
| Alertmanager → Slack（通知） | Incoming Webhook URL | AWS Secrets Manager `panicboat/holmes/alertmanager`（`slack_webhook_url`）を ExternalSecret で sync（`platform` repo 側、`monitoring` namespace） |
| holmes → HolmesGPT `/api/chat` | 認証なし | Holmes API 自体が現状無認証設計のため踏襲。ClusterIP はクラスタ内到達可能。将来的に NetworkPolicy で holmes の pod からのみ許可する多層防御を検討事項として残す |
| holmes → Slack API | Bot token (Bearer) | 上記 `panicboat/holmes/slack` と同じ Secret から取得。`chat.postMessage`（フォールバック通知・スレッド返信）と `conversations.history`（通知メッセージ検索）に使う |

ExternalSecret は oauth2-proxy の既存パターン（`aws-secrets-manager` ClusterSecretStore、`refreshInterval: 1h`）を踏襲する。

## Error Handling

- Holmes API 呼び出し失敗・タイムアウト時: Slack には「調査に失敗しました」の旨をエラー概要とともに投稿する（隠さない）。Alertmanager 側には常に 200 を返す（Alertmanager 側でリトライされても holmes 側の処理自体は冪等ではないため、リトライさせない）。
- Slack 署名検証失敗: 401 を返しログに記録。
- Alertmanager の共有トークン不一致: 401 を返しログに記録。

## Testing

- holmes 単体: 署名検証・Alertmanager トークン検証のユニットテスト、Holmes API / Slack API 呼び出し部分はモックで検証。通知メッセージ検索（fingerprint 一致）・指数バックオフ・フォールバック投稿・スレッド返信の分岐もユニットテストで検証する。
- 結合テスト: 開発環境相当で実際に Slack app mention → holmes → HolmesGPT（sandbox 相当環境があれば）→ Slack 投稿、が一連で通ることを手動確認。
- Alertmanager 側: `amtool` 等で `severity: critical` のテストアラートを送り、Alertmanager の通知と holmes のスレッド返信が同一スレッドに収まることを確認する。

## Open Items (この spec では解決しない)

- sonnet-5 の Bedrock service quota が 0 のまま解消しない件（`bedrock-5gen-quota-blocker` として別トラッキング）。解消次第 `model` を差し替えるだけで holmes 側の変更は不要。
- Holmes API (`/api/chat`) を無認証のまま新しい呼び出し元 (holmes) に開放することの妥当性。NetworkPolicy 等の多層防御は本 spec のスコープ外とし、実装後の運用状況を見て判断する。
