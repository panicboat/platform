# EKS Production Platform Roadmap

## Overview

EKS production cluster `eks-production`（aws/eks の PR #234, #235, #239 で構築済）に各種コンポーネントを段階導入し、production-grade な platform として monorepo を将来受け入れられる状態まで整備するための **roadmap level** の spec。

本 spec は roadmap であり、各 Phase の詳細実装（manifest / Helm values / IRSA 等）は本 spec を起点として別 spec で書き起こす。Phase 1 の詳細 spec が本 spec の直接の後続。

## Goals

1. monorepo 移行を将来受け入れられる production-grade な platform を構築する
2. local 環境（k3d）の観測スタックを production 仕様（S3 永続化、IRSA、resource sizing、認証）に焼き直して持ち込む
3. 各 Phase の完了条件を明示し、段階的に検証しながら進められるようにする
4. nginx sample による end-to-end validation を最終 Phase の完了条件とし、本 spec のスコープを「platform 自体の production-readiness」に限定する

## Non-goals (Out of scope)

- monorepo 本体の K8s 移行（別 spec で扱う）
- develop / staging EKS 構築（別 spec、production と同 module で複製可能）
- Cilium Gateway Controller の北南トラフィック利用（北南は AWS LB Controller の Ingress mode で固定）
- AWS LB Controller の Gateway API mode 利用（Ingress mode で固定）
- Velero（cluster / PV バックアップ）の採用
- AWS for Fluent Bit（CloudWatch Logs export）の採用
- cert-manager の Phase 1 / Phase 2 への前倒し採用（Phase 4 で導入）
- monorepo の認証 Pattern A の production 採用（backend に fallback 実装は残るが、production 本線は Pattern B）

## Architecture decisions

各決定について採用理由とトレードオフを明示する。

### Decision 1: GitOps 実装は FluxCD

local 環境と同じ FluxCD + Helmfile Hydration Pattern を採用する。

- 採用理由: local との一貫性、既存の `kubernetes/components/` および `kubernetes/manifests/` のディレクトリ構造をそのまま production env に拡張できる。Hydration Pattern による「実際に適用される YAML が Git 上に存在する」可視性 / 安全性 / 環境分離の利点を production でも享受する
- トレードオフ: panicboat に `argo-workflows` リポジトリが存在するため Argo CD への乗り換えも選択肢として議論したが、Argo Workflows と Argo CD は別物。Argo CD への乗り換えは本 spec ではコスト便益が見合わないため見送り
- 影響範囲: Phase 1 で FluxCD bootstrap、`kubernetes/clusters/production/` および `kubernetes/manifests/production/` を新設

### Decision 2: CNI は chaining mode（VPC CNI + Cilium）

VPC CNI を IPAM として残し、Cilium を chaining mode で乗せる。aws-eks-production spec の決定を維持する。

- 採用理由:
  1. Pod IP が VPC subnet から払い出されるため、ALB target-type=ip が素直に動く
  2. AWS Support 経路を維持できる（VPC CNI は AWS managed addon）
  3. AWS 公式 blog "Getting started with Cilium service mesh on Amazon EKS" が chaining mode + KPR + L7 機能の組み合わせを実例で実証している
  4. Cilium 公式 blog（2025-07-08 "Installing Cilium on EKS in Overlay(BYOCNI) and CNI Chaining Mode"）も chaining mode を canonical な選択肢の 1 つとして扱っている
- トレードオフ:
  1. CNI が二層になり、VPC CNI と Cilium 両方の運用責任を負う（version bump / CVE 追従が二重）
  2. Cilium の全機能を制限なしで使うには ENI mode の方が一層構成で clean だが、ENI mode は AWS native サポート対象外。ENI mode 移行は別 spec（Future Specs 参照）
  3. `cni.chainingMode=aws-cni` + `cni.exclusive=false` + KPR の組み合わせが EKS 1.35 / AL2023 ARM64 で動作するかは Phase 1 で実機検証必須（Open Questions 参照）
- Future migration path: ENI mode への移行は別 spec "EKS CNI 戦略見直し"。トリガーは Cluster Mesh 要件 / VPC CNI の制約発覚 / Cilium Security Groups for Pods の優位性確立

### Decision 3: 北南トラフィックは AWS LB Controller Ingress mode + ALB → Service direct

外部からの HTTP/HTTPS リクエストは ALB が受け、Service（target-type=ip）に直接転送する。Cilium Gateway Controller は北南で使わない。

- 採用理由:
  1. 責務分離: AWS managed 層（ALB + ACM + WAF）と cluster 内層を混ぜず、障害切り分けを clear に保つ
  2. ALB の機能（AWS WAF / ACM 自動 rotation / ALB access log / target group health check / OIDC authn action）を素直に使える
  3. AWS LB Controller の Ingress mode は最も枯れた経路（Gateway API mode より長く運用されている）
  4. monorepo の Ingress 設計が `Ingress` リソース 1 個で ALB + ACM + Route53 を立ち上げる単純構造に収まる
- トレードオフ:
  1. 北南トラフィックの ALB → Pod 区間は Hubble の観測範囲外（cluster 内に入った時点から Cilium が観測する）
  2. ALB access log（S3）と CloudWatch ALB metrics で補完する。Beyla は Pod 内のアプリで動くため、ALB 経由で到達したリクエストの app-level トレースは取得できる
  3. Cilium Gateway Controller を Decision 4 で東西用に有効化するため、controller を北南でも使う統一感は失う

### Decision 4: 東西トラフィックは Pattern B-Full（Cilium Gateway + HTTPRoute + CiliumEnvoyConfig）

cluster 内 Pod 間の gRPC / HTTP 通信で JWT 検証が必要なものは、Cilium Gateway Controller の Envoy が JWT を検証して `x-user-id` / `x-organization-id` ヘッダーを注入する。backend は注入されたヘッダーを信頼する。

- 採用理由:
  1. monorepo の `docs/分散システム設計/AUTHENTICATION.md` に Pattern B として実装方針が明記されている
  2. ポリグロット化（Ruby / Go / Rust 等）が現実的に発生した場合、認証ロジックを各言語で重複実装する負債を最初から避けられる
  3. backend の `extract_user_id` は `x-user-id` 優先 + JWT 直接検証 fallback の両対応で実装されているため、Pattern B 採用時に backend コード変更が不要
  4. AWS 公式 blog が chaining mode で `CiliumEnvoyConfig` を使った L7 traffic policy を実例として提示しており、技術的成立は確認済
- トレードオフ:
  1. 東西トラフィックに 1 ホップ追加（Pod → Cilium Gateway → Pod）。Cilium Envoy はサイドカーレスで同 node 上に居るため latency overhead は限定的だが、ゼロではない
  2. Cilium Gateway Controller を critical path に入れる運用責任を負う（観測 / SLO / アップグレード時の影響評価）
  3. KPR を有効化する必要があり、VPC CNI の Service datapath との干渉を Phase 1 で検証必須
  4. Cilium 固有 CRD（`CiliumEnvoyConfig`）への依存を許容する（Gateway API 標準のみで完結しない）。ただし monorepo の design doc も Cilium 前提で書かれているため追加の lock-in ではない
- Pattern A との関係: backend には Pattern A（直接 JWT 検証）の fallback 実装が残るが、production の本線は Pattern B。Cilium Gateway 障害時に Pattern A で fallback 動作する性質は **保険として残す** が、運用は Pattern B 経路を前提とする

### Decision 5: Compute は system Managed Node Group + Karpenter NodePool の二層

aws-eks-production spec で構築済の system MNG（m6g.large × 2-4, AL2023 ARM64, gp3 50 GiB）を残し、アプリ用 Pod は Karpenter NodePool で動的にプロビジョニングする EC2 に逃がす。

- 採用理由:
  1. Karpenter controller / cluster critical addon（CoreDNS / Cilium / kube-prometheus-stack の operator 等）を安定 node に pin したい
  2. Karpenter Pod が Karpenter で起動した node に乗る循環依存を避けるため、controller は MNG 上に置く
  3. アプリ Pod は Karpenter で spot を含めた最適化を効かせる
- トレードオフ:
  1. Node pool が 2 系統になり、Pod の `nodeSelector` / `tolerations` 設計を慎重に行う必要がある
  2. system MNG の最低 2 instance 常駐コストが残る
  3. 将来「全部 Karpenter に寄せる」決定をするかは別 spec
- 影響範囲: Phase 2 で Karpenter controller + EC2NodeClass + 1 NodePool + IRSA + EC2 instance profile + SQS interruption queue + EventBridge rules を導入

### Decision 6: Pod autoscaling foundation は Metrics Server + KEDA

HPA の前提として Metrics Server を入れ、event-driven スケール（SQS / Kafka / Cron / Prometheus query 等）を視野に入れて KEDA も Phase 1 から入れる。

- 採用理由:
  1. KEDA は HPA を置き換えず、HPA を内部生成する layer。Metrics Server は KEDA が作る HPA でも resource metrics 用に必要
  2. monorepo にいずれ非同期 worker / batch / queue consumer が乗ることが想定され、CPU ベースの HPA だけでは表現力が足りない
  3. KEDA は CNCF Graduated（2025 年に Incubating → Graduated に昇格）。production 採用に値する成熟度
  4. Phase 1 で foundation として入れておけば、Phase 5 nginx validation で `ScaledObject` を使った Prometheus metric ベースのスケールを demo できる
- トレードオフ:
  1. nginx 単体程度なら HPA 単体で足り、KEDA は overkill。ただし platform foundation として将来用に入れる判断
  2. KEDA controller のリソース消費 / アップグレード追従コストを負う

### Decision 7: 完了基準は nginx sample による end-to-end validation

monorepo 移行ではなく、nginx sample が全コンポーネントを通して動作することを本 spec の完了条件とする。

- 採用理由:
  1. monorepo 側の準備状況に platform spec の完了が引きずられない
  2. nginx は最小構成で全 Phase の成果物（CNI / Ingress / DNS / TLS / 観測 / Secret / autoscaling / Karpenter）を踏むパスを demo できる
  3. monorepo 移行は独立した別 spec として扱える
- トレードオフ:
  1. nginx は monorepo の代用にはならない（gRPC / Pattern B の JWT flow / Beyla の Ruby インスツルメンテーション等は完全には検証されない）
  2. monorepo 移行 spec で改めて end-to-end 検証が必要になる

## Component inventory

採用しないコンポーネントとその理由も明示する。

### Adopted

| Component | Phase | 役割 |
|---|---|---|
| Cilium（再構成） | 1 | CNI chaining + KPR + L7 Envoy + Gateway Controller |
| Gateway API CRDs | 1 | HTTPRoute / Gateway リソース定義（Decision 4 の前提） |
| FluxCD | 1 | GitOps controller、`manifests/production/` を sync |
| AWS Load Balancer Controller | 1 | ALB を Ingress リソースから provisioning（Ingress mode 固定） |
| ExternalDNS | 1 | Route53 レコードを Service / Ingress から自動生成 |
| Metrics Server | 1 | HPA の resource metrics 提供 |
| KEDA | 1 | HPA の external trigger layer |
| Karpenter | 2 | Node 動的 provisioning |
| kube-prometheus-stack | 3 | Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics |
| Thanos sidecar | 3 | Prometheus データを S3 に長期保管 |
| Loki | 3 | Log 集約、S3 backend |
| Tempo | 3 | Trace 集約、S3 backend |
| Fluent Bit | 3 | Pod stdout 収集、OTLP で Collector に送る |
| OpenTelemetry Operator + Collector | 3 | Telemetry hub |
| Beyla | 3 | eBPF auto-instrumentation |
| External Secrets Operator | 4 | AWS Secrets Manager / SSM Parameter Store → K8s Secret |
| Reloader | 4 | Secret / ConfigMap 変更時に Pod 自動 rollout |
| cert-manager | 4 | webhook cert / 内部 mTLS 用の TLS 証明書 |
| Grafana 認証（oauth2-proxy or ALB OIDC） | 4 | Phase 4 spec で詳細選択 |

### Not adopted

| Component | 不採用理由 |
|---|---|
| Velero | EKS の etcd は AWS managed（バックアップは AWS 側）、EBS volume は AWS snapshot で取得可能、cluster 内に取り戻したい stateful 状態を持たない（DB は RDS、ファイルは S3 想定）。要件が顕在化した時点で別 spec |
| AWS for Fluent Bit (CloudWatch Logs export) | Fluent Bit → OTel → Loki → S3 で完結している。CloudWatch にも流すと二重管理 + コスト二重。監査・コンプライアンス要件が顕在化した時点で別 spec |
| Cluster Autoscaler | Karpenter で代替 |
| Cilium Gateway Controller の北南利用 | Decision 3 により AWS LB Controller Ingress mode で固定 |
| AWS LB Controller の Gateway API mode | Decision 3 により Ingress mode で固定 |

### S3 buckets（Phase 3 で構築）

| Bucket（命名は Phase 3 spec で確定） | 用途 |
|---|---|
| `<thanos-bucket>` | Thanos が Prometheus データを長期保管 |
| `<loki-bucket>` | Loki の log chunk |
| `<tempo-bucket>` | Tempo の trace data |

各 bucket に対する IRSA role は Phase 3 spec で構築する（`aws/eks/modules/` に追加するか別 module にするかは Phase 3 spec で決定）。

## Phase breakdown

各 Phase は独立した spec / plan として実装する。Phase 間の依存は完了条件と前提を明示する。

### Phase 1: Foundation

含むコンポーネント: Cilium 再構成、Gateway API CRDs、FluxCD、AWS Load Balancer Controller、ExternalDNS、Metrics Server、KEDA

#### 完了条件

- FluxCD が `kubernetes/manifests/production/` を sync できる
- Cilium が chaining mode（`cni.chainingMode=aws-cni` + `cni.exclusive=false`）+ KPR + Envoy + Gateway Controller の構成で起動する
- 任意の `Ingress` リソースから ALB が provisioning される
- 任意の `Service` / `Ingress` の `external-dns.alpha.kubernetes.io/hostname` annotation で Route53 にレコードが生成される
- `kubectl top pods` が値を返す
- KEDA controller が起動し、`ScaledObject` リソースが作成可能
- Cilium Gateway Controller が `Gateway` リソースから cluster 内部 LB を立ち上げる（東西用、北南未使用）

#### 前提

- aws-eks-production spec の完了（PR #234, #235, #239 で完了済）
- Route53 hosted zone（既存利用 or Phase 1 内で新規作成、Open Questions 参照）

### Phase 2: Compute autoscaling

含むコンポーネント: Karpenter

#### 完了条件

- Karpenter controller が system MNG 上で起動し、EC2NodeClass + 1 NodePool が定義されている
- Karpenter NodePool に matching する Pod を投げると node が自動起動する
- Spot interruption notification が SQS 経由で受信され、graceful drain が実行される
- system MNG と Karpenter NodePool 上の Pod の配置ルール（taint / toleration / nodeSelector）が文書化されている

#### 前提

- Phase 1 完了

### Phase 3: Observability

含むコンポーネント: kube-prometheus-stack（+ Thanos sidecar）、Loki、Tempo、Fluent Bit、OpenTelemetry Operator + Collector、Beyla、Grafana、S3 bucket × 3、IRSA × 3

#### 完了条件

- Prometheus が cluster の metrics を scrape し、Thanos sidecar 経由で S3 に upload する
- Loki が Pod stdout を Fluent Bit + OTel 経由で受け取り、S3 に保存する
- Tempo が Beyla / Hubble の trace を OTel 経由で受け取り、S3 に保存する
- Grafana から Prometheus / Loki / Tempo の data source が参照可能
- Hubble の L3/L4/L7 flow が OTLP で OTel Collector に送られている
- 各コンポーネントのリソース要求が production 想定で設定されている

#### 前提

- Phase 1 完了（Cilium L7 / Hubble が動作）
- Phase 2 完了（Karpenter NodePool 上で観測スタックの一部 Pod が動作する想定）

### Phase 4: Secrets & App readiness

含むコンポーネント: External Secrets Operator、Reloader、cert-manager、Grafana 認証

#### 完了条件

- ESO が AWS Secrets Manager の値を K8s Secret に sync する
- Reloader が Secret / ConfigMap 変更時に annotation 付きの Deployment を rollout する
- cert-manager が webhook 用 cert を発行できる
- Grafana が認証ゲート経由でないと開けない

#### 前提

- Phase 1, 2, 3 完了

### Phase 5: End-to-end validation (nginx sample)

含むコンポーネント: nginx Deployment + Service + Ingress + HPA + KEDA `ScaledObject` + ExternalSecret

#### 完了条件 / End-to-end チェックリスト

- [ ] Pod が起動して Cilium chaining mode で IP を持つ（Phase 1 / VPC CNI bootstrap）
- [ ] ClusterIP Service の DNS 解決ができる（Phase 1 / CoreDNS）
- [ ] `Ingress` から ALB が起動する（Phase 1 / ALB Controller）
- [ ] `external-dns.alpha.kubernetes.io/hostname` annotation で Route53 にレコードが作られる（Phase 1 / ExternalDNS）
- [ ] ACM 証明書が ALB に bind されて HTTPS が通る
- [ ] HPA を `cpu: 50%` で書いて、負荷をかけたら replica が増える（Phase 1 / Metrics Server）
- [ ] KEDA `ScaledObject`（Prometheus query ベース）でも replica が増える（Phase 1 / KEDA + Phase 3 / Prometheus）
- [ ] 高負荷で NodePool が空いたら Karpenter が node を増やす（Phase 2）
- [ ] Hubble が nginx Pod の L3/L4/L7 フローを見せる（Phase 3 / Cilium Hubble + OTel）
- [ ] Beyla が nginx の HTTP request span を Tempo に送る（Phase 3 / Beyla）
- [ ] Pod の stdout が Fluent Bit → OTel → Loki に流れて Grafana で見える（Phase 3）
- [ ] Prometheus に nginx のメトリクスが入って Grafana ダッシュボードで見える（Phase 3）
- [ ] AWS Secrets Manager の値が ESO 経由で Secret になり、nginx に env として注入できる（Phase 4 / ESO）
- [ ] Secrets Manager 側を更新したら Reloader で nginx Pod が rollout される（Phase 4 / Reloader）
- [ ] Grafana が認証ゲートで保護されている（Phase 4）

#### 前提

- Phase 1, 2, 3, 4 完了

## Open Questions

Phase 1 の foundation 構築時に必ず実機検証する項目。各項目は Phase 1 spec で具体化する。

1. **chaining mode + KPR + Gateway API + CEC が EKS 1.35 / AL2023 ARM64 で完全動作するか**: AWS 公式 blog の実証は version が異なる可能性がある。Phase 1 開始時点の EKS / Cilium / VPC CNI の version で再確認する。動作不可の場合のフォールバックは Pattern A での monorepo 投入 + 別 spec で ENI mode 移行検討
2. **`kubeProxyReplacement` を `true`（full）にするか `partial` にするか**: VPC CNI の AWS NLB target group 連携 / Pod readiness gate との互換性を確認
3. **`endpointRoutes.enabled` の値**: VPC CNI の routing と Cilium endpoint routing の干渉を回避するための適切な設定
4. **Cilium Helm `envoy.enabled` を独立 DaemonSet にするか agent 内蔵にするか**: リソース消費 vs 障害分離のトレードオフ。Cilium 公式の chaining mode セットアップ手順を再確認
5. **Production domain の決定**: Route53 hosted zone をどの domain で運用するか（既存利用 or 新規取得）。ExternalDNS / ACM の構成に直結
6. **Grafana 認証方式の選択**: oauth2-proxy（OIDC provider に依存）か ALB OIDC action か。Phase 4 spec で確定

## Future Specs

本 spec のスコープ外で、別 spec として独立に進める予定の項目。

- **EKS CNI 戦略見直し**: chaining → Cilium ENI mode 移行評価。トリガーは Cluster Mesh 要件 / VPC CNI の制約発覚 / Cilium Security Groups for Pods の優位性確立
- **monorepo K8s 移行**: monorepo 本体（Hanami gRPC backend + Next.js BFF）を本 platform に移行する spec。Pattern B-Full の HTTPRoute + CiliumEnvoyConfig での JWT 検証パイプラインを含む
- **develop / staging EKS 構築**: production と同 module で複製、env 設定差分のみ
- **Velero 採用検討**: cluster / PV バックアップが要件として顕在化した時点で
- **AWS for Fluent Bit (CloudWatch Logs export)**: 監査・コンプライアンス要件が顕在化した時点で

## References

- aws-eks-production spec: `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`
- aws-eks-production plan: `docs/superpowers/plans/2026-05-01-aws-eks-production.md`
- aws-vpc cross-stack spec: `docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md`
- monorepo authentication: `panicboat/monorepo` の `docs/分散システム設計/AUTHENTICATION.md`
- monorepo authorization: `panicboat/monorepo` の `docs/分散システム設計/AUTHORIZATION.md`
- AWS blog: "Getting started with Cilium service mesh on Amazon EKS" (`https://aws.amazon.com/jp/blogs/opensource/getting-started-with-cilium-service-mesh-on-amazon-eks/`)
- Cilium blog: "Installing Cilium on EKS in ENI Mode" (2025-06-19, `https://cilium.io/blog/2025/06/19/eks-eni-install/`)
- Cilium blog: "Installing Cilium on EKS in Overlay(BYOCNI) and CNI Chaining Mode" (2025-07-08, `https://cilium.io/blog/2025/07/08/byonci-overlay-install/`)
