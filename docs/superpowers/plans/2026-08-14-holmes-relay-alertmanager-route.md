# holmes-relay Alertmanager Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route `severity: critical` alerts from the existing Alertmanager to the `holmes-relay` service (built separately in `panicboat/monorepo`, see `services/holmes-relay/`), authenticated with a shared bearer token, without touching any other existing routing.

**Architecture:** Extend `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`'s `alertmanager.config` (currently entirely default — everything routes to the `null` receiver) with one additional route matching `severity="critical"` and a `holmes-relay` webhook receiver. The receiver's bearer token comes from a file mounted via `alertmanagerSpec.secrets`, synced from AWS Secrets Manager by a new ExternalSecret in the `monitoring` namespace — the same underlying secret (`panicboat/holmes-relay/alertmanager`) that `services/holmes-relay`'s own ExternalSecret (in monorepo) already syncs for the relay's own token verification.

**Tech Stack:** Helmfile (kube-prometheus-stack chart), Kustomize, External Secrets Operator.

## Global Constraints

- Do not touch any other `alertmanager.config` routing — this repo currently has zero configured receivers other than the chart's default `null` receiver (per the existing `# NOTE: receiver 設定 ... は未設定` comment); this plan is additive only.
- The `holmes-relay` endpoint URL and Slack channel are **not know until `services/holmes-relay` is deployed** (separate plan: `panicboat/monorepo`'s `docs/superpowers/plans/2026-08-14-holmes-relay-service.md`). This plan uses a placeholder-free but explicitly-flagged value that must be confirmed against the real deployed hostname before merging — see Task 2 Step 1.
- Design doc: `docs/superpowers/specs/2026-08-14-holmes-relay-design.md`.

---

## Task 1: ExternalSecret for the Alertmanager shared token

**Files:**
- Create: `kubernetes/components/prometheus-operator/production/kustomization/holmes-relay-alertmanager-external-secret.yaml`
- Modify: `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`

**Interfaces:**
- Produces: K8s Secret `holmes-relay-alertmanager` in the `monitoring` namespace with key `ALERTMANAGER_SHARED_TOKEN`, consumed by Task 2's `alertmanagerSpec.secrets` mount.

- [ ] **Step 1: Write the ExternalSecret**

`kubernetes/components/prometheus-operator/production/kustomization/holmes-relay-alertmanager-external-secret.yaml`:

```yaml
# =============================================================================
# ExternalSecret: holmes-relay shared token (Alertmanager side)
# =============================================================================
# AWS Secrets Manager の panicboat/holmes-relay/alertmanager (property:
# shared_token) を K8s Secret holmes-relay-alertmanager に sync。
# alertmanagerSpec.secrets 経由で Alertmanager pod にファイルとしてマウントされ、
# webhook_configs の http_config.authorization.credentials_file から参照される。
#
# 同じ AWS Secrets Manager path を、holmes-relay 自身(panicboat/monorepo,
# services/holmes-relay)側の ExternalSecret も別途 sync している(受信側の
# トークン検証用)。値の作成元は1箇所(このシークレット)、sync 先は2箇所という
# 構成。
# =============================================================================
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: holmes-relay-alertmanager
  namespace: monitoring
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: holmes-relay-alertmanager
    creationPolicy: Owner
  data:
    - secretKey: ALERTMANAGER_SHARED_TOKEN
      remoteRef:
        key: panicboat/holmes-relay/alertmanager
        property: shared_token
```

- [ ] **Step 2: Register it in the kustomization**

Modify `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# prometheus-operator production kustomization
# =============================================================================
# chart 範囲外 resource (= Grafana admin ExternalSecret, holmes-relay 用
# Alertmanager token ExternalSecret) を helmfile output に上乗せする overlay。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana-admin-external-secret.yaml
  - holmes-relay-alertmanager-external-secret.yaml
```

- [ ] **Step 3: Hydrate and inspect the diff**

Run: `./scripts/kubernetes-hydrate/hydrate-component.sh prometheus-operator production && git diff kubernetes/manifests/production/prometheus-operator`
Expected: diff shows exactly one new `ExternalSecret` resource named `holmes-relay-alertmanager` in the `monitoring` namespace added to the rendered manifest. No other resources change.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/prometheus-operator/production/kustomization/holmes-relay-alertmanager-external-secret.yaml kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml kubernetes/manifests/production/prometheus-operator
git commit -s -m "feat(prometheus-operator): sync holmes-relay Alertmanager token"
```

---

## Task 2: Alertmanager route and receiver

**Files:**
- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl:221-242`

**Interfaces:**
- Consumes: `holmes-relay-alertmanager` Secret (Task 1), the deployed `holmes-relay` service's public hostname and the Slack channel it should post to (both owned by the `panicboat/monorepo` `services/holmes-relay` plan — confirm the real values before Step 1 below).

- [ ] **Step 1: Confirm the real holmes-relay URL and target Slack channel**

Before editing, verify against the actually-deployed `panicboat/monorepo` `services/holmes-relay`:
- The HTTPRoute hostname (design/plan default: `holmes-relay.dystopia.city` — confirm the DNS record actually resolves and TLS is issued via `kubectl -n default get httproute holmes-relay` and `kubectl -n default get certificate`).
- The Slack channel name to post critical-alert investigations to (per the design spec: "既存の運用・incident チャンネルを使う" — get the exact channel name from whoever owns that channel before writing the URL below).

Substitute both into Step 2 in place of `<holmes-relay-host>` and `<slack-channel>`.

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
# severity: critical のアラートのみ holmes-relay (panicboat/monorepo,
# services/holmes-relay) に webhook 転送し、HolmesGPT の調査結果を Slack に
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
    # holmes-relay の Alertmanager shared token を file mount (Task 1 の
    # ExternalSecret が作る Secret)。alertmanagerSpec.secrets は Alertmanager
    # と同一 namespace の Secret のみ参照可能なため、monitoring namespace 側に
    # 専用の ExternalSecret を用意している (services/holmes-relay 側の
    # ExternalSecret とは sync 先が別、値の出どころは同じ)。
    secrets:
      - holmes-relay-alertmanager
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
        - receiver: 'holmes-relay'
          matchers:
            - severity = "critical"
          continue: true
    receivers:
      - name: 'null'
      - name: 'holmes-relay'
        webhook_configs:
          - url: 'https://<holmes-relay-host>/alertmanager/webhook?channel=<slack-channel>'
            http_config:
              authorization:
                credentials_file: /etc/alertmanager/secrets/holmes-relay-alertmanager/ALERTMANAGER_SHARED_TOKEN
    templates:
      - '/etc/alertmanager/config/*.tmpl'
```

Note: this replaces the chart's implicit default `alertmanager.config` (previously unset, so the chart's own default applied — the `global`/`inhibit_rules`/`templates` values above are copied from that chart default so behavior is unchanged for everything except the new `holmes-relay` route/receiver — verified via `helm show values prometheus-community/kube-prometheus-stack`). `continue: true` on the new route means the alert still falls through and gets evaluated by later sibling routes too (there are none here, but this keeps future additions safe — an alert matching `severity="critical"` triggers holmes-relay AND is still available for group_by/inhibition against the top-level default).

- [ ] **Step 3: Hydrate and inspect the diff**

Run: `./scripts/kubernetes-hydrate/hydrate-component.sh prometheus-operator production && git diff kubernetes/manifests/production/prometheus-operator`
Expected: diff shows the Alertmanager config Secret's rendered content changed to include the new `route.routes` entry and `receivers` entry for `holmes-relay`, and the Alertmanager StatefulSet gained a volume mount for the `holmes-relay-alertmanager` secret. No unrelated resources change (confirm by scanning the full diff for anything other than Alertmanager-owned resources).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/prometheus-operator/production/values.yaml.gotmpl kubernetes/manifests/production/prometheus-operator
git commit -s -m "feat(prometheus-operator): route severity=critical alerts to holmes-relay"
```

---

## Task 3: Open Draft PR

**Files:** none (git/GitHub operations only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/holmes-relay-design
```

(Branch already exists and is tracked — this pushes the commits from Task 1 and Task 2, plus the earlier spec commits, in one PR.)

- [ ] **Step 2: Open a Draft PR**

```bash
gh pr create --draft --title "feat(prometheus-operator): route critical alerts to holmes-relay" --body "$(cat <<'EOF'
## Summary
- Add an ExternalSecret in the monitoring namespace syncing the holmes-relay Alertmanager shared token.
- Route severity=critical alerts to a new holmes-relay webhook receiver, leaving all existing (default) routing untouched.

## Dependencies
- Requires services/holmes-relay (panicboat/monorepo) to be deployed first for the webhook URL to have anywhere to send to; the ExternalSecret and route can merge independently but won't have effect until then.
- Requires the AWS Secrets Manager secret panicboat/holmes-relay/alertmanager to have a shared_token value provisioned (see the monorepo plan's Task 8).

## Test plan
- [ ] `hydrate-component.sh prometheus-operator production` diff reviewed — only the intended resources changed
- [ ] After merge and holmes-relay deployment: fire a test critical alert (`amtool alert add ... severity=critical`) and confirm holmes-relay receives the webhook and posts to Slack

Design: docs/superpowers/specs/2026-08-14-holmes-relay-design.md
EOF
)"
```

- [ ] **Step 3: Report the PR URL back to the user.**

---

## Self-Review Notes

- **Spec coverage**: `severity: critical` route-side filtering (Task 2), channel-via-query-param on the webhook URL (Task 2 Step 2, `?channel=<slack-channel>`), shared Bearer token auth (Task 1 + Task 2's `credentials_file`) are all covered. The design's "channel routing lives entirely in Alertmanager config" principle is honored — `holmes-relay` itself does not hardcode a channel.
- **Placeholder scan**: `<holmes-relay-host>` and `<slack-channel>` in Task 2 are intentionally-flagged fill-ins, not plan placeholders — Task 2 Step 1 makes verifying and substituting the real values an explicit, required step before editing, because those values are owned by the separate monorepo plan and are not yet known at plan-writing time.
- **Cross-repo dependency**: this plan has no code dependency on `services/holmes-relay` existing yet (it can be merged independently), but the receiver has no effect until the service is deployed and its real hostname/channel substituted. Noted in the Draft PR body.
