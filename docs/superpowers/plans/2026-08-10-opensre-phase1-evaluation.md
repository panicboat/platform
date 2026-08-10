# OpenSRE Phase 1 Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OpenSRE が production EKS cluster の障害を調査し、根本原因に到達できるかを採点し、採否を判断する。

**Architecture:** OpenSRE はローカル CLI として動かし、クラスタには何もインストールしない。専用の read-only IAM role を EKS access entry で Kubernetes RBAC へマップし、同じ role で Bedrock を呼ぶ。`sandbox` namespace に原因が既知の二層障害（frontend の接続エラー → backend の OOMKill）を仕込み、OpenSRE のレポートがその原因に到達するかで採点する。

**Tech Stack:** OpenSRE CLI (homebrew tap `tracer-cloud/tap`), Amazon Bedrock, Terragrunt + OpenTofu, Kustomize + Flux CD, Ansible

**Design doc:** `docs/superpowers/specs/2026-08-10-opensre-phase1-evaluation-design.md`

## Global Constraints

- 作業 worktree は `.claude/worktrees/feat-opensre-evaluation`、ブランチは `feat/opensre-evaluation`
- commit には必ず `-s` を付ける。`Co-Authored-By` を付与しない
- 出力・コメント・ドキュメント本文は日本語。変数名・関数名・commit message subject は英語
- `kubernetes/manifests/` は完全な生成物。手で編集しない。hydrate script が生成し CI が commit し返す
- `kubernetes/components/<comp>/<env>/` が唯一の手書きソース。hydrate は `helmfile.yaml` と `kustomization/` のみ読み、`namespace.yaml` は `00-namespaces/namespaces.yaml` に集約される
- EKS access policy の ARN は `arn:aws:eks::aws:cluster-access-policy/<NAME>` 形式。IAM managed policy 形式を渡すと `AssociateAccessPolicy` が 400 を返す
- EKS 認証は `! eks-login`（zsh 関数）で行う
- `aws/eks` は cluster の中核 stack。apply 前に必ず plan の差分を確認する

---

### Task 1: Phase 0 — CLI 導入と Bedrock 疎通確認（GATE）

このタスクが失敗した場合、**以降のタスクをすべて中止する**。alpha の Bedrock 実装が機能しないなら、IAM stack と sandbox を作る意味が無い。

`platform` には一切触れない。変更は `ansible` repo のみ。

**Files:**
- Modify: `/Users/takanokenichi/GitHub/panicboat/ansible/roles/homebrew/tasks/main.yaml:13-14`（taps 定義）
- Modify: `/Users/takanokenichi/GitHub/panicboat/ansible/roles/homebrew/tasks/main.yaml:58`（packages 一覧、`opentofu` の直前）

**Interfaces:**
- Produces: ローカルに `opensre` コマンド。Task 5 で使う。Bedrock で利用可能な model ID 一覧（Task 2 の IAM policy resource に使う）

- [ ] **Step 1: Bedrock で利用可能な model と inference profile を列挙する**

`ap-northeast-1` では foundation model を直接呼べず cross-region inference profile 経由になる場合がある。IAM policy の resource に何を書くかがこれで決まる。

```bash
eks-login
aws bedrock list-inference-profiles --region ap-northeast-1 \
  --query 'inferenceProfileSummaries[].{id:inferenceProfileId,arn:inferenceProfileArn,status:status}' --output table
aws bedrock list-foundation-models --region ap-northeast-1 \
  --query 'modelSummaries[?providerName==`Anthropic`].{id:modelId,name:modelName}' --output table
```

出力から使う model を 1 つ決める。まだ有効化されていない場合は AWS Console の Bedrock → Model access から有効化する。

決めた model ID と、`inferenceProfileArn` および参照先 foundation model の ARN を控える。Task 2 で使う。

- [ ] **Step 2: 疎通を先に素の AWS CLI で確認する**

OpenSRE を挟む前に、Bedrock 自体が呼べることを確定させる。ここで失敗したら原因は OpenSRE ではなく Bedrock 設定側にある。

```bash
aws bedrock-runtime converse \
  --region ap-northeast-1 \
  --model-id <Step 1 で決めた ID> \
  --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
  --query 'output.message.content[0].text' --output text
```

期待: 応答テキストが返る。

- [ ] **Step 3: ansible に tap を追加する**

`roles/homebrew/tasks/main.yaml` の `homebrew_taps` に 1 行足す。既存の `brew trust --tap` ループがそのまま新しい tap にも適用される。

```yaml
- name: define homebrew taps
  ansible.builtin.set_fact:
    homebrew_taps:
      - name: fluxcd/tap
      - name: tracer-cloud/tap
```

- [ ] **Step 4: ansible に package を追加する**

一覧は表示名のアルファベット順（`fluxcd/tap/flux` は "flux" として f の位置にある）。`opensre` は `opentofu` の直前に入る。

```yaml
      - nodenv                  # Node.js version manager
      - tracer-cloud/tap/opensre # AI SRE agent framework for incident investigation
      - opentofu                # Open-source Terraform-compatible IaC tool
```

- [ ] **Step 5: ansible を適用して CLI が入ることを確認する**

```bash
cd /Users/takanokenichi/GitHub/panicboat/ansible
export HOMEBREW_NO_REQUIRE_TAP_TRUST=1
ansible-playbook playbook.yaml -i inventory.ini
which opensre
```

期待: `opensre` のパスが出力される。

`HOMEBREW_NO_REQUIRE_TAP_TRUST=1` は既存の手順に含まれている環境変数で、third-party tap の追加に必要になる。

- [ ] **Step 6: OpenSRE を Bedrock で設定する**

```bash
opensre onboard
```

対話で LLM provider に `bedrock` を選ぶ。`AWS_REGION` は `ap-northeast-1`、model は Step 1 で決めたものを指定する。この時点では既存の admin credential をそのまま使う（専用 role は Task 2 で作る）。

- [ ] **Step 7: REPL で疎通を確認する（GATE）**

```bash
opensre
```

REPL で `/status` を実行し、続けて `Kubernetes とは何か一言で` のようなクラスタ非依存の質問を投げる。

期待: `/status` が provider と model を表示し、質問に応答が返る。

**このステップが通らなかった場合**: 失敗内容を design doc の末尾に `## Evaluation result` として記録し、`ansible` の変更を revert して**評価を終了する**。Task 2 以降には進まない。

- [ ] **Step 8: ansible の変更を commit する**

```bash
cd /Users/takanokenichi/GitHub/panicboat/ansible
git add roles/homebrew/tasks/main.yaml
git commit -s -m "feat(homebrew): add opensre CLI via tracer-cloud tap"
```

---

### Task 2: 専用 read-only IAM role と EKS access entry

**Files:**
- Create: `aws/eks/modules/iam_opensre.tf`
- Modify: `aws/eks/modules/access_entries.tf:14-27`（`locals.access_entries` に 1 エントリ追加）

**Interfaces:**
- Consumes: Task 1 Step 1 で控えた Bedrock model ARN
- Produces: IAM role `opensre-investigator-production`。その ARN を Task 4 で `AWS_ROLE_ARN` として OpenSRE に渡す

- [ ] **Step 1: 現状で Secret が読めることを確認する（後で対比するため）**

```bash
eks-login
kubectl auth can-i get secrets --all-namespaces
```

期待: `yes`。admin credential なので読める。Task 2 完了後に専用 role で同じ確認をして `no` になることを見る。

- [ ] **Step 2: `iam_opensre.tf` を作成する**

`iam_admin.tf` と同じ形にする。`data "aws_caller_identity" "current"` は `iam_admin.tf` で既に宣言済みなので再宣言しない。

`<INFERENCE_PROFILE_ARN>` と `<FOUNDATION_MODEL_ARN>` は Task 1 Step 1 で控えた値に置き換える。inference profile を使う場合、profile 自体と参照先 foundation model の両方を列挙する必要がある。

```hcl
# iam_opensre.tf - IAM role for the OpenSRE evaluation (read-only investigation).
#
# OpenSRE runs as a local CLI and assumes this role for two purposes: reading
# the cluster through the Kubernetes API (RBAC granted via Access Entry, see
# access_entries.tf) and invoking Bedrock for inference. Keeping both on one
# role is what lets the evaluation run without storing a long-lived API key.
#
# Bedrock resources are enumerated rather than wildcarded because per-model
# pricing differs by more than an order of magnitude; a misconfigured model in
# OpenSRE fails at IAM instead of on the invoice.
#
# Trust policy mirrors iam_admin.tf: it delegates to the account root, and the
# actual assume permission is governed on the user side outside this repository.

resource "aws_iam_role" "opensre_investigator" {
  name                 = "opensre-investigator-${var.environment}"
  max_session_duration = 3600
  tags                 = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "opensre_describe_cluster" {
  name = "eks-describe-cluster"
  role = aws_iam_role.opensre_investigator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/eks-${var.environment}"
      }
    ]
  })
}

resource "aws_iam_role_policy" "opensre_bedrock_invoke" {
  name = "bedrock-invoke"
  role = aws_iam_role.opensre_investigator.id

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
          "<INFERENCE_PROFILE_ARN>",
          "<FOUNDATION_MODEL_ARN>",
        ]
      }
    ]
  })
}
```

- [ ] **Step 3: `access_entries.tf` にエントリを追加する**

既存の `human_admin` の下に足す。冒頭コメントの「minimal に保つ」方針が変わるため、その理由も併せて書く。

```hcl
locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    # OpenSRE evaluation. An LLM agent reasons over this cluster, so it gets a
    # separate principal with view-only RBAC rather than reusing the admin
    # role: the blast radius of a misbehaving agent is then bounded by IAM
    # rather than by the agent's own restraint.
    opensre = {
      principal_arn = aws_iam_role.opensre_investigator.arn

      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

- [ ] **Step 4: plan の差分を確認する**

`aws/eks` は cluster の中核 stack なので、意図しない差分が無いことを apply 前に確認する。

```bash
cd aws/eks/envs/production
terragrunt plan
```

期待: `aws_iam_role.opensre_investigator`、`aws_iam_role_policy.opensre_describe_cluster`、`aws_iam_role_policy.opensre_bedrock_invoke` の 3 つが追加され、EKS cluster の access entry が 1 つ増えるだけ。cluster 本体・node group・network の差分が出ていたら**apply せず中断して原因を調べる**。

- [ ] **Step 5: apply する**

```bash
terragrunt apply
```

- [ ] **Step 6: role を引き受けられることを確認する**

```bash
ROLE_ARN=$(aws iam get-role --role-name opensre-investigator-production --query 'Role.Arn' --output text)
echo "${ROLE_ARN}"
aws sts assume-role --role-arn "${ROLE_ARN}" --role-session-name opensre-check \
  --query 'Credentials.AccessKeyId' --output text
```

期待: role ARN と一時 AccessKeyId が出力される。

- [ ] **Step 7: 引き受けた credential で読めることを確認する**

```bash
eval "$(aws sts assume-role --role-arn "${ROLE_ARN}" --role-session-name opensre-check \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text \
  | awk '{print "export AWS_ACCESS_KEY_ID="$1"\nexport AWS_SECRET_ACCESS_KEY="$2"\nexport AWS_SESSION_TOKEN="$3}')"
aws eks update-kubeconfig --name eks-production --region ap-northeast-1 --alias opensre-view
kubectl --context opensre-view get pod -A | head
```

期待: Pod 一覧が返る。

- [ ] **Step 8: Secret が読めないことを確認する**

design doc の唯一の未確認仮定を潰すステップ。

```bash
kubectl --context opensre-view auth can-i get secrets --all-namespaces
kubectl --context opensre-view get secret -A
```

期待: `no` と Forbidden エラー。

**`yes` が返った場合**: `AmazonEKSViewPolicy` の想定が誤っている。access entry の `policy_associations` を外し、Secret を除外した自前 ClusterRole + ClusterRoleBinding を `kubernetes/components/` 側に作って access entry は RBAC マップのみにする方式へ切り替える。切り替えたら Step 7 と Step 8 を再実行する。

- [ ] **Step 9: 検証で汚れた環境を戻して commit する**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-opensre-evaluation
git add aws/eks/modules/iam_opensre.tf aws/eks/modules/access_entries.tf
git commit -s -m "feat(aws/eks): add read-only IAM role for OpenSRE evaluation"
```

---

### Task 3: 故障 sandbox component

**Files:**
- Create: `kubernetes/components/sandbox/production/namespace.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/backend.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/frontend.yaml`

**Interfaces:**
- Produces: `sandbox` namespace に `backend`（CrashLoopBackOff）と `frontend`（接続エラーを出し続ける）。Task 5 の調査対象

- [ ] **Step 1: `namespace.yaml` を作成する**

`kubernetes/manifests/production/00-namespaces/namespaces.yaml` に集約されるファイル。既存 namespace のコメント形式に合わせる。

```yaml
# =============================================================================
# sandbox Namespace
# =============================================================================
# OpenSRE 評価用 namespace。原因が既知の障害を持つ workload を 2 つ持ち、
# 調査レポートの採点対象にする。評価が終わったら component ごと削除する。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: sandbox
  labels:
    app.kubernetes.io/name: sandbox
```

- [ ] **Step 2: `backend.yaml` を作成する**

memory limit を超えるまでメモリを確保し続け、OOMKilled → CrashLoopBackOff に入る。HTTP は別スレッドで応答するため、落ちるまでの間は正常に見える。

`python -c` を使い、外部パッケージにも `wget` / `curl` の有無にも依存させない。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  labels:
    app.kubernetes.io/name: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: backend
  template:
    metadata:
      labels:
        app.kubernetes.io/name: backend
    spec:
      containers:
        - name: backend
          image: python:3.13-slim
          # =================================================================
          # 意図的な memory leak。8 MiB ずつ確保し limits.memory を超えた
          # 時点で OOMKilled になる。HTTP 応答は daemon thread で返すため、
          # 落ちるまでは frontend から正常に見える。
          #
          # sleep を挟むのは即死を避けるため。起動直後に落ちると Endpoints に
          # 一度も載らず、「backend が一時的に応答していた」という痕跡が
          # metrics に残らない。
          # =================================================================
          command:
            - python
            - -u
            - -c
            - |
              import http.server, socketserver, threading, time

              class Handler(http.server.BaseHTTPRequestHandler):
                  def do_GET(self):
                      self.send_response(200)
                      self.send_header("Content-Type", "text/plain")
                      self.end_headers()
                      self.wfile.write(b"backend ok\n")

                  def log_message(self, *args):
                      pass

              socketserver.TCPServer.allow_reuse_address = True
              server = socketserver.TCPServer(("", 8080), Handler)
              threading.Thread(target=server.serve_forever, daemon=True).start()
              print("backend: serving on 8080", flush=True)

              blob = []
              while True:
                  blob.append(bytearray(8 * 1024 * 1024))
                  print(f"backend: allocated {len(blob) * 8} MiB", flush=True)
                  time.sleep(5)
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  labels:
    app.kubernetes.io/name: backend
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: backend
  ports:
    - name: http
      port: 8080
      targetPort: http
```

- [ ] **Step 3: `frontend.yaml` を作成する**

backend を 1 秒ごとに叩き、成否を stdout に出す。stdout は Loki に入るため、調査時の「症状」の入口になる。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app.kubernetes.io/name: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: frontend
  template:
    metadata:
      labels:
        app.kubernetes.io/name: frontend
    spec:
      containers:
        - name: frontend
          image: python:3.13-slim
          # =================================================================
          # backend の障害を「上流から見える症状」に変換するだけの workload。
          # 例外の型ではなくメッセージを出すのは、調査側に原因を先出ししない
          # ため。ここで OOMKilled と書いてしまうと採点が成立しない。
          # =================================================================
          command:
            - python
            - -u
            - -c
            - |
              import time, urllib.request

              while True:
                  try:
                      with urllib.request.urlopen("http://backend:8080/", timeout=2) as response:
                          response.read()
                      print("frontend: request ok", flush=True)
                  except Exception as error:
                      print(f"frontend: request failed: {error}", flush=True)
                  time.sleep(1)
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
```

- [ ] **Step 4: `kustomization.yaml` を作成する**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: sandbox

resources:
  - backend.yaml
  - frontend.yaml
```

- [ ] **Step 5: ローカルで hydrate して生成物を確認する**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-opensre-evaluation
./scripts/kubernetes-hydrate/hydrate-component.sh sandbox production
./scripts/kubernetes-hydrate/hydrate-index.sh production
git status --short
```

期待: `kubernetes/manifests/production/sandbox/` が生成され、`kubernetes/manifests/production/00-namespaces/namespaces.yaml` に sandbox が追記され、`kubernetes/manifests/production/kustomization.yaml` に sandbox が加わる。

- [ ] **Step 6: 生成された manifest を目視確認する**

```bash
command grep -nE "memory|name: (backend|frontend)" kubernetes/manifests/production/sandbox/manifest.yaml
```

期待: backend の `limits.memory: 64Mi` と frontend の定義が含まれる。python のコードブロックが YAML として壊れていないこと。

- [ ] **Step 7: commit して push する**

```bash
git add kubernetes/components/sandbox kubernetes/manifests/production
git commit -s -m "feat(kubernetes): add fault-injected sandbox for OpenSRE evaluation"
git push
```

- [ ] **Step 8: Flux が同期して意図した状態になることを確認する**

PR をマージしたあと（または `flux reconcile` で）同期を待つ。

```bash
eks-login
flux reconcile kustomization flux-system --with-source
kubectl -n sandbox get deploy,pod
```

期待: `frontend` が Ready、`backend` の Pod が `CrashLoopBackOff` かつ RESTARTS が増え続ける。

- [ ] **Step 9: 三層の痕跡が実際に残っていることを確認する**

採点の前提が成立しているかの確認。ここが欠けていると OpenSRE が正解に到達できなくても評価にならない。

```bash
# 症状
kubectl -n sandbox logs deploy/frontend --tail=5
# 中間
kubectl -n sandbox get endpoints backend
# 根本
kubectl -n sandbox describe pod -l app.kubernetes.io/name=backend | command grep -A2 "Last State"
```

期待: frontend のログに `request failed`、backend の Endpoints が空、`Last State: Terminated` の `Reason: OOMKilled`。

---

### Task 4: Grafana service account と OpenSRE の接続設定

**Files:**
- 変更なし。Grafana の service account はこのタスクの Step 1 で UI から手動発行し、OpenSRE 側の設定は CLI が管理する

**Interfaces:**
- Consumes: Task 2 の `opensre-investigator-production` role ARN、Task 3 の sandbox
- Produces: Kubernetes と Grafana に接続済みの OpenSRE。Task 5 で調査を実行する

- [ ] **Step 1: Grafana に Viewer の service account を作る**

Grafana は `auto_assign_org_role: Admin` なので、既定に任せず **明示的に Viewer を選ぶ**。

ブラウザで Grafana を開き、Administration → Users and access → Service accounts → Add service account。名前を `opensre-readonly`、role を `Viewer` にして作成し、Add service account token でトークンを発行して控える。

- [ ] **Step 2: Grafana へ port-forward する**

oauth2-proxy を迂回して Service に直結する。別ターミナルで実行し、以降のステップの間つないだままにする。

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

- [ ] **Step 3: トークンで API が通ることを確認する**

```bash
curl -s -H "Authorization: Bearer <Step 1 のトークン>" http://localhost:3000/api/datasources \
  | jq -r '.[] | "\(.uid)\t\(.type)\t\(.name)"'
```

期待: Mimir / Loki / Tempo の datasource が uid 付きで一覧される。ここで得た Loki と Tempo の uid を Step 4 で使う。

- [ ] **Step 4: OpenSRE の integration を設定する**

```bash
opensre integrations setup
```

対話で以下を設定する。

| 項目 | 値 |
|---|---|
| `AWS_ROLE_ARN` | Task 2 Step 6 の role ARN |
| `AWS_REGION` | `ap-northeast-1` |
| `KUBECONFIG_CONTEXT` | `opensre-view`（Task 2 Step 7 で作った alias） |
| `GRAFANA_INSTANCE_URL` | `http://localhost:3000` |
| `GRAFANA_READ_TOKEN` | Step 1 のトークン |
| `GRAFANA_LOKI_DATASOURCE_UID` | Step 3 の Loki uid |
| `GRAFANA_TEMPO_DATASOURCE_UID` | Step 3 の Tempo uid |

- [ ] **Step 5: OpenSRE から接続が見えることを確認する**

```bash
opensre
```

REPL で `/integrations list` を実行する。

期待: Kubernetes と Grafana が接続済みとして表示される。

---

### Task 5: 調査の実行と採点

**Files:**
- Modify: `docs/superpowers/specs/2026-08-10-opensre-phase1-evaluation-design.md`（末尾に `## Evaluation result` を追記）

**Interfaces:**
- Consumes: Task 3 の sandbox、Task 4 の接続設定

- [ ] **Step 1: 原因を示唆しない指示で調査させる**

指示に `backend`、`memory`、`OOM` を含めない。含めると採点が成立しない。

```bash
opensre
```

REPL に次を入力する。

```
sandbox namespace の frontend でエラーが発生している。調査して根本原因を報告してほしい。
```

- [ ] **Step 2: レポート全文と消費コストを記録する**

REPL の出力を控える。続けて `/cost` を実行し、この調査に要した LLM 課金を記録する。

- [ ] **Step 3: 採点する**

design doc の Grading criteria に照らす。

合格: 根本原因を **backend の memory limit 不足による OOMKill** と特定し、根拠として観測データを引用している。

不合格: 症状の記述で止まる / ネットワークや DNS の障害と誤診する / CrashLoopBackOff に言及するが memory limit と結びつけない。

- [ ] **Step 4: 追加の観点を確認する**

採点結果に関わらず記録する。採否判断の材料になる。

- どのデータソースを実際に引きに行ったか（Kubernetes API のみか、Loki / Mimir も使ったか）
- 調査に要した時間と `/cost` の金額
- 誤った断定をしたか、不確実性を表明したか
- read-only 権限で不足した操作があったか

- [ ] **Step 5: 結果を design doc に追記する**

`docs/superpowers/specs/2026-08-10-opensre-phase1-evaluation-design.md` の末尾に `## Evaluation result` を追加する。okteto 評価の spec と同じく、**判断（採用 / 不採用）とその根拠**を明記する。Step 4 の観点も含める。

- [ ] **Step 6: commit して push する**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-opensre-evaluation
git add docs/superpowers/specs/2026-08-10-opensre-phase1-evaluation-design.md
git commit -s -m "docs(superpowers): record OpenSRE Phase 1 evaluation result"
git push
```

---

### Task 6: 撤退または定着

Task 5 の判断に応じて分岐する。**どちらか一方だけを実行する。**

**Files:**
- 不採用の場合 — Delete: `kubernetes/components/sandbox/`、Delete: `aws/eks/modules/iam_opensre.tf`、Modify: `aws/eks/modules/access_entries.tf`
- 採用の場合 — Modify: `kubernetes/components/sandbox/`（削除）のみ

- [ ] **Step 1: sandbox を削除する（分岐によらず必ず実行）**

故障 workload を production に残さない。採用する場合も sandbox は評価専用であり不要になる。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-opensre-evaluation
rm -rf kubernetes/components/sandbox
./scripts/kubernetes-hydrate/hydrate-index.sh production
rm -rf kubernetes/manifests/production/sandbox
git add -A kubernetes/
git commit -s -m "chore(kubernetes): remove OpenSRE evaluation sandbox"
```

- [ ] **Step 2: 不採用の場合のみ — IAM role と access entry を削除する**

```bash
rm aws/eks/modules/iam_opensre.tf
# access_entries.tf の locals から opensre エントリを削除する
cd aws/eks/envs/production && terragrunt plan
```

plan が role 3 リソースと access entry 1 件の削除だけであることを確認してから apply する。

- [ ] **Step 3: 不採用の場合のみ — ローカル側を戻す**

```bash
kubectl config delete-context opensre-view
brew uninstall opensre
brew untap tracer-cloud/tap
```

`ansible` 側の変更も revert する（tap 定義と package 一覧から該当行を削除）。Grafana の service account は UI から削除する。

- [ ] **Step 4: 採用の場合のみ — Phase 2 の起点を記録する**

design doc の `## Evaluation result` に、Phase 2 で解くべき課題を追記する。

- Alertmanager receiver をどう設計するか（現状 receiver は未設定）
- 無人調査に必要な常駐プロセスをどこに置くか（daily release への追従方法を含む）
- read-only を維持するか、remediation を許すか

- [ ] **Step 5: push して PR を Ready にする**

```bash
git push
gh pr ready
```

---

## Verification Summary

design doc の Verification 表と本 plan のステップの対応。

| design doc 手順 | plan のステップ |
|---|---|
| 1. CLI 起動 | Task 1 Step 5, 7 |
| 2. Bedrock 疎通 | Task 1 Step 7 |
| 3. assume-role | Task 2 Step 6 |
| 4. Pod 一覧取得 | Task 2 Step 7 |
| 5. Secret 拒否 | Task 2 Step 8 |
| 6. Flux 同期 | Task 3 Step 8 |
| 7. frontend ログ | Task 3 Step 9 |
| 8. Grafana datasource proxy | Task 4 Step 3 |
| 9. 調査実行 | Task 5 Step 1 |
| 10. 撤退 | Task 6 Step 1 |
