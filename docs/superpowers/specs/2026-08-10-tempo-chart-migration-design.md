# Tempo Chart Repository Migration

> **Goal**: Tempo を deprecated な `grafana/tempo` 1.24.4 から、移管先の `grafana-community/tempo` 2.2.3 に載せ替える。single binary 構成は維持し、更新経路を回復する。

---

## 1. Problem

`kubernetes/components/tempo/production/helmfile.yaml` は `grafana/tempo` 1.24.4 を参照している。この chart は `Chart.yaml` に `deprecated: true` を持ち、`grafana/helm-charts` リポジトリのサポートは 2026-01-30 に終了している。上流の更新は `grafana-community/helm-charts` に移っており、現在は chart 2.2.3 / Tempo 2.10.7 が出ている。こちらは Tempo 2.9.0 に留まっている。

### 気付けなかった理由

renovate は helmfile が参照する repository の index を見る。旧リポジトリでの最新は 1.24.4 であり、上げるべき差分が存在しない。repository URL ごと移管されるケースを renovate は追えないため、バージョンが古いという事実がどこにも現れない。

同じ罠は他の chart にもありうる。旧 `grafana` repository を参照しているのは beyla / mimir-distributed / tempo の 3 component だが、beyla (1.16.10) と mimir-distributed (6.1.0) はいずれも `deprecated: false` で、`grafana-community` 側に対応する chart も存在しない。移管対象は現時点で tempo のみ。

### single binary は廃止されていない

移管先にも `Grafana Tempo Single Binary Mode` として chart が存在し、更新も継続している。構成の作り直し (= `tempo-distributed` への移行) は不要。

---

## 2. Constraints

すべて実測で確認済み。

### StatefulSet の immutable field は一致する

新旧 chart を同一 values で描画して比較した結果、`spec.serviceName` (`tempo-headless`)、`spec.selector.matchLabels`、`spec.volumeClaimTemplates` (name `storage` / 10Gi / gp3 / ReadWriteOnce) がすべて一致する。StatefulSet を in-place で更新でき、PVC の作り直しは発生しない。

### 新 chart の default receivers に opencensus が無い

旧 chart の `values.yaml` は `receivers` に `jaeger` / `opencensus` / `otlp` を持つが、新 chart は `jaeger` / `otlp` のみ。

現在 `values.yaml.gotmpl` には `opencensus: null` がある (= 直前の PR #743 で追加)。これは Helm の「values に null を置くと chart default のキーを削除する」挙動を使ったもので、旧 chart では意図どおり動く。しかし**新 chart では削除対象が存在しないため、単なる明示的 null として設定に出力される**。実際に新 chart で描画すると `opencensus: null` が現れる。Service と StatefulSet からは opencensus のポート宣言が消えるため、Tempo だけが 55678 を bind してどこからも到達できない状態になる。移行時に必ず削除する。

### jaeger は新 chart でも削除できない

新 chart の `_ports.tpl` も `.Values.tempo.receivers.jaeger.protocols.thrift_compact` を無条件に参照する。`jaeger: null` を置くと Service の描画が nil pointer で失敗する。jaeger の 4 protocol (6831/UDP, 6832/UDP, 14268, 14250) は開いたままになる。ClusterIP のみで外部露出はない。

### values schema はほぼ変わらない

top-level キーの差分は `extraContainers` / `initContainers` の追加のみ。`tempo.*` の差分は `streamOverHttpEnabled` の追加のみ。削除も改名もない。現在使っている 6 キー (`tempo` / `persistence` / `service` / `serviceAccount` / `serviceMonitor` / `podDisruptionBudget`) はすべて健在。

`metricsGenerator.remoteWriteHeaders` は新 chart にも無い。tenant header を渡すため `storage.remote_write` をフルリストで指定している現在の書き方は維持する。PDB テンプレートも引き続き存在しない (`podDisruptionBudget` は values にキー自体が無い)。`podDisruptionBudget.enabled: false` は意図の記録として残す。

### Tempo 2.10 の破壊的変更は該当しない

2.10 は vParquet2 の読み取りを廃止した。`storage.trace.block` を明示指定していないため既定の vParquet4 が使われており (live ConfigMap で確認済み)、影響しない。

### 保存済みのトレースが 1 件も無い

S3 の `s3://tempo-559744160976/production/` は 0 objects、`tempo_ingester_blocks_flushed_total` も 0。Tempo は一度も block を flush していない。`/var/tempo/wal` も 8.0K。

OTel Collector の traces pipeline は `tempo.monitoring.svc.cluster.local:4317` に export する設定になっており、配線は繋がっている。トレースが無いのは、トレース対象のアプリケーションが動いていないため (= monorepo の Flux Kustomization が `suspend: true`)。設定の不備ではない。

この結果、block format の互換性はそもそも問題にならず、再起動で失うデータも無い。移行のデータ面のリスクはゼロ。

一方で、**ingest 経路が実トラフィックで検証されていない**ことも意味する。アップグレード後に ingest が壊れても、アプリを動かすまで気付けない。検証では合成トレースを流して確かめる。

---

## 3. Design

### 変更内容

**`kubernetes/components/tempo/production/helmfile.yaml`**

| 項目 | 変更前 | 変更後 |
| --- | --- | --- |
| repository name | `grafana` | `grafana-community` |
| repository url | `https://grafana.github.io/helm-charts` | `https://grafana-community.github.io/helm-charts` |
| chart | `grafana/tempo` | `grafana-community/tempo` |
| version | `1.24.4` | `2.2.3` |

ヘッダコメントに移管の経緯を残す。旧 repository が `deprecated: true` であること、サポートが 2026-01-30 に終了していること、single binary 構成自体は維持であること。

**`kubernetes/components/tempo/production/values.yaml.gotmpl`**

- `receivers` から `opencensus: null` を削除する
- receivers のコメントを書き換える。jaeger を削除できない理由 (= `_ports.tpl` の無条件参照) は新 chart でも同じなので残し、opencensus に関する記述を落とす
- `metricsGenerator` と `podDisruptionBudget` のコメントにある `chart v1.24.4` というバージョン参照を更新する。どちらの前提も 2.2.3 で変わらない

**`kubernetes/manifests/production/tempo/manifest.yaml`**

hydrate 生成物。`scripts/kubernetes-hydrate/hydrate-component.sh` で再生成する。

### 適用後の状態

- StatefulSet が in-place 更新され、Pod 1 台が再起動する (数十秒)
- Tempo image が `2.9.0` → `2.10.7`
- Service から `tempo-opencensus` (55678)、StatefulSet から containerPort `opencensus` が消える
- ServiceMonitor から `jaeger-metrics` endpoint が消える。`tempo-prom-metrics` と `interval: 15s` は維持される
- Tempo の設定に `stream_over_http_enabled: false` が加わる

---

## 4. Out of Scope

### jaeger receivers の削除

Constraints のとおり新 chart でも実現できない。chart 側が Service のポート生成で無条件に参照している以上、chart を fork するか upstream に直してもらう以外に手が無い。

### vParquet5 への切り替え

2.10 で production-ready になったが、既定の vParquet4 のままでも 2.10 は読み書きできる。現状で困っていないため分離する。

### beyla / mimir-distributed の repository

いずれも `deprecated: false` で、移管先に対応する chart が存在しない。動かす理由が無い。

---

## 5. Verification

1. hydrate 差分が想定どおり
   - image が `2.10.7`、chart label が `tempo-2.2.3`
   - `opencensus` を含む行が manifest から消えている
   - StatefulSet の `serviceName` / `selector` / `volumeClaimTemplates` が変わっていない
2. 適用後、`tempo-0` が Ready になり再起動回数が増えない
3. Pod のログにエラーが無く、`Tempo started` が出ている
4. `kubectl -n monitoring get svc tempo` に 55678 が無い
5. 合成トレースの往復
   - OTLP HTTP (4318) に最小のトレースを 1 件 push する
   - Tempo の query API (`/api/traces/<traceID>`) で同じ trace ID を引ける

保存済みトレースが 0 件のため、既存データの読み出しは検証できない (= Constraints 参照)。ingest から query までを一度通す合成トレースが、アップグレード後に経路が生きていることを確かめる唯一の手段になる。

---

## 6. Rollback

1. helmfile と values の変更を revert し、hydrate 生成物を再生成する
2. Flux が旧 chart / Tempo 2.9.0 に戻す

2.10 が書いた WAL を 2.9 が読めない可能性がある。Pod が起動しない場合は PVC の `/var/tempo/wal` を空にしてから起動する。保存済みの block が 0 件なので、これで失うものは無い。
