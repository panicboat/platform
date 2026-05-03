# EKS Production Foundation Addons (beta) Design

## Overview

Phase 1 Foundation の最終 piece として、AWS 連携が必要な foundation addons を production EKS cluster `eks-production` に導入する。Plan 1c-α（Gateway API CRDs / Metrics Server / KEDA）に続く Plan 1c-β。

本 spec のスコープ：

- **AWS Load Balancer Controller**: `Ingress` リソースから ALB を自動 provisioning
- **ExternalDNS**: Service / Ingress の hostname annotation から Route53 レコードを自動生成
- **ACM wildcard 証明書 `*.panicboat.net`**: ALB の HTTPS 終端、ALB Controller の cert auto-discovery で利用
- **IRSA roles**: ALB Controller / ExternalDNS の AWS API access 用
- **VPC subnet tags**: ALB Controller の subnet auto-discovery 用
- **`aws/route53/lookup/`**: Route53 zone を data resource で lookup する共通モジュール（`aws/vpc/lookup/` パターンに倣う）
- **`aws/alb/modules/`**: ACM cert + 将来の ALB 周辺 AWS リソース（WAF / Shield 等）を収める新 stack

ロードマップ spec（`2026-05-02-eks-production-platform-roadmap-design.md`）の **Decision 3**（北南は AWS LB Controller Ingress mode + ALB → Service direct）と Phase 1 完了条件のうち、ALB / ExternalDNS / ACM 関連項目を本 spec で消化する。

## Goals

1. AWS Load Balancer Controller を install し、`Ingress` リソースから ALB が自動 provisioning される状態を作る
2. ExternalDNS を install し、Service / Ingress の `external-dns.alpha.kubernetes.io/hostname` annotation から Route53 レコードが自動生成される状態を作る
3. ACM wildcard cert `*.panicboat.net` を作成し、ALB Controller が cert auto-discovery で HTTPS 終端に利用できる状態を作る
4. IRSA roles（ALB Controller / ExternalDNS）を `aws/eks/modules/` に追加し、IAM 権限を最小限に絞る（ExternalDNS は zone ARN scope 制約）
5. VPC subnet に `kubernetes.io/role/elb` / `kubernetes.io/role/internal-elb` タグを追加し、ALB Controller の subnet auto-discovery を有効化
6. Route53 zone lookup を共通モジュール `aws/route53/lookup/` として整備（複数 stack から再利用可能に）
7. Phase 5 nginx end-to-end validation の北南トラフィック前提を満たす

## Non-goals (Out of scope, with explicit follow-up tracking)

- **cert-manager**（in-cluster TLS / webhook cert 用） → Phase 4
- **`dystopia.city` の ACM cert / ExternalDNS 拡張** → monorepo K8s 移行 spec
- **ALB Controller の Gateway API mode** → ロードマップ Decision 3 で Ingress mode 固定
- **Internal ALB の活用**（`internal-elb` タグは付けるが利用は将来） → 用途出現時に別 spec
- **AWS WAF / Shield** → セキュリティ要件顕在化時に `aws/alb/modules/` に追加
- **Karpenter / 観測スタック** → Plan 2 / Phase 3
- **ExternalDNS の `txtOwnerId` 戦略の精緻化** → 本 spec では cluster name (`eks-production`) 単一所有、複数 cluster で同 zone 共有時に再評価

## Architecture decisions

ロードマップ spec の決定を継承するのみ、本 spec で新規 architectural decision は発生しない。

| 継承元 | 内容 |
|---|---|
| Roadmap Decision 3 | 北南は AWS LB Controller **Ingress mode**、ALB → Service direct（target-type=ip） |
| Roadmap Q5（Production domain） | platform domain = `panicboat.net`、monorepo apps domain = `dystopia.city`（後者は本 spec 範囲外） |

## Component decisions

各コンポーネントの実装上の値を確定する。

### ExternalDNS policy = `sync`

- 既定値: `sync`（auto-delete on Service / Ingress deletion）
- Trade-off:
  - メリット: stale Route53 record が残らない、運用が clean
  - デメリット: Ingress を誤って削除すると即時に hostname 失効
- 緩和策: Flux GitOps 経由のみで Ingress 管理（README の GitOps 原則として既存記載済）。直接 `kubectl delete ingress` の運用ルールは引き続き禁止

### ACM cert auto-discovery

ALB Controller は Ingress の `host` フィールドが ACM cert の SAN にマッチする場合、cert を自動 bind する。本 spec で作成する `*.panicboat.net` wildcard cert は `host: <name>.panicboat.net` の任意 Ingress に自動 bind されるため：

- **`alb.ingress.kubernetes.io/certificate-arn` annotation の明示は不要**（Phase 5 nginx Ingress でも書かない）
- ACM cert ARN を `kubernetes/helmfile.yaml.gotmpl` に流す必要なし、cross-stack value flow が発生しない

### Route53 zone lookup を共通モジュール化

`aws/vpc/lookup/` パターンに倣い、`aws/route53/lookup/` を新設して Route53 zone の data resource lookup を集約。Consumer は 2 stacks（`aws/alb/modules/` の ACM 用、`aws/eks/modules/` の ExternalDNS IRSA scope 制約用）。

将来 `dystopia.city` zone を追加する際、または他の AWS リソースが zone を参照する際に、lookup module 1 箇所の更新で済む。

### `aws/alb/modules/` 新設の理由

- ACM cert は EKS とは独立したライフサイクル（cert は EKS 再作成で道連れにすべきではない）
- ALB 周辺の AWS リソース（WAF / Shield / 共通 SG）が将来追加される想定
- 既存 stack convention `aws/{service}/modules` に綺麗に乗る

## Components 変更マトリクス

### AWS layer (terragrunt)

| File / Resource | 種別 | 内容 |
|---|---|---|
| `aws/vpc/modules/main.tf` | modify | `public_subnet_tags` に `kubernetes.io/role/elb = "1"` を追加、`private_subnet_tags` に `kubernetes.io/role/internal-elb = "1"` を追加（Tier タグは既存維持） |
| `aws/route53/lookup/main.tf` | create | `data "aws_route53_zone" "panicboat_net"` を定義 |
| `aws/route53/lookup/outputs.tf` | create | `zones.panicboat_net.{id, arn, name}` を export |
| `aws/route53/lookup/terraform.tf` | create | provider 設定（既存パターン踏襲） |
| `aws/eks/modules/addons.tf` | modify | `module "alb_controller_irsa"` + `module "external_dns_irsa"` を追加。ExternalDNS 側は `module "route53"` 経由で `external_dns_hosted_zone_arns` に panicboat.net zone ARN を渡し権限を絞る |
| `aws/eks/modules/lookups.tf` | modify | `module "route53"` を追加 |
| `aws/eks/modules/outputs.tf` | modify | `alb_controller_role_arn` / `external_dns_role_arn` を export |
| `aws/alb/Makefile` | create | terragrunt 実行 helper（`aws/eks/Makefile` 踏襲） |
| `aws/alb/root.hcl` | create | terragrunt root（既存 stack と同型、`project_name = "alb"`） |
| `aws/alb/envs/production/env.hcl` | create | environment 固有値（aws_region 等） |
| `aws/alb/envs/production/terragrunt.hcl` | create | env から module へ inputs 渡し |
| `aws/alb/envs/production/.terraform.lock.hcl` | create | provider lock file |
| `aws/alb/modules/terraform.tf` | create | provider 設定 |
| `aws/alb/modules/variables.tf` | create | environment / aws_region / common_tags |
| `aws/alb/modules/lookups.tf` | create | `module "route53" { source = "../../route53/lookup" }` |
| `aws/alb/modules/main.tf` | create | `aws_acm_certificate "wildcard_panicboat_net"` + `aws_acm_certificate_validation` + DNS validation の `aws_route53_record` |
| `aws/alb/modules/outputs.tf` | create | `wildcard_panicboat_net_cert_arn` を export（将来の WAF / Shield 連携で参照される可能性） |

### Kubernetes layer (helmfile / kustomize)

| File / Resource | 種別 | 内容 |
|---|---|---|
| `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml` | create | Helm chart `eks/aws-load-balancer-controller` 最新 stable を pin、namespace `kube-system` |
| `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` | create | `clusterName: eks-production`、`region: ap-northeast-1`、`vpcId` を `.Values.cluster.vpcId` から差し込み、`serviceAccount.annotations` で IRSA role ARN を `.Values.cluster.albControllerRoleArn` から差し込み |
| `kubernetes/components/external-dns/production/helmfile.yaml` | create | Helm chart `external-dns/external-dns` 最新 stable を pin、namespace `external-dns` |
| `kubernetes/components/external-dns/production/values.yaml.gotmpl` | create | `provider: aws`、`policy: sync`、`domainFilters: [panicboat.net]`、`txtOwnerId: eks-production`、`serviceAccount.annotations` で IRSA role ARN を `.Values.cluster.externalDnsRoleArn` から差し込み |
| `kubernetes/components/external-dns/production/namespace.yaml` | create | `external-dns` namespace 定義 |
| `kubernetes/helmfile.yaml.gotmpl` | modify | production env values に `cluster.vpcId` / `cluster.albControllerRoleArn` / `cluster.externalDnsRoleArn` を追加（Plan 1b の `cluster.eksApiEndpoint` パターンに倣う） |
| `kubernetes/manifests/production/{aws-load-balancer-controller,external-dns}/` | hydrated | `make hydrate ENV=production` 出力 |
| `kubernetes/manifests/production/00-namespaces/namespaces.yaml` | regenerated | `external-dns` namespace 追加 |
| `kubernetes/manifests/production/kustomization.yaml` | regenerated | 2 component 追加 |
| `kubernetes/README.md` | modify | Production Operations セクションに ALB Controller / ExternalDNS / ACM 運用を追加 |

## Cross-stack value flow

```
aws/route53/lookup/                               aws/alb/modules/
  data.aws_route53_zone.panicboat_net    ──┬──→  ACM cert DNS validation record
                                            │     output: wildcard_panicboat_net_cert_arn
                                            │
                                            └──→  aws/eks/modules/addons.tf
                                                    external_dns_irsa hosted_zone_arns
                                                    output: external_dns_role_arn
                                                            alb_controller_role_arn
                                                            ↓
                                                    手動で kubernetes/helmfile.yaml.gotmpl の
                                                    production env values に転記
                                                    (Plan 1b の eksApiEndpoint と同パターン)
```

ACM cert ARN は ALB Controller の auto-discovery で利用するため、kubernetes layer への転記は不要。

`aws_eks_cluster.this.vpc_config[0].vpc_id` か `module.vpc.vpc.id` から取得した `vpc_id` も `aws/eks/modules/outputs.tf` で export し、`kubernetes/helmfile.yaml.gotmpl` に転記。

## Migration sequence

Plan 1c-α と同じく既存 service routing への破壊的変更なし、Flux suspend 不要：

> **依存関係の整理**:
> - `aws/route53/lookup/` は **terragrunt stack ではなく Terraform child module**（`aws/vpc/lookup/` と同型）。`aws/alb/` と `aws/eks/` から `module "route53" { source = "../../route53/lookup" }` で参照される
> - `aws/alb/` と `aws/eks/` の apply は相互依存なし（並列実行可、CI の serialization に従う）
> - kubernetes layer は AWS apply 完了を待つ必要がある（IRSA role ARN / vpc_id が helmfile values に必要）

| Step | 内容 | 実行者 |
|---|---|---|
| 1 | Code 変更を 1 PR にまとめて main へ merge（`aws/route53/lookup` + `aws/vpc/` + `aws/eks/` + `aws/alb/` + `kubernetes/` + manifests + README）。**ただし `kubernetes/helmfile.yaml.gotmpl` の IRSA role ARN / vpc_id は Step 5 で埋めるため本 PR では含めない**（または placeholder 値で含めて Step 5 後に値埋め commit） | controller (subagent) + user |
| 2 | CI: `aws/vpc/envs/production` → terragrunt apply（subnet タグ追加、ALB / EKS への副作用なし） | CI auto |
| 3 | CI: `aws/alb/envs/production` → terragrunt apply（ACM cert + DNS validation。Route53 zone は `route53/lookup` 経由 data lookup） | CI auto |
| 4 | CI: `aws/eks/envs/production` → terragrunt apply（IRSA roles 追加、ExternalDNS hosted_zone_arns 制約） | CI auto |
| 5 | operator が `terragrunt output` で IRSA role ARN / vpc_id を取得し、`kubernetes/helmfile.yaml.gotmpl` の production env values に転記する **follow-up PR** | user |
| 6 | follow-up PR merge → CI: `kubernetes/manifests/production` Hydrate workflow → Flux 自動 reconcile → ALB Controller / ExternalDNS install | CI + Flux |
| 7 | Verification battery（後述） | user |

> **Step 5 の理由**: terraform output 値（IRSA role ARN / vpc_id）は initial apply 時に確定するため、Step 4 完了後でないと値が分からない。Plan 1b の `eksApiEndpoint` と同パターン。
>
> **代替案**: kubernetes/helmfile.yaml.gotmpl に placeholder（例: `albControllerRoleArn: "REPLACE_AFTER_APPLY"`）で含めて 1 PR にまとめ、apply 後に値埋めの amendment commit を同 branch に追加（merge 前に値が確定）。本 spec では Plan 1b と同じく follow-up PR を選択（PR 単位の atomicity 重視）。

## Verification checklist

各 Goal について、以下のコマンドが pass すれば達成とみなす。

### IRSA roles

```bash
aws iam get-role --role-name eks-production-alb-controller --query 'Role.Arn'
aws iam get-role --role-name eks-production-external-dns --query 'Role.Arn'
# 両方 ARN を返す
```

### ACM cert

```bash
aws acm list-certificates --region ap-northeast-1 \
  --query "CertificateSummaryList[?DomainName=='*.panicboat.net'].{Arn:CertificateArn,Status:Status}"
# Status: ISSUED
```

### Subnet tags

```bash
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> \
  --query "Subnets[].{Id:SubnetId,Tags:Tags[?Key=='kubernetes.io/role/elb' || Key=='kubernetes.io/role/internal-elb']}"
# public subnets に kubernetes.io/role/elb=1、private subnets に kubernetes.io/role/internal-elb=1
```

### ALB Controller

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller   # READY 1/1 (chart デフォルト)
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=20
# IRSA で AWS API に successful auth した log が見える
```

### ExternalDNS

```bash
kubectl get deployment -n external-dns external-dns                  # READY 1/1
kubectl logs -n external-dns deploy/external-dns --tail=20
# All records are already up to date / Applying changes 等の log
```

### End-to-end smoke test

minimal Ingress を apply して ALB + Route53 record + ACM auto-discovery が動作することを確認：

```bash
# nginx app をデプロイ
kubectl run smoke-target --image=nginx:alpine --port=80 -n default
kubectl expose pod smoke-target --port=80 --target-port=80 -n default --name=smoke-svc

# Ingress（HTTPS、cert ARN annotation 不要）
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: smoke-ing
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    external-dns.alpha.kubernetes.io/hostname: smoke.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: smoke.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: smoke-svc
                port:
                  number: 80
EOF

sleep 90
kubectl get ingress smoke-ing -n default                             # ADDRESS に ALB DNS が出る
aws route53 list-resource-record-sets --hosted-zone-id <panicboat_net_zone_id> \
  --query "ResourceRecordSets[?Name=='smoke.panicboat.net.']"        # A / AAAA / TXT (txtOwnerId) record

# HTTPS 疎通（cert auto-discovery 確認）
curl -I https://smoke.panicboat.net/                                  # 200 OK、cert chain は ACM

# cleanup（policy: sync で Route53 record も自動削除されるはず）
kubectl delete ingress smoke-ing -n default
kubectl delete svc smoke-svc -n default
kubectl delete pod smoke-target -n default
sleep 30
aws route53 list-resource-record-sets --hosted-zone-id <panicboat_net_zone_id> \
  --query "ResourceRecordSets[?Name=='smoke.panicboat.net.']"        # 結果が空（自動削除確認）
```

## Rollback strategy

PR merge 後に問題が発覚した場合：

| 失敗フェーズ | 戻し方 |
|---|---|
| Subnet tag 追加（VPC apply） | terragrunt destroy 不要、tag 削除のみ。ALB / EKS への影響なし |
| ACM cert 作成（ALB stack apply） | revert PR + terragrunt destroy（ACM cert + DNS validation record が削除される、ALB が cert を使っていない状態なら無害） |
| IRSA roles 追加（EKS stack apply） | revert PR + terragrunt destroy（roles 削除、ALB Controller / ExternalDNS は ServiceAccount 認証失敗で動作停止だが production 影響なし） |
| ALB Controller 起動失敗 | revert PR で Flux が manifest を消す。または `flux suspend kustomization flux-system -n flux-system` + 手動 `kubectl delete deploy -n kube-system aws-load-balancer-controller` |
| ExternalDNS が Route53 record を誤って削除 | `policy: sync` の trade-off。手動で record を再作成、または `policy: upsert-only` に変更して別 PR で apply |
| Smoke test の ALB が HTTPS で動かない | ACM cert が `ISSUED` でない可能性。validation record が Route53 に正しく入っているか `aws acm describe-certificate` で確認 |

すべてのフェーズで **production にアプリ未投入のため業務影響なし**。

## Future Specs（明示的に記録）

本 spec のスコープ外で、別 spec として追跡する：

- **monorepo K8s 移行**: `dystopia.city` zone の ACM cert / ExternalDNS 拡張 / ALB Ingress 設計
- **AWS WAF / Shield 連携**: セキュリティ要件顕在化時に `aws/alb/modules/` へ追加
- **Internal ALB の活用**: VPC 内部からのアクセス要件出現時
- **`txtOwnerId` 戦略**: 複数 cluster で同 zone 共有時の所有権マーカー設計
- **cert-manager**（Phase 4 spec で扱う）

## References

- ロードマップ spec: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`
- Plan 1a (Flux bootstrap): merged in PR #255
- Plan 1b (Cilium chaining): merged in PR #257
- Plan 1b 学び反映: merged in PR #259
- Plan 1c-α spec: `docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md`、merged in PR #260
- Plan 1c-α follow-up: merged in PR #261
- aws-eks-production spec: `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`
- aws-vpc cross-stack spec: `docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md`（`aws/vpc/lookup/` パターンの先行事例）
- AWS Load Balancer Controller Helm chart: `https://github.com/aws/eks-charts/tree/master/stable/aws-load-balancer-controller`
- ExternalDNS Helm chart: `https://github.com/kubernetes-sigs/external-dns/tree/master/charts/external-dns`
- terraform-aws-modules/iam `iam-role-for-service-accounts`: `attach_load_balancer_controller_policy` / `attach_external_dns_policy`（既存 vpc_cni / ebs_csi の同モジュール利用）
