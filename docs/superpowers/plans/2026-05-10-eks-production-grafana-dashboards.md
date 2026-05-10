# EKS Production Grafana Dashboards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** local cluster で動いている 3 枚の Grafana dashboard (`app-monitoring` / `infra-monitoring` / `unified-monitoring`) を production cluster に移植する。コピー単純移植では「全 panel が空」になる既知の 2 bug (Prometheus datasource UID 不一致 + Loki empty-compatible matcher 拒否) も併せて fix する。

**Architecture:** local dashboard JSON を production source ディレクトリ (`kubernetes/components/dashboard/production/kustomization/`) にコピーし、(1) `"uid": "prometheus"` → `"uid": "mimir"` 置換 と (2) `templating` の includeAll var に `"allValue": ".+"` 追加 の 2 fix を当てる。`make hydrate-component` + `make hydrate-index` で `manifests/production/dashboard/` と `manifests/production/kustomization.yaml` を自動生成し、Flux の reconcile + Grafana sidecar 経由で auto-import される。

**Tech Stack:** kustomize / Grafana 12 (k8s-sidecar dashboard discovery) / Mimir / Loki / Tempo / GNU Make + helmfile-based hydrate workflow / Flux v2

**Working directory:** `.claude/worktrees/eks-grafana-prod-dashboards/` (worktree on branch `feat/eks-grafana-prod-dashboards`)

---

## File Structure

### Created (人が書く source)

| Path | Responsibility |
|---|---|
| `kubernetes/components/dashboard/production/kustomization/kustomization.yaml` | namespace=monitoring + 3 configMapGenerator + label `grafana_dashboard: "1"` + disableNameSuffixHash |
| `kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json` | local 由来 + 2 fix |
| `kubernetes/components/dashboard/production/kustomization/grafana/infra-monitoring.json` | local 由来 + 2 fix |
| `kubernetes/components/dashboard/production/kustomization/grafana/unified-monitoring.json` | local 由来 + 2 fix |

### Generated (`make hydrate*` が自動生成、commit 対象)

| Path | Responsibility |
|---|---|
| `kubernetes/manifests/production/dashboard/manifest.yaml` | rendered ConfigMap × 3 |
| `kubernetes/manifests/production/dashboard/kustomization.yaml` | `resources: [manifest.yaml]` |
| `kubernetes/manifests/production/kustomization.yaml` | resources リストに `./dashboard` 追加 (alphabetical 順で再生成) |

### Untouched (変更しない)

- `kubernetes/components/dashboard/local/` 配下すべて
- `prometheus-operator` Helm values
- production OTel Collector 設定
- 他の component / manifest

---

## Task 1: Production source ディレクトリ作成 + JSON コピー

**Files:**
- Create: `kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json`
- Create: `kubernetes/components/dashboard/production/kustomization/grafana/infra-monitoring.json`
- Create: `kubernetes/components/dashboard/production/kustomization/grafana/unified-monitoring.json`

- [ ] **Step 1: ディレクトリを作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-grafana-prod-dashboards
mkdir -p kubernetes/components/dashboard/production/kustomization/grafana
```

- [ ] **Step 2: local の JSON 3 枚を production 側にコピー**

```bash
cp kubernetes/components/dashboard/local/kustomization/grafana/app-monitoring.json \
   kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json
cp kubernetes/components/dashboard/local/kustomization/grafana/infra-monitoring.json \
   kubernetes/components/dashboard/production/kustomization/grafana/infra-monitoring.json
cp kubernetes/components/dashboard/local/kustomization/grafana/unified-monitoring.json \
   kubernetes/components/dashboard/production/kustomization/grafana/unified-monitoring.json
```

- [ ] **Step 3: コピー直後の状態を baseline として確認 (期待値が後の Task で正しく変化するため)**

```bash
for f in kubernetes/components/dashboard/production/kustomization/grafana/*.json; do
  echo "=== $(basename $f) ==="
  echo "  prometheus uid count: $(grep -c '"uid": "prometheus"' $f)"
  echo "  allValue count:       $(jq -r '[.templating.list[] | select(.allValue != null)] | length' $f)"
done
```

期待出力:
```
=== app-monitoring.json ===
  prometheus uid count: 14
  allValue count:       0
=== infra-monitoring.json ===
  prometheus uid count: 25
  allValue count:       0
=== unified-monitoring.json ===
  prometheus uid count: 27
  allValue count:       0
```

これで「コピー直後 = local と同じ状態」が確認できる。

---

## Task 2: Fix-1 - Prometheus datasource UID `prometheus` → `mimir` 置換

**Files:**
- Modify: `kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json`
- Modify: `kubernetes/components/dashboard/production/kustomization/grafana/infra-monitoring.json`
- Modify: `kubernetes/components/dashboard/production/kustomization/grafana/unified-monitoring.json`

- [ ] **Step 1: sed で 3 ファイル全置換 (macOS BSD sed の `-i ''` syntax)**

```bash
sed -i '' 's/"uid": "prometheus"/"uid": "mimir"/g' \
  kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json \
  kubernetes/components/dashboard/production/kustomization/grafana/infra-monitoring.json \
  kubernetes/components/dashboard/production/kustomization/grafana/unified-monitoring.json
```

- [ ] **Step 2: 置換後の verify**

```bash
for f in kubernetes/components/dashboard/production/kustomization/grafana/*.json; do
  echo "=== $(basename $f) ==="
  echo "  prometheus uid count: $(grep -c '"uid": "prometheus"' $f)"
  echo "  mimir uid count:      $(grep -c '"uid": "mimir"' $f)"
  echo "  loki uid count:       $(grep -c '"uid": "loki"' $f)"
  echo "  tempo uid count:      $(grep -c '"uid": "tempo"' $f)"
done
```

期待出力:
```
=== app-monitoring.json ===
  prometheus uid count: 0
  mimir uid count:      14
  loki uid count:       3
  tempo uid count:      6
=== infra-monitoring.json ===
  prometheus uid count: 0
  mimir uid count:      25
  loki uid count:       2
  tempo uid count:      0
=== unified-monitoring.json ===
  prometheus uid count: 0
  mimir uid count:      27
  loki uid count:       3
  tempo uid count:      6
```

- [ ] **Step 3: JSON validity 確認 (sed が JSON を壊していないこと)**

```bash
for f in kubernetes/components/dashboard/production/kustomization/grafana/*.json; do
  jq empty $f && echo "OK: $(basename $f)"
done
```

期待出力:
```
OK: app-monitoring.json
OK: infra-monitoring.json
OK: unified-monitoring.json
```

---

## Task 3: Fix-2 - template variable に `allValue: ".+"` 追加

**Files:**
- Modify: `kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json`
- Modify: `kubernetes/components/dashboard/production/kustomization/grafana/infra-monitoring.json`
- Modify: `kubernetes/components/dashboard/production/kustomization/grafana/unified-monitoring.json`

`includeAll: true` の templating var (= `namespace` / `service` / `pod` のうち各 dashboard で該当するもの) に `allValue: ".+"` を追加する。textbox 型 (`search` / `traceId`) は触らない。

- [ ] **Step 1: jq で 3 ファイルそれぞれに patch 適用**

```bash
for f in kubernetes/components/dashboard/production/kustomization/grafana/*.json; do
  tmp=$(mktemp)
  jq '(.templating.list[] | select(.includeAll == true)) |= (. + {allValue: ".+"})' "$f" > "$tmp"
  mv "$tmp" "$f"
done
```

- [ ] **Step 2: 各 JSON の allValue 状態を verify**

```bash
for f in kubernetes/components/dashboard/production/kustomization/grafana/*.json; do
  echo "=== $(basename $f) ==="
  jq -r '.templating.list[] | "  " + .name + ": includeAll=" + (.includeAll | tostring) + ", allValue=" + (.allValue // "null" | tostring)' "$f"
done
```

期待出力:
```
=== app-monitoring.json ===
  namespace: includeAll=true, allValue=.+
  service: includeAll=true, allValue=.+
  pod: includeAll=true, allValue=.+
  search: includeAll=false, allValue=null
  traceId: includeAll=false, allValue=null
=== infra-monitoring.json ===
  namespace: includeAll=true, allValue=.+
  pod: includeAll=true, allValue=.+
=== unified-monitoring.json ===
  namespace: includeAll=true, allValue=.+
  service: includeAll=true, allValue=.+
  pod: includeAll=true, allValue=.+
  search: includeAll=false, allValue=null
  traceId: includeAll=false, allValue=null
```

NOTE: `infra-monitoring.json` には `search` / `traceId` 変数は元々無い (logs panel が "Error Logs" 1 つで keyword textbox を持たないため)。このことは local との一貫性として正しい。

- [ ] **Step 3: JSON validity 再確認**

```bash
for f in kubernetes/components/dashboard/production/kustomization/grafana/*.json; do
  jq empty $f && echo "OK: $(basename $f)"
done
```

期待出力:
```
OK: app-monitoring.json
OK: infra-monitoring.json
OK: unified-monitoring.json
```

---

## Task 4: Production kustomization.yaml 作成

**Files:**
- Create: `kubernetes/components/dashboard/production/kustomization/kustomization.yaml`

- [ ] **Step 1: local の kustomization.yaml と diff を取って構造を再確認**

```bash
cat kubernetes/components/dashboard/local/kustomization/kustomization.yaml
```

期待出力 (= 既存):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

configMapGenerator:
  - name: grafana-dashboard-app-monitoring
    files:
      - grafana/app-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-infra-monitoring
    files:
      - grafana/infra-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-unified-monitoring
    files:
      - grafana/unified-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"

generatorOptions:
  disableNameSuffixHash: true
```

- [ ] **Step 2: production の kustomization.yaml を local と同内容で作成**

```bash
cat > kubernetes/components/dashboard/production/kustomization/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

configMapGenerator:
  - name: grafana-dashboard-app-monitoring
    files:
      - grafana/app-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-infra-monitoring
    files:
      - grafana/infra-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-unified-monitoring
    files:
      - grafana/unified-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"

generatorOptions:
  disableNameSuffixHash: true
EOF
```

- [ ] **Step 3: local と production の kustomization.yaml が完全一致することを確認**

```bash
diff kubernetes/components/dashboard/local/kustomization/kustomization.yaml \
     kubernetes/components/dashboard/production/kustomization/kustomization.yaml
echo "exit code: $?"
```

期待出力:
```
exit code: 0
```

(差分なし = local と production の kustomize 設定が一致)

---

## Task 5: kustomize build で source の妥当性確認

**Files:** なし (read-only verify)

- [ ] **Step 1: production source を kustomize build にかけてエラーが出ないことを確認**

```bash
kustomize build kubernetes/components/dashboard/production/kustomization > /tmp/dashboard-prod-build.yaml
echo "exit code: $?"
```

期待出力:
```
exit code: 0
```

- [ ] **Step 2: 出力に 3 つの ConfigMap が含まれることを確認**

```bash
grep -c '^kind: ConfigMap' /tmp/dashboard-prod-build.yaml
grep '^  name: grafana-dashboard-' /tmp/dashboard-prod-build.yaml
```

期待出力:
```
3
  name: grafana-dashboard-app-monitoring
  name: grafana-dashboard-infra-monitoring
  name: grafana-dashboard-unified-monitoring
```

- [ ] **Step 3: ConfigMap が正しい label と namespace を持つことを確認**

```bash
grep -A 4 '^  labels:' /tmp/dashboard-prod-build.yaml | head -20
grep '^  namespace:' /tmp/dashboard-prod-build.yaml
```

期待出力:
```
  labels:
    grafana_dashboard: "1"
  name: grafana-dashboard-app-monitoring
  namespace: monitoring
...
  namespace: monitoring
  namespace: monitoring
  namespace: monitoring
```

- [ ] **Step 4: 出力 JSON 内に `"uid": "prometheus"` が存在しないこと (= 置換が production hydrate にも反映されること) を確認**

```bash
grep -c '"uid": "prometheus"' /tmp/dashboard-prod-build.yaml
grep -c '"uid": "mimir"' /tmp/dashboard-prod-build.yaml
```

期待出力:
```
0
66
```

(14 + 25 + 27 = 66)

---

## Task 6: hydrate-component と hydrate-index 実行

**Files:**
- Create: `kubernetes/manifests/production/dashboard/manifest.yaml` (Makefile が生成)
- Create: `kubernetes/manifests/production/dashboard/kustomization.yaml` (Makefile が生成)
- Modify: `kubernetes/manifests/production/kustomization.yaml` (Makefile が再生成)

- [ ] **Step 1: hydrate-component を実行 (= dashboard component を render)**

```bash
make -C kubernetes hydrate-component COMPONENT=dashboard ENV=production
```

期待: エラーなく終了。`kubernetes/manifests/production/dashboard/` に 2 ファイル生成。

- [ ] **Step 2: 生成された 2 ファイルを確認**

```bash
ls kubernetes/manifests/production/dashboard/
cat kubernetes/manifests/production/dashboard/kustomization.yaml
```

期待出力:
```
kustomization.yaml
manifest.yaml
```

```yaml
resources:
  - manifest.yaml
```

- [ ] **Step 3: hydrate-index を実行 (= manifests/production/kustomization.yaml の resources リストを再生成)**

```bash
make -C kubernetes hydrate-index ENV=production
```

期待: エラーなく終了。`kubernetes/manifests/production/kustomization.yaml` の resources に `./dashboard` が追加される。

- [ ] **Step 4: トップレベル kustomization.yaml に dashboard が入ったことを確認**

```bash
grep -n 'dashboard' kubernetes/manifests/production/kustomization.yaml
```

期待出力 (1 行):
```
N:  - ./dashboard
```

(行番号 N は alphabetical 順で `cilium` と `external-dns` の間)

- [ ] **Step 5: hydrate 出力された manifest.yaml に 3 ConfigMap が含まれることを確認**

```bash
grep -c '^kind: ConfigMap' kubernetes/manifests/production/dashboard/manifest.yaml
grep '^  name: grafana-dashboard-' kubernetes/manifests/production/dashboard/manifest.yaml
grep -c '"uid": "mimir"' kubernetes/manifests/production/dashboard/manifest.yaml
grep -c '"uid": "prometheus"' kubernetes/manifests/production/dashboard/manifest.yaml
```

期待出力:
```
3
  name: grafana-dashboard-app-monitoring
  name: grafana-dashboard-infra-monitoring
  name: grafana-dashboard-unified-monitoring
66
0
```

---

## Task 7: 全体 build verify (production manifests を root から build)

**Files:** なし (read-only verify)

- [ ] **Step 1: production root を kustomize build → エラーが出ないことを確認**

```bash
kustomize build kubernetes/manifests/production > /tmp/prod-full-build.yaml
echo "exit code: $?"
wc -l /tmp/prod-full-build.yaml
```

期待: exit code 0、build 出力 (= 既存 + 3 ConfigMap 分の追加行数)。

- [ ] **Step 2: 全体 build に dashboard ConfigMap 3 つが含まれることを確認**

```bash
grep '^  name: grafana-dashboard-' /tmp/prod-full-build.yaml
```

期待出力:
```
  name: grafana-dashboard-app-monitoring
  name: grafana-dashboard-infra-monitoring
  name: grafana-dashboard-unified-monitoring
```

---

## Task 8: 変更内容の git diff 確認 + commit

**Files:** すべて (上記 Task で作成・修正されたもの)

- [ ] **Step 1: git status で全変更を一覧**

```bash
git status
```

期待出力 (新規ファイル 6 + 修正 1):
```
On branch feat/eks-grafana-prod-dashboards
Untracked files:
  kubernetes/components/dashboard/production/
  kubernetes/manifests/production/dashboard/
Changes not staged for commit:
  modified:   kubernetes/manifests/production/kustomization.yaml
```

- [ ] **Step 2: 各ファイル群の diff を確認**

```bash
git diff kubernetes/manifests/production/kustomization.yaml
```

期待: `./dashboard` 行が 1 行追加されているのみ (alphabetical 位置)。

```bash
ls -la kubernetes/components/dashboard/production/kustomization/
ls -la kubernetes/components/dashboard/production/kustomization/grafana/
ls -la kubernetes/manifests/production/dashboard/
```

期待: それぞれ kustomization.yaml + 該当ファイルが存在。

- [ ] **Step 3: 全ファイルを stage**

```bash
git add kubernetes/components/dashboard/production/ \
        kubernetes/manifests/production/dashboard/ \
        kubernetes/manifests/production/kustomization.yaml
git status
```

期待: 7 件の new file + 1 件の modified が staged。

- [ ] **Step 4: commit (signoff 必須、Co-Authored-By 禁止)**

```bash
git commit -s -m "feat(eks): port grafana dashboards to production

local の 3 dashboard (app/infra/unified) を production に追加。コピー単純
移植では全 panel が空になる 2 bug も併せて fix:

  1. datasource UID prometheus → mimir 置換 (production には chart 自動生成
     の prometheus uid が無く、Mimir を default として登録しているため)
  2. templating var (namespace/service/pod) に allValue: '.+' 追加 (Loki
     3.x が全 matcher empty-compatible な query を reject する問題回避)

manifests/production/dashboard/ と manifests/production/kustomization.yaml
は make hydrate-component COMPONENT=dashboard ENV=production と
make hydrate-index ENV=production で自動生成。

Spec: docs/superpowers/specs/2026-05-10-eks-production-grafana-dashboards-design.md"
```

期待: commit 成功、`Signed-off-by: ...` 行が footer に入る。`Co-Authored-By` は **入らない** こと。

- [ ] **Step 5: コミットメッセージの footer 検証**

```bash
git log -1 --format=%B | tail -3
```

期待:
```
Spec: docs/superpowers/specs/2026-05-10-eks-production-grafana-dashboards-design.md

Signed-off-by: <git user.name> <git user.email>
```

`Co-Authored-By` 行が含まれていない (= CLAUDE.md 順守) ことを確認。

---

## Task 9: ブランチ push + Draft PR 作成

**Files:** なし (git remote 操作のみ)

- [ ] **Step 1: 新規ブランチを upstream tracking 付きで push**

```bash
git push -u origin HEAD
```

期待: ブランチ `feat/eks-grafana-prod-dashboards` が origin に push される。

- [ ] **Step 2: Draft PR を作成 (CLAUDE.md 必須要件)**

```bash
gh pr create --draft \
  --base main \
  --title "feat(eks): port grafana dashboards to production" \
  --body "$(cat <<'EOF'
## Summary

local cluster の 3 枚の Grafana dashboard (`app-monitoring` / `infra-monitoring` / `unified-monitoring`) を production cluster に移植する。コピー単純移植では「全 panel が空」になる既知の 2 bug を併せて fix。

## What's broken in production (and why a plain copy doesn't work)

1. **Prometheus datasource UID `prometheus` が production に無い**
   - production の prometheus-operator chart は `defaultDatasourceEnabled: false` で chart 自動生成 datasource を disable、代わりに Mimir を `uid: mimir` で `isDefault: true` 登録
   - dashboard JSON 内の全 `"uid": "prometheus"` 参照が解決不能 → Prometheus 系 panel と $namespace/$service variable が空
2. **Loki 3.x が全 matcher empty-compatible な query を reject**
   - 観測されたエラー: ``parse error : queries require at least one regexp or equality matcher that does not have an empty-compatible value``
   - templating var に `allValue` が無いため "All" 選択時に regex が `.*` で展開され、Loki が rejection

## Changes

- **Source 追加**: `kubernetes/components/dashboard/production/kustomization/` 配下に kustomization.yaml + grafana/{app,infra,unified}-monitoring.json (local からコピー + 2 fix 適用)
- **Fix-1**: 全 `"uid": "prometheus"` → `"uid": "mimir"` 置換 (66 箇所、3 ファイル合計)
- **Fix-2**: templating var (namespace/service/pod) に `"allValue": ".+"` 追加 (8 箇所、3 ファイル合計)
- **Hydrated output**: `make hydrate-component COMPONENT=dashboard ENV=production` + `make hydrate-index ENV=production` で生成

## Out of scope

- local 側 dashboard の同種 bug 修正 (surgical changes 原則、別 PR で対応可能)
- production OTel Collector の `transform/logs` processor 追加
- 新 dashboard / panel / alert の追加

## Verification (deploy 後の手動確認)

deploy 後、Grafana UI (https://grafana.panicboat.net) で以下を確認:

1. Dashboards 一覧に 3 枚出現
2. "All" 選択時に namespace / service / pod variable が値を持つ
3. Infrastructure Monitoring の Cluster Overview row に値表示
4. Application Monitoring の Trace Search Results に trace 表示
5. Application Monitoring の Application Logs に log 表示
6. Container Restarts / CPU / Memory panel に値表示

NG が出た場合 (= production OTel logs label 不一致 / Tempo `service.name` 欠落の可能性) は別 PR で query を実 label に合わせて修正。

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-10-eks-production-grafana-dashboards-design.md`
- Plan: `docs/superpowers/plans/2026-05-10-eks-production-grafana-dashboards.md`
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
  "title": "feat(eks): port grafana dashboards to production",
  "isDraft": true,
  "baseRefName": "main",
  "headRefName": "feat/eks-grafana-prod-dashboards"
}
```

---

## Post-merge follow-up (本 PR 範囲外、merge 後に手動実施)

merge 後、以下を手動で行う:

1. Flux reconcile を待つ (= 通常 数分以内)

   ```bash
   kubectl -n flux-system get kustomization
   ```

2. ConfigMap が monitoring namespace に展開されたことを確認

   ```bash
   kubectl -n monitoring get cm -l grafana_dashboard=1
   ```

   期待: 3 つの ConfigMap (`grafana-dashboard-app-monitoring` 等) が表示される。

3. Grafana sidecar log を確認 (dashboard import 成功)

   ```bash
   kubectl -n monitoring logs -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=50
   ```

4. https://grafana.panicboat.net にアクセスし Spec の Verification 表に従って 6 項目を目視確認。

5. 不一致 (= Loki label 不一致 / Tempo `service.name` 欠落) が見つかった場合は follow-up PR を作成。
