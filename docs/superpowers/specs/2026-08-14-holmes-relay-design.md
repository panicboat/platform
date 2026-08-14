# holmes-relay Design

## Background

HolmesGPT は本番導入済み（`docs/superpowers/specs/2026-08-13-holmesgpt-evaluation-design.md`）だが、実際にインシデント発生時どう調査依頼を出すかの導線が無い。当初4つの経路を検討した:

- **A. k9s plugin**（手動、pod 選択から調査）
- **B. ScheduledHealthCheck**（operator CRD による定期チェック）
- **C. Alertmanager 起点の自動調査**
- **D. Slack からの on-demand 調査依頼**（"Ask Holmes" 的な UX）

検討の結果、A・B は利用頻度が見込めないためスコープ外とした。C と D は実装すると「外部イベントを受けて Holmes の `/api/chat` を呼び、結果を Slack に返す」という同一の中継サービスに帰着することが分かったため、1つのサービス **holmes-relay** として統合設計する。

## Goal

Slack からのメンションと、Alertmanager の critical アラートの両方を起点に HolmesGPT の調査を実行し、結果を Slack に届ける中継サービスを設計する。

## Scope

### 対象 (このドキュメントでカバーする)

- `holmes-relay`: Slack Events API と Alertmanager webhook を受け、HolmesGPT `/api/chat` を呼び出し、結果を Slack に投稿する新規サービス
- Alertmanager 側のルーティング設定（`platform` repo, `prometheus-operator` component）
- Slack app の必要スコープ・設定値（手動セットアップ手順として明記。実施はコードでは自動化できない）

### 対象外

- **A (k9s plugin)**: 利用頻度が低い見込みのため見送り。将来必要になれば別途 spec を起こす。
- **B (ScheduledHealthCheck)**: 既存の Prometheus/Alertmanager による監視と役割が重複するため見送り。
- Holmes 本体の toolset/model 構成変更（既存の `kubernetes/components/holmesgpt/` 設定を前提とし、変更しない）

## Architecture

```
Slack (app_mention) ──POST /slack/events──┐
                                            ├──> holmes-relay ──POST /api/chat──> HolmesGPT (holmesgpt-holmes.holmesgpt.svc.cluster.local)
Alertmanager (severity=critical) ──POST /alertmanager/webhook──┘         │
                                                                          └──chat.postMessage──> Slack
```

- **配置場所**: `panicboat/monorepo` の `services/holmes-relay/`（`workspace/` にアプリ本体、`kubernetes/` に Deployment/Service/HTTPRoute）。既存の `frontend`/`monolith` と同じ構成・CI（`reusable--container-builder.yaml`）・Flux デプロイパターンをそのまま使う。新規のインフラパターンは持ち込まない。
- **実装言語**: Go。フレームワーク無し、`net/http` 標準ライブラリのみで実装する単一バイナリ。
- **Holmes API 呼び出し**: `holmesgpt-holmes.holmesgpt.svc.cluster.local`（ClusterIP、クラスタ内到達のため追加公開不要）に `POST /api/chat`、`model: sonnet-4-6` 固定。
  - sonnet-5 は Bedrock 側の service quota が 0 のまま self-service では解消しないため使わない（詳細: 別途トラッキング）。
- **公開エンドポイント**: monorepo 既存の Gateway API + ALB IngressGroup パターンで公開（Slack・Alertmanager 双方とも外部からの到達が必要なため）。TLS は cert-manager、DNS は external-dns、既存 component をそのまま利用。

## Slack Integration (D)

- **UX**: メンション方式。任意チャンネルで `@holmes <調査内容>` と mention すると、同じスレッドで返信する。
- **エンドポイント**: `POST /slack/events`（Slack Events API）。
  - `url_verification` challenge に応答（初回セットアップ時の Slack 側ハンドシェイク）。
  - `event_callback` / `event.type == "app_mention"` を処理。mention 部分を取り除いたテキストを調査依頼文として使う。
  - `X-Slack-Signature` / `X-Slack-Request-Timestamp` を signing secret で HMAC-SHA256 検証（Slack 公式の署名検証手順に従う）。
- **非同期処理**: Slack Events API は 3 秒以内の ACK を要求するが、調査には数十秒かかる（評価時実測 43 秒程度）。リクエストを受けたら即座に 200 を返し、`chat.postMessage` で「🔍 調査中です」を即時投稿した上で、goroutine で Holmes 呼び出し→結果投稿を行う。
- **投稿先**: mention されたチャンネル・スレッド。

### Slack app の手動セットアップ (コードでは自動化できない)

1. api.slack.com で新規 Slack app を作成
2. Event Subscriptions を有効化し、Request URL に holmes-relay の公開エンドポイント (`https://<holmes-relay-host>/slack/events`) を設定
3. Bot Token Scopes: `app_mentions:read`, `chat:write`
4. Subscribe to bot events: `app_mention`
5. ワークスペースにインストールし、signing secret と bot token を取得

## Alertmanager Integration (C)

- **エンドポイント**: `POST /alertmanager/webhook`（Alertmanager 標準の webhook payload 形式を受ける）。
- **対象アラート**: `severity: critical` のみ。この絞り込みは **Alertmanager の route 側**で行う（holmes-relay 側では絞り込まない）。理由: kube-prometheus-stack の default rule は既に `severity` ラベルを付与済み（VERIFIED: 2026-08-14 時点で firing 中の 6 アラート中、critical 3 / warning 1 / info 1 / ラベル無し 1）。新たなラベル付け作業が不要で、運用負担がゼロ。
- **チャンネル振り分け**: holmes-relay 自体はチャンネルをハードコードしない。Alertmanager の receiver ごとに webhook URL のクエリパラメータでチャンネルを渡す（例: `.../alertmanager/webhook?channel=team-x-incidents`）。holmes-relay は受け取った `channel` にそのまま投稿する汎用実装とする。これにより、チーム/サービスごとのチャンネル分離は Alertmanager の route 定義側だけで完結し、holmes-relay のコード変更を必要としない。
- **`platform` repo 側の変更**: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` に `severity: critical` にマッチする route と、holmes-relay を指す `webhook_configs` を持つ receiver を追加する。

## Secrets & Auth

| 経路 | 認証方式 | 保存場所 |
|---|---|---|
| Slack → holmes-relay | Slack 署名検証 (HMAC-SHA256) | AWS Secrets Manager `panicboat/holmes-relay/slack`（`signing_secret`, `bot_token`）を ExternalSecret で sync |
| Alertmanager → holmes-relay | 共有 Bearer トークン | AWS Secrets Manager `panicboat/holmes-relay/alertmanager`（`shared_token`）を ExternalSecret で sync |
| holmes-relay → HolmesGPT `/api/chat` | 認証なし | Holmes API 自体が現状無認証設計のため踏襲。ClusterIP はクラスタ内到達可能。将来的に NetworkPolicy で holmes-relay の pod からのみ許可する多層防御を検討事項として残す |
| holmes-relay → Slack API | Bot token (Bearer) | 上記と同じ Secret から取得 |

ExternalSecret は oauth2-proxy の既存パターン（`aws-secrets-manager` ClusterSecretStore、`refreshInterval: 1h`）を踏襲する。

## Error Handling

- Holmes API 呼び出し失敗・タイムアウト時: Slack には「調査に失敗しました」の旨をエラー概要とともに投稿する（隠さない）。Alertmanager 側には常に 200 を返す（Alertmanager 側でリトライされても holmes-relay 側の処理自体は冪等ではないため、リトライさせない）。
- Slack 署名検証失敗: 401 を返しログに記録。
- Alertmanager の共有トークン不一致: 401 を返しログに記録。

## Testing

- holmes-relay 単体: 署名検証・Alertmanager トークン検証のユニットテスト、Holmes API / Slack API 呼び出し部分はモックで検証。
- 結合テスト: 開発環境相当で実際に Slack app mention → holmes-relay → HolmesGPT（sandbox 相当環境があれば）→ Slack 投稿、が一連で通ることを手動確認。
- Alertmanager 側: `amtool` 等で `severity: critical` のテストアラートを送り、holmes-relay の `/alertmanager/webhook` に届き Slack に投稿されることを確認。

## Open Items (この spec では解決しない)

- sonnet-5 の Bedrock service quota が 0 のまま解消しない件（`bedrock-5gen-quota-blocker` として別トラッキング）。解消次第 `model` を差し替えるだけで holmes-relay 側の変更は不要。
- Holmes API (`/api/chat`) を無認証のまま新しい呼び出し元 (holmes-relay) に開放することの妥当性。NetworkPolicy 等の多層防御は本 spec のスコープ外とし、実装後の運用状況を見て判断する。
