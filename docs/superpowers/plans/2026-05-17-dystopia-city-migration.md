# dystopia.city migration + ALB unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** application 公開 hostname を `develop.panicboat.net` → `dystopia.city` (apex) に切替、 同時に 2 ALB を 1 ALB に集約。 panicboat.net 系 monitoring UIs は keep。

**Architecture:** platform PR 1 個 (= terraform で ACM cert 発行 + kubernetes manifests 更新 + hydrate) + monorepo PR 1 個 (= HTTPRoute hostnames)。 terraform apply は worktree 内で実行し cert 発行 + validation 完了確認後 PR push。 Flux GitRepository + Kustomization reconcile (= ~5 min interval) で ALB 統合 + DNS migration 自動完了。

**Tech Stack:** Terraform / OpenTofu + Terragrunt (= AWS ACM + Route53)、 Kustomize + Helmfile (= kubernetes manifests)、 AWS LB Controller + ExternalDNS + cilium-gateway + Flux CD

**Spec:** `docs/superpowers/specs/2026-05-17-dystopia-city-migration-design.md`

---

## File Structure

### Platform (= 1 PR)

| File | Action | 責任 |
|---|---|---|
| `aws/route53/lookup/main.tf` | Modify | `dystopia.city` zone data source 追加 |
| `aws/route53/lookup/outputs.tf` | Modify | `outputs.zones.dystopia_city` 追加 |
| `aws/alb/modules/main.tf` | Modify | `dystopia.city` ACM cert resource + validation 追加 |
| `aws/alb/modules/outputs.tf` | Modify | 新 cert ARN output 追加 |
| `kubernetes/components/external-dns/production/values.yaml.gotmpl` | Modify | `domainFilters` に `dystopia.city` 追加 |
| `kubernetes/components/cilium/production/kustomization/application-ingress.yaml` | Modify | host を `dystopia.city` に、 ExternalDNS annotation 更新 |
| `kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml` | Modify | 4 Ingress の `group.name` を `monitoring-uis` → `application` に |
| `kubernetes/manifests/production/{cilium,oauth2-proxy,external-dns}/` | Hydrate | rendered manifests 同期 |
| `kubernetes/README.md` | Modify | domain branding 分離 (= 公開 / 非公開) section + dystopia.city reference |

### Monorepo (= 1 PR)

| File | Action | 責任 |
|---|---|---|
| `services/frontend/kubernetes/base/httproute.yaml` | Modify | `hostnames` を `dystopia.city` に |

---

## Task 1: platform worktree 準備

**Files:** N/A (setup only)

- [ ] **Step 1: platform main 同期 + worktree 作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git fetch origin --quiet
git worktree add -b feat/dystopia-city-migration .claude/worktrees/feat-dystopia-city-migration origin/main
cd .claude/worktrees/feat-dystopia-city-migration
git status
```

Expected: `On branch feat/dystopia-city-migration` + clean working tree

---

## Task 2: Route53 zone lookup 追加

**Files:**
- Modify: `aws/route53/lookup/main.tf`
- Modify: `aws/route53/lookup/outputs.tf`

- [ ] **Step 1: `aws/route53/lookup/main.tf` に dystopia.city zone data source 追加**

最終形:
```hcl
# main.tf - Lookup of Route53 hosted zones by domain name.
#
# Add new zones here as they're brought into scope. Consumers reference
# outputs.zones.<key>.

data "aws_route53_zone" "panicboat_net" {
  name         = "panicboat.net."
  private_zone = false
}

data "aws_route53_zone" "dystopia_city" {
  name         = "dystopia.city."
  private_zone = false
}
```

- [ ] **Step 2: `aws/route53/lookup/outputs.tf` の `zones` output に dystopia_city 追加**

最終形:
```hcl
# outputs.tf - Pass-through outputs of the underlying data sources.

output "zones" {
  description = "Route53 hosted zones grouped by domain key (pass-through of aws_route53_zone data sources)."
  value = {
    panicboat_net = {
      id   = data.aws_route53_zone.panicboat_net.zone_id
      arn  = data.aws_route53_zone.panicboat_net.arn
      name = data.aws_route53_zone.panicboat_net.name
    }
    dystopia_city = {
      id   = data.aws_route53_zone.dystopia_city.zone_id
      arn  = data.aws_route53_zone.dystopia_city.arn
      name = data.aws_route53_zone.dystopia_city.name
    }
  }
}
```

- [ ] **Step 3: terraform plan で route53/lookup stack の diff 確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
(cd aws/route53/envs/production && terragrunt plan -no-color 2>&1 | tail -20)
```

Expected: data source 1 個追加、 output 1 個 (zones map に dystopia_city entry 追加)、 no resource creation

- [ ] **Step 4: terraform apply で route53 lookup stack 反映**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
(cd aws/route53/envs/production && terragrunt apply -no-color -auto-approve 2>&1 | tail -10)
```

Expected: `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` (= data sources only、 state に new zone data 追加のみ)

---

## Task 3: ACM cert dystopia.city 追加 + 発行

**Files:**
- Modify: `aws/alb/modules/main.tf`
- Modify: `aws/alb/modules/outputs.tf`

- [ ] **Step 1: `aws/alb/modules/main.tf` に dystopia.city cert + validation 追加**

既存 panicboat_net resource 群の **末尾** に追加 (= 全体 file 構造を維持):

```hcl
# main.tf - ACM wildcard certificate for *.panicboat.net.

resource "aws_acm_certificate" "wildcard_panicboat_net" {
  domain_name               = "*.panicboat.net"
  subject_alternative_names = ["panicboat.net"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.common_tags
}

# DNS validation records in the panicboat.net hosted zone.
resource "aws_route53_record" "wildcard_panicboat_net_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard_panicboat_net.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = module.route53.zones.panicboat_net.id
}

resource "aws_acm_certificate_validation" "wildcard_panicboat_net" {
  certificate_arn         = aws_acm_certificate.wildcard_panicboat_net.arn
  validation_record_fqdns = [for record in aws_route53_record.wildcard_panicboat_net_validation : record.fqdn]
}

# ACM wildcard certificate for *.dystopia.city (= 公開 application domain)。

resource "aws_acm_certificate" "wildcard_dystopia_city" {
  domain_name               = "*.dystopia.city"
  subject_alternative_names = ["dystopia.city"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.common_tags
}

# DNS validation records in the dystopia.city hosted zone.
resource "aws_route53_record" "wildcard_dystopia_city_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard_dystopia_city.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = module.route53.zones.dystopia_city.id
}

resource "aws_acm_certificate_validation" "wildcard_dystopia_city" {
  certificate_arn         = aws_acm_certificate.wildcard_dystopia_city.arn
  validation_record_fqdns = [for record in aws_route53_record.wildcard_dystopia_city_validation : record.fqdn]
}
```

- [ ] **Step 2: `aws/alb/modules/outputs.tf` に新 cert ARN output 追加**

最終形:
```hcl
# outputs.tf - Outputs for the alb module.

output "wildcard_panicboat_net_cert_arn" {
  description = "ARN of the validated *.panicboat.net wildcard ACM certificate"
  value       = aws_acm_certificate_validation.wildcard_panicboat_net.certificate_arn
}

output "wildcard_dystopia_city_cert_arn" {
  description = "ARN of the validated *.dystopia.city wildcard ACM certificate"
  value       = aws_acm_certificate_validation.wildcard_dystopia_city.certificate_arn
}
```

- [ ] **Step 3: terraform plan で alb stack の diff 確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
(cd aws/alb/envs/production && terragrunt plan -no-color -out=/tmp/alb-dystopia.tfplan 2>&1 | tail -30)
```

Expected:
- `+ aws_acm_certificate.wildcard_dystopia_city`
- `+ aws_route53_record.wildcard_dystopia_city_validation["dystopia.city"]` (= 1 record)
- `+ aws_acm_certificate_validation.wildcard_dystopia_city`
- 新 output 1 個
- `Plan: 3 to add, 0 to change, 0 to destroy.`

- [ ] **Step 4: terraform apply で ACM cert 発行 (= 数分 validation 待ち)**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
(cd aws/alb/envs/production && terragrunt apply -no-color /tmp/alb-dystopia.tfplan 2>&1 | tail -10)
```

Expected: `Apply complete! Resources: 3 added, 0 changed, 0 destroyed.` (= cert + validation + cert validation)、 約 1-3 min で完了。

- [ ] **Step 5: cert ISSUED + ALB Controller pick up を verify**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws acm list-certificates --region ap-northeast-1 --query 'CertificateSummaryList[?DomainName==`*.dystopia.city`].{Domain:DomainName,Status:Status,ARN:CertificateArn}' --output table
```

Expected: `*.dystopia.city` Status=`ISSUED`

---

## Task 4: ExternalDNS domainFilters 更新

**Files:**
- Modify: `kubernetes/components/external-dns/production/values.yaml.gotmpl`

- [ ] **Step 1: domainFilters に dystopia.city を追加**

該当 section (= `domainFilters:` block) を以下に置換:

```yaml
# Restrict ExternalDNS to manage records in panicboat.net + dystopia.city zones
# only. panicboat.net: 非公開 monitoring UIs / 個人利用 hosts。 dystopia.city: 公開
# application apex。
domainFilters:
  - panicboat.net
  - dystopia.city
```

- [ ] **Step 2: diff 確認**

```bash
git diff kubernetes/components/external-dns/production/values.yaml.gotmpl
```

Expected: `+  - dystopia.city` + comment update

---

## Task 5: application Ingress を dystopia.city に切替

**Files:**
- Modify: `kubernetes/components/cilium/production/kustomization/application-ingress.yaml`

- [ ] **Step 1: ExternalDNS annotation + rules host を dystopia.city に**

該当 file の以下 2 箇所修正:

```yaml
metadata:
  annotations:
    # ...
    external-dns.alpha.kubernetes.io/hostname: dystopia.city  # 旧: develop.panicboat.net
spec:
  rules:
    - host: dystopia.city  # 旧: develop.panicboat.net
      http:
        paths:
          # ... (= 既存 paths keep)
```

その他 ALB annotation (= scheme / listen-ports / group.name=application / target-type / healthcheck / ssl-policy / ssl-redirect) は **既存 keep**。

- [ ] **Step 2: diff 確認**

```bash
git diff kubernetes/components/cilium/production/kustomization/application-ingress.yaml
```

Expected: 2 行修正 (= external-dns annotation + rules host)、 group.name 等は変更なし

---

## Task 6: monitoring-uis Ingress を application IngressGroup に統合

**Files:**
- Modify: `kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml`

- [ ] **Step 1: 4 Ingress の `alb.ingress.kubernetes.io/group.name` を変更**

各 Ingress (= grafana / prometheus / alertmanager / hubble) の annotation:

```yaml
metadata:
  annotations:
    # ...
    alb.ingress.kubernetes.io/group.name: application  # 旧: monitoring-uis
    # ... (= 他 annotation keep)
```

各 host (= `grafana.panicboat.net` 等) と他 setting は **既存 keep**。

- [ ] **Step 2: diff 確認**

```bash
git diff kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml
```

Expected: 4 箇所修正 (= 4 Ingress 各 group.name = application)

---

## Task 7: README update

**Files:**
- Modify: `kubernetes/README.md`

- [ ] **Step 1: 既存 develop.panicboat.net 言及 + branding 整理**

`kubernetes/README.md` 内の以下 update (= 該当箇所 grep で確認):
- ALB IngressGroup 表記 (= 単一 ALB 構成に変更)
- application 公開 hostname (= develop.panicboat.net → dystopia.city)
- monitoring UIs hosts は keep (= grafana / prometheus / alertmanager / hubble.panicboat.net)
- branding 分離 (= 公開 dystopia.city vs 非公開 panicboat.net) section 追加

editor で適切 update。 内容例 (= 該当部分のみ):
```markdown
## Domain branding

- **dystopia.city**: 公開 application (= apex、 認証 not、 全 user access)
- **panicboat.net**: 非公開 / 個人利用 (= oauth2-proxy + GitHub OAuth で panicboat member のみ、 monitoring UIs hosting)
```

- [ ] **Step 2: diff 確認**

```bash
git diff kubernetes/README.md
```

Expected: develop.panicboat.net → dystopia.city + branding section 追記

---

## Task 8: hydrate manifests

**Files:**
- Hydrate: `kubernetes/manifests/production/{cilium,oauth2-proxy,external-dns}/manifest.yaml`

- [ ] **Step 1: 3 component hydrate**

```bash
bash scripts/kubernetes-hydrate/hydrate-component.sh cilium production
bash scripts/kubernetes-hydrate/hydrate-component.sh oauth2-proxy production
bash scripts/kubernetes-hydrate/hydrate-component.sh external-dns production
```

Expected: 各 component で `kubernetes/manifests/production/<component>/manifest.yaml` が再生成。

- [ ] **Step 2: hydrate diff 確認**

```bash
git diff kubernetes/manifests/production/cilium/manifest.yaml | grep -E "^[+-].*dystopia|^[+-].*panicboat" | head -10
git diff kubernetes/manifests/production/oauth2-proxy/manifest.yaml | grep -E "group.name|application|monitoring-uis" | head -10
git diff kubernetes/manifests/production/external-dns/manifest.yaml | grep -E "domainFilters|dystopia|panicboat" | head -10
```

Expected:
- cilium manifest: application Ingress host `dystopia.city`
- oauth2-proxy manifest: 4 Ingress の group.name = `application`
- external-dns manifest: domain-filter args に `dystopia.city` 追加

---

## Task 9: platform PR commit + push + draft

**Files:** N/A

- [ ] **Step 1: 全 changes stage**

```bash
git add aws/route53/lookup/ aws/alb/modules/ kubernetes/components/ kubernetes/manifests/ kubernetes/README.md
git status
```

Expected: 8-10 file changed (= terraform 4 + kubernetes 3 component values + 3 component manifests + README)

- [ ] **Step 2: commit (= panicboat workflow: -s + Co-Authored-By なし)**

```bash
git commit -s -m "$(cat <<'EOF'
feat: migrate application to dystopia.city + unify ALB IngressGroup

application 公開 hostname を develop.panicboat.net → dystopia.city (apex) に
切替、 同時に既存 2 ALB (= application + monitoring-uis) を 1 ALB に集約。
panicboat.net 系 monitoring UIs (= grafana / prometheus / alertmanager /
hubble) は subdomain で keep し branding 分離 (= 公開 dystopia.city + 非公開
panicboat.net)。

引き継ぎ事項 #33 の dystopia.city 公開部分。 ACM cert は事前 terraform
apply で発行済 (= worktree で実 cert ISSUED 確認)、 Flux reconcile + ALB
Controller auto-discovery で host / cert 反映、 旧 monitoring-uis ALB 自動
delete。

spec: docs/superpowers/specs/2026-05-17-dystopia-city-migration-design.md
plan: docs/superpowers/plans/2026-05-17-dystopia-city-migration.md
EOF
)"
```

- [ ] **Step 3: push (= 初回なので -u origin HEAD)**

```bash
git push -u origin HEAD
```

- [ ] **Step 4: draft PR 作成**

```bash
gh pr create --draft --title "feat: migrate application to dystopia.city + unify ALB IngressGroup" --body "$(cat <<'PR_BODY_EOF'
## Summary

application 公開 hostname を **\`develop.panicboat.net\` → \`dystopia.city\` (apex)** に切替、 同時に既存 2 ALB (= \`application\` + \`monitoring-uis\`) を **1 ALB に集約**。 panicboat.net 系 monitoring UIs は subdomain で keep (= 非公開 / 個人利用)、 branding 分離。 cost ~$16/month 削減。

引き継ぎ事項 #33 の dystopia.city 公開部分。

## Pre-PR operations (= 完了済)

- terraform apply で \`aws_acm_certificate.wildcard_dystopia_city\` 発行 + validation 完了 (= cert ISSUED 確認)
- AWS LB Controller の cert auto-discovery で同 ALB に 2 cert attach 可能な前提

## Test plan

- [ ] PR merge 後 Flux reconcile で ALB IngressGroup 統合 + dystopia.city host rule 追加
- [ ] 旧 ALB \`k8s-monitoringuis-1577bc5126\` 自動削除
- [ ] ExternalDNS で dystopia.city zone に A record 自動作成
- [ ] connecting monorepo PR (= HTTPRoute hostnames) merge 後 \`curl https://dystopia.city/\` → 200
- [ ] \`curl https://grafana.panicboat.net/\` → 200 (= 同 ALB 経由維持)

## Spec / Plan

- spec: https://github.com/panicboat/platform/blob/main/docs/superpowers/specs/2026-05-17-dystopia-city-migration-design.md (= PR #430 merged)
- plan: docs/superpowers/plans/2026-05-17-dystopia-city-migration.md (= 並行 PR)
PR_BODY_EOF
)"
```

Return PR URL.

---

## Task 10: monorepo worktree + HTTPRoute 修正

**Files:**
- Modify: `monorepo/services/frontend/kubernetes/base/httproute.yaml`

- [ ] **Step 1: monorepo worktree 作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git fetch origin --quiet
git worktree add -b chore/frontend-dystopia-city .claude/worktrees/chore-frontend-dystopia-city origin/main
cd .claude/worktrees/chore-frontend-dystopia-city
```

- [ ] **Step 2: HTTPRoute hostnames 修正**

`services/frontend/kubernetes/base/httproute.yaml` の `hostnames:` を以下に置換:

```yaml
spec:
  parentRefs:
    - name: cilium-gateway
      namespace: default
  hostnames:
    - dystopia.city  # 旧: develop.panicboat.net
```

その他 (= apiVersion / kind / metadata / rules) は **既存 keep**。

- [ ] **Step 3: kustomize build verify**

```bash
kustomize build services/frontend/kubernetes/overlays/production 2>&1 | grep -B 2 -A 5 "kind: HTTPRoute"
```

Expected: `hostnames` に `dystopia.city` 1 個

---

## Task 11: monorepo commit + push + draft PR

**Files:** N/A

- [ ] **Step 1: commit + push + draft PR**

```bash
git add services/frontend/kubernetes/base/httproute.yaml
git commit -s -m "chore(frontend): switch HTTPRoute hostname to dystopia.city

引き継ぎ事項 #33 の dystopia.city 公開部分。 frontend HTTPRoute hostname
を develop.panicboat.net → dystopia.city (apex) に切替。 platform PR
(= ALB IngressGroup 統合 + ACM cert + ExternalDNS) と連続 merge で cutover。

spec: https://github.com/panicboat/platform/blob/main/docs/superpowers/specs/2026-05-17-dystopia-city-migration-design.md"
git push -u origin HEAD
gh pr create --draft --title "chore(frontend): switch HTTPRoute hostname to dystopia.city" --body "$(cat <<'PR_BODY_EOF'
## Summary

frontend HTTPRoute hostname を \`develop.panicboat.net\` → \`dystopia.city\` (apex) に切替。 引き継ぎ事項 #33 の dystopia.city 公開部分。

## Related

- platform PR (= ALB IngressGroup 統合 + ACM cert + ExternalDNS): https://github.com/panicboat/platform/pull/XXX
- spec: https://github.com/panicboat/platform/blob/main/docs/superpowers/specs/2026-05-17-dystopia-city-migration-design.md

## Merge order

1. platform PR merge
2. 本 PR merge
3. Flux reconcile で HTTPRoute 反映、 dystopia.city 経由 application 動作開始
PR_BODY_EOF
)"
```

Return PR URL.

---

## Task 12: post-merge verification (= user merge 後)

**Files:** N/A (cluster verification)

- [ ] **Step 1: Flux Kustomization reconcile state 確認**

```bash
eks-login >/dev/null 2>&1
kubectl get kustomization -n flux-system flux-system frontend monolith monorepo-cluster
```

Expected: 全 READY=True、 main 最新 sha applied

- [ ] **Step 2: ALB 統合 confirm**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws elbv2 describe-load-balancers --region ap-northeast-1 --query 'LoadBalancers[?starts_with(LoadBalancerName, `k8s-`)].{Name:LoadBalancerName,State:State.Code}' --output table
```

Expected: ALB 1 個のみ (= 旧 monitoring-uis 削除済、 application のみ残存)

- [ ] **Step 3: 2 cert attach 確認**

```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --region ap-northeast-1 --query 'LoadBalancers[?starts_with(LoadBalancerName, `k8s-application`)].LoadBalancerArn' --output text)
LISTENER_ARN=$(aws elbv2 describe-listeners --region ap-northeast-1 --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`443`].ListenerArn' --output text)
aws elbv2 describe-listener-certificates --region ap-northeast-1 --listener-arn "$LISTENER_ARN" --query 'Certificates[].CertificateArn' --output table
```

Expected: 2 cert ARN (= `*.panicboat.net` + `*.dystopia.city`)

- [ ] **Step 4: ExternalDNS log で dystopia.city zone reconcile 確認**

```bash
eks-login >/dev/null 2>&1
kubectl logs -n external-dns deploy/external-dns --tail=200 --since=10m 2>&1 | grep -iE "dystopia|create record" | head -10
```

Expected: dystopia.city zone への record 作成 log

- [ ] **Step 5: DNS resolve 確認**

```bash
dig dystopia.city +short
dig grafana.panicboat.net +short
```

Expected: 両方 ALB DNS (= 同 ALB に point) を返す

- [ ] **Step 6: HTTP/TLS 動作確認**

```bash
curl -sk -o /dev/null -w "dystopia.city: HTTP %{http_code} cert: %{ssl_verify_result}\n" --max-time 6 https://dystopia.city/
curl -sk -o /dev/null -w "grafana.panicboat.net: HTTP %{http_code}\n" --max-time 6 https://grafana.panicboat.net/
```

Expected:
- `dystopia.city`: HTTP 200 (= frontend Pod に到達)
- `grafana.panicboat.net`: HTTP 302/200 (= oauth2-proxy 経由 GitHub OAuth、 認証 redirect or auth 済の場合 200)

- [ ] **Step 7: 旧 develop.panicboat.net record 削除確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws route53 list-resource-record-sets --hosted-zone-id Z07598371GKBU0WMF89MD --query "ResourceRecordSets[?Name=='develop.panicboat.net.'].Name" --output text
```

Expected: 空 (= ExternalDNS が削除済)。 もし残存なら 5 min 後再確認 + manual cleanup 検討

---

## Task 13: worktree cleanup (= optional)

**Files:** N/A

- [ ] **Step 1: platform worktree remove**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-dystopia-city-migration
git branch -D feat/dystopia-city-migration
```

- [ ] **Step 2: monorepo worktree remove**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git worktree remove .claude/worktrees/chore-frontend-dystopia-city
git branch -D chore/frontend-dystopia-city
```

---

## Plan summary

| Task | scope | impact |
|---|---|---|
| 1. platform worktree | setup | 0 |
| 2. Route53 zone lookup 追加 + terragrunt apply | terraform | 0 resource (= data source only) |
| 3. ACM cert 発行 + terragrunt apply | terraform | 3 resource add (= cert + validation record + cert validation)、 ~1-3 min |
| 4. ExternalDNS domainFilters update | kubernetes manifest | 0 (= PR merge 後 reconcile) |
| 5. application Ingress host 切替 | kubernetes manifest | 0 (= PR merge 後 reconcile) |
| 6. monitoring-uis IngressGroup 統合 | kubernetes manifest | 0 (= PR merge 後 reconcile) |
| 7. README update | doc | 0 |
| 8. hydrate manifests | rendered | 0 |
| 9. platform PR commit / push / draft | git | 0 |
| 10-11. monorepo worktree + HTTPRoute + PR | git | 0 |
| 12. post-merge verification | cluster | user merge 後 反映確認 |
| 13. cleanup | git | 0 |

**Total**: 13 task、 platform 1 PR + monorepo 1 PR + post-merge verify。

**Merge order**: platform PR → monorepo PR 連続 merge。 transient downtime ~5-10 min 許容 (= user 認可済)。

## Out of scope (= 別 phase / 引き継ぎ)

- panicboat.net domain 自体の廃止 (= 当面 keep)
- staging / production multi-env 化 + release-please 統合 (= 引き継ぎ #33 の別部分、 別 brainstorm)
- application 側の認証導入 (= 公開 application で認証必要時 別 brainstorm)
- ALB scheme=internal 化 (= 緩い解釈 keep internet-facing)
