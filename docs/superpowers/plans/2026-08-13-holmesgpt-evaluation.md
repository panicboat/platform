# HolmesGPT Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** HolmesGPT を cluster 内に導入し、原因が既知の障害を調査させて採否を判断する。

**Architecture:** 公式 Helm chart `robusta/holmes` を helmfile component として追加し、Flux が適用する。AWS 認証は IRSA、Kubernetes 権限は chart 提供の read-only ClusterRole をそのまま使う。`sandbox` namespace に二層障害（frontend の接続エラー → backend の OOMKill）を再現し、`POST /api/chat` で調査させて採点する。

**Tech Stack:** HolmesGPT Helm chart 0.39.0, Amazon Bedrock (us region), Terragrunt + OpenTofu, Helmfile + Kustomize + Flux CD

**Design doc:** `docs/superpowers/specs/2026-08-13-holmesgpt-evaluation-design.md`

## Global Constraints

- 作業 worktree は `.claude/worktrees/feat-holmesgpt-evaluation`、ブランチは `feat/holmesgpt-evaluation`
- commit には必ず `-s` を付ける。`Co-Authored-By` を付与しない
- 出力・コメント・ドキュメント本文は日本語。変数名・関数名・commit message subject は英語
- `kubernetes/manifests/` は完全な生成物。手で編集しない
- `kubernetes/components/<comp>/<env>/` が唯一の手書きソース。`namespace.yaml` は component 直下に置き `hydrate-index.sh` が集約する
- AWS account ID は `559744160976`、cluster は `eks-production`、region は `ap-northeast-1`（Bedrock のみ `us-east-1`）
- **`aws` は `/opt/homebrew/bin/aws` を明示する。** `/usr/local/bin/aws` の 2.11.4 が PATH を占有しており `bedrock` サブコマンドを持たない
- EKS 認証は `! eks-login`。ただし Bash tool には環境変数が引き継がれないため、`aws sts assume-role --role-arn arn:aws:iam::559744160976:role/eks-admin-production` して export するラッパー経由で実行する
- `aws/eks` は cluster の中核 stack。apply 前に必ず plan の差分を確認する

---

### Task 1: Bedrock 用 IRSA role

**Files:**
- Create: `aws/eks/modules/iam_holmesgpt.tf`

**Interfaces:**
- Produces: IAM role `eks-production-holmesgpt`。ARN を Task 2 の helmfile に定数で埋める

- [ ] **Step 1: 使う model が invoke できることを確認する**

`us.` profile が実際に応答するかを先に確定させる。ここが通らないと IAM を書く意味が無い。

```bash
AWS=/opt/homebrew/bin/aws
for m in us.anthropic.claude-sonnet-4-6 us.anthropic.claude-opus-5; do
  printf "%-40s " "$m"
  $AWS bedrock-runtime converse --region us-east-1 --model-id "$m" \
    --messages '[{"role":"user","content":[{"text":"Reply with exactly: ok"}]}]' \
    --query 'output.message.content[0].text' --output text 2>&1 | tail -1
done
```

期待: `sonnet-4-6` が `ok` を返す。

`opus-5` が `AccessDeniedException` の場合、model access の反映が未完了である。`bedrock create-foundation-model-agreement` は実行済みで `get-foundation-model-availability` は `AVAILABLE` を返すが、runtime への伝播に時間差がある。段階 1 の採点は `sonnet-4-6` だけで成立するため、待たずに進めてよい。

- [ ] **Step 2: profile が経由する region を確認する**

IAM policy の resource に何を列挙するかがこれで決まる。

```bash
/opt/homebrew/bin/aws bedrock get-inference-profile --region us-east-1 \
  --inference-profile-identifier us.anthropic.claude-sonnet-4-6 \
  --query 'models[].modelArn' --output text | tr '\t' '\n'
```

期待: `us-east-1` / `us-east-2` / `us-west-2` の三つが返る。

- [ ] **Step 3: `iam_holmesgpt.tf` を作成する**

既存の `module.external_dns_irsa` と同じ `iam-role-for-service-accounts` submodule を使う。Bedrock には組み込みポリシーが無いため `aws_iam_policy` を作って `policies` に渡す。

```hcl
# iam_holmesgpt.tf - IRSA role for the HolmesGPT evaluation (Bedrock inference only).
#
# HolmesGPT runs in-cluster and reads the cluster through the Kubernetes API.
# That access comes from the chart's own read-only ClusterRole, not from this
# role — this role exists solely so the agent can call Bedrock without a
# long-lived API key anywhere.
#
# Bedrock resources are enumerated rather than wildcarded because per-model
# pricing differs by an order of magnitude (Opus 5 is $5/$25 per MTok against
# Haiku 4.5 at $1.10/$5.50); a misconfigured model fails at IAM instead of on
# the invoice.
#
# `us.` inference profiles route to three regions. Listing only the profile ARN
# is not enough — the call fails on whichever region the profile picks.

resource "aws_iam_policy" "holmesgpt_bedrock" {
  name        = "eks-${var.environment}-holmesgpt-bedrock"
  description = "Bedrock invoke permissions for the HolmesGPT evaluation"
  tags        = var.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-opus-5",
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-5",
          "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-opus-5",
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-opus-5",
        ]
      }
    ]
  })
}

module "holmesgpt_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "eks-${var.environment}-holmesgpt"
  use_name_prefix = false

  policies = {
    bedrock = aws_iam_policy.holmesgpt_bedrock.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["holmesgpt:holmesgpt"]
    }
  }

  tags = var.common_tags
}
```

`namespace_service_accounts` の `holmesgpt:holmesgpt` は Task 2 で `customServiceAccountName: holmesgpt` を設定することに対応する。chart の既定名は release 名から導出されて変わりうるため固定する。

- [ ] **Step 4: plan の差分を確認する**

```bash
cd aws/eks/envs/production
terragrunt plan -no-color -lock=false 2>&1 | sed 's/^[0-9:.]* STDOUT tofu: //' | grep -E "^  # |^Plan: "
```

期待: `aws_iam_policy.holmesgpt_bedrock` と `module.holmesgpt_irsa.*` の追加のみ。

これに加えて次の定常 churn が必ず出る。これらは本変更と無関係であり、毎回の plan に現れる。

- `module.eks.aws_security_group.node[0] will be updated in-place`（`kubernetes.io/cluster/<name>=owned` タグの付与）
- `terraform_data.node_sg_cluster_tag_removal must be replaced`（上のタグを `local-exec` で消す仕組み）

cluster 本体・node group・network の差分が出ていたら **apply せず中断して原因を調べる**。

`Inconsistent dependency lock file` で失敗した場合は `terragrunt init -upgrade` を実行してから再試行する。リポジトリに `.terraform.lock.hcl` は commit されていないため影響は cache 内に閉じる。

- [ ] **Step 5: apply する**

```bash
terragrunt apply -auto-approve
```

- [ ] **Step 6: role と trust policy を確認する**

```bash
AWS=/opt/homebrew/bin/aws
$AWS iam get-role --role-name eks-production-holmesgpt \
  --query '{arn:Role.Arn,trust:Role.AssumeRolePolicyDocument}' --output json
```

期待: ARN が `arn:aws:iam::559744160976:role/eks-production-holmesgpt`、trust policy の `Condition` に `holmesgpt:holmesgpt` を含む `sub` 制約がある。

- [ ] **Step 7: commit する**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-holmesgpt-evaluation
git add aws/eks/modules/iam_holmesgpt.tf
git commit -s -m "feat(aws/eks): add IRSA role for HolmesGPT Bedrock access"
```

---

### Task 2: HolmesGPT component

**Files:**
- Create: `kubernetes/components/holmesgpt/namespace.yaml`
- Create: `kubernetes/components/holmesgpt/production/helmfile.yaml`
- Create: `kubernetes/components/holmesgpt/production/values.yaml.gotmpl`

**Interfaces:**
- Consumes: Task 1 の role ARN `arn:aws:iam::559744160976:role/eks-production-holmesgpt`
- Produces: `holmesgpt` namespace に Deployment `holmes` と Service。Task 3 以降で `POST /api/chat` を叩く

- [ ] **Step 1: `namespace.yaml` を作成する**

component 直下に置く。env ごとに namespace を変える理由が無いため、falco / reloader と同じ配置にする。

```yaml
# =============================================================================
# holmesgpt Namespace
# =============================================================================
# HolmesGPT (CNCF Sandbox) の評価用 namespace。chart 提供の read-only
# ClusterRole で cluster を調査し、Bedrock へは IRSA で接続する。
# 採点が終わったら component ごと削除する。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: holmesgpt
  labels:
    app.kubernetes.io/name: holmesgpt
```

- [ ] **Step 2: `helmfile.yaml` を作成する**

`environments.production.values` に role ARN を定数で置く。`use_name_prefix = false` により ARN が決定的であるため成立する。既存 component と同じ規約である。

```yaml
# =============================================================================
# holmesgpt Helmfile for production
# =============================================================================
# HolmesGPT (CNCF Sandbox) の deploy。chart は read-only ClusterRole と
# ServiceAccount を自前で作るため、RBAC をこちらで定義しない。
# =============================================================================
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の environments values を
    # 子 helmfile に auto-inherit しないため、ここで再定義する。
    values:
      - cluster:
          # STABLE: aws/eks/modules/iam_holmesgpt.tf で deterministic 化済
          holmesgptRoleArn: arn:aws:iam::559744160976:role/eks-production-holmesgpt
---
repositories:
  - name: robusta
    url: https://robusta-charts.storage.googleapis.com

releases:
  - name: holmesgpt
    namespace: holmesgpt
    chart: robusta/holmes
    version: "0.39.0"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 3: `values.yaml.gotmpl` を作成する**

```yaml
# =============================================================================
# HolmesGPT Configuration for production
# =============================================================================

# -----------------------------------------------------------------------------
# ServiceAccount / IRSA
# -----------------------------------------------------------------------------
# chart 既定の SA 名は release 名から導出されて変わりうる。IRSA の trust policy
# は namespace:serviceaccount を固定で参照するため、名前を固定する。
createServiceAccount: true
customServiceAccountName: holmesgpt

# k8sRBAC は「RBAC を自前で用意する」という意味で、true にすると chart 側の
# ClusterRole が丸ごと無効になり、SA も automountServiceAccountToken: false の
# 素のものだけになる (= Kubernetes API を叩けなくなる)。
#   holmesgpt-service-account.yaml:      if and createServiceAccount (not k8sRBAC)
#   holmesgpt-rbac-service-account.yaml: if and createServiceAccount k8sRBAC
# chart の read-only ClusterRole をそのまま使うため既定の false を明示する。
k8sRBAC: false

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.cluster.holmesgptRoleArn }}

# -----------------------------------------------------------------------------
# LLM (Amazon Bedrock)
# -----------------------------------------------------------------------------
# model ID は LiteLLM 形式の `bedrock/` 接頭辞 + inference profile ID。
# us. profile は us-east-1 / us-east-2 / us-west-2 へルーティングする。
#
# 二段階で採点する。sonnet-4-6 は OpenSRE 評価と同一 model であり、ツール間の
# 比較を model 差に汚されずに行うために置く。opus-5 は現行世代での上限を見る。
additionalEnvVars:
  - name: AWS_REGION_NAME
    value: us-east-1

modelList:
  sonnet-4-6:
    model: bedrock/us.anthropic.claude-sonnet-4-6
    temperature: 0
  opus-5:
    model: bedrock/us.anthropic.claude-opus-5
    temperature: 0

# -----------------------------------------------------------------------------
# Toolsets
# -----------------------------------------------------------------------------
toolsets:
  kubernetes/core:
    enabled: true
  kubernetes/logs:
    enabled: true

  # Mimir が default datasource であり長期保存を持つ。Prometheus 互換 endpoint
  # をそのまま向ける。Mimir は X-Scope-OrgID を要求しない (Loki のみ anonymous
  # 固定で要求する) ため追加ヘッダーは不要。
  prometheus/metrics:
    enabled: true
    config:
      prometheus_url: http://mimir-distributed-gateway.monitoring.svc.cluster.local/prometheus

  # エラーメッセージや docs の参照に使う。製品価値の一部であり、落とすと機能を
  # 削った状態で評価することになる。
  internet:
    enabled: true

  # Robusta SaaS 連携。使わないのに外部通信が発生するため無効化する。
  robusta:
    enabled: false

  # chart 既定は extended。差分の 11 コマンド (cat / base64 / ls / find / stat /
  # du / df / tar -tf / gzip -l / zcat / zgrep) は調査対象である cluster では
  # なく HolmesGPT 自身のコンテナを向いている。core でも kubectl get/describe/
  # logs と jq / grep が残るため調査は成立する。
  # 不足すればレポートに拒否として現れるので、見てから上げる。
  bash:
    enabled: true
    config:
      builtin_allowlist: "core"

# -----------------------------------------------------------------------------
# CRD permissions
# -----------------------------------------------------------------------------
# このクラスタが実際に使うものだけを有効化する。
crdPermissions:
  flux: true
  gatewayApi: true
  keda: true
  externalSecrets: true

# -----------------------------------------------------------------------------
# Security context
# -----------------------------------------------------------------------------
# chart 既定は空。readOnlyRootFilesystem は chart が常に true にするため
# ここでは指定しない。
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL

# -----------------------------------------------------------------------------
# Resources
# -----------------------------------------------------------------------------
resources:
  requests:
    cpu: 50m
    memory: 512Mi
  limits:
    memory: 2Gi
```

- [ ] **Step 4: hydrate して生成物を確認する**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-holmesgpt-evaluation
./scripts/kubernetes-hydrate/hydrate-component.sh holmesgpt production
./scripts/kubernetes-hydrate/hydrate-index.sh production
git status --short
```

期待: `kubernetes/manifests/production/holmesgpt/` が生成され、`00-namespaces/namespaces.yaml` に holmesgpt が追記され、`kustomization.yaml` に holmesgpt が加わる。

- [ ] **Step 5: 生成された manifest を検証する**

設計上の意図が生成物に現れているかを確認する。

```bash
M=kubernetes/manifests/production/holmesgpt/manifest.yaml
echo "=== 書き込み系 verb が無いこと ==="
grep -oE '"?(create|update|delete|patch|deletecollection)"?' "$M" | sort -u; echo "(何も出なければ read-only)"
echo "=== core group に secrets が無いこと ==="
grep -n "secrets" "$M" | head -5; echo "(external-secrets.io の CRD だけなら想定どおり)"
echo "=== IRSA annotation ==="
grep -n -A2 "eks.amazonaws.com/role-arn" "$M" | head -4
echo "=== SA 名 ==="
grep -nE "name: holmesgpt$" "$M" | head -3
```

期待: 書き込み verb が 0 件、`secrets` は `external-secrets.io` の CRD のみ、role ARN が埋まっている、SA 名が `holmesgpt`。

- [ ] **Step 6: commit して push する**

```bash
git add kubernetes/components/holmesgpt kubernetes/manifests/production
git commit -s -m "feat(kubernetes): deploy HolmesGPT for evaluation"
git push
```

---

### Task 3: デプロイと疎通確認（GATE）

このタスクが失敗した場合、**Task 4 以降を中止して原因を調べる**。model ID 形式が誤っていれば調査そのものが成立しない。

**Files:**
- リポジトリへの変更なし

**Interfaces:**
- Consumes: Task 2 の component
- Produces: 動作する HolmesGPT。Task 5 で `POST /api/chat` を叩く

- [ ] **Step 1: PR を Ready にしてマージする**

```bash
gh pr ready 766
gh pr checks 766
gh pr merge 766 --squash --delete-branch=false
```

- [ ] **Step 2: Flux を同期する**

```bash
eks-login   # 対話シェルで実行してもらう
flux reconcile source git flux-system
flux reconcile kustomization flux-system
kubectl -n holmesgpt get deploy,pod
```

期待: `deployment.apps/holmesgpt-holmes` が Ready。

- [ ] **Step 3: 起動ログに認証エラーが無いことを確認する**

```bash
kubectl -n holmesgpt logs deploy/holmesgpt-holmes --tail=50 | grep -iE "error|denied|credential|bedrock" | head -10
```

期待: Bedrock の認証エラーが出ていない。`AccessDenied` があれば IRSA の trust policy か SA 名の不一致を疑う。

- [ ] **Step 4: model が認識されていることを確認する（GATE 本体）**

```bash
kubectl -n holmesgpt port-forward svc/holmesgpt-holmes 5050:80 &
sleep 3
curl -s localhost:5050/api/model | python3 -m json.tool
```

期待: `sonnet-4-6` と `opus-5` が一覧に出る。

**通らなかった場合**: LiteLLM 形式の `bedrock/` 接頭辞に inference profile ID を渡せていない可能性が高い。`kubectl -n holmesgpt logs deploy/holmesgpt-holmes` に LiteLLM のエラーが出ているはずなので、そこから正しい形式を判断する。foundation model ID 直指定（`bedrock/anthropic.claude-sonnet-4-6`）も試す。

- [ ] **Step 5: RBAC が Secret を拒否することを確認する**

allowlist は `kubectl` を許すが RBAC が拒否する、という多層防御を直接確かめる。

```bash
kubectl -n holmesgpt exec deploy/holmesgpt-holmes -- kubectl auth can-i get secrets --all-namespaces
kubectl -n holmesgpt exec deploy/holmesgpt-holmes -- kubectl get pod -A --no-headers | wc -l
```

期待: 前者が `no`、後者が Pod 数を返す。

- [ ] **Step 6: `bash` が core に制限されていることを確認する**

```bash
curl -s -X POST localhost:5050/api/chat -H 'Content-Type: application/json' \
  -d '{"ask":"Run `cat /etc/hostname` and tell me the output.","model":"sonnet-4-6"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('analysis','')[:400])"
```

期待: `cat` が許可されていない旨が返る。`core` allowlist が効いている証拠になる。

---

### Task 4: 故障 sandbox の復元

**Files:**
- Create: `kubernetes/components/sandbox/production/namespace.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/backend.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/frontend.yaml`

**Interfaces:**
- Produces: `sandbox` namespace に frontend（Ready）と backend（CrashLoopBackOff）。Task 5 の調査対象

- [ ] **Step 1: git 履歴から復元する**

OpenSRE 評価で使ったものと同一のファイルを使う。書き直さない。同じ物差しで採点するためである。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-holmesgpt-evaluation
mkdir -p kubernetes/components/sandbox/production/kustomization
for f in namespace.yaml kustomization/kustomization.yaml kustomization/backend.yaml kustomization/frontend.yaml; do
  git show 647ef5e:kubernetes/components/sandbox/production/$f > kubernetes/components/sandbox/production/$f
done
find kubernetes/components/sandbox -type f | sort
```

期待: 4 ファイルが復元される。

- [ ] **Step 2: 内容が壊れていないことを確認する**

```bash
kustomize build kubernetes/components/sandbox/production/kustomization | grep -cE "^kind:"
python3 -c "
import yaml
docs=[d for d in yaml.safe_load_all(open('kubernetes/components/sandbox/production/kustomization/backend.yaml')) if d]
c=docs[0]['spec']['template']['spec']['containers'][0]
print('backend limits:', c['resources'].get('limits'))
print('cmd lines:', len(c['command'][-1].splitlines()))
"
```

期待: 3 kind、backend の `limits.memory` が `64Mi`、埋め込み Python が 22 行。

- [ ] **Step 3: hydrate して commit する**

```bash
./scripts/kubernetes-hydrate/hydrate-component.sh sandbox production
./scripts/kubernetes-hydrate/hydrate-index.sh production
git add kubernetes/components/sandbox kubernetes/manifests/production
git commit -s -m "feat(kubernetes): restore fault-injected sandbox for HolmesGPT evaluation"
git push
```

- [ ] **Step 4: PR を作ってマージする**

PR 番号は作成時の出力から取り出す。手で控えない。

```bash
PR=$(gh pr create --draft \
  --title "feat(kubernetes): restore fault-injected sandbox for HolmesGPT evaluation" \
  --body "HolmesGPT の採点対象。OpenSRE 評価 (#751) と同一のファイルを git 履歴から復元した。同じ物差しで比較するため書き直さない。採点後に Task 7 で削除する。" \
  | grep -oE '[0-9]+$')
echo "PR=$PR"
gh pr ready "$PR"
gh pr merge "$PR" --squash --delete-branch=false
```

- [ ] **Step 5: 三層の痕跡が成立することを確認する**

```bash
flux reconcile source git flux-system && flux reconcile kustomization flux-system
sleep 60
echo "=== 症状 ==="; kubectl -n sandbox logs deploy/frontend --tail=5
echo "=== 中間 ==="; kubectl -n sandbox get endpoints backend
echo "=== 根本 ==="; kubectl -n sandbox describe pod -l app.kubernetes.io/name=backend | grep -A4 "Last State"
```

期待: frontend のログに `request failed`、backend の Endpoints が空、`Reason: OOMKilled`。

backend は約 40 秒で OOMKill に至るため、`sleep 60` を挟む。

---

### Task 5: 段階 1 の採点（Sonnet 4.6）

**Files:**
- リポジトリへの変更なし。結果は Task 7 で spec に追記する

**Interfaces:**
- Consumes: Task 3 の HolmesGPT、Task 4 の sandbox

- [ ] **Step 1: 原因を示唆しない指示で調査させる**

指示に `backend` / `memory` / `OOM` を含めない。含めると採点が成立しない。

```bash
kubectl -n holmesgpt port-forward svc/holmesgpt-holmes 5050:80 &
sleep 3
curl -s -X POST localhost:5050/api/chat -H 'Content-Type: application/json' -d '{
  "ask": "The frontend workload in the sandbox namespace is continuously logging request failures: '\''frontend: request failed: <urlopen error [Errno 111] Connection refused>'\''. It was healthy earlier. Investigate and report the root cause.",
  "model": "sonnet-4-6"
}' -o /tmp/holmes-sonnet46.json
python3 -m json.tool /tmp/holmes-sonnet46.json | head -60
```

- [ ] **Step 2: 使ったツールと証拠を記録する**

レポート本文に加えて次を控える。OpenSRE では `evidence:0` でツールを一つも使わなかったため、ここが比較の要になる。

```bash
python3 -c "
import json
d=json.load(open('/tmp/holmes-sonnet46.json'))
print('keys:', list(d.keys()))
print()
print(json.dumps(d, ensure_ascii=False, indent=2)[:3000])
"
```

- [ ] **Step 3: 採点する**

design doc の Grading criteria に照らす。OpenSRE と同一の基準である。

合格: 根本原因を **backend の memory limit 不足による OOMKill** と特定し、根拠として観測データを引用している。

不合格:
- 「frontend にエラーが出ている」という症状の記述で止まる
- ネットワーク障害や DNS 障害と誤診する
- backend の CrashLoopBackOff に言及するが memory limit と結びつけない

参考: OpenSRE は「複数候補の一つとして OOMKilled を挙げたが特定せず、evidence 0 件」であった。

- [ ] **Step 4: 追加の観点を記録する**

- 実際に使った toolset と得た証拠の件数
- 調査に要した時間
- `bash` を `core` に下げたことで拒否された操作の有無
- 誤った断定をしたか、不確実性を表明したか

---

### Task 6: 段階 2 の採点（Opus 5）

**Files:**
- リポジトリへの変更なし

**Interfaces:**
- Consumes: Task 5 と同じ環境。model だけを変える

- [ ] **Step 1: Opus 5 が invoke できることを再確認する**

Task 1 Step 1 で拒否されていた場合、ここで反映されている可能性がある。

```bash
/opt/homebrew/bin/aws bedrock-runtime converse --region us-east-1 \
  --model-id us.anthropic.claude-opus-5 \
  --messages '[{"role":"user","content":[{"text":"Reply with exactly: ok"}]}]' \
  --query 'output.message.content[0].text' --output text
```

まだ拒否される場合、段階 2 は実施せず Task 7 にその旨を記録する。段階 1 だけで採否の判断は成立する。

- [ ] **Step 2: 同一の指示を Opus 5 で走らせる**

指示文を Task 5 Step 1 と完全に一致させる。model 以外を変えると差分の原因が特定できない。

```bash
curl -s -X POST localhost:5050/api/chat -H 'Content-Type: application/json' -d '{
  "ask": "The frontend workload in the sandbox namespace is continuously logging request failures: '\''frontend: request failed: <urlopen error [Errno 111] Connection refused>'\''. It was healthy earlier. Investigate and report the root cause.",
  "model": "opus-5"
}' -o /tmp/holmes-opus5.json
python3 -m json.tool /tmp/holmes-opus5.json | head -60
```

- [ ] **Step 3: 段階 1 と比較する**

同じ基準で採点したうえで、次の差を記録する。

- 根本原因への到達（両方合格 / Opus 5 のみ合格 / 両方不合格）
- 使ったツールと証拠の件数の差
- 調査時間の差

**この差が model 由来である**と言えるのは、ツール・権限・sandbox・指示文がすべて同一だからである。

---

### Task 7: 結果の記録と撤退または定着

**Files:**
- Modify: `docs/superpowers/specs/2026-08-13-holmesgpt-evaluation-design.md`（末尾に `## Evaluation result` を追記）
- 不採用の場合 — Delete: `kubernetes/components/holmesgpt/`、Delete: `kubernetes/components/sandbox/`、Delete: `aws/eks/modules/iam_holmesgpt.tf`

- [ ] **Step 1: sandbox を削除する（判断によらず必ず実行）**

故障 workload を production に残さない。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-holmesgpt-evaluation
rm -rf kubernetes/components/sandbox
./scripts/kubernetes-hydrate/hydrate-index.sh production
rm -rf kubernetes/manifests/production/sandbox
```

- [ ] **Step 2: 結果を spec に追記する**

`## Evaluation result` を追加し、**判断（採用 / 不採用）とその根拠**を明記する。

含める内容:

- 段階 1（Sonnet 4.6）の採点結果とレポートの要点
- 段階 2（Opus 5）の採点結果。実施できなかった場合はその理由
- 両段階の差と、それが model 由来であると言える根拠
- 使った toolset と証拠の件数
- OpenSRE との比較（同一 model・同一 sandbox・同一基準での対比）
- `bash` を `core` に下げたことで不足が生じたか
- 調査時間と Bedrock の課金

- [ ] **Step 3: 不採用の場合のみ — 撤去する**

```bash
rm -rf kubernetes/components/holmesgpt
rm -f aws/eks/modules/iam_holmesgpt.tf
./scripts/kubernetes-hydrate/hydrate-index.sh production
rm -rf kubernetes/manifests/production/holmesgpt
cd aws/eks/envs/production && terragrunt plan
```

plan が `aws_iam_policy.holmesgpt_bedrock` と `module.holmesgpt_irsa.*` の削除、および Task 1 Step 4 に記した定常 churn だけであることを確認してから apply する。

- [ ] **Step 4: 採用の場合のみ — 常用に向けた課題を記録する**

spec の `## Evaluation result` に追記する。

- Alertmanager receiver をどう設計するか（現状 receiver は未設定）
- prompt injection の境界。ログは攻撃者が内容に影響を与えうる入力であり、`configmaps` と Pod ログが外部 LLM へ送られる
- `bash` を `core` のまま運用するか、必要に応じて上げるか
- `internet` toolset の egress を NetworkPolicy で絞るか

- [ ] **Step 5: commit して push し、PR を作る**

PR 本文は Step 2 で spec に書いた `## Evaluation result` から、判断・根拠・OpenSRE との比較の三点を抜き出して書く。新しく考えない。

```bash
git add -A docs/superpowers/specs kubernetes/ aws/
git commit -s -m "docs(superpowers): record HolmesGPT evaluation result"
git push
gh pr create --draft \
  --title "docs(superpowers): record HolmesGPT evaluation result" \
  --body-file <(sed -n '/## Evaluation result/,$p' docs/superpowers/specs/2026-08-13-holmesgpt-evaluation-design.md)
```

---

## Verification Summary

design doc の Verification 表と本 plan のステップの対応。

| design doc 手順 | plan のステップ |
|---|---|
| 1. IRSA role が存在する | Task 1 Step 6 |
| 2. Flux が同期して Ready | Task 3 Step 2 |
| 3. Bedrock 認証エラーが無い | Task 3 Step 3 |
| 4. `GET /api/model` | Task 3 Step 4 |
| 5. Secret が拒否される | Task 3 Step 5 |
| 6. sandbox が同期 | Task 4 Step 5 |
| 7. `POST /api/chat` で調査 | Task 5 Step 1 / Task 6 Step 2 |
| 8. 撤退 | Task 7 Step 1 / Step 3 |
