# Alertmanager-Owned Slack Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native Alertmanager Slack notification (Incoming Webhook, independent of holmes) for `severity: critical` alerts, embedding each alert's `fingerprint` in the message text so holmes can later find and thread its investigation under it.

**Architecture:** Extend the existing critical-alert receiver in `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` (currently named `holmes`, holding only a `webhook_configs` entry to holmes) with a `slack_configs` entry using the Incoming Webhook method (`api_url_file`, no `channel` field — Incoming Webhooks are channel-fixed at creation and reject channel overrides). The webhook URL comes from a **new, independent** AWS Secrets Manager secret (`panicboat/alertmanager/slack-notify`, property `webhook_url`) tied to a **dedicated Slack app** created solely for this notification — deliberately not sharing holmes's own Slack app or `panicboat/holmes/*` secret path, so that neither the notification channel nor its credentials are coupled to holmes's app registration or pod availability. Since the receiver now serves two independent concerns (Slack notification + holmes investigation trigger), it is renamed from `holmes` to `critical-alerts`.

**Tech Stack:** Helmfile (kube-prometheus-stack chart), Kustomize, External Secrets Operator, Alertmanager `slack_config`.

## Global Constraints

- Do not touch any other `alertmanager.config` routing — only the existing critical-alert route/receiver is modified (renamed + one integration added); the `Watchdog -> null` route and its ordering stay untouched.
- Incoming Webhooks are channel-fixed at creation and **reject a `channel` override in the payload** — the `slack_configs` entry must NOT set a `channel` field.
- `slack_configs.api_url` and `api_url_file` are mutually exclusive — use `api_url_file` (file-mounted secret), never `api_url` (would put the raw webhook URL in plaintext Helm values).
- The AWS secret `panicboat/alertmanager/slack-notify` (property `webhook_url`) must already exist with a real value before the ExternalSecret in this plan can sync successfully — creating the dedicated Slack app, enabling Incoming Webhooks, and provisioning the AWS secret are manual steps documented in `docs/superpowers/specs/2026-08-14-holmes-relay-design.md`'s "通知用 Slack app の手動セットアップ" section, out of this plan's scope (cannot be automated).
- Design doc: `docs/superpowers/specs/2026-08-14-holmes-relay-design.md`.

---

## Task 1: ExternalSecret for the Alertmanager notification webhook URL

**Files:**
- Create: `kubernetes/components/prometheus-operator/production/kustomization/alertmanager-slack-notify-external-secret.yaml`
- Modify: `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`

**Interfaces:**
- Produces: K8s Secret `alertmanager-slack-notify` in the `monitoring` namespace with key `SLACK_WEBHOOK_URL`, consumed by Task 2's `alertmanagerSpec.secrets` mount and `slack_configs.api_url_file`.

- [ ] **Step 1: Write the ExternalSecret**

`kubernetes/components/prometheus-operator/production/kustomization/alertmanager-slack-notify-external-secret.yaml`:

```yaml
# =============================================================================
# ExternalSecret: Alertmanager critical-alert Slack notification webhook
# =============================================================================
# Deliberately independent of panicboat/holmes/* — this Incoming Webhook
# belongs to its own dedicated Slack app, not holmes's, so neither the
# notification channel nor its credentials are coupled to holmes's app
# registration or pod availability.
# =============================================================================
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: alertmanager-slack-notify
  namespace: monitoring
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: alertmanager-slack-notify
    creationPolicy: Owner
  data:
    - secretKey: SLACK_WEBHOOK_URL
      remoteRef:
        key: panicboat/alertmanager/slack-notify
        property: webhook_url
```

- [ ] **Step 2: Register it in the kustomization**

Modify `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml` — add one line to `resources`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana-admin-external-secret.yaml
  - holmes-alertmanager-external-secret.yaml
  - alertmanager-slack-notify-external-secret.yaml
```

Update the file's header comment to mention the new resource, following the existing style (see the current comment block at the top of the file for the pattern — English, states what each overlay resource is for).

- [ ] **Step 3: Hydrate and inspect the diff**

Run: `./scripts/kubernetes-hydrate/hydrate-component.sh prometheus-operator production && git diff kubernetes/manifests/production/prometheus-operator`
Expected: diff shows exactly one new `ExternalSecret` resource named `alertmanager-slack-notify` in the `monitoring` namespace added to the rendered manifest. No other resources change.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/prometheus-operator/production/kustomization/alertmanager-slack-notify-external-secret.yaml kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml kubernetes/manifests/production/prometheus-operator
git commit -s -m "feat(prometheus-operator): sync Alertmanager Slack notification webhook"
```

---

## Task 2: Wire the Slack notification into the critical-alert receiver

**Files:**
- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl:230-306` (the `alertmanager:` block — exact line numbers may have shifted after Task 1's hydrate; locate by the `# Alertmanager Configuration` header comment)

**Interfaces:**
- Consumes: `alertmanager-slack-notify` Secret (Task 1), key `SLACK_WEBHOOK_URL`.

- [ ] **Step 1: Rename the receiver from `holmes` to `critical-alerts`**

In `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`, find:

```yaml
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
```

Replace both `'holmes'` occurrences with `'critical-alerts'`:

```yaml
      routes:
        - receiver: 'null'
          matchers:
            - alertname = "Watchdog"
        - receiver: 'critical-alerts'
          matchers:
            - severity = "critical"
          continue: true
    receivers:
      - name: 'null'
      - name: 'critical-alerts'
```

(The receiver now drives two independent side effects — a Slack notification and a holmes investigation trigger — so its name reflects what it matches, not just one consumer.)

- [ ] **Step 2: Mount the new secret alongside the existing one**

Find:

```yaml
    secrets:
      - holmes-alertmanager
```

Replace with:

```yaml
    secrets:
      - holmes-alertmanager
      - alertmanager-slack-notify
```

- [ ] **Step 3: Add the `slack_configs` entry to the renamed receiver**

Find the `critical-alerts` receiver block (after Step 1's rename):

```yaml
      - name: 'critical-alerts'
        webhook_configs:
          - url: 'https://holmes.panicboat.net/alertmanager/webhook?channel=platform-alert-p1'
            send_resolved: false
            http_config:
              authorization:
                credentials_file: /etc/alertmanager/secrets/holmes-alertmanager/ALERTMANAGER_SHARED_TOKEN
```

Replace with (adds `slack_configs` as a sibling to `webhook_configs` under the same receiver):

```yaml
      - name: 'critical-alerts'
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/alertmanager-slack-notify/SLACK_WEBHOOK_URL
            send_resolved: false
            title: 'Critical alert(s) firing'
            text: |-
              {{ range .Alerts }}*{{ .Labels.alertname }}* ({{ .Labels.namespace }})
              {{ .Annotations.summary }}
              fingerprint: `{{ .Fingerprint }}`
              {{ end }}
        webhook_configs:
          - url: 'https://holmes.panicboat.net/alertmanager/webhook?channel=platform-alert-p1'
            send_resolved: false
            http_config:
              authorization:
                credentials_file: /etc/alertmanager/secrets/holmes-alertmanager/ALERTMANAGER_SHARED_TOKEN
```

Do not add a `channel` field to `slack_configs` — the Incoming Webhook is already bound to a specific channel at creation time in Slack, and providing `channel` in the payload is rejected/ignored for this auth method.

Also update the `# Alertmanager Configuration` header comment (just above `alertmanager:`) to mention both the Slack notification and the holmes route, since it currently only describes the holmes webhook. Replace:

```yaml
# severity: critical alerts only are webhook-forwarded to holmes
# (panicboat/monorepo, system-components/holmes), which posts HolmesGPT's
# investigation result to Slack. The severity label is already applied by
# kube-prometheus-stack's default rules, so no new labeling work is needed
# (verified 2026-08-14: 3 of 6 firing alerts were critical). Alertmanager
# evaluates sibling routes top-to-bottom on first match, so the existing
# Watchdog->null route is kept ahead of the new one.
```

with:

```yaml
# severity: critical alerts fire two independent things: a native Slack
# notification (slack_configs, own Incoming Webhook/app — stays up even if
# holmes is down) and a webhook to holmes (panicboat/monorepo,
# system-components/holmes), which posts HolmesGPT's investigation result
# threaded under whichever Slack message holmes finds by fingerprint match
# (see design doc). The severity label is already applied by
# kube-prometheus-stack's default rules, so no new labeling work is needed
# (verified 2026-08-14: 3 of 6 firing alerts were critical). Alertmanager
# evaluates sibling routes top-to-bottom on first match, so the existing
# Watchdog->null route is kept ahead of the new one.
```

- [ ] **Step 4: Hydrate and inspect the diff**

Run: `./scripts/kubernetes-hydrate/hydrate-component.sh prometheus-operator production && git diff kubernetes/manifests/production/prometheus-operator`
Expected: the rendered Alertmanager config Secret's `alertmanager.yaml` gains a `slack_configs` entry (with `api_url_file`, `title`, `text` containing the `{{ range .Alerts }}...{{ end }}` template and no `channel` key) under the receiver now named `critical-alerts`, and the receiver's route matcher is unchanged (`severity = "critical"`). The Alertmanager CR's `spec.secrets` gains `alertmanager-slack-notify` alongside the existing `holmes-alertmanager`. No unrelated resources change.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/components/prometheus-operator/production/values.yaml.gotmpl kubernetes/manifests/production/prometheus-operator
git commit -s -m "feat(prometheus-operator): add Slack notification to critical-alerts receiver"
```

---

## Task 3: Open Draft PR

**Files:** none (git/GitHub operations only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/holmes-alertmanager-notification
```

- [ ] **Step 2: Open a Draft PR**

```bash
gh pr create --draft --title "feat(prometheus-operator): Alertmanager-owned Slack notification for critical alerts" --body "$(cat <<'EOF'
## Summary
- Add an ExternalSecret syncing a dedicated Slack app's Incoming Webhook URL for critical-alert notifications (`panicboat/alertmanager/slack-notify`, independent of holmes's own `panicboat/holmes/*` secrets and Slack app).
- Rename the critical-alert receiver from `holmes` to `critical-alerts` (it now drives two independent integrations) and add a `slack_configs` entry alongside the existing `webhook_configs` to holmes.
- Each alert's `fingerprint` is embedded in the notification text so holmes (separate change, panicboat/monorepo) can find this message and thread its investigation under it.

## Dependencies
- Requires the dedicated Slack app + Incoming Webhook to be manually created and `panicboat/alertmanager/slack-notify`'s `webhook_url` provisioned in AWS Secrets Manager before this ExternalSecret can sync (see design doc's "通知用 Slack app の手動セットアップ").
- holmes's own fingerprint-search/backoff/fallback/thread logic is a separate plan (panicboat/monorepo) — until that ships, holmes will still receive and investigate critical alerts via its existing `webhook_configs`, just without threading under this new notification.

## Test plan
- [ ] `hydrate-component.sh prometheus-operator production` diff reviewed — only the intended resources changed
- [ ] After merge and Slack app setup: fire a test critical alert (`amtool alert add ... severity=critical`) and confirm the notification lands in the target channel with a `fingerprint: ` line

Design: docs/superpowers/specs/2026-08-14-holmes-relay-design.md
EOF
)"
```

- [ ] **Step 3: Report the PR URL back to the user.**

---

## Self-Review Notes

- **Spec coverage**: Incoming Webhook method with `api_url_file` (design's "通知用 Slack app の手動セットアップ" + Secrets & Auth table), fingerprint embedded in the notification text (design's "検索キー" bullet), dedicated Slack app / independent secret path (design's "通知の責務分離" bullet) are all covered.
- **Placeholder scan**: none — every YAML block is the literal content to write, no TBD/fill-in-later markers.
- **Type/naming consistency**: the receiver rename (`holmes` -> `critical-alerts`) is applied consistently across both its `routes[].receiver` reference and its `receivers[].name` definition in Task 2 Step 1; Task 2 Steps 2-3 both reference the post-rename receiver. The Secret name/key (`alertmanager-slack-notify` / `SLACK_WEBHOOK_URL`) introduced in Task 1 matches exactly what Task 2 Steps 2-3 consume.
- **Scope boundary**: holmes's own Go changes (fingerprint field, `conversations.history` search, backoff, fallback post, threaded reply) are explicitly out of scope for this plan — separate plan, separate repo (panicboat/monorepo), noted in the Draft PR's Dependencies section so a reviewer isn't surprised threading doesn't work until that ships too.
