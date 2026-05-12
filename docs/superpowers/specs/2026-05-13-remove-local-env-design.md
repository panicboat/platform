# Local Environment Removal

## Goal

`kubernetes/` から local 環境（k3d 前提の構成）を削除し、`production` EKS だけを扱う構造にする。

## Problem

`kubernetes/clusters/`, `kubernetes/components/`, `kubernetes/manifests/` の各階層に `local/` と `production/` が並んでおり、コンポーネント有無の不一致が「どのクラスタに何が実際に入っているか」の判別を困難にしている。

現状の内訳（`components/` 配下 22 component）:

- production のみ: 11 (aws-load-balancer-controller, cert-manager, external-dns, external-secrets, karpenter, keda, metrics-server, mimir, nginx-sample, oauth2-proxy, reloader)
- local のみ: 2 (coredns, fluent-bit)
- 両方: 9

local と production は同名 component でも構成が異なる別物（例: loki/mimir/tempo は production が S3 backend、local が local PVC backend）。当初 local は k3d クラスタへ実 apply して動作確認するための環境だったが、production EKS の整備が進みローカル試打が不要になった。

## Scope: Delete

- `kubernetes/clusters/local/`
- `kubernetes/components/*/local/`（11 ディレクトリ）
- `kubernetes/manifests/local/`
- `kubernetes/Makefile`（全削除）
- `kubernetes/helmfile.yaml.gotmpl` の `local:` environment block と `cluster.isLocal` value

  `isLocal` は `components/` 配下で参照ゼロ（`grep -rn 'isLocal' kubernetes/components/` で 0 hit）のため production 側からも除去する。

- `kubernetes/README.md` の local 関連章（k3d セットアップ、`*.local` ホスト名、phase1-4、`make ENV=local` 等の記述）
- `workflow-config.yaml` の `local` environment entry（CI が deploy-trigger 時にこの env を読み、`components/*/local/` を hydrate しに行こうとするため、削除しないと CI が壊れる）

## Hydrate Logic Migration

`Makefile` の hydrate ターゲット 3 つ（`hydrate-component`, `hydrate-index`, `hydrate`）は現状 CI でのみ使用されているが、ローカルからの手動実行手段を保つため bash script として切り出す。

新規ファイル:

```
scripts/
└── kubernetes-hydrate/
    ├── hydrate-component.sh   # 引数: <component> <env>
    └── hydrate-index.sh       # 引数: <env>
```

旧 `hydrate` ターゲット（全 component 一括 hydrate）は `reusable--kubernetes-hydrator.yaml` 内の bash loop に既に存在するため script 化しない。

## CI Workflow Update

`.github/workflows/reusable--kubernetes-hydrator.yaml` の以下を新 script の呼び出しに置換する。

- `make -C kubernetes hydrate-component COMPONENT="$svc" ENV="${{ inputs.environment }}"`
  → `bash scripts/kubernetes-hydrate/hydrate-component.sh "$svc" "${{ inputs.environment }}"`
- `make -C kubernetes hydrate-index ENV=${{ inputs.environment }}`
  → `bash scripts/kubernetes-hydrate/hydrate-index.sh "${{ inputs.environment }}"`

## scripts/ Directory Convention

本 PR で `scripts/` を新規導入するため、命名規約を確立する。

### Rule

全 script を `scripts/<purpose>/` 配下に配置する。

- `<purpose>` は `<domain-hint>-<action>` または `<action>` のいずれか
  - 例: `scripts/kubernetes-hydrate/`
  - 例: `scripts/eks-lifecycle/`（別 plan で予定）
- 単一 domain / 複数 domain を問わず一律 purpose-first

### Why

domain-first（`<domain>/scripts/`）ではなく purpose-first を採る理由:

- すべての script が `scripts/` 配下に集約され、探索の入り口が 1 箇所に揃う
- cross-domain script と single-domain script が同じ階層で並び、粒度の混在がない
- domain ディレクトリ（`kubernetes/`, `aws/`）が宣言的なもの（manifest, IaC）だけになり、how-to-operate と分離される
- domain-first だと cross-domain script だけが repo root の `scripts/` に浮き、粒度が不揃いになる

## Operations after Removal

- 動作確認は production EKS cluster への deploy で行う（k3d でのローカル試打は廃止）
- hydrate の検証は CI（`reusable--kubernetes-hydrator.yaml`）に一本化
- 「production に入れる前のお試し」は PR ベースで CI hydrate diff を確認

## Out of Scope

- `clusters/`, `components/`, `manifests/` の production 側構造変更
- 既存 production component の values 修正
- README.md の production 部分のリライト（local 章の削除以外は触らない）
- `scripts/eks-lifecycle/60-flux-bootstrap.sh` の実装（別 plan）

## Verification

- `git grep -nE 'k3d|isLocal' kubernetes/` で hit ゼロを確認（k3d と `isLocal` は local 環境固有のため全削除されるべき）
- `git grep -n 'local' kubernetes/` の hit を目視確認し、k3d / local 環境への参照が残っていないこと、および production の説明文中の一般用語（"local PVC" 等）のみであることを確認
- CI で `reusable--kubernetes-hydrator.yaml` が production 環境に対して成功することを確認
- `bash scripts/kubernetes-hydrate/hydrate-component.sh <comp> production` を手元で実行し、`kubernetes/manifests/production/<comp>/manifest.yaml` が生成され、既存ファイルと内容差分ゼロ（= 移行による振る舞いの変化なし）であることを確認
