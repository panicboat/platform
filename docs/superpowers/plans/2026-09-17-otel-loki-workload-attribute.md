# OTel Collector / Loki: Workload Attribute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OTel Collector の logs/traces pipeline に、Kubernetes workload（Deployment/StatefulSet/DaemonSet/CronJob の安定した名前）を表す resource attribute `workload` を付与し、Loki 側でそれを index label に昇格させる。

**Architecture:** `k8sattributes` processor の `extract.metadata` を拡張して owner kind ごとの name (`k8s.deployment.name` 等5種) を取得し、新規 `transform/workload` processor (OTTL) でそれらを単一の `workload` attribute に合成する。Loki 側は `limits_config.otlp_config.resource_attributes.attributes_config` で `workload` を index label として明示的に昇格する。Tempo 側は追加設定不要。

**Tech Stack:** OpenTelemetry Collector (chart `opentelemetry/opentelemetry-collector` v0.166.0) / Loki (chart `grafana-community/loki` v18.11.7) / helmfile / OTTL (transform processor)

**Spec:** `docs/superpowers/specs/2026-09-17-otel-loki-workload-attribute-design.md`

**Working directory:** `.claude/worktrees/feat-otel-loki-workload-attribute/` (worktree on branch `feat/otel-loki-workload-attribute`)

## Global Constraints

- 合成する resource attribute のキー名は `workload`（Mimir の `namespace_workload_pod:kube_pod_owner:relabel` の `workload` label と同じ文字列。将来の dashboard 側 PR で両者を同じ変数名として扱うため必須）
- values.yaml.gotmpl に追加するコメントは1行に収める。複数行のコメントブロックは書かない。現在のタスク・PR への言及もしない (AGENTS.md Documentation > Content Rules)
- commit は `-s` (signoff) 必須、`Co-Authored-By` 禁止
- 新規ブランチの初回 push は `git push -u origin HEAD`
- PR は `gh pr create --draft` のみ、タイトルは英語

---

## File Structure

### Modified

| Path | Responsibility |
|---|---|
| `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl` | `k8sattributes.extract.metadata` 拡張、`transform/workload` processor 追加、logs/traces pipeline への組み込み |
| `kubernetes/components/loki/production/values.yaml.gotmpl` | `limits_config.otlp_config.resource_attributes.attributes_config` で `workload` を index_label に昇格 |

### Generated (hydrate script が自動生成、commit 対象)

| Path | Responsibility |
|---|---|
| `kubernetes/manifests/production/opentelemetry-collector/manifest.yaml` | rendered DaemonSet + ConfigMap 等 |
| `kubernetes/manifests/production/loki/manifest.yaml` | rendered StatefulSet + ConfigMap 等 |

### Untouched

- Mimir 側 `namespace_workload_pod:kube_pod_owner:relabel` recording rule
- Grafana dashboard JSON (`app-monitoring.json` / `infra-monitoring.json`) — 別 PR の scope
- `clusterRole.rules`（現行 RBAC のまま。Task 3 の検証で不足が判明した場合のみ別途対応、本 plan では追加しない）

---

## Task 1: OTel Collector - k8sattributes 拡張 + transform/workload processor 追加

**Files:**
- Modify: `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`

**Interfaces:**
- Produces: OTLP resource attribute `workload`（logs/traces 双方の pipeline を通過する全 telemetry に付与される。値は Deployment 配下なら Deployment 名、StatefulSet/DaemonSet 配下ならその名前、CronJob 配下の Job なら CronJob 名、bare Job なら Job 名）

- [ ] **Step 1: 現在の `processors:` セクションを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-otel-loki-workload-attribute
grep -n "processors:" -A 10 kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl | head -15
```

期待出力 (該当箇所):
```
  processors:
    resource:
      attributes:
        # cluster identification (Beyla 等の他 source と横断クエリ可能にする)
        - key: cluster.name
          value: eks-production
          action: upsert
```

- [ ] **Step 2: `k8sattributes` processor と `transform/workload` processor を追加**

`processors:` セクションを以下の内容に置き換える (既存の `resource` processor は維持しつつ、前後に新規 processor を追加):

```yaml
  processors:
    k8sattributes:
      extract:
        metadata:
          # chart preset default の 6 項目 (Deployment のみ owner 名を extract)
          - k8s.namespace.name
          - k8s.pod.name
          - k8s.pod.uid
          - k8s.pod.start_time
          - k8s.deployment.name
          - k8s.node.name
          # StatefulSet/DaemonSet/Job/CronJob も pod owner 名を extract、transform/workload で workload に合成
          - k8s.statefulset.name
          - k8s.daemonset.name
          - k8s.job.name
          - k8s.cronjob.name
    resource:
      attributes:
        # cluster identification (Beyla 等の他 source と横断クエリ可能にする)
        - key: cluster.name
          value: eks-production
          action: upsert
    transform/workload:
      error_mode: ignore
      resource_statements:
        - context: resource
          statements:
            # owner kind ごとの name を workload に集約 (Mimir の namespace_workload_pod:kube_pod_owner:relabel と同じ役割)
            - set(attributes["workload"], attributes["k8s.deployment.name"]) where attributes["k8s.deployment.name"] != nil
            - set(attributes["workload"], attributes["k8s.statefulset.name"]) where attributes["k8s.statefulset.name"] != nil
            - set(attributes["workload"], attributes["k8s.daemonset.name"]) where attributes["k8s.daemonset.name"] != nil
            - set(attributes["workload"], attributes["k8s.job.name"]) where attributes["k8s.job.name"] != nil
            # CronJob 配下は k8s.job.name (実行毎に変わる) より後に評価し、安定した CronJob 名で上書きする
            - set(attributes["workload"], attributes["k8s.cronjob.name"]) where attributes["k8s.cronjob.name"] != nil
```

- [ ] **Step 3: `service.pipelines` の processors 配列に `transform/workload` を追加**

`traces` と `logs` の両方の `processors:` 配列に、`resource` の直後・`batch` の直前で `transform/workload` を挿入する:

```yaml
      traces:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, resource, transform/workload, batch]
        exporters: [otlp_grpc/tempo]
      logs:
        # filelog のみ。fluent-bit が撤去されたため OTLP receiver 経由の log push は不要。
        receivers: [filelog]
        processors: [memory_limiter, k8sattributes, resource, transform/workload, batch]
        exporters: [otlp_http/loki]
```

- [ ] **Step 4: YAML syntax を確認**

```bash
yq eval '.' kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl > /dev/null && echo "YAML syntax OK"
```

期待出力:
```
YAML syntax OK
```

- [ ] **Step 5: helmfile template で render し、processor 構成を確認**

```bash
helmfile -f kubernetes/components/opentelemetry-collector/production/helmfile.yaml -e production template > /tmp/otel-render.yaml
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/otel-render.yaml')))
for d in docs:
    if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'opentelemetry-collector-agent':
        cfg = yaml.safe_load(d['data']['relay'])
        print('processors:', sorted(cfg['processors'].keys()))
        print('k8s_attributes.extract.metadata:', cfg['processors']['k8s_attributes']['extract']['metadata'])
        print('transform/workload statements:', len(cfg['processors']['transform/workload']['resource_statements'][0]['statements']))
        print('traces pipeline processors:', cfg['service']['pipelines']['traces']['processors'])
        print('logs pipeline processors:', cfg['service']['pipelines']['logs']['processors'])
"
```

期待出力:
```
processors: ['batch', 'k8s_attributes', 'memory_limiter', 'resource', 'transform/workload']
k8s_attributes.extract.metadata: ['k8s.namespace.name', 'k8s.pod.name', 'k8s.pod.uid', 'k8s.pod.start_time', 'k8s.deployment.name', 'k8s.node.name', 'k8s.statefulset.name', 'k8s.daemonset.name', 'k8s.job.name', 'k8s.cronjob.name']
transform/workload statements: 5
traces pipeline processors: ['memory_limiter', 'k8s_attributes', 'resource', 'transform/workload', 'batch']
logs pipeline processors: ['memory_limiter', 'k8s_attributes', 'resource', 'transform/workload', 'batch']
```

NOTE: values.yaml では processor 名を `k8sattributes` (underscore なし) と書くが、chart preset が内部的に `k8s_attributes` (underscore あり) というキーで管理しており、render 結果はそちらに正しくマージされる。これは chart 側の既存の挙動で、今回の変更で作り出したものではない。

- [ ] **Step 6: ClusterRole が変化していないこと (= 現行 RBAC のまま) を確認**

```bash
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/otel-render.yaml')))
for d in docs:
    if d and d.get('kind') == 'ClusterRole':
        print(d['rules'])
"
```

期待出力:
```
[{'apiGroups': [''], 'resources': ['pods', 'namespaces'], 'verbs': ['get', 'watch', 'list']}, {'apiGroups': ['apps'], 'resources': ['replicasets'], 'verbs': ['get', 'list', 'watch']}, {'apiGroups': ['extensions'], 'resources': ['replicasets'], 'verbs': ['get', 'list', 'watch']}]
```

(= 変更前と同じ。StatefulSet/DaemonSet/Job/CronJob の owner name 抽出が追加 RBAC なしで動くかは Post-merge follow-up で確認する)

---

## Task 2: Loki - `workload` を index label に昇格

**Files:**
- Modify: `kubernetes/components/loki/production/values.yaml.gotmpl`

**Interfaces:**
- Consumes: Task 1 が付与する resource attribute `workload`
- Produces: Loki の index label `workload`（`label_values({...}, workload)` で query 可能になる）

- [ ] **Step 1: 現在の `limits_config:` セクションを確認**

```bash
grep -n "limits_config:" -A 6 kubernetes/components/loki/production/values.yaml.gotmpl
```

期待出力:
```
  limits_config:
    # logs entry の最大保持期間 = aws/eks-logs/ S3 lifecycle 30d と整合
    retention_period: 720h
    # 1 stream あたりのログ entry rate 制限 (= burst protection)
    ingestion_rate_mb: 4
    ingestion_burst_size_mb: 6
```

- [ ] **Step 2: `otlp_config` を追加**

`limits_config:` セクションの末尾 (`ingestion_burst_size_mb: 6` の直後) に追加:

```yaml
  limits_config:
    # logs entry の最大保持期間 = aws/eks-logs/ S3 lifecycle 30d と整合
    retention_period: 720h
    # 1 stream あたりのログ entry rate 制限 (= burst protection)
    ingestion_rate_mb: 4
    ingestion_burst_size_mb: 6
    otlp_config:
      resource_attributes:
        attributes_config:
          # OTel Collector の transform/workload processor が合成する独自属性、Loki default の昇格対象外なので明示指定
          - action: index_label
            attributes:
              - workload
```

- [ ] **Step 3: YAML syntax を確認**

```bash
yq eval '.' kubernetes/components/loki/production/values.yaml.gotmpl > /dev/null && echo "YAML syntax OK"
```

期待出力:
```
YAML syntax OK
```

- [ ] **Step 4: helmfile template で render し、`otlp_config` が反映されていることを確認**

```bash
helmfile -f kubernetes/components/loki/production/helmfile.yaml -e production template > /tmp/loki-render.yaml
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/loki-render.yaml')))
for d in docs:
    if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'loki':
        cfg = yaml.safe_load(d['data']['config.yaml'])
        print(cfg['limits_config']['otlp_config'])
"
```

期待出力:
```
{'resource_attributes': {'attributes_config': [{'action': 'index_label', 'attributes': ['workload']}]}}
```

---

## Task 3: hydrate + 全体 build sanity check

**Files:**
- Modify: `kubernetes/manifests/production/opentelemetry-collector/manifest.yaml`
- Modify: `kubernetes/manifests/production/loki/manifest.yaml`

- [ ] **Step 1: 変更前の行数を記録 (差分の目安)**

```bash
wc -l kubernetes/manifests/production/opentelemetry-collector/manifest.yaml kubernetes/manifests/production/loki/manifest.yaml
```

期待出力 (変更前の baseline):
```
     430 kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
    1206 kubernetes/manifests/production/loki/manifest.yaml
    1636 total
```

- [ ] **Step 2: 両 component を hydrate**

```bash
bash scripts/kubernetes-hydrate/hydrate-component.sh opentelemetry-collector production
bash scripts/kubernetes-hydrate/hydrate-component.sh loki production
```

期待: エラーなく終了。

- [ ] **Step 3: hydrate-index を実行 (resources リストの整合性確認、既存 component なので差分は出ないはず)**

```bash
bash scripts/kubernetes-hydrate/hydrate-index.sh production
git status --short kubernetes/manifests/production/kustomization.yaml
```

期待出力: 何も出力されない (= 差分なし、`opentelemetry-collector` と `loki` は既に登録済みのため)

- [ ] **Step 4: hydrate 後の manifest.yaml に新しい processor 設定が反映されていることを確認**

```bash
grep -c "transform/workload" kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
grep -c "k8s.cronjob.name" kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
grep -c "index_label" kubernetes/manifests/production/loki/manifest.yaml
```

期待出力:
```
3
2
1
```

(`transform/workload`: processor 定義1箇所 + traces/logs pipeline 各1箇所 = 3。`k8s.cronjob.name`: extract.metadata 1箇所 + transform statement 1箇所 = 2。`index_label`: 1箇所)

- [ ] **Step 5: production 全体を kustomize build してエラーが出ないことを確認**

```bash
kustomize build kubernetes/manifests/production > /tmp/prod-full-build.yaml
echo "exit code: $?"
```

期待出力:
```
exit code: 0
```

---

## Task 4: 変更内容の git diff 確認 + commit

**Files:** すべて (Task 1-3 で変更されたもの)

- [ ] **Step 1: git status で全変更を一覧**

```bash
git status --short
```

期待出力:
```
 M kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl
 M kubernetes/components/loki/production/values.yaml.gotmpl
 M kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
 M kubernetes/manifests/production/loki/manifest.yaml
```

- [ ] **Step 2: source (values.yaml.gotmpl) の diff を目視確認**

```bash
git diff kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl kubernetes/components/loki/production/values.yaml.gotmpl
```

期待: Task 1 Step 2-3、Task 2 Step 2 で書いた内容のみが追加されている (既存行の削除・変更がないこと)。

- [ ] **Step 3: 全ファイルを stage して commit (signoff 必須、Co-Authored-By 禁止)**

```bash
git add kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl \
        kubernetes/components/loki/production/values.yaml.gotmpl \
        kubernetes/manifests/production/opentelemetry-collector/manifest.yaml \
        kubernetes/manifests/production/loki/manifest.yaml

git commit -s -m "feat(kubernetes): add workload resource attribute to logs/traces

k8sattributes processor の default extract は Deployment 以外の owner kind
をカバーしておらず、CronJob 配下の pod は実行毎に変わる Job 名しか取れな
かった。extract.metadata を拡張し、新規 transform/workload processor
(OTTL) で owner kind ごとの name を単一の workload attribute に合成する
(Mimir の namespace_workload_pod:kube_pod_owner:relabel と同じ役割)。

Loki 側は limits_config.otlp_config で workload を index label に明示
昇格 (Loki の default 昇格リストは標準 semconv キーのみ対象のため)。
Tempo は追加設定不要。

Spec: docs/superpowers/specs/2026-09-17-otel-loki-workload-attribute-design.md"
```

期待: commit 成功、`Signed-off-by:` 行が footer に入る。`Co-Authored-By` は **入らない** こと。

- [ ] **Step 4: コミットメッセージの footer 検証**

```bash
git log -1 --format=%B | tail -3
```

期待: `Signed-off-by: <git user.name> <git user.email>` のみで `Co-Authored-By` が含まれない。

---

## Task 5: ブランチ push + Draft PR 作成

**Files:** なし (git remote 操作のみ)

- [ ] **Step 1: 新規ブランチを upstream tracking 付きで push**

```bash
git push -u origin HEAD
```

期待: ブランチ `feat/otel-loki-workload-attribute` が origin に push される。

- [ ] **Step 2: Draft PR を作成**

```bash
gh pr create --draft --title "feat(kubernetes): add workload resource attribute to logs/traces" --body "$(cat <<'EOF'
## Summary
- k8sattributes processor の extract.metadata を拡張し、Deployment 以外
  (StatefulSet/DaemonSet/Job/CronJob) の owner name も extract する。
- 新規 transform/workload processor (OTTL) で owner kind ごとの name を
  単一の resource attribute `workload` に合成する。CronJob 配下の Job は
  実行毎に変わる Job 名ではなく、安定した CronJob 名を優先する。
- Loki 側で `workload` を index label に昇格 (limits_config.otlp_config)。
  Tempo は追加設定不要、resource attribute としてそのまま TraceQL で
  検索可能。

## Test plan
- [x] `helmfile template` で OTel Collector / Loki 両方の config が意図通りに
      render されることを確認 (VERIFIED)
- [x] ClusterRole が変更前と同一であることを確認 (VERIFIED)
- [x] `kustomize build kubernetes/manifests/production` が成功することを確認 (VERIFIED)
- [ ] production deploy 後、Deployment/StatefulSet/DaemonSet/CronJob 配下の
      pod で `workload` label が正しい値で Loki / Tempo に付くことを確認
      (spec の Verification 手順、merge 後に実施)
- [ ] CronJob 配下の pod で `k8s.cronjob.name` が追加 RBAC なしで取得できる
      ことを確認。取得できない場合は ClusterRole に `batch/v1 jobs` の
      get,watch,list を追加する follow-up が必要

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-09-17-otel-loki-workload-attribute-design.md`
- Plan: `docs/superpowers/plans/2026-09-17-otel-loki-workload-attribute.md`
EOF
)"
```

期待: PR 作成成功、URL が出力される。Draft 状態。

- [ ] **Step 3: 作成された PR を確認**

```bash
gh pr view --json number,title,isDraft,baseRefName,headRefName
```

期待出力:
```json
{
  "number": <N>,
  "title": "feat(kubernetes): add workload resource attribute to logs/traces",
  "isDraft": true,
  "baseRefName": "main",
  "headRefName": "feat/otel-loki-workload-attribute"
}
```

---

## Post-merge follow-up (本 PR 範囲外、merge 後に手動実施)

merge 後、以下を手動で行う (spec の Verification 節に対応):

1. Flux reconcile を待つ

   ```bash
   kubectl -n flux-system get kustomization
   ```

2. OTel Collector DaemonSet が新しい ConfigMap で正常に起動していることを確認 (CrashLoopBackOff がないこと)

   ```bash
   kubectl -n monitoring get pods -l app.kubernetes.io/name=opentelemetry-collector
   kubectl -n monitoring logs -l app.kubernetes.io/name=opentelemetry-collector --tail=50 | grep -i error
   ```

3. Deployment 配下の pod のログに `workload` label が付き、値が ReplicaSet ハッシュを含まない Deployment 名になっていることを確認

   ```bash
   kubectl -n monitoring port-forward svc/loki-gateway 8080:80
   curl -s -H "X-Scope-OrgID: anonymous" 'http://localhost:8080/loki/api/v1/label/workload/values' | jq
   ```

4. StatefulSet / DaemonSet 配下の pod でも `workload` label が付くことを同様に確認

5. CronJob 配下の pod で `workload` label が **CronJob 名**になっていることを確認 (Job 名の末尾ハッシュが残っていないこと)。もし `workload` label 自体が付かない場合は `k8s.cronjob.name` の抽出に追加 API 権限が必要な可能性が高い — その場合は `clusterRole.rules` に `batch/v1 jobs` の `get,watch,list` を追加する follow-up PR を作成する

6. Tempo 側で TraceQL `{resource.workload="<name>"}` が意図した span を返すことを確認

7. 上記すべて確認できたら、Grafana dashboard 側 (`app-monitoring.json` の `pod` variable を Loki + `workload=~"$workload"` cascade に戻す) の別 PR に着手する
