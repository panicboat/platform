# Tempo Chart Repository Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tempo を deprecated な `grafana/tempo` 1.24.4 から移管先の `grafana-community/tempo` 2.2.3 に載せ替え、Tempo 本体を 2.9.0 → 2.10.7 に上げる。single binary 構成は維持する。

**Architecture:** helmfile の repository / chart / version を差し替え、values から `opencensus: null` を除く。新旧 chart は StatefulSet の immutable field が一致するため in-place 更新で完了する。保存済みトレースが 0 件で ingest 経路が実トラフィックで検証されていないため、移行前後に合成トレースの往復を通して経路の生死を確かめる。

**Tech Stack:** helmfile / helm / kustomize / Flux CD / Grafana Tempo (single binary) / OTLP HTTP

**Design doc:** `docs/superpowers/specs/2026-08-10-tempo-chart-migration-design.md`

## Global Constraints

- 作業ブランチは `feat/tempo-chart-migration`、worktree は `.claude/worktrees/feat-tempo-chart-migration/`。ブランチと worktree を切り直さない
- commit は `git commit -s` (= `--signoff`) を使う。commit message に `Co-Authored-By` を付けない
- PR は `gh pr create --draft` で作成する。Draft 以外で作らない。PR タイトルは英語
- ドキュメントは見出しが英語、本文が日本語
- 依頼範囲外のリファクタ・コメント追加をしない。変更するのは helmfile / values / hydrate 生成物の 3 ファイルのみ
- `kubernetes/manifests/production/tempo/manifest.yaml` は hydrate 生成物。手で編集しない
- `tempo-distributed` への構成変更、vParquet5 への切り替え、jaeger receivers の削除はいずれも範囲外
- EKS 認証は zsh 関数 `eks-login`。Claude Code のセッションからは `! eks-login` で実行する

## Deployment Path (前提知識)

- Flux は `main` を 1 分間隔で取得し、`./kubernetes/clusters/production` を 10 分間隔で apply する。**merge して初めて本番に反映される**
- PR を開くと label-dispatcher が `deploy:tempo` を自動付与し、hydrator が hydrate 結果を PR ブランチに commit、kustomize-diff が差分を PR コメントに投稿する
- hydrate の toolchain は repository root の `aqua.yaml` で pin されている。`AQUA_CONFIG` の設定は不要 (= 素の shell で `helm version` が `v3.17.3` を返す)

## File Structure

| ファイル | 責務 | 変更 |
| --- | --- | --- |
| `kubernetes/components/tempo/production/helmfile.yaml` | chart の出所とバージョンの宣言 | repository / chart / version を移管先に差し替え |
| `kubernetes/components/tempo/production/values.yaml.gotmpl` | Tempo の設定 | `opencensus: null` を削除、コメントのバージョン参照を更新 |
| `kubernetes/manifests/production/tempo/manifest.yaml` | hydrate 生成物 | スクリプトで再生成 |

---

### Task 1: 移行前に合成トレースの往復を確認する

**実行者:** エージェント (= `! eks-login` 実行後)

**Files:** なし (= 検証のみ、リポジトリを変更しない)

**Interfaces:**
- Consumes: なし
- Produces: 現行構成 (Tempo 2.9.0) での ingest → query 往復の成否。Task 4 の同じ検証と対比する基準になる

**なぜ最初にやるか:** S3 に保存済み block が 0 件で、ingest 経路は実トラフィックで一度も検証されていない。移行後に往復が失敗したとき、この baseline が無いと「移行で壊れた」のか「元から通っていなかった」のかを切り分けられない。

- [ ] **Step 1: cluster に到達できることを確認する**

```bash
kubectl -n monitoring get pod tempo-0 -o custom-columns=READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image --no-headers
```

期待: `true` と `docker.io/grafana/tempo:2.9.0`

到達できない場合は `! eks-login` を実行してから再試行する。

- [ ] **Step 2: port-forward を開く**

```bash
kubectl -n monitoring port-forward svc/tempo 4318:4318 3200:3200 > /tmp/tempo-pf.log 2>&1 &
echo $! > /tmp/tempo-pf.pid
sleep 4
```

4318 は OTLP HTTP の ingest、3200 は query API。

- [ ] **Step 3: 合成トレースを 1 件 push する**

```bash
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
NOW=$(( $(date +%s) * 1000000000 ))
END=$(( NOW + 1000000 ))
echo "TRACE_ID=$TRACE_ID"
curl -s -o /dev/null -w 'ingest HTTP %{http_code}\n' -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"tempo-migration-check\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"migration-check\",\"kind\":1,\"startTimeUnixNano\":\"$NOW\",\"endTimeUnixNano\":\"$END\"}]}]}]}"
```

期待: `ingest HTTP 200`

`traceId` は 32 桁、`spanId` は 16 桁の hex である必要がある。`openssl rand -hex 16` / `-hex 8` がそれぞれの桁数を返す。

- [ ] **Step 4: 同じ trace ID を query API で引く**

```bash
sleep 10
curl -s -H 'Accept: application/json' "http://localhost:3200/api/traces/$TRACE_ID" \
  | jq -r 'if (.batches | length) > 0 then "FOUND spans=\([.batches[].scopeSpans[].spans[]] | length)" else "NOT FOUND" end'
```

期待: `FOUND spans=1`

`NOT FOUND` の場合は `sleep 20` してもう一度引く。それでも出なければ **Task 2 に進まない**。現行構成で ingest 経路が通っていないため、先に原因を特定する必要がある。

- [ ] **Step 5: port-forward を止める**

```bash
kill "$(cat /tmp/tempo-pf.pid)" 2>/dev/null; rm -f /tmp/tempo-pf.pid /tmp/tempo-pf.log
```

**Task 1 完了条件:** Step 3 が `200`、Step 4 が `FOUND spans=1` を返し、port-forward が停止している。

---

### Task 2: chart 参照を移管先に切り替える

**実行者:** エージェント

**Files:**
- Modify: `kubernetes/components/tempo/production/helmfile.yaml`
- Modify: `kubernetes/components/tempo/production/values.yaml.gotmpl`
- Regenerate: `kubernetes/manifests/production/tempo/manifest.yaml`

**Interfaces:**
- Consumes: Task 1 の baseline (= 合否のみ。コードには現れない)
- Produces: hydrate 済み manifest (= Task 3 で PR に載せる)

- [ ] **Step 1: helmfile のヘッダコメントに移管の経緯を足す**

`kubernetes/components/tempo/production/helmfile.yaml` の以下の 2 行を探す。

```yaml
# Tempo 公式が small production OK とする position に準拠)。grafana/tempo-
# distributed への切替は HA / scale 要件が顕在化した時点で再評価する。
```

直後に以下を挿入する。

```yaml
# chart は grafana-community/helm-charts から取る。旧 grafana/helm-charts の
# tempo chart は Chart.yaml に deprecated: true を持ち、repository 自体の
# サポートが 2026-01-30 に終了している。移管先でも single binary mode の
# 提供は継続する。renovate は参照中の repository index しか見ないため、
# repository ごと移管される変更は検知できない。
```

- [ ] **Step 2: repository と chart 参照を差し替える**

同ファイルの以下のブロックを

```yaml
repositories:
  - name: grafana
    url: https://grafana.github.io/helm-charts

releases:
  - name: tempo
    namespace: monitoring
    chart: grafana/tempo
    version: "1.24.4"
```

以下で置き換える。

```yaml
repositories:
  - name: grafana-community
    url: https://grafana-community.github.io/helm-charts

releases:
  - name: tempo
    namespace: monitoring
    chart: grafana-community/tempo
    version: "2.2.3"
```

`values:` 以下と `environments:` ブロックは変更しない。

- [ ] **Step 3: values から opencensus を外し、receivers のコメントを書き換える**

`kubernetes/components/tempo/production/values.yaml.gotmpl` の receivers block を探す。`# Receivers (= OTel Collector からの OTLP 受信用)` を含む見出しの 1 行上の `# ---...` 区切りから、`          endpoint: 0.0.0.0:4318` の行までが対象。

以下で置き換える。

```yaml
  # -------------------------------------------------------------------------
  # Receivers (= OTel Collector からの OTLP 受信用)
  # -------------------------------------------------------------------------
  # chart default の receivers に jaeger が含まれ、values の map は deep-merge
  # されるため otlp だけ書いても jaeger の 4 protocol は開いたままになる。
  # `jaeger: null` では消せない: chart の _ports.tpl が
  # .Values.tempo.receivers.jaeger.protocols.thrift_compact を無条件に参照して
  # おり、キーを削除すると Service の描画が nil pointer で失敗する。
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
```

`opencensus: null` の行が消えることが要点。移管先の chart には default に opencensus が無く、削除対象が存在しないため、残すと「明示的な null」として receiver が復活する。

- [ ] **Step 4: metricsGenerator のコメントのバージョン参照を更新する**

同ファイルの以下の行を

```yaml
  # NOTE: chart v1.24.4 は metricsGenerator.remoteWriteHeaders field を持たない。
```

以下で置き換える。

```yaml
  # NOTE: chart 2.2.3 は metricsGenerator.remoteWriteHeaders field を持たない。
```

前提 (= field が無いこと) は移管先でも変わらないため、記述はバージョン参照だけを直す。

- [ ] **Step 5: podDisruptionBudget のコメントのバージョン参照を更新する**

同ファイルの以下の 2 行を

```yaml
# (Tempo chart v1.24.4 は PDB テンプレートを持たないが、chart upgrade に
# 備えて明示 disable で意図を文書化する)
```

以下で置き換える。

```yaml
# (Tempo chart 2.2.3 は PDB テンプレートを持たないが、chart upgrade に
# 備えて明示 disable で意図を文書化する)
```

- [ ] **Step 6: hydrate を実行する**

```bash
bash scripts/kubernetes-hydrate/hydrate-component.sh tempo production
```

期待: エラーなく終了する。`aqua.yaml` は repository root にあるため `AQUA_CONFIG` の設定は不要。

- [ ] **Step 7: hydrate 結果を検証する**

**計数に `grep -c` を使わないこと。** この環境の `grep` はシェル関数に置き換わっており `-c` が `unknown option '-G'` で失敗する。`awk` で数える。

```bash
awk '/grafana\/tempo:2\.10\.7/{a++} /tempo-2\.2\.3/{b++} /opencensus/{c++} /grafana\/tempo:2\.9\.0/{d++} \
  END{printf "image 2.10.7      : %d\nchart label 2.2.3 : %d\nopencensus 残り   : %d\n旧 image 2.9.0    : %d\n", a+0, b+0, c+0, d+0}' \
  kubernetes/manifests/production/tempo/manifest.yaml
```

期待する出力:

```
image 2.10.7      : 1
chart label 2.2.3 : 6
opencensus 残り   : 0
旧 image 2.9.0    : 0
```

`chart label` の 6 は 6 リソース分の `helm.sh/chart` ラベル (= 変更前の manifest で `tempo-1.24.4` を数えても 6)。`opencensus` の 0 は、変更前の 2 件 (= Service の port name と StatefulSet の containerPort name) が移管先の chart で消えることによる。数が違う場合は Step 2 / Step 3 が未反映なので戻って直す。

- [ ] **Step 8: StatefulSet の immutable field が変わっていないことを確認する**

```bash
M=kubernetes/manifests/production/tempo/manifest.yaml
diff <(git show HEAD:$M | yq 'select(.kind=="StatefulSet") | {"serviceName":.spec.serviceName,"selector":.spec.selector,"vct":.spec.volumeClaimTemplates}') \
     <(yq 'select(.kind=="StatefulSet") | {"serviceName":.spec.serviceName,"selector":.spec.selector,"vct":.spec.volumeClaimTemplates}' $M) \
  && echo "IMMUTABLE FIELDS UNCHANGED"
```

期待: `IMMUTABLE FIELDS UNCHANGED`

差分が出た場合は **commit せずに停止する**。StatefulSet を in-place 更新できず、Flux の apply が失敗する。

- [ ] **Step 9: 差分の範囲を確認する**

```bash
git status --short
```

期待: 以下の 3 ファイルのみ。

```
 M kubernetes/components/tempo/production/helmfile.yaml
 M kubernetes/components/tempo/production/values.yaml.gotmpl
 M kubernetes/manifests/production/tempo/manifest.yaml
```

- [ ] **Step 10: commit する**

```bash
git add -A kubernetes/components/tempo kubernetes/manifests/production/tempo
git commit -s -F - <<'EOF'
feat(kubernetes/components/tempo/production): move to the grafana-community chart

grafana/tempo 1.24.4 は Chart.yaml に deprecated: true を持ち、grafana/helm-charts
repository 自体のサポートが 2026-01-30 に終了している。上流は grafana-community に
移り chart 2.2.3 / Tempo 2.10.7 が出ているが、renovate は参照中の repository index
しか見ないため上げるべき差分が存在せず、古いことがどこにも現れていなかった。

single binary の廃止ではなく repository の移管なので構成は変えない。新旧 chart を
同一 values で描画して StatefulSet の serviceName / selector / volumeClaimTemplates が
一致することを確認済みで、in-place 更新で完了する。

values の opencensus: null を削除する。移管先の chart は default receivers に
opencensus を持たないため、Helm の null 削除セマンティクスが働かず、残すと明示的な
null として receiver が復活する。Service と StatefulSet からはポート宣言が消えるため、
Tempo だけが 55678 を bind してどこからも到達できない状態になる。
EOF
```

**Task 2 完了条件:** Step 7 が `1 / 5 / 0 / 0` を返し、Step 8 が `IMMUTABLE FIELDS UNCHANGED` を返し、Step 9 の差分が 3 ファイルに収まり、commit が作られている。

---

### Task 3: PR を作成して CI の出力を確認する

**実行者:** エージェント

**Files:** なし (= リポジトリ操作のみ)

**Interfaces:**
- Consumes: Task 2 の commit
- Produces: Draft PR (= Task 4 で merge する)

- [ ] **Step 1: push してトラッキングを設定する**

```bash
git push -u origin HEAD
```

- [ ] **Step 2: Draft PR を作成する**

```bash
gh pr create --draft \
  --title "feat(kubernetes/components/tempo/production): move to the grafana-community chart" \
  --body-file - <<'EOF'
## Why

`grafana/tempo` 1.24.4 は `Chart.yaml` に `deprecated: true` を持ち、`grafana/helm-charts` repository 自体のサポートが 2026-01-30 に終了している。上流は `grafana-community/helm-charts` に移り chart 2.2.3 / Tempo 2.10.7 が出ているが、こちらは Tempo 2.9.0 に留まっていた。

renovate は helmfile が参照する repository の index を見る。旧 repository での最新が 1.24.4 なので上げるべき差分が存在せず、古いという事実がどこにも現れない。repository URL ごと移管される変更を renovate は追えない。

## What

- repository を `grafana-community` (`https://grafana-community.github.io/helm-charts`) に、chart を `grafana-community/tempo` 2.2.3 に差し替え
- values から `opencensus: null` を削除

single binary の廃止ではなく repository の移管なので、`tempo-distributed` への構成変更はしない。

## opencensus を消す理由

移管先の chart は default receivers に `opencensus` を持たない。Helm の「values に null を置くと chart default のキーを削除する」挙動は削除対象があって初めて働くため、残すと明示的な null として設定に出力され receiver が復活する。Service と StatefulSet からはポート宣言が消えるので、Tempo だけが 55678 を bind してどこからも到達できない状態になる。直前の #743 で入れた行をここで戻す形になる。

## Impact

- StatefulSet が in-place 更新され、Pod 1 台が再起動する (数十秒)
- Tempo image が `2.9.0` → `2.10.7`
- Service から `tempo-opencensus` (55678)、StatefulSet から containerPort `opencensus` が消える
- ServiceMonitor から `jaeger-metrics` endpoint が消える。`tempo-prom-metrics` と `interval: 15s` は維持される
- Tempo の設定に `stream_over_http_enabled: false` が加わる

StatefulSet の `serviceName` / `selector` / `volumeClaimTemplates` は新旧で一致しており、PVC の作り直しは発生しない。

Tempo 2.10 の破壊的変更は vParquet2 の読み取り廃止だが、`storage.trace.block` を明示指定しておらず既定の vParquet4 を使っているため該当しない。そもそも S3 上の保存済み block が 0 件。

Design: `docs/superpowers/specs/2026-08-10-tempo-chart-migration-design.md`
Plan: `docs/superpowers/plans/2026-08-10-tempo-chart-migration.md`
EOF
```

- [ ] **Step 3: CI の完了を待って出力を確認する**

```bash
gh pr checks --watch
gh pr view --json labels --jq '[.labels[].name] | join(", ")'
```

確認する内容:

1. 全チェックが pass
2. ラベルに `deploy:tempo` が自動付与されている
3. hydrator が追加 commit を作っていない (= Task 2 Step 6 でローカル hydrate 済みのため差分ゼロが正常)。追加 commit がある場合は `git pull` して内容を確認し、原因を特定するまで進まない
4. kustomize-diff の PR コメントに image `2.10.7` への変更と opencensus ポートの削除が現れている

**Task 3 完了条件:** Draft PR が存在し、CI が green で、kustomize-diff の内容が意図と一致している。

---

### Task 4: merge と本番検証

**実行者:** エージェント (= merge と kubectl 検証)

**Files:** なし

**Interfaces:**
- Consumes: Task 1 の baseline、Task 3 の Draft PR
- Produces: 本番稼働中の Tempo 2.10.7

- [ ] **Step 1: PR を ready にして merge する**

```bash
gh pr ready
gh pr merge --squash
```

- [ ] **Step 2: Flux の反映を確認する**

```bash
flux reconcile kustomization flux-system --with-source
kubectl -n monitoring get statefulset tempo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

期待: `docker.io/grafana/tempo:2.10.7`

- [ ] **Step 3: rollout の完了を確認する**

```bash
kubectl -n monitoring rollout status statefulset/tempo --timeout=300s
kubectl -n monitoring get pod tempo-0 -o custom-columns=READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount --no-headers
```

期待: rollout 成功、`true` と `0`

- [ ] **Step 4: ログにエラーが無いことを確認する**

```bash
kubectl -n monitoring logs tempo-0 -c tempo --tail=50 | grep -iE 'level=error|panic|fatal' || echo "no errors"
kubectl -n monitoring logs tempo-0 -c tempo | awk '/Tempo started/{n++} END{print "Tempo started: " n+0}'
```

期待: `no errors` と `Tempo started: 1`

計数に `grep -c` を使わない理由は Task 2 Step 7 と同じ。

- [ ] **Step 5: Service から opencensus ポートが消えたことを確認する**

```bash
kubectl -n monitoring get svc tempo -o jsonpath='{range .spec.ports[*]}{.name}={.port} {end}{"\n"}' | tr ' ' '\n' | grep -i opencensus || echo "opencensus port removed"
```

期待: `opencensus port removed`

- [ ] **Step 6: 合成トレースの往復を再確認する**

Task 1 とまったく同じ手順を実行する。

```bash
kubectl -n monitoring port-forward svc/tempo 4318:4318 3200:3200 > /tmp/tempo-pf.log 2>&1 &
echo $! > /tmp/tempo-pf.pid
sleep 4
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
NOW=$(( $(date +%s) * 1000000000 ))
END=$(( NOW + 1000000 ))
echo "TRACE_ID=$TRACE_ID"
curl -s -o /dev/null -w 'ingest HTTP %{http_code}\n' -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"tempo-migration-check\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"migration-check\",\"kind\":1,\"startTimeUnixNano\":\"$NOW\",\"endTimeUnixNano\":\"$END\"}]}]}]}"
sleep 10
curl -s -H 'Accept: application/json' "http://localhost:3200/api/traces/$TRACE_ID" \
  | jq -r 'if (.batches | length) > 0 then "FOUND spans=\([.batches[].scopeSpans[].spans[]] | length)" else "NOT FOUND" end'
kill "$(cat /tmp/tempo-pf.pid)" 2>/dev/null; rm -f /tmp/tempo-pf.pid /tmp/tempo-pf.log
```

期待: `ingest HTTP 200` と `FOUND spans=1`

Task 1 が通っていて本 Step が失敗した場合は、移行が原因と断定できる。Rollback に進む。

- [ ] **Step 7: worktree を片付ける**

merge 済みを確認してから実行する。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-tempo-chart-migration
git worktree prune
git fetch origin --prune
git branch -D feat/tempo-chart-migration
git merge --ff-only origin/main
```

**Task 4 完了条件:** Step 2 が `2.10.7`、Step 3 が Ready かつ RESTARTS=0、Step 5 が `opencensus port removed`、Step 6 が `FOUND spans=1` を返している。

---

## Rollback

Task 4 のいずれかで失敗した場合。

1. merge した commit を revert して push する

```bash
git revert <merge-commit-sha>
git push
flux reconcile kustomization flux-system --with-source
```

2. Pod が起動しない場合、2.10 が書いた WAL を 2.9 が読めていない可能性がある。PVC ごと捨てて作り直す

```bash
kubectl -n monitoring scale statefulset tempo --replicas=0
kubectl -n monitoring wait --for=delete pod/tempo-0 --timeout=120s
kubectl -n monitoring delete pvc storage-tempo-0
kubectl -n monitoring scale statefulset tempo --replicas=1
kubectl -n monitoring rollout status statefulset/tempo --timeout=300s
```

StatefulSet の `volumeClaimTemplates` が同名の PVC を作り直す。PVC には WAL と短期 compactor cache しか無く、保存済み block は 0 件なので失うものは無い。
