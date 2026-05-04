# EKS Production: Karpenter Tuning Design

## Background

Plan 2 (Karpenter migration, PR #271-#276) で導入した `karpenter_bootstrap` MNG と `system-components` NodePool について、Plan 2 完了後の運用レビューで以下 2 点の改善余地が判明した:

1. **bootstrap MNG 命名** (Plan 2 learnings PR #278 / L1): `karpenter_bootstrap` は terraform-aws-modules/eks Karpenter sample 由来の命名で「初回起動」の含意があるが、本 cluster では Karpenter controller pod (replicas=2) を長期常駐させる host MNG として機能している。役割を識別子から読み取れない。

2. **NodePool requirements**: Plan 2 spec は `instance-category=[m,c,r]` (general / compute / memory) + `instance-generation=Gt 7` (Graviton 4 のみ) で設定したが、production system workload (CoreDNS / Cilium operator / Flux 4 controllers / KEDA / metrics-server / Karpenter / ebs-csi-controller / external-dns / aws-lb-controller) は **小粒で大量の general-purpose** 構成のため、c/r series は Karpenter price-aware consolidation でほぼ選ばれない。同時に `Gt 7` は Graviton 4 (m8g) のみに限定する厳しい設定で、m6g/m7g の availability・price 優位性を捨てている。

## Goals

### G1: bootstrap MNG 命名を role-explicit に変更

Karpenter controller host としての役割を HCL identifier・AWS 物理 name・K8s nodeSelector label の 3 階層で読み取れるようにする。

- HCL: `karpenter_bootstrap` → `karpenter_controller_host`
- AWS 物理 name: `karpenter_bootstrap` → `karpenter-controller-host`
- K8s label: `node-role/karpenter-bootstrap=true` → `node-role/karpenter-controller-host=true`

### G2: NodePool requirements を system workload に最適化 + capacity-type に SPOT を追加

`instance-category` を general-purpose のみに絞り、`instance-generation` を `Gt 5` (= 実質 `Ge 6` = m6g 以降) で Graviton 2-4 の 3 世代 + 将来の m9g+ を forward-compatible に含める。`instance-size` 制約 (`medium..4xlarge`) は維持。

加えて Plan 2 spec の `capacity-type=["on-demand"]` を `capacity-type=["spot", "on-demand"]` に変更し、SPOT を優先採用 + 不足時 on-demand fallback 構成にする (cost ~70% 削減見込み、Karpenter price-capacity-optimized 戦略で spot 優先選択)。

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["spot", "on-demand"]  # Karpenter は price-aware で spot を優先採用、不足時 on-demand fallback
- key: karpenter.k8s.aws/instance-category
  operator: In
  values: ["m"]
- key: karpenter.k8s.aws/instance-generation
  operator: Gt
  values: ["5"]  # Ge 6 相当 (Ge operator は K8s NodeSelectorRequirement 仕様に存在しない)
- key: karpenter.k8s.aws/instance-size
  operator: In
  values: ["medium", "large", "xlarge", "2xlarge", "4xlarge"]
```

### G3: 1 PR で 2 つの変更を統合 + 単純 rename 戦略

両変更は `aws/karpenter/` + `kubernetes/components/karpenter/production/` の小さな範囲に閉じるため 1 PR で扱う。MNG rename は terraform `create_before_destroy` で新 MNG 起動 → 旧 MNG destroy の単純戦略で進め、Karpenter controller の一時 unavailable (~2-3 分) を許容する。

## Non-goals

- Karpenter NodePool node の force re-provisioning (NodePool 設定変更だけでは既存 node は drift せず、自然な consolidation / `expireAfter 720h` で順次置き換わる)
- Karpenter controller helm chart version の変更 (現状 1.6.5 維持)
- bootstrap MNG (改名後 `karpenter_controller_host`) の disk size / instance types / count の見直し (現状 `t4g.small` × 2 / 20 GiB 維持)
- taint key (`karpenter.sh/controller=true:NoSchedule`) の変更 (既に role-explicit な命名で問題なし)
- system-components NodePool 名 (`system-components`) の変更
- `aws/karpenter/lookups.tf` 経由の cross-stack lookup の変更

## Architecture decisions

### Decision 1: bootstrap MNG の rename pattern

3 階層で identifier を変える:

| Layer | 旧 | 新 |
|---|---|---|
| HCL identifier (`module "..."`) | `karpenter_bootstrap` | `karpenter_controller_host` |
| AWS MNG 物理 name (`name = "..."`) | `karpenter_bootstrap` | `karpenter-controller-host` |
| K8s label key | `node-role/karpenter-bootstrap` | `node-role/karpenter-controller-host` |
| terraform variable (input/default) | `bootstrap_*` (instance_types / disk_size / desired_size / min_size / max_size) | `controller_host_*` |

**変更しないもの:**
- taint key (`karpenter.sh/controller=true:NoSchedule`): 既に role-explicit。Karpenter Helm chart の `tolerations` 既定値がこの key を期待しているため変更すると tolerations 追加対応が必要になり scope 増える
- access entry の IAM role 名 (terraform-aws-modules が internally に生成する): random suffix 付き名前で、HCL rename に追従して terraform が自動 recreate する

### Decision 2: 単純 rename (戦略 A) で 1 PR

terraform で `module "karpenter_bootstrap"` を `module "karpenter_controller_host"` に書き換え + `name` 引数値を `karpenter-controller-host` に変えると、AWS API 上 MNG name は immutable のため terraform は **新 MNG create → 旧 MNG destroy** の create_before_destroy 動作になる。

- Karpenter controller pod は新 MNG node に再 schedule される (~2-3 分の unavailable)
- 既存 system-components NodePool node 上の workload は影響を受けない (Karpenter controller は scale 判断をするだけで、既存 node の lifecycle に介入していない)
- 不採用案: Rolling A/B (新 MNG 追加 PR → controller 移行検証 PR → 旧 MNG 削除 PR)。3 PR 必要、検証ステップ複雑、本変更の disruption 規模に対して過剰

### Decision 3: NodePool requirements 簡素化 + capacity-type に SPOT 追加

Plan 2 spec の requirements を以下のように変更:

| 軸 | 旧 | 新 | 理由 |
|---|---|---|---|
| capacity-type | `["on-demand"]` | `["spot", "on-demand"]` | system workload は冗長 (replicas≥2 + PDB) または再起動耐性 (reconcile loop) を持つため spot 中断耐性あり。Karpenter price-capacity-optimized で spot 優先選択、不足時 on-demand fallback。cost ~70% 削減見込み |
| instance-category | `[m, c, r]` | `[m]` | system workload は general-purpose 構成。c (compute) / r (memory) は Karpenter price-aware consolidation でほぼ選ばれず spec ノイズ |
| instance-generation | `Gt 7` (Graviton 4 のみ) | `Gt 5` (m6g 以降。Ge 6 相当) | m6g (Graviton 2) / m7g (Graviton 3) の AZ availability + 価格優位性を活用。最新 1 世代だけ縛るより 3 世代 + forward-compat の方が cluster の resilience が高い |
| instance-size | `[medium..4xlarge]` | 同上 | 8xlarge+ は bin-packing 悪化、metal 不要。維持 |

### Decision 4: K8s NodeSelectorRequirement に `Ge` operator は存在しない

Karpenter NodeRequirement は `karpenter.sh/v1` API で `kubernetes/api/core/v1.NodeSelectorRequirement` 仕様に準拠する。利用可能な operator は `In | NotIn | Exists | DoesNotExist | Gt | Lt` のみ。`Ge` / `Le` は仕様に存在しない。

`Gt 5` は実質 `Ge 6` の意味で、generation 6 以降 (m6g / m7g / m8g / 将来 m9g+) を含める。

**spec/yaml に明示コメントを置く** (見逃し防止): `Gt 5` の意図と Ge/Le 不在を nodepool.yaml 内のコメントで明文化し、利用可能 instance type の reference として `https://karpenter.sh/docs/reference/instance-types/` を参照リンク。

### Decision 5: SPOT 採用にあたっての前提と Karpenter 動作

system workload を SPOT で扱う前提 (G2 cost 削減) は以下の technical fact に基づく:

- **AWS SQS interruption queue + EventBridge rules は既に Plan 2 PR 1 で provision 済**: `aws/karpenter/modules/main.tf` で `module "karpenter"` (terraform-aws-modules/eks Karpenter sub-module) が SQS / EventBridge を構築しており、Karpenter controller は spot interruption 通知 (2-min warning) を受信して gracefully drain & replace するパスが既に有効
- **system workload の冗長性**:
  - Replicas ≥ 2 + PDB を持つ deployment (CoreDNS / ebs-csi-controller / aws-load-balancer-controller / Karpenter 自身) は中断耐性あり
  - Replicas = 1 の deployment (external-dns / KEDA operator / metrics-server / Cilium operator / Flux 6 controllers) は reconcile loop で自動 resume できるため、数十秒の unavailable は許容
- **Karpenter 自身は SPOT 対象外**: Karpenter controller pod は別 MNG (`karpenter_controller_host` = on-demand) に nodeSelector で固定されているため、system-components NodePool の SPOT 化と独立
- **NodePool diversity**: instance-category=m + generation Gt 5 + size medium..4xlarge の組み合わせで `m6g/m7g/m8g × 5 sizes = 15 instance types` が候補となり、spot pool の同時枯渇リスクは低い

## Components matrix

| Layer | File | 変更内容 |
|---|---|---|
| AWS (terragrunt) | `aws/karpenter/modules/main.tf` | `module "karpenter_bootstrap"` → `module "karpenter_controller_host"`、`name = "karpenter-controller-host"`、labels の key 変更、コメント内の旧 name 参照を更新 |
| AWS (terragrunt) | `aws/karpenter/modules/variables.tf` | `bootstrap_instance_types` / `bootstrap_disk_size` / `bootstrap_desired_size` / `bootstrap_min_size` / `bootstrap_max_size` を `controller_host_*` に rename |
| AWS (terragrunt) | `aws/karpenter/envs/production/terragrunt.hcl` | input variable name の追従 (default 値で sufficient ならば passthrough のみ) |
| Kubernetes | `kubernetes/components/karpenter/production/values.yaml.gotmpl` | `nodeSelector.node-role/karpenter-bootstrap` を `node-role/karpenter-controller-host` に変更 |
| Kubernetes | `kubernetes/components/karpenter/production/kustomization/nodepool.yaml` | requirements の capacity-type / category / generation 値変更 + Ge 不在に関するコメント追加 |
| Kubernetes | `kubernetes/README.md` | `karpenter-bootstrap` 言及を `karpenter-controller-host` に追従 (該当する場合) |

## Migration sequence

### PR 作成 → review → merge

1. 本 spec / plan に従い 1 PR (`feat/eks-production-karpenter-tuning`) を Draft 作成
2. terragrunt plan diff で create_before_destroy ロジックを確認:
   - `module.karpenter_controller_host.aws_eks_node_group.this` create
   - `module.karpenter_bootstrap.aws_eks_node_group.this` destroy
   - 関連 IAM role / instance profile / launch template も create / destroy
3. PR を Ready for review → merge

### CI / Flux apply 後の cluster behavior

1. terragrunt apply で 新 MNG `karpenter-controller-host` が AWS 上に create (~2 分)
2. 新 MNG node が Ready になったら、Flux が values.yaml.gotmpl の `nodeSelector` 変更を反映 → Karpenter Deployment の rolling update が triggered
3. Karpenter pod が新 MNG node 上に再 schedule (~30 秒)
4. 旧 MNG `karpenter_bootstrap` 上の Karpenter pod が drain 対象に → terraform が旧 MNG を destroy (cordoned → drain → MNG 削除)
5. NodePool 変更も Flux 経由で反映: 既存 system-components NodePool node には影響なし (`expireAfter 720h` または consolidation で順次 m6g/m7g/m8g 系に置き換わる、または現状 c8g.large / c8g.medium のまま稼働続行)

### 観察すべきタイミング

- 新 MNG node Ready 確認: `kubectl get nodes -l node-role/karpenter-controller-host=true`
- Karpenter pod 移行確認: `kubectl get pods -n karpenter -o wide`
- 旧 MNG destroy 完了確認: `aws eks list-nodegroups --cluster-name eks-production` で `karpenter-controller-host` のみ
- NodePool requirements 反映確認: `kubectl get nodepool system-components -o yaml | yq .spec.template.spec.requirements`
- SPOT capacity 反映観察 (24-72h): Karpenter consolidation で system-components NodePool node が SPOT instance に自然遷移するか `kubectl get nodes -L karpenter.sh/capacity-type` で確認

### エラーシナリオと対処

| 事象 | 原因 | 対処 |
|---|---|---|
| 新 MNG node が起動しない | Plan 2 learnings L2 / L5 由来の cluster info / node SG 配線問題が rename で再発 | `aws/karpenter/modules/main.tf` の `cluster_endpoint` / `cluster_auth_base64` / `cluster_service_cidr` / `cluster_ip_family` / `vpc_security_group_ids` 配線が rename 編集で破損していないか確認 |
| Karpenter pod が新 MNG node に schedule されない | values.yaml.gotmpl の nodeSelector 変更が Flux 経由でまだ反映されていない | `flux reconcile kustomization flux-system -n flux-system` 後、`kubectl get pod -n karpenter -o yaml | yq .spec.nodeSelector` で `node-role/karpenter-controller-host` に変わっているか確認 |
| Karpenter pod が CrashLoopBackOff (Plan 2 L6 再現) | 新 MNG の SG 適用順タイミング | `kubectl delete pod karpenter-... -n karpenter --force --grace-period=0` で eviction bypass (Plan 2 L6 既知 recovery 手順) |
| 旧 MNG destroy が PDB blocker で stall (Plan 2 L6 再現) | Karpenter pod が旧 MNG 上で NotReady のまま PDB が drain reject | 同じく force delete pod。terraform は MNG destroy retry で完走 |
| SPOT 中断頻発で system workload が flaky | 特定 instance type の spot pool が逼迫 | NodePool requirements を一時的に `capacity-type=["on-demand"]` に hotfix で revert、原因 instance type を診断後 spot pool diversity を `instance-family` 個別指定で広げる |

## Verification checklist

### PR merge → terragrunt apply 完了直後

- [ ] `aws eks list-nodegroups --cluster-name eks-production --region ap-northeast-1` の結果が `["karpenter-controller-host-..."]` のみ (旧 `karpenter_bootstrap-...` が消えている)
- [ ] `kubectl get nodes -L eks.amazonaws.com/nodegroup,node-role/karpenter-controller-host` で controller-host MNG node 2 台が `Ready` + label `node-role/karpenter-controller-host=true` を持つ
- [ ] `kubectl get pods -n karpenter -o wide` で Karpenter deployment の 2 replica が新 MNG node 上で `Running 1/1`
- [ ] `kubectl get nodepool system-components -o yaml` で requirements が新仕様 (capacity-type=[spot, on-demand] / category=m / generation Gt 5 / size medium..4xlarge) を持つ
- [ ] `kubectl get nodeclaims` で既存 NodeClaim (system-components-...) が `Ready=True` を維持

### 後続観察 (24-72h)

- [ ] Karpenter controller log (`kubectl logs -n karpenter deployment/karpenter`) に新仕様 NodePool に対する provision / consolidation event がエラーなく流れる
- [ ] Karpenter consolidation (or expireAfter) で system-components NodePool node が m6g/m7g/m8g instance + SPOT capacity に自然遷移するか観察 (強制ではないので 30 日以内に発生すれば OK)
- [ ] `kubectl get nodes -L karpenter.sh/capacity-type` で 全 system-components node が `spot` になる (on-demand fallback が頻発しない) ことを確認

## Trade-offs (accepted explicitly)

- **Karpenter controller の一時 unavailable (~2-3 分)** を許容: rolling A/B (3-PR split) の代わりに単純 rename 1 PR を選択。alternative よりも cluster 状態が単純化される
- **m6g (Graviton 2) を含めることで cluster 内 instance heterogeneity が増える**: 異なる世代 (m6g/m7g/m8g) が同じ NodePool 内で混在しても Karpenter consolidation が price-aware に処理する。OS / kernel / containerd version は AMI 共通なので運用上の問題なし
- **`Gt 5` の semantic 解釈リスク**: コメント明記でカバー。コード review 時に `Gt 5 = Ge 6` の意図が伝わらないと「なぜ 5 (m5g なし) を境界に？」という疑問を招く。Karpenter docs reference link をコメントに含めることで明示
- **SPOT 中断による system workload の一時不可用 (~30-60秒)** を許容: replicas≥2 の deployment は PDB で連続中断防止、replicas=1 の reconcile-loop deployment (external-dns / KEDA / metrics-server / Cilium operator / Flux) は再起動で resume。Karpenter SQS interruption queue (Plan 2 PR 1 で provision 済) が 2-min warning を受けて gracefully drain & replace。production-grade な best practice (Karpenter 公式 docs / `Spot best practices`)
- **SPOT pool 同時枯渇による全 system-components node Pending** の極小確率: instance-category=m + Gt 5 + size 5 種の組み合わせで 15+ instance type が候補となり、AZ 跨ぎ + family/generation diversity で同時枯渇は実質 unlikely。発生時は capacity-type に on-demand fallback が即時動作 (Karpenter 内蔵動作)

## Rollback strategy

- 新 MNG 起動失敗 / Karpenter pod CrashLoop が解消しない場合: PR を revert (`git revert <merge-sha>`) → 再度 PR で旧 MNG (`karpenter_bootstrap`) に戻す → terragrunt apply で旧 MNG 再 create + 新 MNG destroy
- NodePool requirements の調整失敗 (新 spec で provision されない instance type が出る等) の場合: nodepool.yaml のみ revert PR で対応 (MNG rename は維持)
- 完全 revert する場合は Plan 2 完了状態 (origin/main の `2fb19e1` 直前 = `42bf97c`) に戻すのが理想だが、本 spec の変更はいずれも非破壊なので部分 revert で十分

## Future Specs (本 spec の Out of scope)

- bootstrap MNG (改名後 `karpenter_controller_host`) の instance type を `t4g.small` から ARM64 generation update (`t5g.small` 等) に上げる検討
- Phase 3 (Observability) で Prometheus / Loki / Tempo を追加する際の system-components NodePool の `limits.cpu` (現状 200) 見直し
- Karpenter controller を multi-AZ で 2 replica 強制配置する topologySpreadConstraints の追加 (現状 nodeSelector + tolerations のみ)
