# Okteto CLI Evaluation Design

## Goal

Okteto の OSS CLI が EKS production cluster で使えるかを判定できる状態を作る。
判定に必要な操作は、クラスタで動いている Deployment をローカル作業ディレクトリと同期した開発コンテナに差し替え、保存した内容が即座に反映されることを確認し、元の Deployment に戻すまでの一巡である。

## Non-goals

- Okteto Platform の導入。Helm chart、license key、S3 バケット、wildcard DNS と証明書を必要とするため、評価の対象から外す
- `panicboat/monorepo` の復旧、および実アプリケーションへの適用
- 日常運用のための runbook 整備。採用を決めたあとに着手する

## Why the OSS CLI

「okteto」という名前は二つの製品を指す。

**Okteto CLI** は Apache-2.0 の OSS で、`okteto context`、`okteto up`、`okteto down` の三つのコマンドだけを持つ。
クラスタ側に何もインストールせず、kubeconfig があれば動く。
okteto manifest のうち `dev` セクションだけを解釈する。

**Okteto Platform** は商用の backend である。
Helm chart をクラスタに導入し、license key を必要とする。
IdP 認証、開発者ごとの namespace 払い出し、クラスタ内 buildkit によるリモート build、PR ごとの preview 環境、自動 SSL endpoint を提供する。

Platform を選ばない理由は、費用ではなく構成の重複と失効リスクにある。
Self-Hosted の Free Tier は license key 自体が無料で発行されるが、クラスタには NGINX Ingress を含む一式が入る。
この cluster はすでに aws-load-balancer-controller と Gateway API を持っており、ingress 層が二重化する。
加えて Free Tier の license は期限切れとともに全ログインが不能になる。

Platform が提供する機能のうち `okteto deploy` は Flux がすでに担っており、開発者ごとの namespace 払い出しは利用者が一人である現状で価値を持たない。
残るのは preview 環境とリモート build だが、どちらも CLI の評価を終えてから個別に判断できる。

## Repository conventions

この repo の Kubernetes 層は次の規約で動いている。
本設計はこの規約に従い、例外を作らない。

`kubernetes/components/<comp>/<env>/` が唯一の手書きソースである。
hydrate の対象は `helmfile.yaml` と `kustomization/` ディレクトリだけで、`namespace.yaml` は `00-namespaces/namespaces.yaml` に集約される。

`kubernetes/manifests/` は完全な生成物である。
PR 上で CI が hydrate して commit し返すため、手で編集しない。

`workflow-config.yaml` の `stack_conventions` に `kubernetes/components/{service}` があるため、新規 component は設定を追加せずに CI へ拾われる。

`dashboard` component が helmfile を持たず `kustomization/` だけで構成されている。
Helm chart を持たない sandbox もこの形に収まる。

## Changes across repositories

変更は三つの repo にまたがる。
それぞれ独立して適用でき、クラスタに影響するのは `platform` の変更だけである。

| repo | 変更 | 目的 |
|---|---|---|
| `ansible` | `roles/homebrew/tasks/main.yaml` のパッケージ配列に `okteto` を追加 | CLI をマシンセットアップに載せる |
| `dotfiles` | `.zshrc` に okteto の zsh completion を追加 | 補完。`kubectl` と同じ cache パターンに従う |
| `platform` | `kubernetes/components/sandbox/production/` を新規追加 | 差し替え対象の workload と、okteto manifest および同期対象ソース |

`okteto` は homebrew-core に formula があるため、tap の追加を必要としない。

## Sandbox component

```
kubernetes/components/sandbox/production/
├── namespace.yaml              # Namespace sandbox
├── kustomization/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── index.html              # configMapGenerator 経由で配信する cluster 版の内容
├── okteto.yml
└── app/
    └── index.html              # sync 対象のローカル版の内容
```

`okteto.yml` と `app/` を component 配下に同居させる。
`hydrate-component.sh` は `helmfile.yaml` と `kustomization/` しか読まず、`hydrate-index.sh` は `namespace.yaml` しか読まないため、これらは生成物に混入しない。
同居させる理由は、撤退がディレクトリの削除一回で完結することにある。

Deployment は Python 公式イメージの slim variant で `python -m http.server` を動かすだけの構成にする。
配信ディレクトリには ConfigMap 由来の `index.html` をマウントする。

この構成にすると、HTTP レスポンス一つで二つのことが同時に確認できる。
差し替え前は ConfigMap 版の内容が返り、`okteto up` のあとはローカルの `app/index.html` の内容が返って、編集するたびに変わる。
hot reload の仕組みもデータベースも必要なく、`kubectl port-forward` と `curl` だけで検証が閉じる。

Service は ClusterIP のみで、外部公開しない。
Ingress も証明書も不要になる。
resource requests は `cpu: 10m` と `memory: 32Mi` を置く。
静的ファイルを配信するだけのプロセスであり、cluster 全体で実使用量に合わせて requests を絞る方針に従う。

## Flux coexistence

`okteto up` は対象の Deployment を 0 replica にし、開発コンテナを持つ複製 Deployment を別名で作る。
Flux はこれを drift として検知し、reconcile のたびに元へ戻そうとする。
評価の中心はこの衝突を解けるかどうかにある。

Deployment に `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` を付ける。
この SSA policy は、リソースがクラスタに存在しないときだけ apply し、以後の drift 補正を行わない。

他の方法を採らない理由は次のとおりである。

Flux Kustomization の suspend は使えない。
root は `clusters/production` の単一 Kustomization であり、suspend すると platform stack 全体が止まる。

`ssa: Ignore` も使えない。
このポリシーは apply 自体を飛ばすため、差し替える対象の Deployment がそもそも作られない。

annotation を付けない選択は、`okteto up` が 0 replica にした直後に Flux が戻すため成立しない。

この annotation には副作用がある。
以後この Deployment の manifest を変更しても Flux は反映しない。
変更したいときは手で削除して再作成させる。
影響は sandbox 一つに閉じている。

`okteto up` が作る複製 Deployment は Flux の inventory に含まれないため、prune の対象にならない。
この点は検証手順 6 で実際に確認する。

## Verification

| # | 手順 | 期待 |
|---|---|---|
| 1 | ansible 適用後に `okteto version` | バージョンが出力される |
| 2 | PR マージ後に Flux が同期 | `kubectl -n sandbox get deploy sandbox` が Ready |
| 3 | `port-forward` して `curl` | ConfigMap 版の内容が返る |
| 4 | `okteto up` | 元の Deployment が 0 replica、複製が Ready。`curl` がローカル版を返す |
| 5 | ローカルの `app/index.html` を編集 | 再度の `curl` で即座に反映される |
| 6 | `flux reconcile kustomization flux-system` を二回実行 | 複製が生き残り、元の Deployment が 0 replica のまま |
| 7 | `okteto down` | 複製が消え、元の Deployment が Ready に戻る |
| 8 | component ディレクトリを削除して hydrate | orphan prune と Flux prune で namespace ごと消える |

成功基準は手順 6 が通ることである。
ここが落ちた場合、Flux 管理下の workload に okteto を使えないという結論になり、その事実自体が評価の成果になる。

## Rollback

`platform` の変更は検証手順 8 と同じ操作で撤回する。

`ansible` と `dotfiles` の変更は、それぞれパッケージ配列と `.zshrc` から該当行を削除するだけで戻る。
どちらもクラスタに影響しないため、`platform` の撤退と順序を揃える必要はない。

## Open items

実装時に実行して確認する。

- `okteto completion zsh` サブコマンドの有無。存在しない場合は `dotfiles` の変更を取り下げる
- `okteto.yml` の `dev` セクションの schema。`sync` の記法と `command` が配列か文字列かを確認する
- `okteto down` が sync 用 PVC を残すかどうか。残る場合は EBS の課金が継続するため、`okteto down -v` を撤退手順に含める
