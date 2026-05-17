# dystopia.city migration + ALB unification (= 引き継ぎ事項 #33 部分)

> **Goal**: application を `develop.panicboat.net` → `dystopia.city` (apex) に切替、 同時に既存 2 ALB (= `application` + `monitoring-uis`) を 1 ALB に集約。 panicboat.net 系 monitoring UIs (= grafana / prometheus / alertmanager / hubble) は subdomain で keep、 cost ~$16/month 削減 + branding 分離 (= 公開 `dystopia.city` + 非公開 `panicboat.net`)。

---

## 1. 経緯 + 現状

### Phase 7-0 closure 時点

panicboat の application 公開 hostname は `develop.panicboat.net` で 1 ALB (= `k8s-application-92fded7941`)、 monitoring UIs は別 ALB (= `k8s-monitoringuis-1577bc5126`) で 4 host (= grafana / prometheus / alertmanager / hubble).panicboat.net 公開、 oauth2-proxy + GitHub OAuth で SSO 認証 (= cookie_domains `.panicboat.net`)。 ALB Controller の cert auto-discovery で `*.panicboat.net` ACM cert を両 ALB に attach。

### dystopia.city 準備状況

- Route53 zone `dystopia.city.` 既存 (= AWS Route53 console / 事前手動作成、 records 未投入)
- Domain registration `dystopia.city` 取得済 (= expiry 2027-04-29)
- ACM cert `*.dystopia.city` **未発行**
- monorepo frontend UI branding (= `services/frontend/workspace/src/app/layout.tsx` title + `GuestTopNavBar.tsx` 表示) は既に `dystopia.city`

### Branding 分離方針 (= 本 PR で確立)

| domain | 用途 | 認証 | scope |
|---|---|---|---|
| **dystopia.city** | 公開 application | 認証 not (= application 内部 auth に委譲) | 不特定多数 user |
| **panicboat.net** | 非公開 / 個人利用 monitoring + 運用 UI | oauth2-proxy + GitHub OAuth (= panicboat member のみ) | panicboat 開発者 |

「非公開」 は緩い解釈 (= internet 経由 + oauth2-proxy 認証で保護)、 strict internal-only (= scheme=internal + VPN) は採用せず。

---

## 2. Architecture (= 最終形)

```
                         ┌─────────────────────┐
                         │ user (= public)     │
                         └──────────┬──────────┘
                                    │ HTTPS 443
              ┌─────────────────────┴────────────────────┐
              │                                          │
              ▼                                          ▼
   ┌──────────────────────┐                  ┌──────────────────────┐
   │ Route53              │                  │ Route53              │
   │ panicboat.net zone   │                  │ dystopia.city zone   │
   │ (非公開系 records)   │                  │ (公開系 records)     │
   │ • grafana            │                  │ • apex (dystopia.city)│
   │ • prometheus         │                  └──────────┬───────────┘
   │ • alertmanager       │                             │
   │ • hubble             │                             │
   └──────────┬───────────┘                             │
              │ ALIAS                                   │ ALIAS
              └────────────────┬────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────────┐
                  │ ALB (= 1 個に集約)      │
                  │ IngressGroup: application│
                  │ 2 cert attached:         │
                  │  - *.panicboat.net + apex│
                  │  - *.dystopia.city + apex│
                  │ (ACM auto-discovery)     │
                  └──────────┬───────────────┘
                             │
              ┌──────────────┼──────────────────────────┐
              │ host header                             │
              │                                         │
              ▼ dystopia.city                           ▼ *.panicboat.net
   ┌─────────────────────┐               ┌─────────────────────────┐
   │ application-gateway │               │ oauth2-proxy Service    │
   │ Service (= cilium-  │               │ (= 4 monitoring UIs)    │
   │  envoy hostNetwork) │               └──────────┬──────────────┘
   └──────────┬──────────┘                          │
              │ Cilium Gateway                       ▼
              ▼ HTTPRoute (hostnames: dystopia.city) Grafana / Prometheus /
   ┌─────────────────────┐                         Alertmanager / Hubble UI
   │ frontend Pod        │
   │ (Next.js)           │
   └─────────────────────┘
```

ALB を 1 個に集約することで cost ~$16/month 削減、 panicboat.net cert と dystopia.city cert 2 個を同 ALB に attach、 host header で routing 振り分け。

---

## 3. Files changed

### Platform (= terraform + kubernetes)

**aws/alb/modules/main.tf** に dystopia.city cert + validation resource 追加:
```hcl
resource "aws_acm_certificate" "wildcard_dystopia_city" {
  domain_name               = "*.dystopia.city"
  subject_alternative_names = ["dystopia.city"]
  validation_method         = "DNS"
}
resource "aws_acm_certificate_validation" "wildcard_dystopia_city" { ... }
```

**aws/route53/lookup/main.tf** に dystopia.city zone data source 追加 (= comment "Add new zones here" の通り、 cert validation 用)

**aws/alb/modules/outputs.tf** に新 cert ARN output 追加 (= 既存 panicboat.net cert ARN output と同形)

**kubernetes/components/external-dns/production/values.yaml.gotmpl**:
```yaml
domainFilters:
  - panicboat.net
  - dystopia.city  # 追加
```

**kubernetes/components/cilium/production/kustomization/application-ingress.yaml**:
- `external-dns.alpha.kubernetes.io/hostname: develop.panicboat.net` → `dystopia.city`
- `spec.rules[].host: develop.panicboat.net` → `dystopia.city`
- `alb.ingress.kubernetes.io/group.name: application` (= 既存 keep)

**kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml**:
- 4 Ingress (= grafana / prometheus / alertmanager / hubble) の host は panicboat.net で keep
- `alb.ingress.kubernetes.io/group.name: monitoring-uis` → **`application`** に変更 (= ALB 集約)

**kubernetes/manifests/production/{cilium,oauth2-proxy,external-dns}/** hydrate

**kubernetes/README.md**: develop.panicboat.net 言及 update + dystopia.city / branding 分離 (= 公開 vs 非公開) section 追加

### Monorepo (= application)

**services/frontend/kubernetes/base/httproute.yaml**:
```yaml
hostnames:
  - dystopia.city  # 旧: develop.panicboat.net
```

### Out of scope (= 既存 keep)

- monorepo frontend UI branding (= 既に `dystopia.city` 表示)
- oauth2-proxy `cookie_domains: [".panicboat.net"]` (= monitoring UIs 用、 application は無認証で対象外)
- panicboat.net domain registration 自体 (= 個人利用 + monitoring UIs hosting で当面 keep)
- `nyx.place` zone (= Route53 list で観測、 用途未確認、 本 scope 外)

---

## 4. Migration sequence + cutover

### Merge / Apply order

```
1. platform PR merge
   ↓
2. terraform apply (= aws/alb/modules で ACM cert dystopia.city 発行 + DNS validation)
   ↓ (cert ISSUED = 数分、 Route53 validation record 自動作成)
3. Flux GitRepository fetch + Kustomization reconcile (= ~5 min interval)
   - ExternalDNS values 反映 (= dystopia.city zone 管理開始)
   - application Ingress host 更新 → ALB が dystopia.city 用 listener rule 追加
   - monitoring-uis Ingress の group.name 変更 → ALB Controller が application ALB に rule 統合、 旧 monitoring-uis ALB 廃止
   - hydrated manifests reconcile
   ↓
4. monorepo PR merge (= HTTPRoute hostnames `dystopia.city`)
   - Flux monorepo Kustomization reconcile → HTTPRoute hostnames `dystopia.city` 反映
   ↓
5. verify (= dig / curl)
```

### Transient state 期間 (= ~5-10 min)

- 旧 ALB `k8s-monitoringuis-1577bc5126` 削除 → 削除中 monitoring 4 hosts 数秒 unreachable
- ExternalDNS が `develop.panicboat.net` A record cleanup + `dystopia.city` A record 作成 → DNS propagation ~5 min (= Route53 default TTL)
- 旧 HTTPRoute hostname (= develop.panicboat.net) と新 (= dystopia.city) の連続 merge 間 ~数分は dystopia.city が 404/502

user 認可済の "traffic 一時停止 OK" 範囲内。

### Cutover の atomic 性

- platform PR と monorepo PR は **別 repo / 別 merge** で同時化 不可
- 連続 merge で短時間 (= 数分) host mismatch transient

---

## 5. Risks + mitigations

| Risk | Mitigation |
|---|---|
| ACM cert validation で `dystopia.city` Route53 zone data lookup 漏れ | `aws/route53/lookup/main.tf` にも dystopia.city zone data source 追加 |
| ExternalDNS `txtOwnerId` 設定で dystopia.city zone も owner 認識するか | 既存 txtOwnerId は cluster name (= eks-production) で zone 横断、 domainFilters に dystopia.city 追加で同 owner で reconcile 開始 |
| ALB に 2 cert 同時 attach (= `*.panicboat.net` + `*.dystopia.city`) で auto-discovery 動作 | AWS LB Controller の cert auto-discovery は host header から 適切 cert を match する設計、 multi-cert OK (= 公式 doc + 既存 monitoring-uis ALB が同 cert を使用していた実績) |
| 旧 `develop.panicboat.net` Route53 record が ExternalDNS で削除されない | TXT owner record で source 識別、 旧 Ingress host 削除で ExternalDNS が削除 reconcile、 万一残存なら manual `aws route53 change-resource-record-sets` |
| Flux reconcile timing で連続 merge 間 transient host mismatch | user 認可済 traffic 一時停止許容。 GitRepository interval 1m + Kustomization interval 5m で最大 6 min 待ち |
| oauth2-proxy の cookie_domains `.panicboat.net` が monitoring UIs のみで application 影響なし | application は無認証で oauth2-proxy 不経由、 影響なし (= 設定 keep) |
| monorepo HTTPRoute hostnames 変更で application が一時 404 | platform PR merge + reconcile で ALB 側 host dystopia.city 認識後、 monorepo PR 続けて merge で短時間 mismatch |

---

## 6. Validation

### Platform PR merge + terraform apply 後

- [ ] `aws acm list-certificates` で `*.dystopia.city` ISSUED 確認
- [ ] `aws route53 list-resource-record-sets` で dystopia.city zone に validation TXT record (= cert validation) 自動作成確認
- [ ] ExternalDNS log で dystopia.city zone reconcile 開始確認 (`kubectl logs -n external-dns deploy/external-dns | grep dystopia.city`)
- [ ] ALB listener 443 rule に host `dystopia.city` rule 追加確認 (`aws elbv2 describe-rules`)
- [ ] 旧 ALB `k8s-monitoringuis-1577bc5126` 削除確認 (= application ALB に統合)
- [ ] ALB に 2 cert attach 確認 (= `*.panicboat.net` + `*.dystopia.city`)

### Monorepo PR merge 後

- [ ] Flux Kustomization frontend READY=True
- [ ] HTTPRoute hostnames `dystopia.city` 確認 (`kubectl get httproute -n default frontend -o jsonpath='{.spec.hostnames}'`)
- [ ] `dig dystopia.city` で ALB DNS 返答確認
- [ ] `curl https://dystopia.city/` → HTTP 200
- [ ] `curl https://grafana.panicboat.net/` → 200 (= 同 ALB 経由、 monitoring 4 hosts 動作確認)
- [ ] Route53 panicboat.net zone から develop record 削除確認 (= ExternalDNS 経由)
- [ ] TLS handshake で正しい cert (= dystopia.city → *.dystopia.city cert、 grafana.panicboat.net → *.panicboat.net cert)

---

## 7. Out of scope

- panicboat.net domain 自体の廃止 (= 当面 keep、 個人利用 + monitoring UIs hosting)
- dystopia.city subdomain (= 将来必要時 wildcard cert で対応可)
- `nyx.place` zone (= 用途未確認、 別 scope)
- application 側の認証導入 (= 公開 application で認証必要なら別 brainstorm)
- ALB scheme=internal 化 (= 緩い解釈で keep internet-facing + oauth2-proxy)
