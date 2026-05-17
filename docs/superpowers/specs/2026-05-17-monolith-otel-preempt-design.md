# monolith OTel preempt to Operator native (= 引き継ぎ事項 #25)

> **Goal**: Phase 6 closure で workaround として monolith Pod に hardcode した OTel SDK env vars 6 個を **今 削除し、 OTel Operator が将来 Ruby auto-injection を native support した時点で auto 復活する状態に preempt**。 短期 monolith trace 消失を許容、 Operator merge + chart upgrade で何もせずに復活する path。

---

## 1. 経緯 + 現状

### Phase 6 closure 時の workaround

OTel Operator chart 0.113.0 (= app version 0.151.0) は Java / .NET / Go / Node.js / Python / Apache HTTPD / nginx の auto-instrumentation を support するが、 **Ruby は upstream 未実装**。 monolith (Ruby) は Operator auto-injection を受けず、 SDK が動作するために env vars 6 個を `services/monolith/kubernetes/base/deployment.yaml` に hardcode + `services/monolith/workspace/config/initializers/opentelemetry.rb` で `OpenTelemetry::SDK.configure { |c| c.service_name = "monolith"; c.use_all }` を call する path で運用。

### 2026-05-17 upstream 動向再確認

| upstream | state | 最終 update | 備考 |
|---|---|---|---|
| [opentelemetry-operator#3756](https://github.com/open-telemetry/opentelemetry-operator/pull/3756) "[autoinstrumentation] add ruby autoinstrumentation" | OPEN / CHANGES_REQUESTED | 2026-01-23 | 4 ヶ月 stuck、 dependency 待ち |
| [opentelemetry-ruby-contrib#1384](https://github.com/open-telemetry/opentelemetry-ruby-contrib/pull/1384) (= `opentelemetry-autoinstrumentation` gem) | OPEN / APPROVED | 2026-05-15 | **直近 active**、 APPROVED で merge 待ち |

`ruby-contrib#1384` が merge されれば `opentelemetry-operator#3756` の dependency 解消、 数週〜数ヶ月で Operator native Ruby auto-injection が release される見込み。

---

## 2. 採用 path: preempt + 短期 trace 消失許容

### Why preempt

Operator merge + chart upgrade まで「現状の workaround を継続」 もしくは「**今 preempt して deployment.yaml を将来形に合わせる**」 の選択肢のうち後者を採用:

1. `deployment.yaml` を frontend (= Node.js Operator auto-inject 動作中、 env 0 個) と類似 clean state にできる
2. Operator merge + chart upgrade で auto 復活 (= transition step 不要)
3. application code (= `initializer.rb`) も将来 autoinstrumentation gem との conflict 回避のため今削除しておく
4. 短期 monolith trace 消失は user 許容済 (= Pod log + Beyla / kube-state-metrics 経由の observability で初期 incident 対応可能)

### 採用しなかった代替案

- **ConfigMap 集約 (= 共通 or service 別)**: workaround の location 変更 のみ、 transition cost が上乗せ。 真の elimination は Operator 待ち
- **application code SDK init で endpoint / exporter hardcode**: monorepo application code 変更、 transition で再変更必要
- **kustomize component で共通 patch**: 1 Ruby service のみで overkill (= YAGNI)

---

## 3. Architecture

### Before (= 現状)

```
monolith Pod
  metadata.annotations: (なし)
  spec.containers[].env:
    OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector.monitoring.svc.cluster.local:4317
    OTEL_RESOURCE_ATTRIBUTES=service.name=monolith
    OTEL_TRACES_EXPORTER=otlp
    OTEL_METRICS_EXPORTER=otlp
    OTEL_LOGS_EXPORTER=otlp
    OTEL_PROPAGATORS=tracecontext,baggage
  spec.containers[].envFrom:
    - configMapRef: monolith
    - secretRef: monolith-database

monolith app boot
  config/initializers/opentelemetry.rb:
    OpenTelemetry::SDK.configure { |c| c.service_name = "monolith"; c.use_all }
  ↓ env vars 経由 SDK が OTel Collector に trace emit
```

### After (= 本 PR)

```
monolith Pod
  metadata.annotations:
    instrumentation.opentelemetry.io/inject-ruby: default/panicboat-application
  spec.containers[].env: [] (= 削除)
  spec.containers[].envFrom:
    - configMapRef: monolith
    - secretRef: monolith-database

monolith app boot
  config/initializers/opentelemetry.rb: (= 削除)
  ↓ SDK init 走らない、 trace emit なし
```

### Future (= Operator merge + chart upgrade 後の auto 復活)

```
monolith Pod
  metadata.annotations:
    instrumentation.opentelemetry.io/inject-ruby: default/panicboat-application  ← 既存
  spec.containers[].env: [] (= 既存)
  spec.containers[].envFrom: (= 既存)
  Operator が webhook で以下を auto-inject:
    initContainer: autoinstrumentation-ruby image (SDK + autoinstrumentation gem)
    env:
      RUBYOPT=-r/otel-auto-instrumentation-ruby/autoinstrumentation.rb
      OTEL_EXPORTER_OTLP_ENDPOINT=... (Instrumentation CR より)
      OTEL_SERVICE_NAME=monolith
      OTEL_TRACES_SAMPLER=...
      OTEL_PROPAGATORS=...
      OTEL_RESOURCE_ATTRIBUTES=k8s.* + service.namespace + ...

monolith app boot
  autoinstrumentation gem auto-require (= RUBYOPT 経由)
    → SDK auto-init + use_all 相当
    → 通常運用復活
```

---

## 4. Files changed

### 本 PR (= 2 repo)

**monorepo PR** (= deploy 反映で trace 消失開始):
- `services/monolith/kubernetes/base/deployment.yaml`
  - `spec.template.metadata.annotations` に `instrumentation.opentelemetry.io/inject-ruby: default/panicboat-application` 追加
  - `spec.containers[0].env` の OTel 関連 6 個削除
  - 既存 hardcode 説明 comment 削除
- `services/monolith/workspace/config/initializers/opentelemetry.rb`
  - **file 削除**

**platform PR** (= doc 更新):
- `docs/superpowers/specs/2026-05-17-monolith-otel-preempt-design.md` (= 本 file 新規作成)
- `docs/superpowers/specs/2026-05-13-eks-production-phase-6-closure-design.md`
  - #25 entry の stance update (= 「upstream PR active で direction positive、 monorepo 側 preempt 実施済、 Operator merge + chart upgrade で auto 復活」)

### Future (= Operator merge + chart upgrade 後の別 PR)

- `platform/kubernetes/components/opentelemetry/production/helmfile.yaml` chart version bump (= Ruby auto-instrumentation 対応 version)
- `platform/kubernetes/components/opentelemetry/production/instrumentation.yaml` (= Instrumentation CR) に `spec.ruby` 設定追加
- `monorepo/services/monolith/workspace/Gemfile` に `opentelemetry-autoinstrumentation` gem 追加 (= 上記 ruby-contrib#1384 merge 後の gem release 後)
- `monorepo/services/monolith/workspace/Gemfile` から旧 `opentelemetry-sdk` / `opentelemetry-instrumentation-all` / `opentelemetry-exporter-otlp` の整理 (= autoinstrumentation gem に統合される場合)

---

## 5. Risks + mitigations

| Risk | Mitigation |
|---|---|
| 短期 monolith trace 消失で observability ギャップ | user 認可済。 Pod log + container / node metrics は別経路 (= Beyla eBPF、 kube-state-metrics) で 引き続き観測可。 critical incident は Pod log + Grafana metrics で初期対応 |
| Operator merge までの period 長期化 (= 数ヶ月以上) | 監視 watch task (= 月 1 で upstream PR status 確認)。 長期化見込みなら復活 PR (= initializer 再 commit) を中継 fallback として用意可 |
| `inject-ruby` annotation を現状の Operator が warning / error 出す | chart 0.113.0 / app 0.151.0 では unknown annotation は silently ignored の見込み。 deploy 後 Operator log 確認 (= warning 出ても無害) |
| Operator merge 時に Gemfile 側 `opentelemetry-autoinstrumentation` gem 追加忘れ | 引き継ぎ事項に明示記録、 transition checklist で履行 |

---

## 6. Validation

### 本 PR merge 後 (= 即時)

- [ ] monolith Pod restart 後 Running (= application 起動成功、 initializer 不在で起動可能)
- [ ] frontend Pod の trace は 引き続き flowing (= 影響なし)
- [ ] OTel Collector log で monolith からの OTLP push 0 件 (= 期待挙動)
- [ ] `kubectl exec monolith-pod -- env | grep OTEL` で 0 件 (= env 削除確認)
- [ ] `kubectl get pod monolith -o yaml` の annotations に `inject-ruby` 存在確認
- [ ] OTel Operator log で `inject-ruby` annotation の warning / error 確認 (= 出ても無害だが認識)
- [ ] develop.panicboat.net で curl 200 (= application 動作 healthy)

### Future (= Operator merge + chart upgrade 後)

- [ ] chart upgrade で Operator が Ruby auto-instrumentation 対応 version に
- [ ] Instrumentation CR `spec.ruby` 設定追加 + apply
- [ ] monorepo Gemfile に `opentelemetry-autoinstrumentation` gem 追加 + image rebuild
- [ ] monolith Pod restart 後、 `kubectl exec monolith-pod -- env | grep OTEL` で env auto-injected 確認
- [ ] OTel Collector log で monolith からの OTLP push 復活確認
- [ ] Tempo / Grafana ServiceMap で monolith node が trace 受信中表示

---

## 7. Out of scope

- Operator chart upgrade + Instrumentation CR `spec.ruby` 設定 (= 別 PR、 Operator PR #3756 merge 後)
- monorepo Gemfile の `opentelemetry-autoinstrumentation` gem 追加 (= 別 PR、 ruby-contrib#1384 merge + gem release 後)
- Beyla 等 eBPF auto-trace の monolith 適用検討 (= 短期 trace 消失軽減策、 別 brainstorm)
- frontend / 他 service の OTel 設定 (= 既に Operator auto-inject で動作、 影響なし)
