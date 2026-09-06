# Private Trust Security Group Design

## Goal

production VPC 内の Security Group を、resource ごとの個別境界から一つの private trust boundary へ統合する。
対象は EKS control plane、system-critical managed node group、Karpenter node、monolith RDS である。

private trust boundary に所属する resource 間は全 protocol・全 port の相互通信を許可し、IPv4 の外向き通信も全て許可する。
この境界は lateral movement を制限しない。EKS node の一台が侵害された場合、その node は RDS を含む同じ境界内の全 listener に到達できる。この性質は本設計で受け入れる。

## Non-goals

- Internet-facing ALB の frontend Security Group 統合
- Amazon EKS が作成する primary cluster Security Group の削除または置換
- VPC default Security Group の再利用
- IPv6 egress の許可
- Network ACL、Cilium NetworkPolicy、Kubernetes NetworkPolicy の変更
- Security Group を関連付けられない resource への境界適用
- production 以外の未作成 environment の provision

## Current State

repository から確認できる Security Group の役割は次のとおりである。

| Security Group | Owner | Attachment / use |
|---|---|---|
| VPC default SG | `platform/aws/vpc` | rule を全て削除した未使用の隔離用 SG |
| EKS primary SG | Amazon EKS | EKS control plane ENI、managed node、現行 Karpenter node |
| Module cluster SG | `terraform-aws-modules/eks/aws` | EKS control plane ENI。module node SG から TCP 443 を許可 |
| Module node SG | `terraform-aws-modules/eks/aws` | system-critical managed node group。node 間通信と control plane からの通信を許可 |
| RDS SG | monorepo の monolith infrastructure | private subnet CIDR から RDS TCP 5432 を許可 |
| ALB frontend SG | AWS Load Balancer Controller | Internet から ALB listener への ingress |

`terraform-aws-modules/eks/aws` v21.25.0 には二つの cluster SG 概念がある。

- `cluster_primary_security_group_id`: Amazon EKS が必ず作る primary cluster SG
- `cluster_security_group_id`: module が `aws_security_group.cluster` として追加作成する SG

現行 `aws/eks/modules/outputs.tf` は module 作成 SG を「Cluster security group created by EKS」と説明する一方、`aws/eks/lookup/outputs.tf` の同名 field は EKS primary SG を返す。同じ名前が異なる resource を指しているため、consumer が所有者と lifecycle を判別できない。

現行 module node SG には `kubernetes.io/cluster/eks-production` tag が module 内で追加される。AWS Load Balancer Controller が EKS primary SG と module node SG の両方を target SG 候補にする問題を避けるため、`terraform_data.node_sg_cluster_tag_removal` が `local-exec` で tag を削除している。

実環境 inventory は未確認である。現在の AWS CLI context では `Name=vpc-production` の VPC が見つからなかった。正しい production account / role で live attachment を取得するまで migration を開始しない。

## Decision

### Trust boundary

`platform/aws/vpc` が environment ごとに `private-trust-${var.environment}` を所有する。production では `private-trust-production` になる。

rule は次の二つだけを持つ。

| Direction | Protocol | Port | Peer |
|---|---|---|---|
| Ingress | All | All | 自身の Security Group ID |
| Egress | All | All | `0.0.0.0/0` |

self-reference は両方の ENI に共通 SG が関連付けられた時だけ ingress を許可する。IPv4 egress rule は routing table、NAT Gateway、Network ACL を変更しないため、database subnet に Internet route を追加するものではない。

共通 SG には `kubernetes.io/cluster/*` および `aws:eks:cluster-name` tag を付けない。AWS Load Balancer Controller が node / Pod ENI 上で EKS primary SG だけを cluster SG として識別できる状態を維持する。

### Ownership

VPC stack を owner にする理由は、共通 SG の lifetime が EKS cluster より長く、RDS も consumer になるためである。
EKS stack が owner になると、RDS が関連付けられている間は EKS teardown 時の SG 削除が `DependencyViolation` になる。EKS primary SG を共通利用すると、EKS service が rule と tag を復元する resource に RDS lifecycle が結合する。

VPC default SG は `default-vpc-${var.environment}-locked` として rule ゼロを維持する。暗黙の SG attachment を通信可能にしない責務と、明示的に private trust boundary へ参加させる責務を分離する。

### Discovery contract

共通 SG の cross-stack identifier は `Name=private-trust-${environment}` と VPC ID の組である。AWS は `Name` tag の一意性を保証しないため、lookup が複数件に一致した場合は data source を失敗させる。曖昧な一致を先頭要素で選ばない。

platform 内の consumer は `aws/vpc/lookup` の typed output を使う。monorepo は platform の Terraform state に依存せず、既存の VPC tag lookup と同じ AWS data source pattern で共通 SG を取得する。

## Component Changes

### Platform VPC

`aws/vpc/modules` に共通 SG と独立した ingress / egress rule resource を追加する。module output に `private_trust_security_group_id` を追加する。

`aws/vpc/lookup` は対象 VPC 内で共通 SG を検索し、`security_groups.private_trust` として data source を公開する。consumer は SG ID を再構成せず、この output の `id` を使う。

### Platform EKS

`aws/eks/modules` は次の module input で追加 SG の作成を止め、VPC owner の共通 SG を使用する。

| Input | Target value |
|---|---|
| `create_security_group` | `false` |
| `security_group_id` | private trust SG ID |
| `create_node_security_group` | `false` |
| `node_security_group_id` | private trust SG ID |

Amazon EKS は primary cluster SG を引き続き作成し、control plane ENI と managed node group に関連付ける。共通 SG は module の existing SG input を通じて control plane ENI に追加される。

module node SG がなくなるため、`data.aws_security_group.node_sg` と `terraform_data.node_sg_cluster_tag_removal` を削除する。これにより AWS CLI `local-exec`、意図的な error suppression、apply ごとの tag drift を除去する。

output contract は所有者を表す名前に直す。

- EKS root module は `cluster_primary_security_group_id` を公開する
- VPC root module は `private_trust_security_group_id` を公開する
- EKS root module の曖昧な `cluster_security_group_id` と `node_security_group_id` は削除する
- `aws/eks/lookup` の cluster object は `cluster_primary_security_group_id` を公開し、module node SG lookup を削除する

repository 内の consumer は同じ変更単位で新しい field に切り替える。repository 外の consumer は検索で確認できていないため、production apply 前に remote-state output の利用有無を運用側で確認する。

### System-critical Managed Node Group

`aws/eks-karpenter/modules` の system-critical managed node group には次の二つを関連付ける。

- `cluster_primary_security_group_id`: EKS lookup が返す EKS primary SG
- `vpc_security_group_ids`: VPC lookup が返す private trust SG

EKS primary SG は control-plane-to-data-plane 通信と AWS Load Balancer Controller の cluster SG 識別のために残す。private trust SG は RDS と他の private member への共通 identity になる。

launch template の Security Group 変更は managed node group update を発生させる。OpenTofu が AWS update の完了または失敗を受け取り、完了前に次の migration phase へ進まない。

### Karpenter Nodes

`EC2NodeClass/system-components` の `securityGroupSelectorTerms` は次の二系統を OR 条件で選択する。

- `aws:eks:cluster-name=eks-production`: EKS primary SG
- `Name=private-trust-production`: private trust SG

Karpenter は一致した SG を全て instance に関連付ける。selector 変更で既存 NodeClaim が drift 対象になった場合、Karpenter controller が replacement を所有する。操作側は全 NodeClaim と Node の Ready、および全 node ENI の共通 SG attachment を確認するまで完了としない。

現行 NodePool は disruption budget を明示していないため、cluster に導入済み CRD の default budget が適用される。migration のために budget を緩和しない。

### Monolith RDS

monorepo の `dystopia/monolith/infrastructure/aws/modules` は `private-trust-production` を VPC ID と Name tag で検索する。
RDS の `vpc_security_group_ids` を共通 SG のみにし、`aws_security_group.monolith_db` と ingress rule を削除する。

RDS stack は共通 SGを所有しない。RDS destroy は DB と ENI の削除だけを行い、VPC stack の SGを残す。

### Public Load Balancers

Internet-facing ALB の frontend SG は AWS Load Balancer Controller 管理を維持し、private trust SGを関連付けない。ALB から `target-type=ip` backend への rule 管理も controller に委ねる。

node / Pod ENI には cluster tag を持つ EKS primary SGと、cluster tag を持たない private trust SGが付く。controller の target SG 候補を一件に保ちながら、private member 間通信を共通 SGで許可する。

### Future Private Resources

production VPC に追加する SG 対応 private resource は、個別の分離要件がない限り private trust SGを明示的に関連付ける。SG の暗黙選択には依存しない。public ingress、cross-account、compliance、workload isolation のいずれかが必要な resource はこの境界へ参加させず、別 design で扱う。

## Migration

### Phase 0: Inventory

正しい production account / role を選び、次を取得する。

- VPC 内の全 Security Group と rule
- 全 ENI の Security Group attachment、description、interface type、owner
- EKS control plane、system-critical managed node group、Karpenter node、RDS の対応 ENI
- Terraform state 外から既存 module SG output を参照する consumer

`vpc-production` が一件でない、想定外 ENI が削除対象 SGを使う、または owner を特定できない attachment がある場合は migration を開始しない。

### Phase 1: Create

platform VPC stack で private trust SGを作成して apply する。この phase は attachment を変更しない。

plan の許容差分は共通 SG と二つの rule、および output / lookup contract だけである。VPC、subnet、route table、VPC default SG の変更があれば停止する。

### Phase 2: Attach Alongside

削除対象 SGを残したまま共通 SGを追加する。

| Consumer | Intermediate attachment |
|---|---|
| EKS control plane ENI | EKS primary + module cluster + private trust |
| System-critical MNG | EKS primary + module node + private trust |
| Karpenter node | EKS primary + private trust |
| RDS | RDS SG + private trust |

EKS control plane は module cluster SG を作成したまま `additional_security_group_ids` に private trust SG を追加する。system-critical MNG は現行 module node SG を残したまま `vpc_security_group_ids` に private trust SG を追加する。RDS は現行 RDS SG と private trust SG の両方を `vpc_security_group_ids` に指定する。Phase 2 では `create_security_group` と `create_node_security_group` を無効化しない。

EKS と RDS の intermediate HCL には、verification 後に旧 attachment を外すことを示す `// TODO:` を付ける。最終 phase で marker ごと削除する。

Karpenter reconciliation、managed node group update、EKS VPC configuration update、RDS SG association update は、それぞれ controller / AWS service / OpenTofu が実行する。操作側は各 status と command exit code を待つ。完了を待つ主体がない background process は起動しない。

### Phase 3: Verification Checkpoint

次を全て満たすまで削除 phase に進まない。

1. 対象 private ENI が全て private trust SGを持つ
2. EKS control plane、全 NodeClaim、全 Node、全常駐 Pod が Ready
3. cluster 内 DNS lookup と Kubernetes API access が成功
4. monolith から PostgreSQL への実 query が成功
5. ALB target group が healthy で公開 endpoint が期待する HTTP response を返す
6. AWS Load Balancer Controller log に Security Group 識別 error がない
7. Karpenter controller が EC2NodeClass Ready を報告し、意図しない replacement loop がない
8. private workload から既存の外向き通信が成功

checkpoint 失敗時は旧 SGを保持する。private trust SGを各 consumer から外せば phase 2 前へ戻せる。

### Phase 4: Detach and Remove

cross-stack deletion dependency を避けるため次の順で行う。

1. system-critical MNG を EKS primary + private trust の二つに更新し、全 node replacement の完了を待つ
2. RDS を private trust のみに更新し、RDS SG と rule を削除する
3. EKS module の cluster / node SG 作成を無効化し、tag cleanup resource と node SG lookup を削除する
4. module cluster SG と module node SG の ENI attachment がゼロであることを確認して削除を完了する
5. output consumer と documentation を現在の resource 名に更新する

削除対象 SG が一件でも ENI に残る場合は、その SG の削除を実行しない。削除後の rollback は旧 SG の再作成を要するため、phase 3 の checkpoint を不可逆操作の gate とする。

### Phase 5: Final Verification

- private trust SG が対象 private ENI 全てに関連付けられている
- private trust SG の rule が self ingress all と IPv4 egress all の二つである
- VPC default SG の ingress / egress がともにゼロである
- EKS primary SG と ALB frontend SG が残っている
- module cluster SG、module node SG、RDS SG が存在しない
- 対象 stack の最終 `terragrunt plan` が差分ゼロである
- phase 3 の runtime checks が再度成功する

## Failure Handling

| Failure | Cause boundary | Action |
|---|---|---|
| production VPC が見つからない | AWS authentication / account selection | account / role を修正し、inventory を最初から取得する |
| plan が VPC、EKS cluster、RDS replacement を含む | module input または immutable field の変更 | apply せず、replacement を引き起こした field を特定する |
| MNG update が失敗する | launch template、PDB、capacity、node bootstrap | 旧 SGを残し、AWS update error と node event を調査する |
| Karpenter replacement が収束しない | selector、capacity、CNI、disruption | 旧 node を削除せず、EC2NodeClass / NodeClaim condition と controller log を調査する |
| RDS query が失敗する | SG attachment、route、DNS、credential、DB health | SG attachment だけでなく接続経路を分解し、原因確定まで旧 SGを残す |
| ALB target が unhealthy | controller-managed backend rule または node SG identification | common SG の cluster tag 不在と EKS primary SG の cluster tag を確認する |
| SG delete が `DependencyViolation` | 未確認 ENI attachment | delete を再試行せず、attachment owner を特定して migration 対象へ戻す |

## Testing

### Toolchain

platform と monorepo の Terraform module は OpenTofu `1.12.6` を要求するが、両 repository の `aqua.yaml` は `1.12.0` を pin している。test / validate 前に両方を `1.12.6` に揃える。provider version は各 repository の既存固定値を維持し、新しい dependency は追加しない。

### Test Code

OpenTofu native test は mock provider と `command = plan` を使い、AWS resource を作成しない。

| Test | Behavior |
|---|---|
| `creates_private_trust_security_group` | VPC module が stable name、self ingress all、IPv4 egress all、private trust output を生成する |
| `uses_private_trust_security_group_for_eks` | EKS module が control plane と node の existing SG input に同じ ID を使い、module cluster / node SGを作成しない |
| `selects_primary_and_private_trust_security_groups` | rendered EC2NodeClass が EKS primary と private trust の二つを選び、共通 SG selector に cluster tag を使わない |
| `uses_private_trust_security_group_for_rds` | RDS が private trust SGだけを参照し、専用 SG と rule を作成しない |

platform には VPC / EKS module の `*.tftest.hcl` と、Kustomize output の selector contract を検証する shell test を置く。monorepo には RDS module の `*.tftest.hcl` を置く。test 名と assertion は上表の振る舞いを表し、resource block の文字列一致だけを成功条件にしない。

### Static Verification

- 変更対象 module の `tofu fmt -check`
- 変更対象 Terragrunt directory の HCL format check と validate
- VPC、EKS、EKS-Karpenter、monolith RDS の `tofu test`
- Karpenter component の `kustomize build`
- generated EC2NodeClass selector contract test
- `git diff --check`

repository 全体の baseline `tofu fmt -check -recursive aws` は、変更前から `aws/eks-secrets/modules/main.tf` で失敗する。本変更ではその file を修正せず、変更対象 file の format check と既存 failure の分離を報告する。

### Plan Verification

各 migration phase の plan で resource action と dependency order を確認する。特に次を failure とする。

- VPC、subnet、route table、EKS cluster、RDS instance の replace / destroy
- phase 2 で既存 module SG または RDS SG の destroy
- phase 4 で attachment が残る SG の destroy
- VPC default SG への rule 追加
- public ALB frontend SG の ownership 変更

## Completion Criteria

次を全て満たした時だけ implementation 完了とする。

1. test code が追加され、OpenTofu `1.12.6` で全追加 test が成功する
2. static verification が既知の baseline failure を除いて成功する
3. migration phase ごとの plan が許容差分だけを含む
4. phase 3 と phase 5 の runtime verification が成功する
5. 削除対象 SG の attachment がゼロになってから削除される
6. 最終 plan が差分ゼロになる
7. repository documentation と output 名が最終構成を表す

実行した command と結果を `VERIFIED`、code / plan 読解に基づく判断を `REASONED`、production access 不足で確認できなかった項目を `ASSUMED` として最終報告で区別する。

## References

- [Amazon EKS security group requirements](https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html)
- [Amazon VPC security group rules](https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html)
- [terraform-aws-eks v21.25.0 module](https://github.com/terraform-aws-modules/terraform-aws-eks/tree/v21.25.0)
- [Karpenter NodeClasses](https://karpenter.sh/preview/concepts/nodeclasses/)
- [AWS Load Balancer Controller security group management](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/security_groups/)
- [OpenTofu test command](https://opentofu.org/docs/cli/commands/test/)
- [OpenTofu v1.12.6 release](https://github.com/opentofu/opentofu/releases/tag/v1.12.6)
