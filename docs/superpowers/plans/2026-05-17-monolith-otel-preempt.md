# monolith OTel preempt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** monolith Pod の OTel SDK env vars 6 個 + `config/initializers/opentelemetry.rb` を削除、 `instrumentation.opentelemetry.io/inject-ruby` annotation を追加して Operator merge を anticipate (= 短期 trace 消失許容)。

**Architecture:** monorepo single PR で deployment.yaml 修正 + initializer.rb 削除。 cluster 反映は Flux GitRepository 経由 (= main merge → Flux Kustomization reconcile)。 verification は kubectl + curl で post-deploy 確認。

**Tech Stack:** Kubernetes Deployment + OpenTelemetry Operator (chart 0.113.0) + Flux GitRepository + Ruby (Hanami) application

**Spec:** `docs/superpowers/specs/2026-05-17-monolith-otel-preempt-design.md`

---

## File Structure

| File | Action | 責任 |
|---|---|---|
| `monorepo/services/monolith/kubernetes/base/deployment.yaml` | Modify | Pod 定義から OTel env 削除、 annotation 追加 |
| `monorepo/services/monolith/workspace/config/initializers/opentelemetry.rb` | Delete | application code SDK init を removal (= future autoinstrumentation gem との conflict 回避) |

---

## Task 1: monorepo worktree + branch 準備

**Files:**
- N/A (setup only)

- [ ] **Step 1: monorepo の最新 main を fetch**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git fetch origin --quiet
```

- [ ] **Step 2: worktree 作成 (= 既存 WIP に影響なし)**

```bash
git worktree add -b chore/otel-25-preempt-monolith .claude/worktrees/chore-otel-25-preempt-monolith origin/main
```

Expected: `Preparing worktree (new branch 'chore/otel-25-preempt-monolith')`

- [ ] **Step 3: worktree directory に移動 + state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/chore-otel-25-preempt-monolith
git status
```

Expected: `On branch chore/otel-25-preempt-monolith` + clean working tree

---

## Task 2: deployment.yaml 修正

**Files:**
- Modify: `monorepo/services/monolith/kubernetes/base/deployment.yaml`

- [ ] **Step 1: 現状確認**

```bash
cat services/monolith/kubernetes/base/deployment.yaml
```

Expected: `env:` block に OTel env vars 6 個、 `template.metadata.annotations` に `inject-ruby` 不在。

- [ ] **Step 2: deployment.yaml を以下の content に置換**

最終形:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monolith
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  revisionHistoryLimit: 1
  selector:
    matchLabels:
      app: monolith
  template:
    metadata:
      labels:
        app: monolith
      annotations:
        # OTel Operator が Ruby auto-injection native support 後に effective に。
        # 現状 (= chart 0.113.0) では Operator が unknown annotation として silently
        # ignore、 monolith Pod の trace 取得は停止。 upstream PR の merge + chart
        # upgrade で auto 復活する。
        # 引き継ぎ #25 / spec: docs/superpowers/specs/2026-05-17-monolith-otel-preempt-design.md
        instrumentation.opentelemetry.io/inject-ruby: default/panicboat-application
    spec:
      containers:
        - name: monolith
          image: ghcr.io/panicboat/monorepo/monolith:latest # {"$imagepolicy": "flux-system:monolith"}
          imagePullPolicy: IfNotPresent
          command: ["./bin/start"]
          ports:
            - containerPort: 9001
          envFrom:
            - configMapRef:
                name: monolith
            - secretRef:
                name: monolith-database
```

- [ ] **Step 3: diff 確認**

```bash
git diff services/monolith/kubernetes/base/deployment.yaml
```

Expected: `env:` block 削除 (= OTel 6 個 + comment)、 `template.metadata.annotations` 追加。

---

## Task 3: initializer.rb 削除

**Files:**
- Delete: `monorepo/services/monolith/workspace/config/initializers/opentelemetry.rb`

- [ ] **Step 1: 削除前 content 再確認 (= 不可逆 operation なので)**

```bash
cat services/monolith/workspace/config/initializers/opentelemetry.rb
```

Expected: `OpenTelemetry::SDK.configure { |c| c.service_name = "monolith"; c.use_all }`

- [ ] **Step 2: git rm で削除**

```bash
git rm services/monolith/workspace/config/initializers/opentelemetry.rb
```

Expected: `rm 'services/monolith/workspace/config/initializers/opentelemetry.rb'`

- [ ] **Step 3: git status 確認**

```bash
git status
```

Expected: 2 file changes staged (= deployment.yaml modified、 opentelemetry.rb deleted)

---

## Task 4: kustomize build で expected output 確認

**Files:** N/A (verify only)

- [ ] **Step 1: kustomize build で final manifest 出力**

```bash
kustomize build services/monolith/kubernetes/overlays/production 2>&1 | head -50
```

Expected:
- `kind: Deployment` の `spec.template.metadata.annotations` に `instrumentation.opentelemetry.io/inject-ruby: default/panicboat-application`
- `spec.template.spec.containers[0]` に `env:` block **不在**
- `envFrom:` は `configMapRef: monolith` + `secretRef: monolith-database` 維持

- [ ] **Step 2: OTel env vars 不在確認**

```bash
kustomize build services/monolith/kubernetes/overlays/production 2>&1 | /usr/bin/grep -i otel | /usr/bin/head -10
```

Expected: `instrumentation.opentelemetry.io/inject-ruby: default/panicboat-application` の **1 行のみ** (= env vars 不在)

---

## Task 5: commit + push + draft PR

**Files:** N/A

- [ ] **Step 1: commit**

```bash
git commit -s -m "$(cat <<'EOF'
chore(monolith): remove OTel env hardcode + initializer, add inject-ruby annotation (= #25 preempt)

OTel Operator upstream Ruby auto-instrumentation 動向 (= ruby-contrib#1384
APPROVED + 直近 active) を踏まえ、 Operator merge + chart upgrade での auto
復活を anticipate して preempt。 deployment.yaml の OTel env vars 6 個削除 +
config/initializers/opentelemetry.rb 削除 + instrumentation.opentelemetry.io/
inject-ruby annotation 追加。 短期 monolith trace 消失を許容、 Operator
merge + chart upgrade で auto 復活する path。

spec: docs/superpowers/specs/2026-05-17-monolith-otel-preempt-design.md
plan: docs/superpowers/plans/2026-05-17-monolith-otel-preempt.md
EOF
)"
```

Expected: commit success + 2 files changed

- [ ] **Step 2: push**

```bash
git push -u origin HEAD
```

- [ ] **Step 3: draft PR 作成**

```bash
gh pr create --draft --title "chore(monolith): remove OTel env hardcode + initializer, add inject-ruby annotation (= #25 preempt)" --body "$(cat <<'EOF'
## Summary

引き継ぎ事項 **#25** の preempt 実装。 monorepo monolith side で:
- \`deployment.yaml\` の OTel SDK env vars 6 個削除
- \`spec.template.metadata.annotations\` に \`instrumentation.opentelemetry.io/inject-ruby: default/panicboat-application\` 追加
- \`config/initializers/opentelemetry.rb\` 削除

OTel Operator が将来 Ruby auto-injection native support した時点で auto 復活する path。 短期 monolith trace 消失を許容 (= Operator merge + chart upgrade まで)。

## Spec / Plan

- spec: [docs/superpowers/specs/2026-05-17-monolith-otel-preempt-design.md](https://github.com/panicboat/platform/blob/main/docs/superpowers/specs/2026-05-17-monolith-otel-preempt-design.md) (= platform/PR #425 merged)
- plan: docs/superpowers/plans/2026-05-17-monolith-otel-preempt.md (= platform/PR docs/otel-25-preempt-plan)

## Test plan

- [ ] kustomize build output で env: 不在 + inject-ruby annotation 存在を手元確認 (= 手元 verify 済)
- [ ] PR merge 後 Flux reconcile で deploy → monolith Pod restart
- [ ] kubectl exec monolith-pod -- env | grep OTEL で 0 件 (= env 削除確認)
- [ ] kubectl get pod monolith -o yaml で annotations に inject-ruby 存在
- [ ] monolith Pod Running (= application 起動成功)
- [ ] curl https://develop.panicboat.net/ で 200 (= application 動作)
- [ ] OTel Operator log で inject-ruby annotation の warning / error 確認 (= 出ても無害)
- [ ] OTel Collector log で monolith からの OTLP push 0 件 (= 期待挙動)
EOF
)"
```

Expected: PR URL 返却

---

## Task 6: post-merge verification (= user merge 後)

**Files:** N/A (cluster verification)

- [ ] **Step 1: Flux reconcile 確認**

```bash
eks-login >/dev/null 2>&1
kubectl get kustomization -n flux-system monolith
```

Expected: READY=True、 最新 revision applied

- [ ] **Step 2: monolith Pod restart 確認**

```bash
kubectl get pods -n default -l app=monolith
```

Expected: 新 Pod が Running、 AGE が短い

- [ ] **Step 3: env 削除確認**

```bash
POD=$(kubectl get pod -n default -l app=monolith -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default -c monolith "$POD" -- /bin/sh -c 'env | grep OTEL || echo "(no OTEL env)"'
```

Expected: `(no OTEL env)` (= 全 env 削除確認)

- [ ] **Step 4: annotation 存在確認**

```bash
kubectl get pod -n default "$POD" -o jsonpath='{.metadata.annotations.instrumentation\.opentelemetry\.io/inject-ruby}'
echo ""
```

Expected: `default/panicboat-application`

- [ ] **Step 5: application 動作確認**

```bash
curl -sk -o /dev/null -w "HTTP %{http_code}\n" --max-time 6 https://develop.panicboat.net/
```

Expected: HTTP 200

- [ ] **Step 6: OTel Operator log で annotation 関連 warning 確認**

```bash
kubectl logs -n opentelemetry-operator-system -l app.kubernetes.io/name=opentelemetry-operator --tail=100 --since=5m 2>&1 | /usr/bin/grep -iE "inject-ruby|monolith" | /usr/bin/head -10
```

Expected: warning 出ても無害 / 0 件のはず

- [ ] **Step 7: monolith からの OTLP push 0 件 confirm (= 期待挙動)**

```bash
AGENT=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$(kubectl get pod -n default "$POD" -o jsonpath='{.spec.nodeName}') -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system "$AGENT" -c cilium-agent -- hubble observe --from-pod default/monolith --to-namespace monitoring --output compact --since 2m --last 10
```

Expected: monolith → opentelemetry-collector への flow 0 件 (= trace emit なし)

---

## Task 7: worktree cleanup (= optional)

**Files:** N/A

- [ ] **Step 1: worktree remove (= user merge 後)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git worktree remove .claude/worktrees/chore-otel-25-preempt-monolith
git branch -D chore/otel-25-preempt-monolith
```

---

## Out of scope (= 別 PR、 future)

- platform chart upgrade (= OTel Operator Ruby support release 後)
- platform Instrumentation CR `spec.ruby` 設定追加
- monorepo Gemfile に `opentelemetry-autoinstrumentation` gem 追加
- Beyla 等 eBPF auto-trace の monolith 適用検討

詳細は spec doc Section 4 + 7 を参照。
