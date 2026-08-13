# HolmesGPT Evaluation Design

## Goal

HolmesGPT が production EKS cluster の障害を調査し、根本原因に到達できるかを採点できる状態を作る。
判定に必要な操作は、原因が既知の障害を sandbox に仕込み、cluster 内の HolmesGPT に調査させ、出力されたレポートが仕込んだ原因を特定しているかを確認するまでの一巡である。

採点基準は `2026-08-10-opensre-phase1-evaluation-design.md` と同一にする。両者を同じ物差しで比較するためである。

## Non-goals

- Alertmanager receiver の設計とアラート駆動の自動調査。これ自体が独立した設計テーマであり、採点結果を待って着手する
- Robusta Platform（SaaS / self-hosted）の導入。chart は standalone で動作する
- Loki toolset の設定。三層の痕跡は `kubernetes/logs` と `prometheus/metrics` で到達でき、Loki は評価に不要である
- NetworkPolicy による egress 制限。`internet` toolset を有効にする判断と併せて、今回は入れない

## Why HolmesGPT after OpenSRE

OpenSRE の評価は配布物の不具合で成立しなかった。判断の前提が違うため、その理由を記録する。

| | OpenSRE | HolmesGPT |
|---|---|---|
| ガバナンス | 単一ベンダーの Public Alpha | CNCF Sandbox（Robusta + Microsoft） |
| version | `v0.1.YYYY.M.D`、ほぼ日次 | semver、月 3-4 回 |
| Kubernetes 配布 | chart 無し。自前 manifest が要る | 公式 Helm chart `robusta/holmes` |
| RBAC | 自分で設計 | chart が read-only ClusterRole を提供 |
| AWS 認証 | 自前 role + kubeconfig | IRSA（`serviceAccount.annotations`） |
| 非対話実行 | REPL が TTY 必須 | `POST /api/chat` |
| 商用依存 | 無し | Robusta Platform は任意 |

## Why in-cluster, unlike OpenSRE

OpenSRE ではローカル CLI に留めた。理由は chart が存在せず、日次リリースの成果物を Flux 管理下に置くと更新追従が恒常的な負担になるためだった。

HolmesGPT にはどちらも当てはまらない。公式 chart があり、リリースは月 3-4 回で他の component と同程度である。Renovate の運用に乗る。

cluster 内に置く積極的な理由もある。
Grafana / Mimir / Loki へ ClusterIP で直接届くため、`kubectl port-forward` を挟む必要が無い。
IRSA を使えば kubeconfig を持ち込まずに済む。
ローカルマシンには何もインストールしない。

## Permission design

### Kubernetes RBAC

chart が生成する ClusterRole をそのまま使う。自前で書かない。

`helm template` で描画して確認した内容は次のとおりである。

- 書き込み系 verb（`create` / `update` / `delete` / `patch` / `deletecollection` / `*`）は **0 件**。`get` / `list` / `watch` のみ
- core API group（`apiGroups: [""]`）の resources に **`secrets` は含まれない**。`configmaps` / `pods` / `pods/log` / `events` / `services` / `endpoints` / `nodes` など
- `external-secrets.io` の CRD（`externalsecrets` / `secretstores` 等）は読める。ただしこれらは同期の定義であって値ではない

`secrets` が読めないことは、このエージェントが読んだ内容を外部 LLM へ送る以上、重要である。
ログ経由の prompt injection で Secret の読み取りへ誘導されても、API サーバーが拒否する。エージェント側の自制に依存しない。

`configmaps` は読める。慣習上 credential を置く場所ではないが、接続文字列や内部構成が外部 LLM へ流れうる点は認識しておく。

`crdPermissions` は `flux` / `gatewayApi` / `keda` / `externalSecrets` を有効化する。このクラスタが実際に使っているものに限る。

### AWS 認証

IRSA を使う。`aws/eks/modules/` に IRSA role を一つ足し、`serviceAccount.annotations` に ARN を与える。

この repo には IRSA と Pod Identity の両方の前例がある。
IRSA は alb-controller / ebs-csi / external-dns / mimir が使う。
Pod Identity は cilium-operator と karpenter が使うが、採用理由は cilium-operator の 5 秒 hardcoded timeout を bootstrap 時に超過する問題であり、HolmesGPT には当てはまらない。

chart が `serviceAccount.annotations` を第一級の設定項目として持つこと、アプリ系ワークロードの主流が IRSA であることから、IRSA を採る。

権限は Bedrock の呼び出しのみとする。

```
bedrock:InvokeModel
bedrock:InvokeModelWithResponseStream
```

resource には `jp.` inference profile と参照先 foundation model を region ごとに列挙する。
`jp.` profile は `ap-northeast-1` と `ap-northeast-3` の両方へルーティングするため、片方だけでは呼び出しが失敗する。
OpenSRE 評価で確立した形をそのまま使う。

model ARN をワイルドカードにしない理由は、model ごとの価格が桁で違うためである。設定ミスで高価な model を呼んでも IAM で止まる。

## Toolset design

chart の既定から三点を変える。

| toolset | 既定 | 本設計 | 理由 |
|---|---|---|---|
| `kubernetes/core` `kubernetes/logs` `prometheus/metrics` | 有効 | 維持 | 調査の中核 |
| `bash` | `extended` | **`core`** | 後述 |
| `robusta` | 有効 | **無効** | SaaS 連携。使わないのに外部通信が発生する |
| `internet` | 有効 | 維持 | エラーメッセージや docs の参照に使う。製品価値の一部であり、落とすと機能を削った状態で評価することになる |

### Why bash core instead of extended

`extended` が `core` に追加するのは 11 コマンドで、内訳はファイル読み取り（`cat` `base64`）、ファイルシステム走査（`ls` `find` `stat` `du` `df`）、アーカイブ確認（`tar -tf` `gzip -l` `zcat` `zgrep`）である。

`core` / `extended` のどちらにも変更系 kubectl は含まれない。`kubectl` は `get` / `describe` / `logs` / `top` / `explain` / `auth can-i` / `events` など読み取りのみで、`DEFAULT_DENY_LIST` は空である。

この Pod で `cat` が読めるものを列挙すると、k8s の ServiceAccount トークン、IRSA の projected token、自身の設定 ConfigMap、環境変数である。
SA トークンが与える権限は上述の read-only と同じで、IRSA トークンは Bedrock 呼び出しのみに交換できる。
IRSA を使い静的な認証情報を環境変数に置かない限り、`extended` が増やす実被害はほぼ無い。

それでも `core` を採る理由は三つある。

第一に、`extended` の 11 コマンドは調査対象を向いていない。
調査対象は cluster であって HolmesGPT 自身のコンテナではない。
`kubectl get/describe/logs` と `jq` / `grep`（すべて `core`）で Kubernetes と Prometheus の調査は成立する。

第二に、将来 Secret をマウントしたときに効く。
chart は `mcpAddons.github.auth.secretName` のように GitHub PAT を Secret でマウントする経路を持つ。
有効化した時点で `cat` が意味を持つが、そのとき `extended` を選んだ経緯を思い出せる保証は無い。

第三に、判断が可逆で観測可能である。
`core` で不足するなら、レポートに「実行しようとしたが拒否された」と現れる。見てから上げればよい。
逆方向は成立しない。`extended` で始めると、必要だったのか惰性だったのか区別がつかない。

### Prometheus 接続先

`prometheus_url` に `http://mimir-distributed-gateway.monitoring.svc.cluster.local/prometheus` を設定する。

Grafana の datasource 定義で Mimir が default であり、長期保存を持つためである。
Mimir 側は `X-Scope-OrgID` を要求しない（Loki だけが `anonymous` 固定で要求する）ため、追加のヘッダー設定は不要である。

## Component layout

```
kubernetes/components/holmesgpt/
├── namespace.yaml          # 全 env 共通。falco / reloader と同じ配置
└── production/
    ├── helmfile.yaml
    └── values.yaml.gotmpl
```

`hydrate-index.sh` は `<comp>/<env>/namespace.yaml` を優先し、無ければ `<comp>/namespace.yaml` を読んで `00-namespaces/namespaces.yaml` へ集約する。
env ごとに namespace を変える理由が無いため、component 直下に置く。

`workflow-config.yaml` の `stack_conventions` が `kubernetes/components/{service}` を持つため、新規 component は設定を追加せずに CI へ拾われる。

chart version は `0.39.0` を pin する。Renovate が更新を提案する。

namespace は専用の `holmesgpt` を作る。
cert-manager / external-dns / keda / falco / keycloak と同じく、この repo は component ごとに専用 namespace を持つ規約である。
Mimir へは FQDN で namespace を跨いで到達できるため、`monitoring` へ同居させる利点は無い。
専用 namespace のほうが撤退時に消し残しを確認しやすい。

`podSecurityContext` は chart の既定が空であるため、`runAsNonRoot` 等を明示する。
`readOnlyRootFilesystem` は chart が常に true にするため指定しない。

## Sandbox component

`2026-08-10-opensre-phase1-evaluation-design.md` の sandbox をそのまま再現する。
`kubernetes/components/sandbox/production/` の 4 ファイルは git 履歴から復元でき、三層の障害が成立することは OpenSRE 評価で実測済みである。

`backend` は python slim で `http.server` を動かしつつ 8 MiB ずつメモリを確保し、`limits.memory: 64Mi` を超えて OOMKilled に至る。
`frontend` は一秒ごとに backend を叩き、結果を stdout へ出す。

| 層 | 観測される事象 | 到達に使う toolset |
|---|---|---|
| 症状 | frontend のログに接続エラー | `kubernetes/logs` |
| 中間 | backend の Endpoints が空 | `kubernetes/core` |
| 根本 | OOMKilled の Event と container memory metric | `kubernetes/core` / `prometheus/metrics` |

三層が異なる経路に痕跡を残す構成にすることで、観測基盤との統合そのものを評価対象に含める。

## Verification

| # | 手順 | 期待 |
|---|---|---|
| 1 | terragrunt apply 後に IRSA role が存在する | role と policy が作られる |
| 2 | PR マージ後に Flux が同期 | `kubectl -n holmesgpt get deploy holmes` が Ready |
| 3 | `kubectl -n holmesgpt logs deploy/holmes` | Bedrock 認証エラーが出ていない |
| 4 | port-forward して `GET /api/model` | 設定した model が返る |
| 5 | `kubectl -n holmesgpt exec deploy/holmes -- kubectl auth can-i get secrets --all-namespaces` | `no` が返る |
| 6 | sandbox が同期 | frontend が Ready、backend が CrashLoopBackOff |
| 7 | `POST /api/chat` で sandbox の調査を指示 | レポートが返る |
| 8 | component ディレクトリを削除して hydrate | Flux prune で消える |

手順 4 が通らない場合、Bedrock の model ID 形式（`bedrock/jp.anthropic.claude-sonnet-4-6`）が誤っている可能性が高い。
公式ドキュメントは `bedrock/eu.anthropic.claude-sonnet-4-20250514-v1:0` という region 接頭辞付きの例を示すが、`jp.` での動作は未確認である。

### Grading criteria

手順 7 のレポートを次で採点する。OpenSRE と同一の基準である。

合格は、根本原因を backend の memory limit 不足による OOMKill と特定し、その根拠として観測データを引用していることである。

次のいずれかに該当した場合は不合格とする。

- 「frontend にエラーが出ている」という症状の記述で止まる
- ネットワーク障害や DNS 障害と誤診する
- backend の CrashLoopBackOff に言及するが、memory limit と結びつけない

参考として、OpenSRE は「複数候補の一つとして OOMKilled を挙げたが特定せず、evidence 0 件」であった。

採点と併せて次を記録する。

- 実際に使った toolset と、そこで得た証拠の件数
- 調査に要した時間と Bedrock の課金
- `bash` を `core` に下げたことで拒否された操作の有無
- 誤った断定をしたか、不確実性を表明したか

## Rollback

| 対象 | 手順 |
|---|---|
| HolmesGPT component | ディレクトリを削除して hydrate。Flux prune で消える |
| sandbox component | 同上 |
| IRSA role | `iam_holmesgpt.tf` を削除して apply |

ローカルマシンには何もインストールしないため、撤退はリポジトリの操作で完結する。

## Repository conventions

この repo の Kubernetes 層は次の規約で動いている。本設計はこれに従う。

`kubernetes/components/<comp>/<env>/` が唯一の手書きソースである。
`hydrate-component.sh` の対象は `helmfile.yaml` と `kustomization/` だけで、`namespace.yaml` は `hydrate-index.sh` が `00-namespaces/namespaces.yaml` へ集約する。

`kubernetes/manifests/` は完全な生成物であり、CI が hydrate して commit し返す。

`aws/eks/modules/` に IRSA role を足す場合、既存の `module.*_irsa` と同じ `terraform-aws-modules/iam` の submodule を使う。

## Risk

`aws/eks` は cluster の中核 stack である。IRSA role をここへ足す以上、apply の失敗は cluster 全体に影響しうる。
apply 前に plan の差分を確認し、opensre 評価で確認した定常 churn（node SG のタグ付け替えと `terraform_data` の置換）以外が出ていないことを見る。

HolmesGPT は cluster 内に常駐し、読んだ内容を外部 LLM へ送る。
read-only RBAC と `secrets` の除外で被害は限定されるが、`configmaps` と Pod のログは送信対象になりうる。
prompt injection の観点では、ログの内容は攻撃者が影響を与えうる入力である。
本評価は採点までを範囲とし、常用する場合はこの境界を改めて設計する。
