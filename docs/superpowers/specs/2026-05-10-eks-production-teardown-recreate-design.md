# EKS Production: Teardown + Recreate Lifecycle

> **Phase**: Phase 5 closure 後 (= roadmap Phase 5 完了後) の運用機能追加。
>
> **Nature**: 手元 shell から `make eks-teardown ENV=production` / `make eks-recreate ENV=production` で **temporary 削除と冪等な再作成** を行う lifecycle 機構の design spec。
>
> **Goal**: panicboat 個人運用 cluster `eks-production` を temporarily 削除して NAT gateway / EC2 / EBS 課金を完全停止できる経路を作る。再作成は同じ cluster 名で冪等に実行でき、AWS Secrets Manager service の secret 値（manual 管理）と route53 hosted zone は teardown / recreate 経由でも残ることを保証する。

---

## 0. Errata (post-implementation revision)

PR #326 (Phase 2) 実装時に CI で fail し、本 spec の **hydrate-time exec 案 (= §3 Decision 7 / §5 Phase 2 / §8 Q2 で記述) は採用不可** であることが判明した。

### 不採用の理由

- 現 CI flow (= `gruntwork-io/terragrunt-action@v3.2.0` ベース) は **PR-time に hydrate / plan、merge 後に apply** という ordering
- `{{ exec terragrunt output -raw <name> }}` を helmfile に書くと、新規 output (= `cluster_endpoint_hostname`) が **PR-time の state に未反映**で `Output not found` で fail
- IRSA rotation も同様に、PR-time hydrate は OLD 名を読んでしまい、apply 後 (= rotation 完了後) には manifest と実 role 名が乖離

### 採用した設計 (= 本 spec の Phase 2 / Phase 3 を以下で読み替え)

| 値 | 性質 | 取り扱い |
|---|---|---|
| `albControllerRoleArn` / `externalDnsRoleArn` | Phase 2 で deterministic 化 (= recreate 後も同名) | `helmfile.yaml.gotmpl` に **hardcoded literal** を NEW 名で書く (= IRSA naming 変更と同一 PR で atomic)、`# STABLE` marker 付与 |
| `nodeRoleName` (Karpenter) | 同上 | 同上 |
| `interruptionQueueName` | 既に deterministic | 変更なし、`# STABLE` marker 付与 |
| `eksApiEndpoint` | cluster 作成のたびに変化 | hardcoded、`# RECREATE: <command>` marker 付与 (= PR #330)、Phase 3 lifecycle script で operator が手動更新 |
| `vpcId` | VPC 作成のたびに変化 | 同上 |

### Phase 3 lifecycle script の手法選択

`# RECREATE:` marker (= PR #330) の処理について、3 案を検討:

1. **hydrate-time exec** (= 当初 spec): CI ordering で破綻 (= PR #326 で実証)、不採用
2. **lifecycle script が sed で自動置換** (= 中間案、commit `d3ba15f` で plan 反映): pattern 依存度が高く誤置換リスク、PR #326 audit 漏れの反省を踏まえ不採用
3. **Plan A: operator-prompted manual updates** (= 最終採用): script は marker を grep して列挙、operator が手で edit、y/N で進行

### 本 spec の以下の記述は読み替え

- §3 Decision 7: 「hydrate-time substitution」を「deterministic naming + RECREATE marker convention + Phase 3 operator-prompted manual update」と読み替え
- §5 Phase 2: aqua / hydrate workflow 拡張は **撤回**。helmfile は exec ではなく hardcoded NEW 値、`# RECREATE:` / `# STABLE:` marker 付与
- §5 Phase 3 60-flux-bootstrap.sh: **operator-prompted step を採用** (= grep '# RECREATE:' → 列挙して提示 → operator が手で edit → y/N → hydrate → commit + push)
- §8 Open Q2 (CI hydrate workflow に terragrunt + AWS auth): 不要、closed

### Phase 2 incident の学び (= 2026-05-10)

PR #326 apply 時、`kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml` の hardcoded `role: Karpenter-eks-production-2026...` が更新漏れで、IRSA rotation 後に EC2NodeClass が削除済 OLD role を参照する状態に。新規 NodeClaim の EC2 instance が bootstrap できず cluster 一時 degraded。PR #332 の hot-fix で復旧。

**反省点と Phase 3 反映**:
- audit pass scope を `kubernetes/components/*/production/` の helmfile.yaml だけでなく **kustomization/*.yaml も含む全 source file** に拡張
- Phase 3 の `60-flux-bootstrap.sh` の grep は `kubernetes/helmfile.yaml.gotmpl` + `kubernetes/components/` 配下全体を対象とする (= helmfile / kustomize の経路差異に関わらず marker 捕捉)
- IRSA rotation で running EC2 instance のクレデンシャルが失効する **構造的問題** は別 spec 化を検討 (= node IAM role 変更時は instance profile の段階的更新が必要、本 lifecycle の scope 外)

詳細は `docs/superpowers/plans/2026-05-10-eks-production-teardown-recreate.md` の Errata 節を参照。

---

## 1. Goals

1. `eks-production` cluster とその周辺 AWS stack を、手元 1 コマンドで temporary 削除できる
2. 同じ cluster 名で同じ cluster を、手元 1 コマンドで冪等に再作成できる
3. teardown 中の AWS 課金を NAT gateway 含めて停止する（hosted zone $0.50/月 程度の極小残置を除く）
4. teardown / recreate を **何度実行しても安全**（partial state からの再 run が冪等）
5. recreate 後は roadmap Phase 1〜5 の全コンポーネントが Ready になり、Phase 5 で確立した end-to-end checklist を再び満たす

## 2. Non-goals (Out of scope)

- `develop` 環境の teardown / recreate（`workflow-config.yaml` 上は active だが cluster 未作成）
- `local` 環境（k3d cluster、AWS 非依存）への適用
- CI / GitHub Actions からの自動 trigger（手元 Makefile / shell script のみ）
- `workflow-config.yaml` の schema 拡張（enabled flag 等）
- panicboat/deploy-actions の修正
- AWS Secrets Manager service の secret 値の terragrunt 化
- VPC / cluster destroy 中も storage を保つ「データ永続化」設計（teardown は完全消去、recreate は new cluster）
- recreate 時のロールバック（前進復旧のみサポート）
- 別 region / 別 account への migration

## 3. Architecture decisions

### Decision 1: Trigger は手元 Makefile / shell script のみ

`make eks-teardown ENV=production` / `make eks-recreate ENV=production` を repo root の `Makefile` から発火。CI / GitHub Actions は使わない。

- 採用理由:
  1. 操作者 = panicboat 個人 (= 1 人) で、手元の IAM principal で `sts:AssumeRole` を回せる前提が既に揃っている (= `aws/eks/README.md` の手元 destroy 手順と同経路)
  2. teardown 中に hang した resource (= ENI 残骸 / Karpenter ノード drain timeout / S3 bucket 中身) を **対話的に診断 → 手動介入** する場面が頻発しやすく、CI 上では debug ループが遅い
  3. temporary 削除 cycle 数が限定的 (= panicboat 個人運用、Phase 5-3 rationale で「cost optimization の effective benefit 小」と user 自身が記述) で、CI 化の amortization が効きにくい
- トレードオフ:
  1. 実行記録が手元に閉じる (= GitHub Actions log のように残らない)。個人運用なら問題小
  2. 操作者の手元に AWS apply role assume 権限と `tofu` / `terragrunt` / `kubectl` / `flux` / `jq` / `aws` CLI が必要
- 退けた選択肢:
  - **GitOps switch (workflow-config.yaml flag)**: PR merge した瞬間に production が destroy される sharp さ + panicboat/deploy-actions への侵襲で却下
  - **GitHub Actions workflow_dispatch**: hang 時の debug 反復が「commit → run → wait」になり teardown のような対話的操作に不向き

### Decision 2: 削除スコープは EKS 専用 stack に限定、共通インフラは残す

| Stack | 方針 | 理由 |
|---|---|---|
| `aws/eks` / `karpenter` / `eks-secrets` / `eks-logs` / `eks-metrics` / `eks-traces` | **destroy** | EKS 専用 |
| `aws/alb` (ACM wildcard cert `*.panicboat.net`) | **destroy** | EKS Ingress 専用 cert、scope の対称性優先 |
| `aws/vpc` | **destroy** | NAT gateway $30/月削減、subnet ID は recreate 時に lookup module で透過追従 |
| `aws/route53` | **残す** | EKS 非依存の共通インフラ (panicboat.net hosted zone $0.50/月) |
| `aws/github-oidc-auth` / `ai-assistant` / `cost-management` | **残す** | EKS 非依存 |
| `kubernetes/clusters/production/` | **残す** | git 上、cluster destroy で reconcile 対象が消えるだけ |
| `kubernetes/manifests/production/` | **残す** | git 上、recreate 後の Flux reconcile 対象 |
| `workflow-config.yaml` の `production` env | **残す** | `aws/*/envs/production/` ディレクトリ自体は削除しないため、CI は通常通り動作 |

退けた選択肢:
- **VPC を残す**: NAT gateway $30/月の課金が残り、temporary 削除のコスト効果が半減
- **ACM cert だけ残す**: scope の対称性が崩れる、cert 自体は無料、DNS validation 待ちは recreate 全体時間に対し相対小

### Decision 3: AWS Secrets Manager service の secret 値だけ残す（terragrunt 管理外として明示）

`aws/eks-secrets` stack は **IRSA + Pod Identity Association** のみ管理しており、AWS Secrets Manager service の secret 値そのものは terragrunt 管理外（手動管理）。teardown で `aws/eks-secrets` を destroy しても secret 値は AWS service 上に残るため、recreate 後に新 ESO が同じ secret 値を参照できる。

- 採用理由: secret 値の手動再投入を避ける、recreate 後の application Pod 起動を speedy に保つ
- 前提: secret 値は **panicboat 個人運用で手動管理されている前提** が成立する範囲でのみ有効。multi-team / IaC 完備運用には不向き
- recreate 後の検証は本 spec の success criteria に含む (= 6.4)

### Decision 4: 削除順序を script に hardcode、terragrunt run-all は使わない

`30-destroy-stacks.sh` / `50-apply-stacks.sh` 内で 8 stack を **固定順** で `terragrunt destroy` / `apply`。terragrunt の `dependency` block を新規追加して `run-all` で順序解決する案は採用しない。

- 採用理由:
  1. 既存 stack 設定 (`aws/*/envs/production/terragrunt.hcl`) への侵襲を避ける（CLAUDE.md "Surgical Changes" 原則）
  2. `run-all destroy` は失敗 stack を skip して他を続行する挙動 (= terragrunt version による) があり、partial state を増やすリスク
  3. 順序 hardcode は変更頻度が低い (= 8 stack 構成が頻繁に増減しない)
- トレードオフ: 新 stack 追加時に script の順序定義に手を入れる必要

### Decision 5: AWS API fallback / orphan resource 強制削除は組み込まない

teardown / recreate の失敗時、script は **fail fast** + **診断メッセージ出力** + **exit 1** で止まる。AWS API 直叩きでの orphan resource (= ENI / EBS / target group / SG) 強制削除 fallback は実装しない。

- 採用理由:
  1. panicboat 個人運用 + 手元実行 + 緊急介入できる前提 → autonomous fallback 投資は YAGNI
  2. 強制削除は terragrunt state file との不整合を生むリスク → 後続 recreate で「既に消えてる」誤判定の origin
- トレードオフ: hang 時の人間介入コスト ↑（spec 6.5 で前進復旧 only と明示）

### Decision 6: 削除順序の対称性で recreate 順を決める

teardown は **依存される側を後で消す** 順、recreate は **依存する側を先に作る** 逆順。

- teardown: karpenter → eks-secrets → eks-logs/metrics/traces → eks → alb → vpc
- recreate: vpc → alb → eks → karpenter → eks-secrets → eks-logs/metrics/traces

ALB stack (= ACM cert) の依存関係は **route53 hosted zone のみ** (= 残置 stack で常時可用)。EKS / VPC とは independent。recreate 時の position は cert validation の完了 (= 5〜10 分) を Phase 1 Ingress reconcile 開始前に確実に終わらせる目的で **vpc 直後**。terragrunt apply は sequential のため EKS 起動と時間 overlap はしない（別途 parallelize する設計はしない、§5.3 で再考しない）。

### Decision 7: ハードコード値の clean up と S3 force_destroy を spec に含める

`kubernetes/helmfile.yaml.gotmpl` 等に直書きされた **cluster 固有値** (= eksApiEndpoint / vpcId / IRSA role ARN with timestamp suffix / Karpenter node role name with timestamp suffix) が recreate を破壊する。また `aws/eks-{logs,metrics,traces}/modules/main.tf` の S3 bucket は `force_destroy` が無く destroy が hang する。本 spec は teardown / recreate script (= Phase 3) に加え、これらの clean up を **Phase 1 (S3 force_destroy)** + **Phase 2 (deterministic naming + hydrate-time substitution)** として包含する。

- 採用理由: prerequisites を別 spec に切り出すと依存関係が見失われ、PR 順序の miss コミュニケーションが発生する
- トレードオフ: spec の長さと PR 数が増える（3 PR 順次 merge）
- Phase の境界: Phase 1 = attribute-only 変更 (= terraform 上の `force_new = false`、resource recreate なし)。Phase 2 = IRSA role の destroy → create + helmfile 値の hydrate 経由切替を atomic で行う変更

詳細: §5 参照。

## 4. Architecture overview

### 4.1 Boundary

- **Lifecycle script の責務**: 削除・再作成の **順序制御** と **k8s 側 cleanup / AWS 側 orphan verify** のみ
- **Lifecycle script の非責務**: stack 内部の terraform module 修正、Renovate / EKS version 管理、CI/CD pipeline 改造、AWS Secrets Manager service の secret 値の生成

### 4.2 実行 model

1. 操作者が手元 shell から `make eks-teardown ENV=production` または `make eks-recreate ENV=production` を打つ
2. script は内部で `github-oidc-auth-production-github-actions-apply-role` と `eks-admin-production` を assume → AWS credentials を export → kubeconfig 更新
3. 各 stack `terragrunt destroy/apply` を順次呼ぶ。順序は script に hardcode
4. step 失敗時は **fail fast**、診断メッセージ出力 + 同じ subtarget で再 run 可

### 4.3 前提

- 操作者が `sts:AssumeRole` で `github-oidc-auth-production-github-actions-apply-role` を assume できる IAM principal を持っている (= 既存の `aws/eks/README.md` 手元 destroy 手順と同条件)
- `eks-admin-production` role も assume 可能（k8s cleanup 用）
- `tofu` / `terragrunt` / `kubectl` / `flux` / `jq` / `aws` CLI が installed

### 4.4 Scope 境界

- `ENV=production` のみ対象。script 冒頭で `ENV` の値を検証し、production 以外なら exit 1
- AWS region は `aws/eks/envs/production/env.hcl` から動的取得 (`ap-northeast-1`)

## 5. Phases

本 spec は 3 phase の順次実装を要求する。各 phase は独立 PR で merge され、後段 phase の前提となる。

### Phase 1: S3 force_destroy

#### Phase 1 で行う module changes

| Module | 変更 | 影響 |
|---|---|---|
| `aws/eks-logs/modules/main.tf` の S3 bucket resource | `force_destroy = true` 追加 | terragrunt destroy が bucket 内オブジェクトを自動削除 |
| `aws/eks-metrics/modules/main.tf` の S3 bucket resource | 同上 | 同上 |
| `aws/eks-traces/modules/main.tf` の S3 bucket resource | 同上 | 同上 |

Phase 1 はリソース recreate を伴わない attribute 変更のみ (= `force_destroy` は terraform 上 `force_new = false` の attribute)。terragrunt apply は state 上の attribute 更新だけで完了し、cluster 上の running pod に影響しない。

#### Phase 1 の retrofit 検証

- `grep -A2 "aws_s3_bucket\b" aws/eks-logs/modules/main.tf` → `force_destroy = true` 確認
- `grep -A2 "aws_s3_bucket\b" aws/eks-metrics/modules/main.tf` → 同上
- `grep -A2 "aws_s3_bucket\b" aws/eks-traces/modules/main.tf` → 同上
- `terragrunt show` で各 stack の S3 bucket resource attribute に `force_destroy = true` が反映済を確認

### Phase 2: Deterministic resource naming + hydrate-time substitution

Phase 2 は terraform module changes (= IRSA / Karpenter node role の deterministic 化) と hydrate-time substitution (= helmfile gotmpl の cluster 固有値を terragrunt output から動的取得) を **同一 PR で atomic に変更** する。Phase 1 の S3 attribute 変更とは異なり、Phase 2 の terraform 変更は IRSA role を destroy → create で recreate させる (= role 名が変わるため `force_new`)。同じ PR 内で hydrate も走らせて新 ARN を manifests に反映させないと、role 名が古い ARN を annotation に持つ pod が役立たずになる。

#### Phase 2 で行う terraform module changes

| Module | 変更 | 影響 |
|---|---|---|
| `aws/eks/modules/addons.tf` の `module "alb_controller_irsa"` | `use_name_prefix = false` 追加 | role 名が `eks-production-alb-controller` に固定 (timestamp suffix 廃止)、apply で role が destroy → create |
| `aws/eks/modules/addons.tf` の `module "external_dns_irsa"` | 同上 | 同上 |
| `aws/karpenter/modules/main.tf` の `module "karpenter"` | node IAM role が deterministic 名になるよう `node_iam_role_use_name_prefix = false` 追加。サポートされていない場合は `node_iam_role_name` を直接指定（§8 Q1 で flag 済） | node role 名が固定、apply で role が destroy → create |
| `aws/eks/modules/outputs.tf` | `cluster_endpoint_hostname` output 追加 (= `regex_replace_all("^https://", module.eks.cluster.endpoint, "")`) | hydrate 時の helmfile が exec で参照 |
| `aws/vpc/modules/outputs.tf` | `vpc_id` output 確認 / 追加 | hydrate 時の helmfile が exec で参照 |

注: `aws/eks-secrets` / `aws/eks-logs` / `aws/eks-metrics` / `aws/eks-traces` の Pod Identity 用 IAM role (= `eks-${var.environment}-${local.service_name}`) は既に **fixed name** で `name_prefix` 不使用 → 変更不要。`aws/karpenter` の `karpenter_controller_host` MNG role (= `karpenter-controller-host-eks-node-group`) も既に `iam_role_use_name_prefix = false` → 変更不要。

#### Phase 2 で fix する hardcode

| File | Line | 値 | 修正方法 |
|---|---|---|---|
| `kubernetes/helmfile.yaml.gotmpl` | 27 | `eksApiEndpoint: ...gr7.ap-northeast-1.eks.amazonaws.com` | `exec terragrunt output -raw cluster_endpoint_hostname` |
| `kubernetes/helmfile.yaml.gotmpl` | 30 | `vpcId: vpc-02ea5d0ed3b7a3266` | `exec terragrunt output -raw vpc_id` |
| `kubernetes/helmfile.yaml.gotmpl` | 33 | `albControllerRoleArn: ...:role/eks-production-alb-controller-2026...` | `exec terragrunt output -raw alb_controller_role_arn`（Phase 2 で deterministic 化済） |
| `kubernetes/helmfile.yaml.gotmpl` | 34 | `externalDnsRoleArn: ...:role/eks-production-external-dns-2026...` | 同上 |
| `kubernetes/helmfile.yaml.gotmpl` | 39 | `nodeRoleName: Karpenter-eks-production-2026...` | `exec terragrunt output -raw karpenter_node_role_name` |
| `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml` | 17 | `albControllerRoleArn` / `vpcId` 再定義 | helmfile v1.4 の inheritance 制限による重複定義、ここも `exec` 化 |
| `kubernetes/components/external-dns/production/helmfile.yaml` | 16 | `externalDnsRoleArn` 再定義 | 同上 |
| `kubernetes/components/cilium/production/helmfile.yaml` | 16 | `eksApiEndpoint` 再定義 | 同上 |

#### `exec` 利用例

helmfile gotmpl の `exec` は **helmfile プロセスの CWD で実行** される。helmfile を repo root から呼ぶ場合 (= `helmfile -e production -f kubernetes/helmfile.yaml.gotmpl ...`) と、kubernetes/ から呼ぶ場合とで CWD が異なるため、確実な path 解決には `git rev-parse --show-toplevel` を使う pattern を採用する:

```yaml
production:
  values:
    - cluster:
        name: eks-production
        eksApiEndpoint: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw cluster_endpoint_hostname") }}
        vpcId: {{ exec "sh" (list "-c" "cd $(git rev-parse --show-toplevel)/aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt output -raw vpc_id") }}
```

`exec` 失敗時は helmfile が abort する (= silent な空文字列 fallback はしない)。これにより hydrate 時に terragrunt 未 apply / credentials 切れ等を即検出。

#### Phase 2 の apply 手順

1. PR 2 を作成 → CI が plan を回す → diff を確認（IRSA role が destroy → create される箇所、hydrate workflow が manifests を書き換える箇所をレビュー）
2. PR 2 を merge → main push trigger で：
   - terragrunt apply jobs (= aws/eks / aws/karpenter) が IAM roles を rotate
   - hydrate workflow が新 terragrunt outputs で manifests を再生成 + auto-commit
3. apply / hydrate が並行で走る期間中、ALB controller / external-dns / Karpenter pods は短時間 (= 数十秒〜数分) 認証エラーになるが、Flux が新 manifests を pickup したら自動 self-heal
4. apply / hydrate 完了後、 `kubectl get pods -A | grep -v Running` が空になるまで観測

注: §8 Q2 の通り、CI の hydrate workflow が terragrunt + AWS credentials を持つかは spec 時点で未確認。持たない場合は Phase 2 PR 内で `.github/workflows/reusable--kubernetes-hydrator.yaml` の拡張も実施。

#### Phase 2 の retrofit 検証

- `aws iam get-role --role-name eks-production-alb-controller` → success (= timestamp suffix なし)
- `aws iam get-role --role-name eks-production-external-dns` → success
- `aws iam get-role --role-name $(cd aws/karpenter/envs/production && TG_TF_PATH=tofu terragrunt output -raw karpenter_node_role_name)` → success
- `terragrunt output -raw cluster_endpoint_hostname` (= `aws/eks/envs/production`) が値を返す
- `terragrunt output -raw vpc_id` (= `aws/vpc/envs/production`) が値を返す
- 手元で `make hydrate-component` を 2 回連続実行 → 2 回目 diff なし (= idempotent)

#### Phase 2 の audit pass

`grep -REn '[A-F0-9]{32}\.gr[0-9]+\.[a-z0-9-]+\.eks\.amazonaws\.com|vpc-[a-f0-9]{17}|role/[a-z0-9-]+-2026[0-9]+' kubernetes/components/*/production/ kubernetes/helmfile.yaml.gotmpl` 等で **見落とされた hardcode が無い** ことを確認。検出されたら同 PR で fix。pattern は (1) EKS API endpoint hostname、(2) VPC ID、(3) timestamp suffix 付き role ARN を network/scope-wide にカバー。

### Phase 3: Lifecycle scripts

#### Phase 3 で追加するファイル

```
platform/
├── Makefile                                            # 新設
├── scripts/
│   └── eks-lifecycle/
│       ├── README.md                                   # 利用方法 / 前提 / 各 step の役割
│       ├── teardown.sh                                 # entry: 全 step を順に実行
│       ├── recreate.sh                                 # entry: 全 step を順に実行
│       └── lib/
│           ├── common.sh                               # ログ関数 / fail fast / env 検証 / run wrapper (DRY_RUN 対応)
│           ├── 00-auth.sh                              # apply role assume + admin role assume
│           ├── 10-k8s-cleanup.sh                       # teardown: kubectl delete ingress / LB svc / Karpenter NodePool / nodes drain 待機
│           ├── 30-destroy-stacks.sh                    # teardown: 8 stacks を固定順で terragrunt destroy
│           ├── 40-orphan-verify.sh                     # teardown: ENI / EBS / target group / SG / Route53 record / CloudWatch log group の orphan 検出
│           ├── 50-apply-stacks.sh                      # recreate: 8 stacks を固定順で terragrunt apply
│           ├── 60-flux-bootstrap.sh                    # recreate: kubectl apply -k kubernetes/clusters/production/flux-system
│           └── 70-reconcile-watch.sh                   # recreate: 全 HelmRelease を Phase 単位で wait
```

注: step 番号 20 (= S3 empty) は Phase 1 の `force_destroy = true` で不要となったため欠番。連番性より step 役割の明確さを優先。

#### Make targets (root `Makefile`)

```make
ENV ?= production

eks-teardown: eks-teardown-k8s eks-teardown-aws eks-teardown-verify
eks-teardown-k8s:    ; ENV=$(ENV) bash scripts/eks-lifecycle/lib/10-k8s-cleanup.sh
eks-teardown-aws:    ; ENV=$(ENV) bash scripts/eks-lifecycle/lib/30-destroy-stacks.sh
eks-teardown-verify: ; ENV=$(ENV) bash scripts/eks-lifecycle/lib/40-orphan-verify.sh

eks-recreate: eks-recreate-aws eks-recreate-flux eks-recreate-watch
eks-recreate-aws:    ; ENV=$(ENV) bash scripts/eks-lifecycle/lib/50-apply-stacks.sh
eks-recreate-flux:   ; ENV=$(ENV) bash scripts/eks-lifecycle/lib/60-flux-bootstrap.sh
eks-recreate-watch:  ; ENV=$(ENV) bash scripts/eks-lifecycle/lib/70-reconcile-watch.sh
```

各 numbered script は **独立して実行可能** (= subtarget で人間が個別に呼べる)。共有状態は env vars (= AWS credentials) と AWS API / k8s API 上のリソース状態のみ。

#### `common.sh` が提供する utilities

- 色付きログ関数 (`info` / `warn` / `error`)
- `set -euo pipefail`
- `require_env` (= `ENV` が `production` であることを検証)
- `require_cmd` (= `tofu` / `terragrunt` / `kubectl` / `flux` / `jq` / `aws` の存在を検証)
- `confirm "..."` (= destructive 操作前の y/N 確認)
- `run` (= `DRY_RUN=1` 時は echo のみ、それ以外は exec)
- session credentials の expiration tracking (= `00-auth.sh` で記録、後続 step が再 source する)

#### `00-auth.sh` の詳細

1. `aws sts get-caller-identity` で account ID 動的取得
2. `aws sts assume-role --role-arn arn:aws:iam::<acct>:role/github-oidc-auth-production-github-actions-apply-role --role-session-name eks-lifecycle-${USER:-debug}` で apply role assume → `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` を export
3. `aws sts assume-role --role-arn arn:aws:iam::<acct>:role/eks-admin-production --role-session-name eks-lifecycle-admin-${USER:-debug}` で admin role assume → 一時 file に保存（apply 用 credentials を main env と分離）
4. `aws eks update-kubeconfig --region <region> --name eks-${ENV}` を admin credentials で実行
5. `kubectl get nodes` で疎通確認 → 失敗時 `CLUSTER_EXISTS=false` flag を立てる (= step 10 の skip 判定用)
6. session expiration time を `/tmp/eks-lifecycle-creds-expire-$$` 等に記録

#### `10-k8s-cleanup.sh` の詳細

`CLUSTER_EXISTS=true` の場合のみ実行:

1. `kubectl delete ingress --all -A --timeout=180s` (= ALB controller が target group / listener / ENI を解放)
2. `kubectl delete svc -A --field-selector spec.type=LoadBalancer --timeout=180s` (= NLB / ENI 解放)
3. `kubectl delete nodepools.karpenter.sh --all --timeout=300s` (= Karpenter controller が EC2 ノードを drain + terminate)
4. `kubectl wait nodes -l karpenter.sh/nodepool --for=delete --timeout=600s`
5. `kubectl get pods -A -o wide` を log 出力（人間 sanity check）
6. **Cilium / VPC CNI / 各 addon の helm uninstall は意図的にしない**: terragrunt destroy で cluster ごと消す流れに任せる（個別 uninstall は finalizers で詰まりやすい）

#### `30-destroy-stacks.sh` の詳細

固定順で `terragrunt destroy` 呼び出し:

| 順 | Stack |
|---|---|
| 1 | `aws/karpenter/envs/production` |
| 2 | `aws/eks-secrets/envs/production` |
| 3 | `aws/eks-logs/envs/production` |
| 4 | `aws/eks-metrics/envs/production` |
| 5 | `aws/eks-traces/envs/production` |
| 6 | `aws/eks/envs/production` |
| 7 | `aws/alb/envs/production` |
| 8 | `aws/vpc/envs/production` |

各 stack で `cd aws/<stack>/envs/production && TG_TF_PATH=tofu terragrunt destroy -auto-approve`。失敗時は **fail fast で exit 1**。

各 stack 完了後 30s sleep (= AWS API eventual consistency 対策)。

#### `40-orphan-verify.sh` の詳細

検出のみ、削除しない。検出されたら exit 1 + 削除コマンド例を提示。

| 検出対象 | AWS API |
|---|---|
| ENI | `aws ec2 describe-network-interfaces --filters Name=tag:Environment,Values=production Name=tag:Project,Values=eks` |
| EBS volumes | `aws ec2 describe-volumes --filters Name=tag:KubernetesCluster,Values=eks-production Name=status,Values=available` |
| Target groups | `aws elbv2 describe-target-groups`（VPC ID は destroy 前に env file へ保存しておいた値で filter） |
| Security groups | `aws ec2 describe-security-groups --filters Name=tag:Environment,Values=production` |
| Route53 records | `aws route53 list-resource-record-sets --hosted-zone-id <id>` から `external-dns` owner TXT record (= `_external-dns.*.panicboat.net`) と関連 A/AAAA を抽出 |
| CloudWatch log groups | `aws logs describe-log-groups --log-group-name-prefix /aws/eks/eks-production` |

検出 0 件で exit 0、teardown 完了。

#### `50-apply-stacks.sh` の詳細

固定順で `terragrunt apply` 呼び出し:

| 順 | Stack |
|---|---|
| 1 | `aws/vpc/envs/production` |
| 2 | `aws/alb/envs/production` |
| 3 | `aws/eks/envs/production` |
| 4 | `aws/karpenter/envs/production` |
| 5 | `aws/eks-secrets/envs/production` |
| 6 | `aws/eks-logs/envs/production` |
| 7 | `aws/eks-metrics/envs/production` |
| 8 | `aws/eks-traces/envs/production` |

各 stack で `cd aws/<stack>/envs/production && TG_TF_PATH=tofu terragrunt apply -auto-approve`。失敗時は **fail fast for exit 1**。

各 stack 完了後 30s sleep (= eventual consistency 対策)。

apply 中の credentials 期限切れ (= 1h) 対策: 各 stack apply 開始前に `00-auth.sh` から記録した expiration を確認し、残り 5 分以下なら再 assume。

#### `60-flux-bootstrap.sh` の詳細

1. admin role を再 assume → `aws eks update-kubeconfig` で kubeconfig 更新
2. `kubectl wait --for=condition=Ready node --all --timeout=300s` (= system MNG 2 ノードが Ready)
3. **必ず** `make hydrate-component` を呼び出し `kubernetes/manifests/production/` を最新の terragrunt output で再生成。recreate 後は cluster ID / VPC ID が変わっており、git に commit 済の manifests は古い値を持つため、再 hydrate は省略不可。生成された差分を `git status` で確認 → `confirm` で y/N → `git add` + `git commit -s` + `git push origin main`（Flux が main を polling して pickup する経路）
4. `kubectl apply -k kubernetes/clusters/production/` (= Flux controllers + GitRepository + Kustomization の bootstrap)
5. `kubectl wait kustomization/flux-system -n flux-system --for=condition=Ready --timeout=300s`
6. `flux get sources git -A` / `flux get kustomizations -A` を log 出力

注: step 3 の "git commit + push" は **lifecycle script が git を変更する非自明な挙動** のため、`confirm` で人間 y/N を必ず求める。CLAUDE.md "Surgical Changes" 原則に対しては「temporary 削除に伴う `kubernetes/manifests/production/` の再 hydrate は当然の帰結 (= cluster ID / VPC ID が必然的に変わる)」として正当化。

#### `70-reconcile-watch.sh` の詳細

Flux が `kubernetes/manifests/production/` を順次 reconcile。Phase 単位で wait:

| Phase | 対象 HelmRelease / Kustomization | timeout |
|---|---|---|
| Phase 1 (foundation) | cilium / coredns / metrics-server / aws-load-balancer-controller / external-dns / external-secrets / keda | 各 600s |
| Phase 2 (Karpenter) | karpenter / EC2NodeClass / NodePool | 600s |
| Phase 3 (observability) | prometheus-operator / mimir / loki / tempo / fluent-bit / opentelemetry-collector / beyla | 1200s (= S3 backend 初期化込み) |
| Phase 4 (cert-manager + ESO + reloader) | cert-manager / external-secrets ClusterSecretStore / reloader | 600s |
| Phase 5 (oauth2-proxy + nginx-sample) | oauth2-proxy / nginx-sample | 600s |

最後に `kubectl get helmreleases -A` / `kubectl get kustomizations -A` の状態を tabular に出力。Failed があれば exit 1。

### Phase 順序の理由

| 順 | Phase | 必要性 |
|---|---|---|
| 1 | Phase 1 (S3 force_destroy) | Phase 3 の teardown で S3 bucket destroy が hang しないために必要 |
| 2 | Phase 2 (deterministic naming + hydrate-time substitution) | Phase 3 で recreate しても hardcoded 値が残っていれば cluster が起動しない |
| 3 | Phase 3 (lifecycle scripts) | Phase 1 + 2 が前提として揃った後に teardown / recreate を実行可能 |

**前後関係の固定**: Phase 1 と Phase 2 は独立 (= 順序逆転可能) だが、いずれも Phase 3 より先に merge & apply 完了している必要がある。spec 上は Phase 1 → Phase 2 → Phase 3 の順を推奨 (= Phase 1 が小さく safe な変更、Phase 2 が IRSA rotation を伴う大きな変更、Phase 3 が機能追加)。

## 6. Error handling

### 6.1 Fail-fast

全 script は冒頭で `set -euo pipefail`。任意 step の非ゼロ exit で script 全体停止 + 診断メッセージ + exit 1。

### 6.2 失敗パターンと診断

各 step で想定される失敗を `common.sh` のログ関数で出力。代表例:

| Step | 失敗 | 診断 + 介入 |
|---|---|---|
| 0 (auth) | apply role assume 失敗 | `ERROR: cannot assume ${role}. IAM principal の sts:AssumeRole 権限を確認 (panicboat/ansible 側 provision)` |
| 0 (auth) | admin role assume 失敗 (= 既に role が消えている) | `WARN: admin role not found. teardown 中の再 run なら CLUSTER_EXISTS=false flag で続行` |
| 10 (k8s) | `kubectl delete ingress` timeout | `WARN: ingress deletion timed out. kubectl patch ingress <name> -p '{"metadata":{"finalizers":[]}}' --type=merge で finalizer 強制除去` |
| 10 (k8s) | Karpenter NodePool drain timeout | `WARN: karpenter nodes did not drain in 600s. kubectl delete node <name> --force` |
| 30 (destroy) | terragrunt destroy hang | `ERROR: terragrunt destroy failed at <stack>. cd aws/<stack>/envs/production && TG_TF_PATH=tofu terragrunt destroy で再実行` |
| 40 (verify) | orphan resource 検出 | `WARN: orphan resources found: <list with deletion command examples>` |
| 50 (apply) | terragrunt apply 失敗 (= eventual consistency) | `ERROR: ${stack} apply failed. 30s 待ってから make eks-recreate-aws を再実行` |
| 50 (apply) | session credentials expired | `ERROR: AWS credentials expired (1h limit). make eks-recreate-aws を再実行 (= 00-auth.sh が再 assume)` |
| 60 (flux) | system MNG nodes not Ready | `ERROR: system MNG nodes not Ready in 300s. kubectl describe node / aws eks describe-nodegroup` |
| 60 (flux) | flux-system Kustomization not Ready | `ERROR: flux-system kustomization not Ready. flux logs --all-namespaces; kubectl events -n flux-system` |
| 70 (watch) | HelmRelease Failed | `ERROR: HelmRelease <name> in <ns> Failed. flux logs -n <ns>; kubectl describe helmrelease <name> -n <ns>` |

### 6.3 Partial state からの再 run 戦略

各 step は AWS / k8s state を見て動作判定。`make eks-teardown` / `make eks-recreate` を **何度実行しても安全**:

- Step 0 で kubeconfig 取得失敗 → `CLUSTER_EXISTS=false` flag
- Step 10 は `CLUSTER_EXISTS=false` なら skip
- Step 30 / 50 の各 stack destroy / apply は terragrunt が "already destroyed/created" を idempotent に扱う
- Step 40 は AWS API を直接 query するので state file 非依存
- Step 60 の `kubectl apply -k` は idempotent (= 既存リソースには no-op、新規だけ作成)。再 run 時に明示的な skip 判定は不要
- Step 70 は Helm reconcile を待つだけで idempotent

### 6.4 AWS API eventual consistency

各 stack apply / destroy 後に **固定 30s sleep** を挟む。retry loop は組まない (= panicboat 個人運用 + 1 環境のみ、investigation が必要なら fail fast)。

### 6.5 Credentials 期限切れ

apply role の session 1h 制限。recreate 全工程 30〜60 分のため境界。`00-auth.sh` で expiration 記録 → 各 step 開始前に残り時間チェック → 5 分以下なら再 assume。

### 6.6 ロールバック方針

teardown / recreate 中断時は **前進復旧のみ**。「中途半端な state を teardown 前に戻す」設計はしない:

- temporary 削除 = 元の cluster は意図的に消す → 戻る対象なし
- partial 状態は terragrunt state の整合性で再前進可能

### 6.7 Defense in depth

- `confirm` (= y/N) を destructive step の冒頭で必ず呼ぶ
- `--dry-run` (= `DRY_RUN=1` env var) で実コマンドを echo のみ
- script 冒頭で `ENV` 検証 (= `production` 以外で exit 1)

## 7. Testing / validation

### 7.1 Static checks

- `shellcheck` を `scripts/eks-lifecycle/**/*.sh` 全てに通す
- `bash -n` で syntax check
- `make` target 名衝突なし確認

### 7.2 Dry-run

`make eks-teardown DRY_RUN=1 ENV=production` / `make eks-recreate DRY_RUN=1 ENV=production` で AWS / kubectl コマンドを echo のみ。

確認項目:
- 8 stack が想定順序で呼ばれている
- `kubectl delete` 対象が正しい (= ingress + LB svc + NodePool)
- S3 / ENI / target group / SG / Route53 / CloudWatch verify の filter 正しさ

### 7.3 Live run validation (= 本番 1 周)

#### Phase 1 / 2 retrofit 確認 (= teardown 実行前)

- Phase 1: `grep "force_destroy = true" aws/eks-logs/modules/main.tf aws/eks-metrics/modules/main.tf aws/eks-traces/modules/main.tf` で 3 件確認
- Phase 2: `aws iam get-role --role-name eks-production-alb-controller` 等で deterministic 名確認
- Phase 2: `grep -REn '[A-F0-9]{32}\.gr[0-9]+\.[a-z0-9-]+\.eks\.amazonaws\.com|vpc-[a-f0-9]{17}|role/[a-z0-9-]+-2026[0-9]+' kubernetes/components/*/production/ kubernetes/helmfile.yaml.gotmpl` で漏れなし確認

#### Phase 3 teardown 検証

```bash
make eks-teardown DRY_RUN=1 ENV=production
make eks-teardown ENV=production
```

teardown 完了後の checklist:

- [ ] `aws eks describe-cluster --name eks-production` → ResourceNotFoundException
- [ ] `aws ec2 describe-vpcs --filters Name=tag:Environment,Values=production` で空
- [ ] `aws iam get-role --role-name eks-production-alb-controller` → NoSuchEntity
- [ ] step 40 が exit 0 (= orphan resource 0 件)
- [ ] AWS Cost Explorer で翌日 NAT gateway / EC2 / EBS の課金停止確認 (= 24h lag)
- [ ] AWS Secrets Manager service の secret 値が **そのまま残存** (= `aws secretsmanager list-secrets`)

#### Phase 3 recreate 検証

```bash
make eks-recreate DRY_RUN=1 ENV=production
make eks-recreate ENV=production
```

recreate 完了後の checklist (= roadmap Phase 1〜5 単位):

- [ ] `kubectl get nodes` → system MNG 2 ノード Ready
- [ ] Phase 1 全 HelmRelease (= cilium / aws-load-balancer-controller / external-dns 等) Ready
- [ ] Phase 2: `kubectl get nodepool` Ready、taint / label 一致
- [ ] Phase 3 全 HelmRelease (= prometheus / mimir / loki / tempo / fluent-bit / opentelemetry-collector / beyla) Ready
- [ ] Phase 4 全 HelmRelease (= cert-manager / external-secrets / reloader) Ready
- [ ] **ESO 経由で AWS Secrets Manager secret 値が `kubectl get secret` から取得でき、teardown 前と同一値**（本 spec の核心 success criteria）
- [ ] Phase 5: `curl https://<nginx host>.panicboat.net/` → HTTP 200 (= ALB + ACM + external-dns + Cilium + nginx の end-to-end)
- [ ] Phase 5: Tempo 上で nginx HTTP request span を query → 検出

### 7.4 Spec 完了条件

1. PR 1 (terraform module changes) が merged & applied
2. PR 2 (hydrate-time substitution) が merged & hydrated
3. PR 3 (lifecycle scripts) が merged
4. live run で teardown → recreate を 1 周完走
5. §7.3 の checklist が全 pass
6. `scripts/eks-lifecycle/README.md` に運用手順記載

## 8. Open questions

### Q1: Karpenter node IAM role の deterministic 名 fixing 方法

`terraform-aws-modules/eks/aws//modules/karpenter` v21.19.0 が公開する変数で `node_iam_role_use_name_prefix = false` をサポートするかは未確認。サポートが無ければ `node_iam_role_name` を直接指定する代替策、またはモジュールの IRSA を bypass して自前 `aws_iam_role` を作る代替策が必要。Phase 1 着手時に module ドキュメント / source を確認して確定する。

### Q2: Hydration pipeline が CI 上で terragrunt output を読めるか

`reusable--kubernetes-hydrator.yaml` workflow が `tofu` / `terragrunt` / AWS credentials を持つかは spec 時点で未確認。持たない場合、Phase 2 で workflow を拡張する PR を含める必要がある。Phase 2 着手時に `.github/workflows/reusable--kubernetes-hydrator.yaml` を確認して spec を更新する。

### Q3: 60-flux-bootstrap.sh の git push commit message format

recreate 中に `make hydrate-component` で生成された `kubernetes/manifests/production/` の差分を operator が `confirm` で確認 → `git commit -s` + push する設計を採用した。commit メッセージの format は Phase 3 実装時に確定させる。`docs(eks): post-recreate manifest re-hydrate (= cluster IDs refreshed)` のような Conventional Commits 準拠案を有力候補とするが、CI gatekeeper / semantic-pull-request workflow の rule に合致するかは実装時検証要。

## 9. References

- aws/eks/README.md (= 既存の手元 destroy 手順、Decision 1 の前提)
- docs/superpowers/specs/2026-04-30-aws-eks-production-design.md (= 元の cluster 設計)
- docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md (= roadmap、recreate 後の Phase 1〜5 検証対象)
- docs/superpowers/specs/2026-05-10-eks-production-phase-5-closure-design.md (= Phase 5 完了状態)
- docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md (= VPC cross-stack lookup convention、recreate 時の subnet ID 透過追従の理論的根拠)
- CLAUDE.md (= Surgical Changes / Simplicity First / YAGNI 原則の根拠)
