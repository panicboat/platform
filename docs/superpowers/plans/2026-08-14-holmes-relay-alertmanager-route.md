# holmes Alertmanager Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route `severity: critical` alerts from the existing Alertmanager to the `holmes` service (deployed in `panicboat/monorepo`, see `system-components/holmes/`), authenticated with a shared bearer token, without touching any other existing routing.

**Architecture:** Extend `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`'s `alertmanager.config` (currently entirely default — everything routes to the `null` receiver) with one additional route matching `severity="critical"` and a `holmes` webhook receiver. The receiver's bearer token comes from a file mounted via `alertmanagerSpec.secrets`, synced from AWS Secrets Manager by a new ExternalSecret in the `monitoring` namespace — the same underlying secret (`panicboat/holmes/alertmanager`) that `system-components/holmes`'s own ExternalSecret (in monorepo) already syncs for the relay's own token verification. That secret already has a real `shared_token` value provisioned (holmes is live in production).

**Tech Stack:** Helmfile (kube-prometheus-stack chart), Kustomize, External Secrets Operator.

## Global Constraints

- Do not touch any other `alertmanager.config` routing — this repo currently has zero configured receivers other than the chart's default `null` receiver (per the existing `# NOTE: receiver 設定 ... は未設定` comment); this plan is additive only.
- `holmes` is already deployed and verified reachable at `https://holmes.panicboat.net` (plain `Ingress`, not `HTTPRoute` — it shares the `application` ALB with the other `panicboat.net` monitoring UIs, no oauth2-proxy in front since Alertmanager can't complete an OAuth login).
- Target Slack channel: `#platform-alert-p1` (passed to holmes as the `channel` query parameter, without the leading `#` — Slack's `chat.postMessage` accepts a bare channel name).
- Design doc: `docs/superpowers/specs/2026-08-14-holmes-relay-design.md`.

---

## Task 1: ExternalSecret for the Alertmanager shared token

**Files:**
- Create: `kubernetes/components/prometheus-operator/production/kustomization/holmes-alertmanager-external-secret.yaml`
- Modify: `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`

**Interfaces:**
- Produces: K8s Secret `holmes-alertmanager` in the `monitoring` namespace with key `ALERTMANAGER_SHARED_TOKEN`, consumed by Task 2's `alertmanagerSpec.secrets` mount.

- [ ] **Step 1: Write the ExternalSecret**

`kubernetes/components/prometheus-operator/production/kustomization/holmes-alertmanager-external-secret.yaml`:

```yaml
# =============================================================================
# ExternalSecret: holmes shared token (Alertmanager side)
# =============================================================================
# AWS Secrets Manager の panicboat/holmes/alertmanager (property:
# shared_token) を K8s Secret holmes-alertmanager に sync。
# alertmanagerSpec.secrets 経由で Alertmanager pod にファイルとしてマウントされ、
# webhook_configs の http_config.authorization.credentials_file から参照される。
#
# 同じ AWS Secrets Manager path を、holmes 自身(panicboat/monorepo,
# system-components/holmes)側の ExternalSecret も別途 sync している(受信側の
# トークン検証用)。値の作成元は1箇所(このシークレット)、sync 先は2箇所という
# 構成。
# =============================================================================
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: holmes-alertmanager
  namespace: monitoring
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: holmes-alertmanager
    creationPolicy: Owner
  data:
    - secretKey: ALERTMANAGER_SHARED_TOKEN
      remoteRef:
        key: panicboat/holmes/alertmanager
        property: shared_token
```

- [ ] **Step 2: Register it in the kustomization**

Modify `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# prometheus-operator production kustomization
# =============================================================================
# chart 範囲外 resource (= Grafana admin ExternalSecret, holmes 用
# Alertmanager token ExternalSecret) を helmfile output に上乗せする overlay。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana-admin-external-secret.yaml
  - holmes-alertmanager-external-secret.yaml
```

- [ ] **Step 3: Hydrate and inspect the diff**

Run: `./scripts/kubernetes-hydrate/hydrate-component.sh prometheus-operator production && git diff kubernetes/manifests/production/prometheus-operator`
Expected: diff shows exactly one new `ExternalSecret` resource named `holmes-alertmanager` in the `monitoring` namespace added to the rendered manifest. No other resources change.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/prometheus-operator/production/kustomization/holmes-alertmanager-external-secret.yaml kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml kubernetes/manifests/production/prometheus-operator
git commit -s -m "feat(prometheus-operator): sync holmes Alertmanager token"
```

---

## Task 2: Alertmanager route and receiver

**Files:**
- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl:221-242`

**Interfaces:**
- Consumes: `holmes-alertmanager` Secret (Task 1).

- [ ] **Step 1: Confirm holmes is still up before wiring the route**

```bash
kubectl -n default get ingress holmes
curl -s -o /dev/null -w '%{http_code}\n' https://holmes.panicboat.net/healthz
```

Expected: the `Ingress` exists with an ALB address, and the healthz check returns `200`. (holmes was verified live and receiving real Slack traffic before this plan was written — this step is a pre-flight sanity check, not discovery of an unknown value.)

- [ ] **Step 2: Replace the Alertmanager Configuration section**

In `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`, replace:

```yaml
# =============================================================================
# Alertmanager Configuration
# =============================================================================
# NOTE: receiver 設定 (Slack / SNS / PagerDuty) は未設定
alertmanager:
  enabled: true
  alertmanagerSpec:
    # cpu: 実測平均 0m (ほぼ idle) に対し 100m は過大。right-size。
    resources:
      requests:
        cpu: 25m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          resources:
            requests:
              storage: 2Gi
```

with:

```yaml
# =============================================================================
# Alertmanager Configuration
# =============================================================================
# severity: critical のアラートのみ holmes (panicboat/monorepo,
# system-components/holmes) に webhook 転送し、HolmesGPT の調査結果を Slack に
# 投稿させる。severity ラベルは kube-prometheus-stack の default rule に
# 既に付与されているため、新たなラベル付け作業は不要 (2026-08-14 実測: firing
# 中 6 件中 critical 3 件)。route の見つけ方は "最初にマッチした sibling
# route を上から順に評価" なので、既存の Watchdog->null を残したまま追加する。
alertmanager:
  enabled: true
  alertmanagerSpec:
    # cpu: 実測平均 0m (ほぼ idle) に対し 100m は過大。right-size。
    resources:
      requests:
        cpu: 25m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          resources:
            requests:
              storage: 2Gi
    # holmes の Alertmanager shared token を file mount (Task 1 の
    # ExternalSecret が作る Secret)。alertmanagerSpec.secrets は Alertmanager
    # と同一 namespace の Secret のみ参照可能なため、monitoring namespace 側に
    # 専用の ExternalSecret を用意している (system-components/holmes 側の
    # ExternalSecret とは sync 先が別、値の出どころは同じ)。
    secrets:
      - holmes-alertmanager
  config:
    global:
      resolve_timeout: 5m
    inhibit_rules:
      - source_matchers:
          - 'severity = critical'
        target_matchers:
          - 'severity =~ warning|info'
        equal:
          - 'namespace'
          - 'alertname'
      - source_matchers:
          - 'severity = warning'
        target_matchers:
          - 'severity = info'
        equal:
          - 'namespace'
          - 'alertname'
      - source_matchers:
          - 'alertname = InfoInhibitor'
        target_matchers:
          - 'severity = info'
        equal:
          - 'namespace'
      - target_matchers:
          - 'alertname = InfoInhibitor'
    route:
      group_by: ['namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'null'
      routes:
        - receiver: 'null'
          matchers:
            - alertname = "Watchdog"
        - receiver: 'holmes'
          matchers:
            - severity = "critical"
          continue: true
    receivers:
      - name: 'null'
      - name: 'holmes'
        webhook_configs:
          - url: 'https://holmes.panicboat.net/alertmanager/webhook?channel=platform-alert-p1'
            http_config:
              authorization:
                credentials_file: /etc/alertmanager/secrets/holmes-alertmanager/ALERTMANAGER_SHARED_TOKEN
    templates:
      - '/etc/alertmanager/config/*.tmpl'
```

Note: this replaces the chart's implicit default `alertmanager.config` (previously unset, so the chart's own default applied — the `global`/`inhibit_rules`/`templates` values above are copied from that chart default so behavior is unchanged for everything except the new `holmes` route/receiver — verified via `helm show values prometheus-community/kube-prometheus-stack`). `continue: true` on the new route means the alert still falls through and gets evaluated by later sibling routes too (there are none here, but this keeps future additions safe — an alert matching `severity="critical"` triggers holmes AND is still available for group_by/inhibition against the top-level default).

- [ ] **Step 3: Hydrate and inspect the diff**

Run: `./scripts/kubernetes-hydrate/hydrate-component.sh prometheus-operator production && git diff kubernetes/manifests/production/prometheus-operator`
Expected: diff shows the Alertmanager config Secret's rendered content changed to include the new `route.routes` entry and `receivers` entry for `holmes`, and the Alertmanager StatefulSet gained a volume mount for the `holmes-alertmanager` secret. No unrelated resources change (confirm by scanning the full diff for anything other than Alertmanager-owned resources).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/prometheus-operator/production/values.yaml.gotmpl kubernetes/manifests/production/prometheus-operator
git commit -s -m "feat(prometheus-operator): route severity=critical alerts to holmes"
```

---

## Task 3: Open Draft PR

**Files:** none (git/GitHub operations only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/holmes-alertmanager-route
```

- [ ] **Step 2: Open a Draft PR**

```bash
gh pr create --draft --title "feat(prometheus-operator): route critical alerts to holmes" --body "$(cat <<'EOF'
## Summary
- Add an ExternalSecret in the monitoring namespace syncing the holmes Alertmanager shared token.
- Route severity=critical alerts to a new holmes webhook receiver, leaving all existing (default) routing untouched.

## Dependencies
- `system-components/holmes` (panicboat/monorepo) is already deployed and live at `https://holmes.panicboat.net`.
- The AWS Secrets Manager secret `panicboat/holmes/alertmanager` already has a `shared_token` value provisioned.

## Test plan
- [ ] `hydrate-component.sh prometheus-operator production` diff reviewed — only the intended resources changed
- [ ] After merge: fire a test critical alert (`amtool alert add ... severity=critical`) and confirm holmes receives the webhook and posts to #platform-alert-p1

Design: docs/superpowers/specs/2026-08-14-holmes-relay-design.md
EOF
)"
```

- [ ] **Step 3: Report the PR URL back to the user.**

---

## Self-Review Notes

- **Spec coverage**: `severity: critical` route-side filtering (Task 2), channel-via-query-param on the webhook URL (Task 2 Step 2, `?channel=platform-alert-p1`), shared Bearer token auth (Task 1 + Task 2's `credentials_file`) are all covered. The design's "channel routing lives entirely in Alertmanager config" principle is honored — `holmes` itself does not hardcode a channel.
- **Placeholder scan**: none remaining — `holmes.panicboat.net` and `#platform-alert-p1` are confirmed real values (holmes is live in production; channel confirmed 2026-08-16), not placeholders.
- **Naming**: this plan and its resources use `holmes`, matching the service's actual deployed name (renamed from `holmes-relay` during `panicboat/monorepo` PR #963, before this plan was executed).
