# Pod Identity Injection Detection (= 引き継ぎ事項 #15)

> **Goal**: AWS EKS Pod Identity webhook が Pod に `AWS_CONTAINER_CREDENTIALS_FULL_URI` env を inject し損なう timing race を自動検出する framework の初期着手。 ad-hoc shell script を 1 本作成し、 manual run で immediate value を確保。 cron / alert backend 連携は別 phase。

---

## 1. Problem

### Pod Identity injection の仕組み

EKS Pod Identity Association では、 `aws-eks-pod-identity-webhook` (= `eks-pod-identity-agent` DaemonSet が webhook を兼ねる、 cluster recreate runbook で confirmed) が Pod schedule 時に対象 SA を持つ Pod へ以下を inject:

- `AWS_CONTAINER_CREDENTIALS_FULL_URI` env var (= AWS SDK が credential 取得 endpoint として参照)
- `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` env var (= token file path)
- token を mount する volume

application は AWS SDK 経由でこの env を見て、 endpoint から短期 credential を取得して AWS API call。

### Race condition

webhook は Pod admission tag で fire するが、 以下条件で **inject 失敗 silent fail** が観測されている:

1. webhook DaemonSet 自体が起動前に Pod が schedule された (= cluster bootstrap 時)
2. webhook Pod が一時 down 中に target Pod recreate
3. ServiceAccount に Pod Identity Association が deploy 順序で 後付け (= Pod 先 schedule)

結果: env 不在で Pod 起動 → AWS SDK が credential 不在 → AWS API call 全て fail。 specific symptom:
- ESO (= external-secrets) Pod が AWS Secrets Manager から secret を取れず、 ESO 経由作成の Secret が stale / 不在
- cilium-operator Pod が AWS EC2 ENI 操作不可 (= Phase 4-1 でも observed)
- 一般的に「Pod は Running だが AWS access だけ silent fail」 で symptom が出にくい

### 現状

- 検出は **manual** (= `kubectl exec <pod> -- env | grep AWS_CONTAINER_CREDENTIALS_FULL_URI`)
- sporadic な race のため、 偶発発生時に気付くのが遅れる

---

## 2. Detection approach

### Probe target

「Pod Identity Association を持つ ServiceAccount を使う 全 Pod」 が probe 対象:

1. AWS API (`aws eks list-pod-identity-associations`) で cluster の全 PIA を取得
2. 各 PIA の `(namespace, serviceAccount)` を抽出
3. kubectl で 該当 SA を使う Pod を list
4. 各 Pod の env field に `AWS_CONTAINER_CREDENTIALS_FULL_URI` 存在 verify

### Env 存在 check 方法

`kubectl get pod -o json` で取得した spec の env を見るだけで判定可能:

```jsonpath
.spec.containers[].env[] | select(.name == "AWS_CONTAINER_CREDENTIALS_FULL_URI")
```

webhook が inject する env は **Pod manifest の env field** に追加されるため、 `kubectl exec` 不要 (= Pod が CrashLoop でも probe 可)。

### Output

- `OK: ns=<> sa=<> pod=<>` (= injected)
- `FAIL: ns=<> sa=<> pod=<>: AWS_CONTAINER_CREDENTIALS_FULL_URI not injected`
- `INFO: ns=<> sa=<>: no Pods using this SA` (= association exists but Pod 不在)
- exit code: 0 (= all OK)、 1 (= fail あり)

manual run + cron / CI 統合の両 case で exit code 解釈可。

---

## 3. Implementation scope (本 PR)

### 含む

- `scripts/post-flight/check-pod-identity-injection.sh` (= 上記 logic の bash 実装)
- spec doc + plan doc

### 含まない (別 phase)

- K8s CronJob 化 (= 定期 probe)
- alert backend 連携 (= Prometheus AlertManager / PagerDuty)
- Pod admission validator (= webhook 失敗時 deploy block)
- post-flight check framework 全般 (= 引き継ぎ #5 と統合検討)

---

## 4. Limitations

### Race-window detection の限界

本 script は probe 実行時点の Pod state を見るため、 「Pod schedule 時の race → 不在 → 後で recreated で recover」 のような transient case は probe 時点で healthy なら detect 不可。 真の検出には webhook event hook (= Pod admission audit) が必要だが scope 外。

### AWS API rate limit

`aws eks list-pod-identity-associations` は paginated API、 association 数 100+ で次 page 取得必要。 panicboat の現状 association 数は少ない (= cilium-operator + ESO 程度) ため初期は無視可。

### IAM 権限

probe 実行 IAM principal は `eks:ListPodIdentityAssociations` 権限必要。 eks-admin role には付与なしの可能性 (= 確認 + 必要なら追加)。 現状 IAM user `panicboat` で実行する場合は AdministratorAccess で OK。

---

## 5. Phase 7+ extension

| Step | content |
|---|---|
| A (本 PR) | ad-hoc script 1 本 + spec / plan doc |
| B | K8s CronJob 化 (= 1 時間間隔等で定期 probe、 Job log を Loki で aggregate) |
| C | alert backend 連携 (= Prometheus textfile collector 経由 metric expose → AlertManager rule) |
| D | post-flight check framework (= 引き継ぎ #5) との統合 (= cert-manager mTLS chain verify 等 他 probe と同 framework) |

---

## 6. Out of scope

- 引き継ぎ #5 post-flight check framework 全般 (= 本 #15 は同 framework の 1 probe として 位置付け、 framework 設計は別 spec)
- 引き継ぎ #16 distributed system chart audit (= 別 categorize)
- 引き継ぎ #19 mTLS chain verify default 化 (= 同上)

---

## 7. Validation

- `bash scripts/post-flight/check-pod-identity-injection.sh eks-production` を eks-production cluster で実行、 OK + FAIL 各 line を 想定通り出力
- 既存 cilium-operator / ESO 等の Pod Identity 関連 Pod が "OK" になることを baseline 確認
- 意図的に env を持たない Pod (= Pod Identity 関連ではない Pod) は probe 対象から除外されていることを確認
