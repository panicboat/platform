# OpenSRE Phase 1 Evaluation Design

## Goal

OpenSRE が production EKS cluster の障害を調査し、根本原因に到達できるかを採点できる状態を作る。
判定に必要な操作は、原因が既知の障害を sandbox に仕込み、OpenSRE に調査させ、出力されたレポートが仕込んだ原因を特定しているかを確認するまでの一巡である。

## Non-goals

- クラスタ内への OpenSRE デプロイ。理由は後述する
- Alertmanager receiver の設計、およびアラート駆動の自動調査。これ自体が独立した設計テーマであり、Phase 1 の採点結果を待って着手する
- remediation の実行許可。参照のみに限定する
- Postgres / Redis による永続化。CLI 単独動作に不要であることを確認済み

## What OpenSRE is

[Tracer-Cloud/opensre](https://github.com/tracer-cloud/opensre) は AI SRE エージェントを構築するための Apache-2.0 の framework である。
アラートを受け取り、観測データを集め、仮説を立て、ツールを叩いて検証し、根拠付きの原因分析レポートを出力する。
外部 LLM へ送る前に機密識別子をマスクする機構を持つ。

CLI は REPL を既定とし、`opensre onboard` で LLM provider と integration を設定する。
Postgres / Redis / サーバーを必要とせずローカル単独で動作する。

Public Alpha である。
README は「コアワークフローは初期探索には使えるが、まだ安定していない。API と統合は変わりうる」と明記している。

## Why local CLI, not in-cluster

version 体系は `v0.1.YYYY.M.D` で、リリースはほぼ毎日行われている。
2026-08-01 から 2026-08-10 までの 10 日間に 9 つのタグが打たれた。

この速度の成果物を Flux 管理下の常駐サービスに置くと、更新追従が恒常的な運用負担になる。
ローカル CLI に留めれば撤退は `brew uninstall` で完結し、クラスタ側に何も残らない。

判断が逆転する条件は Phase 2 で扱う。
アラート駆動の無人調査を行うには常駐プロセスが要るため、そこで改めて配置を設計する。

## Phase structure

最も不確実なものを最初に潰す順序で組む。

| | 内容 | `platform` の変更 | 潰す不確実性 |
|---|---|---|---|
| Phase 0 | CLI を導入し `opensre onboard` で Bedrock を設定。クラスタには接続せず LLM 疎通のみ確認 | なし | alpha の Bedrock 実装が機能するか |
| Phase 1 | 専用 read-only 権限と故障 sandbox を作り、調査レポートを採点 | あり | 自クラスタに対する推論品質 |
| Phase 2 | Alertmanager receiver 整備とアラート駆動調査 | 別 spec | — |

Phase 0 は `ansible` 側の CLI 導入だけを伴い、クラスタにも `platform` にも触れない。

Phase 0 を先に置く理由は、Bedrock 対応が壊れていた場合に IAM stack と sandbox の作業が無駄になるためである。
Phase 0 が落ちた時点で評価を終了する。

## Why Bedrock

OpenSRE の `.env.example` は Bedrock について次のように記述する。

```
# Amazon Bedrock — set `LLM_PROVIDER=bedrock` above. Uses the same AWS
# credential chain as the AWS integration block below (region, keys, or IAM
# role). No LLM API key.
BEDROCK_REASONING_MODEL=
BEDROCK_CLASSIFICATION_MODEL=
BEDROCK_TOOLCALL_MODEL=
```

`AWS_ROLE_ARN` が第一級の設定項目であるため、後述の専用 role をそのまま推論にも使える。
長期有効な API key をどこにも保管しない構成が成立する。
cluster のログと設定が AWS の外へ出ないことも、この選択で担保される。

model は推論用・分類用・ツール呼び出し用の三つに分かれており、用途ごとに異なる model を割り当てられる。

## Permission design

`aws/eks/modules/access_entries.tf` は EKS の組み込み access policy で IAM principal を Kubernetes RBAC へマップしている。
この形に read-only の principal を一つ足す。ClusterRole を自作しない。

```
aws/eks/modules/
├── iam_admin.tf        # 既存: eks_admin role
├── iam_opensre.tf      # 追加: opensre_investigator role
└── access_entries.tf   # 既存 locals に opensre エントリを追加
```

`opensre_investigator` role が持つ権限は三つである。

| 用途 | 付与内容 |
|---|---|
| クラスタ参照 | EKS access entry で `arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy` を cluster scope で関連付け |
| kubeconfig 取得 | `eks:DescribeCluster` |
| 推論 | `bedrock:InvokeModel` と `bedrock:InvokeModelWithResponseStream`。resource に model ARN を明示列挙する |

信頼ポリシーは admin identity からの assume のみを許可する。
OpenSRE へは `AWS_ROLE_ARN` として渡す。

model ARN をワイルドカードにしない理由は、Bedrock の課金が model ごとに大きく異なるためである。
設定ミスで高価な model を呼んでも、IAM 側で止まる。

`access_entries.tf` の既存コメントが記録している落とし穴に従う。
EKS access policy の ARN は `arn:aws:eks::aws:cluster-access-policy/<NAME>` 形式であり、IAM managed policy 形式を渡すと `AssociateAccessPolicy` が 400 を返す。

`AmazonEKSViewPolicy` が Secret の読み取りを除外するかは実装時に検証する。
除外していない場合は自前の ClusterRole へ切り替える。

### Grafana access

OpenSRE は metrics / logs / traces を Grafana の datasource proxy 越しに読む。
Prometheus 専用の設定項目は存在しない。

```
GRAFANA_READ_TOKEN=
GRAFANA_INSTANCE_URL=
GRAFANA_LOKI_DATASOURCE_UID=
GRAFANA_TEMPO_DATASOURCE_UID=
```

この cluster の Grafana は `auth.proxy` モードで oauth2-proxy と連携し、`X-Forwarded-User` header から user を auto-create する。
`auto_assign_org_role` は `Admin` である。

公開経路から接続すると oauth2-proxy が Google ログインへリダイレクトし、token 認証が成立しない。
`kubectl port-forward` で Grafana Service に直結し、`Viewer` role の service account token を使う。
新たな公開経路を作らないため、証明書も DNS も不要になる。

service account は Grafana UI から手動で発行する。
kube-prometheus-stack の values に service account を宣言する経路が無く、評価のために provisioning 機構を持ち込む価値が無いためである。
撤退は UI からの削除で完結する。

## Sandbox component

`sandbox` namespace に二つの Deployment を置く。

```
kubernetes/components/sandbox/production/
├── namespace.yaml              # Namespace sandbox
└── kustomization/
    ├── kustomization.yaml
    ├── backend.yaml            # Deployment + Service
    └── frontend.yaml           # Deployment
```

`backend` は python 公式イメージの slim variant で `http.server` を動かす。
memory limit を実使用量の直上に設定し、起動後に段階的にメモリを確保させて OOMKilled に至らせる。
結果として CrashLoopBackOff に入り、Service の Endpoints が空になる。

`frontend` は一秒ごとに backend の Service を叩き、結果を stdout へ出す。
backend が落ちている間、接続エラーがログに出続ける。

どちらも ClusterIP のみで外部公開せず、volume を持たない。
配信内容も起動コマンドが生成し、ConfigMap を使わない。

resource requests は `cpu: 10m` を置く。
memory requests は backend の OOMKill を成立させる値を実装時に決める。

### Why two workloads

症状と根本原因の間にホップを作るためである。

単一 Pod が落ちるだけの構成では `kubectl get pod` 一回で原因が判明し、エージェントの調査能力を測ったことにならない。

| 層 | 観測される事象 | 痕跡の所在 |
|---|---|---|
| 症状 | frontend のログに接続エラーが出続ける | Loki |
| 中間 | backend の Endpoints が空 | Kubernetes API |
| 根本 | backend が memory limit 超過で OOMKilled | Event / restart metric / container memory (Mimir) |

三層すべてが異なるデータソースに痕跡を残す。
Kubernetes API だけを見て答えに到達できない構成にすることで、観測基盤との統合そのものを評価対象に含める。

## Flux coexistence

okteto 評価で使った `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` は使わない。
Deployment をローカルへ差し替える操作が無く、Flux に drift 補正させたままでよいためである。

sandbox は Flux の管理下に置き、manifest の変更が通常どおり反映される状態を保つ。

## Verification

| # | 手順 | 期待 |
|---|---|---|
| 1 | ansible 適用後に `opensre` を起動 | REPL が起動し `/status` が応答する |
| 2 | `opensre onboard` で `LLM_PROVIDER=bedrock` を設定し REPL で任意の質問 | Bedrock から応答が返る。ここが落ちたら評価終了 |
| 3 | terragrunt apply 後に `aws sts assume-role` | `opensre_investigator` を引き受けられる |
| 4 | 引き受けた credential で `kubectl get pod -A` | Pod 一覧が返る |
| 5 | 同 credential で `kubectl get secret -A` | 拒否される |
| 6 | PR マージ後に Flux が同期 | `kubectl -n sandbox get deploy` に frontend が Ready、backend が CrashLoopBackOff |
| 7 | `kubectl -n sandbox logs deploy/frontend` | 接続エラーが継続的に出力される |
| 8 | Grafana へ port-forward し `GRAFANA_READ_TOKEN` で datasource proxy を叩く | Mimir / Loki のクエリが通る |
| 9 | `opensre` に sandbox の異常調査を指示 | レポートが出力される |
| 10 | component ディレクトリを削除して hydrate | orphan prune と Flux prune で namespace ごと消える |

### Grading criteria

手順 9 のレポートを次で採点する。

合格は、根本原因を backend の memory limit 不足による OOMKill と特定し、その根拠として観測データを引用していることである。

次のいずれかに該当した場合は不合格とする。

- 「frontend にエラーが出ている」という症状の記述で止まる
- ネットワーク障害や DNS 障害と誤診する
- backend の CrashLoopBackOff に言及するが、memory limit と結びつけない

手順 5 が落ちた場合は `AmazonEKSViewPolicy` の想定が誤っていたことを意味する。
自前の ClusterRole へ切り替えたうえで手順 4 と 5 を再実行する。

## Changes across repositories

変更は二つの repository にまたがる。

| repository | 変更 | 目的 |
|---|---|---|
| `ansible` | homebrew role に tap `tracer-cloud/tap` と `opensre` を追加 | CLI をマシンセットアップに載せる |
| `platform` | `aws/eks/modules/` に role と access entry、`kubernetes/components/sandbox/production/` に故障 workload | 権限と評価対象 |

`okteto` と異なり homebrew-core に formula が無いため、tap の追加が要る。

## Rollback

| 対象 | 手順 |
|---|---|
| sandbox | ディレクトリを削除して hydrate。検証手順 10 と同一 |
| IAM role / access entry | `iam_opensre.tf` を削除し `access_entries.tf` から該当エントリを外して apply |
| Grafana token | Grafana UI から service account を削除 |
| CLI | `brew uninstall opensre` |

クラスタに恒久的な変更は残らない。

## Risk

`aws/eks` は cluster の中核 stack である。
評価目的の変更をここへ入れる以上、apply の失敗は cluster 全体に影響しうる。

それでもこの配置を採る理由は、access entry の定義が `aws/eks/modules/` 内にあり、他所へ置けないためである。
role だけを別 stack へ切り出すと access entry と分離し、撤退時に二箇所を同期させる必要が生じる。

## Repository conventions

この repo の Kubernetes 層は次の規約で動いている。本設計はこれに従う。

`kubernetes/components/<comp>/<env>/` が唯一の手書きソースである。
hydrate の対象は `helmfile.yaml` と `kustomization/` だけで、`namespace.yaml` は `00-namespaces/namespaces.yaml` に集約される。

`kubernetes/manifests/` は完全な生成物であり、CI が hydrate して commit し返す。

`workflow-config.yaml` の `stack_conventions` が `kubernetes/components/{service}` と `aws/{service}` を持つため、新規 component は設定を追加せずに CI へ拾われる。

`dashboard` component が helmfile を持たず `kustomization/` だけで構成されている。
Helm chart を持たない sandbox もこの形に収まる。

## CLI details

確認した仕様を記録する。

install は `brew tap tracer-cloud/tap && brew install tracer-cloud/tap/opensre` で行う。
`curl | bash` 形式の installer も提供されるが、これは main の rolling build を取得するため採らない。
tap 経由なら version が tag に固定される。

`opensre` は引数なしで REPL を起動する。
slash command として `/help`、`/status`、`/cost`、`/sessions`、`/resume`、`/new`、`/integrations list`、`/agents`、`/exit` を持つ。
`/cost` があるため、評価中の LLM 課金を CLI 内で確認できる。

`opensre investigate -i <file>` は alert JSON を入力として一回だけ調査する。
`opensre integrations setup` が Kubernetes / Grafana などの接続設定を対話的に行う。

Kubernetes 接続は `KUBECONFIG`、`KUBECONFIG_CONTEXT`、`KUBECONFIG_NAMESPACE` で設定する。
kubeconfig を渡す汎用方式であり、EKS 固有の設定項目は無い。

## Evaluation result

判断: **現時点では採用しない。** ただし本設計が測ろうとした「自クラスタのテレメトリに対する推論品質」は測れていない。macOS 配布物が調査を実行できず、評価対象が成立しなかったためである。

### 何が起きたか

`v0.1.2026.8.12` の darwin-arm64 配布物には、独立した 3 つのパッケージング不具合がある。いずれも upstream 側の問題で、本 repo の設定に起因しない。

| # | 不具合 | 症状 |
|---|---|---|
| 1 | homebrew formula の install block が実行ファイルしか配置しない | PyInstaller onedir バンドルの `_internal/`（4882 エントリ）が捨てられ、`dlopen` が `_internal/Python` を見つけられず起動しない |
| 2 | 同梱 `Python.framework` と 110 個の Mach-O の ad-hoc 署名が不正 | 「code has no resources but signature indicates they must be present」。macOS がロードを拒否し SIGKILL（exit 137） |
| 3 | 調査用ツールモジュールがバンドルに含まれていない | `integrations.kubernetes.tools` 等がバンドル内に存在しない。動的 import の hidden-import 漏れと見られる |

1 は formula 自身の `test do` が `opensre --version` の成功を assert しているため、CI で `brew test` を回していれば検出できた。2 は `v0.1.2026.8.10` にも存在し、単発の回帰ではない。vendor 自身の installer も 2 を検知して中断する。

1 と 2 は全 Mach-O を ad-hoc 再署名すれば回避でき、実際に `opensre --version` / `doctor` / `investigate` は動作した。3 は回避できない。

### 3 の帰結

`integrations verify` は kubernetes / grafana とも `✓ passed` を返す。credential は正しく、`namespace 'sandbox' accessible` まで確認できる。それでも調査は次のようになる。

```
No tools available for investigation
  ● Loading integrations  0ms   kubernetes, grafana_local
  ● Investigation        48.6s  evidence:0 messages:2
```

integration はロードされるがツールが 0 件で、48.6 秒かけて証拠を 1 つも集めない。レポート自身が「No live tool calls could be made — all verification must be performed manually by the on-call engineer」と述べ、`kubectl get pods` すら実行しない。

つまりこの配布物で測れるのは「アラート文面だけから何を推測できるか」であって、観測基盤との統合ではない。

### 採点

参考として、上記の制約下でのレポートを Grading criteria に照らす。

> The most probable cause is that backend pod(s) are not running (CrashLoopBackOff, **OOMKilled**, or scaled to zero) **or** the Kubernetes Service has no healthy endpoints due to a selector or targetPort mismatch

仕込んだ原因を複数候補の一つとして挙げたが特定しておらず、観測データの引用も無い。`validity_score` は自己申告 0.55。「backend の CrashLoopBackOff に言及するが memory limit と結びつけない」に該当し**不合格**である。

ただしこれは推論能力の評価ではない。アラート文面だけを与えられた条件では、この程度の仮説列挙は妥当な出力とも言える。

### 副次的な観測

- **テレメトリを既定で収集する。** `~/.opensre/posthog_events.txt` に CLI バージョン、OS、`composite_fingerprint`（host / platform / user のハッシュ）、`llm_provider`、session_id、investigation のループ回数を記録する。クラスタ名・namespace・アラート内容は含まれない
- **エラーハンドリングが粗い。** 不正な model ID を渡すと例外が処理されずプロセスごと落ちる
- **非対話での駆動は可能。** `investigate --input-json` / `-o` / `--evaluate`、`-y` / `--no-interactive` / `-j` がある。integration 設定だけは対話ウィザードだが stdin パイプで駆動でき、`~/.opensre/integrations.json` を直接編集してもよい
- **kubeconfig は inline YAML でのみ成立する。** `kubeconfig_path` 方式は保存できても検証を通らない
- **更新のたびに 110 ファイルの再署名が要る。** ほぼ日次リリースと合わせると運用負荷は無視できない

### Bedrock 側の結果

Bedrock 連携そのものは機能した。`AWS_ROLE_ARN` を使わず、専用 role の credential で直接実行して推論が通る。不正な model ID が HTTP 400 を返すことで、設定した model が実際に使われていることを確認した。

この account では Opus tier と 5 世代が未有効で、利用可能な最上位は Sonnet 4.6 だった。`list-inference-profiles` は付与されていない profile も `ACTIVE` と報告するため、判定には invoke が要る。

### 権限設計の結果

`AmazonEKSViewPolicy` が Secret を除外するという未確認の仮定は正しかった。Pod は 94 件読め、`secrets` は Forbidden になる。自前 ClusterRole への切り替えは不要である。

### 次にやるなら

推論品質の評価をやり直すには、PyInstaller バンドルを避けてソースから導入する必要がある。パッケージング不具合 3 件を一度に回避でき、ツールモジュールも揃う。

再評価しない場合は、`aws/eks` の role と access entry、および sandbox component を撤去する。撤退手順は Rollback にある。
