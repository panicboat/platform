# OTel Collector / Loki: Workload 属性の付与 Design

> **Goal**: production の logs (Loki) / traces (Tempo) に、Kubernetes workload（Deployment/StatefulSet/DaemonSet/CronJob 等の安定した名前、Pod 名やハッシュ付き ReplicaSet/Job 名を含まない）を表す resource attribute `workload` を付与する。Mimir 側で既に稼働している recording rule `namespace_workload_pod:kube_pod_owner:relabel` と同じ役割を、logs/traces 側にも持たせる。

---

## Context

### 現状

- Grafana dashboard (`app-monitoring.json`) に Workload filter を追加しようとした際、`pod` variable の候補取得元を Loki (`k8s_pod_name` label) から Mimir (`kube_pod_info` / `namespace_workload_pod:kube_pod_owner:relabel`) に切り替える案を一度実装した（PR #944、close 済み）
- この案は「pod 一覧の根拠」が「実際にログを出した pod」から「Kubernetes API 上に存在した pod」に変わってしまい、ログを一度も出していない pod まで候補に出る regression があると指摘を受けた
- 調査の結果、Loki は OTLP ingest 時に `k8s.deployment.name` / `k8s.statefulset.name` / `k8s.daemonset.name` / `k8s.cronjob.name` / `k8s.job.name` を index label へ昇格するデフォルト設定を既に持っている（VERIFIED、Grafana 公式ドキュメント）
- **訂正 (レビューで判明)**: `k8sattributes` processor の `extract.metadata` は upstream README 記載の raw default (6項目) ではなく、この chart の `presets.kubernetesAttributes.enabled: true` が生成する preset 自体が既に23項目 (owner kind 全種の name/uid、container image、service.* 等) を extract 済み (`kubernetes/manifests/production/opentelemetry-collector/manifest.yaml` の現行 (変更前) 内容で VERIFIED)。Deployment 以外の owner kind も既に extract されており、`extract.metadata` の拡張は不要どころか、明示的な override は preset の23項目リストを狭い10項目で**上書き**して既存の `service.name` 等13項目を失わせる regression になる
- 現行 ClusterRole (`helm template` で実際に render して確認、VERIFIED) は `pods` / `namespaces` (core) と `replicasets` (apps/extensions) の `get,watch,list` のみ。この RBAC のまま preset は StatefulSet/DaemonSet/Job/CronJob の owner name も extract できている (= Pod 自身の `ownerReferences` から解決しており追加 API watch が要らない)

### なぜ単純な label 追加だけでは足りないか

- Mimir の `namespace_workload_pod:kube_pod_owner:relabel` は、単に owner name を転記しているのではなく:
  - Deployment: owner の ReplicaSet 名からハッシュ suffix を除去し、Deployment 自体の安定名にする
  - CronJob 配下の Job: 実行毎に変わる Job 名ではなく **CronJob の名前**を使う（そうしないと実行のたびに別 workload 扱いになり、フィルタとして機能しない）
- k8sattributes processor (既存 preset) が `k8s.deployment.name` / `k8s.statefulset.name` / `k8s.daemonset.name` / `k8s.job.name` / `k8s.cronjob.name` を個別に extract していても、pod ごとに **どれか1つしか値が入らない**ため、Grafana 変数の `label_values()` は単一 label しか引けず、そのままでは統一的な `$workload` filter を組めない
- そのため、これらを単一の `workload` 属性に**合成**する処理が必要

---

## Architecture

```
Pod (Deployment/StatefulSet/DaemonSet/CronJob 配下)
  ↓ filelog receiver (logs) / otlp receiver (traces, Beyla 等由来)
  ↓ memory_limiter
  ↓ k8sattributes processor (既存 preset のまま、無修正)
  │   preset が既に owner kind 全種の name/uid を extract 済み
  ↓ resource processor (既存の cluster.name upsert はそのまま)
  ↓ transform/workload processor (新規、OTTL)
  │   owner 種別ごとの name を単一の resource attribute `workload` に合成
  │   (Mimir の namespace_workload_pod:kube_pod_owner:relabel と同じ役割)
  ↓ batch processor
  ↓ exporters
      logs  → Loki (OTLP):  limits_config.otlp_config で `workload` を
              index_label に昇格 (Loki 側の追加設定が必要)
      traces → Tempo (OTLP): 昇格設定不要、resource attribute として
              そのまま TraceQL で検索可能
```

logs/traces 両方の pipeline に `transform/workload` を追加する（traces 側も将来 workload 単位の filter/drill-down を見据えて対称にする）。

---

## Implementation

### `k8sattributes` processor は無修正

`presets.kubernetesAttributes.enabled: true` が生成する既存 preset が、Deployment を含む全 owner kind の name/uid、container image、`service.*` 等23項目を既に extract している（`kubernetes/manifests/production/opentelemetry-collector/manifest.yaml` の現行内容で VERIFIED）。`config.processors.k8sattributes.extract.metadata` を明示指定すると Helm の値マージは list を **置換**するため、この23項目が上書きされて失われる。よって `k8sattributes` には一切手を加えない。

### 変更点 1: `transform/workload` processor の新規追加

owner 種別ごとの name を `workload` 属性に合成する。1 pod の owner kind は基本的に1種類しかないため
`set` 文の実行順は通常結果に影響しないが、**CronJob 配下の Job** だけは `k8s.job.name` と
`k8s.cronjob.name` が同時に populate されうる。後勝ち（後の `set` が前の値を上書き）なので、
`k8s.cronjob.name` の statement を最後に置き、Job 名ではなく CronJob 名で確定させる。

```yaml
  transform/workload:
    error_mode: ignore
    resource_statements:
      - context: resource
        statements:
          - set(attributes["workload"], attributes["k8s.deployment.name"]) where attributes["k8s.deployment.name"] != nil
          - set(attributes["workload"], attributes["k8s.statefulset.name"]) where attributes["k8s.statefulset.name"] != nil
          - set(attributes["workload"], attributes["k8s.daemonset.name"]) where attributes["k8s.daemonset.name"] != nil
          - set(attributes["workload"], attributes["k8s.job.name"]) where attributes["k8s.job.name"] != nil
          - set(attributes["workload"], attributes["k8s.cronjob.name"]) where attributes["k8s.cronjob.name"] != nil
```

具体的な OTTL statement は実装時に、CronJob 名解決の可否（下記オープン課題）を確認した上で確定する。

### 変更点 2: pipeline への組み込み

```yaml
  service:
    pipelines:
      logs:
        processors: [memory_limiter, k8sattributes, resource, transform/workload, batch]
      traces:
        processors: [memory_limiter, k8sattributes, resource, transform/workload, batch]
```

### 変更点 3: Loki 側で `workload` を index label に昇格

`kubernetes/components/loki/production/values.yaml.gotmpl` の `loki.limits_config` に追加（schema は Grafana 公式ドキュメントで確認済み、VERIFIED）:

```yaml
  limits_config:
    otlp_config:
      resource_attributes:
        attributes_config:
          - action: index_label
            attributes:
              - workload
```

Tempo 側は追加設定不要（resource attribute はそのまま TraceQL で `{resource.workload="..."}` として検索可能）。

### 変更しないもの

- Grafana dashboard (`app-monitoring.json` / `infra-monitoring.json`) — workload label が実際に production で付くことを確認してから、別 PR で `pod` variable を Loki + `workload=~"$workload"` cascade に戻す（本 spec の scope 外）
- Mimir 側の `namespace_workload_pod:kube_pod_owner:relabel` recording rule — 変更不要、既存のまま
- `k8sattributes` の RBAC (ClusterRole) — 現行の `pods`/`namespaces`/`replicasets` で足りる想定（下記オープン課題参照、不足が判明した場合のみ追加）

---

## Verification

1. `helm template` で新しい `values.yaml.gotmpl` を render し、`transform/workload` processor と pipeline 定義が意図通りに出力されることを確認
2. `scripts/kubernetes-hydrate/hydrate-component.sh opentelemetry-collector production` / `loki production` を実行し、`kubernetes/manifests/production/` を再生成
3. production へ deploy 後（Flux reconcile）、以下を確認:
   - Deployment 配下の pod のログに `workload` label が付き、値が ReplicaSet ハッシュを含まない Deployment 名になっている
   - StatefulSet / DaemonSet 配下の pod でも同様に `workload` label が付く
   - CronJob 配下の pod で `workload` label が CronJob 名になっている（Job 名そのままではないこと）
   - Loki の `/loki/api/v1/labels` に `workload` が出現し、`label_values` で妥当な値が返る
   - Tempo 側で `{resource.workload="<name>"}` の TraceQL が意図した span を返す
4. OTel Collector DaemonSet の rollout でログ収集が一時的に途切れないか（`filelog.storeCheckpoints: true` により tail 位置は resume される想定）を確認

検証で CronJob 名解決ができないと判明した場合、`transform/workload` の statement を Job 名からの正規表現 suffix 除去（Mimir 同等のヒューリスティック）に差し替える。

---

## Risks / Open Questions

| リスク / オープン課題 | 影響 | 対応方針 |
|---|---|---|
| `k8s.cronjob.name` は preset の extract.metadata に既に含まれ現行 RBAC のまま render されている (VERIFIED) が、実際に値が populate されるかは未確認 | CronJob 配下の pod の workload が不安定 (Job 名のまま) になる可能性 | production deploy 後、実 CronJob pod で検証。populate されない場合は正規表現ベースの OTTL fallback (Job 名から suffix 除去) に切り替え |
| Loki の label 上限 (default `max_label_names_per_series: 15`) に対する現状の label 数と、`workload` 追加後の余裕 | 上限超過で ingestion error | 実装時に現状の label 数を確認してから deploy |
| OTel Collector DaemonSet の rollout | 全 node で一時的に再起動、ログ収集に短い gap の可能性 | `storeCheckpoints: true` で tail 位置を resume、production への影響が小さい時間帯に deploy |
| `transform/workload` を traces pipeline にも適用することで span 処理に追加コストが乗る | 無視できるレベルの想定だが未検証 | 実装後、OTel Collector の resource 使用量を確認 |

---

## Out of Scope

- Grafana dashboard 側の `pod` variable を Loki + `workload` cascade に戻す変更（別 PR、本 spec の infra 変更が production で検証できてから着手）
- Mimir 側 recording rule の変更
- `workload_type`（Deployment/StatefulSet 等の種別）を表す属性の追加 — 現時点でこれを使う dashboard 要件がないため YAGNI で見送り
