# Okteto CLI Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Okteto OSS CLI をローカルに導入し、EKS production cluster の `sandbox` namespace で `okteto up` による Deployment 差し替えが Flux の drift correction と共存できるかを判定する。

**Architecture:** `ansible` に CLI を追加してインストールする。`platform` には `kubernetes/components/sandbox/production/` を新規 component として追加し、差し替え対象の Deployment と okteto manifest と同期対象ソースを同居させる。Deployment に `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` を付けて Flux の drift correction を止め、`okteto up` 中に Flux を二回 reconcile させて開発コンテナが生き残るかを確認する。

**Tech Stack:** Okteto CLI (homebrew-core) / Kubernetes Deployment + Service / Kustomize v5.6.0 / Flux GitOps (kustomize-controller SSA policy) / Python 公式イメージ slim variant / Ansible + Homebrew

**Spec:** `docs/superpowers/specs/2026-08-08-okteto-cli-evaluation-design.md`

**Worktree branch:** `feat/okteto-cli-evaluation` (= `.claude/worktrees/feat-okteto-cli-evaluation/`)

## Global Constraints

- コミットは必ず `-s`（`--signoff`）を付ける。`Co-Authored-By` を付与しない
- 新規ブランチの初回 push は `git push -u origin HEAD` でトラッキングを設定する
- PR は `gh pr create --draft` で作成する。Draft 以外で作らない。タイトルは英語で書く
- `ansible` と `platform` の 2 repo とも worktree で作業する。ディレクトリは `.claude/worktrees/<branch の / を - に置換した名前>`
- `platform` でローカル hydrate を実行する前に `AQUA_CONFIG` を export する。設定しないと CI が空行だけの hydrate commit を積む
- コード内の要素（変数名、コマンド、コメント）は英語。ドキュメント本文は日本語
- 検証結果を報告するときは VERIFIED（実行して確認、コマンドと出力を添える）と REASONED（コード読解による推論）を区別する

---

### Task 1: Install the okteto CLI via ansible

**Files:**
- Modify: `~/GitHub/panicboat/ansible/roles/homebrew/tasks/main.yaml:57-58`（`nodenv` と `opentofu` の間）

**Interfaces:**
- Produces: PATH 上の `okteto` コマンド。Task 5 が使う

`okteto` は homebrew-core にある。tap の追加は不要。

- [ ] **Step 1: ansible の worktree を作る**

```bash
cd ~/GitHub/panicboat/ansible
git fetch origin main
git worktree add -b feat/okteto-cli .claude/worktrees/feat-okteto-cli origin/main
cd .claude/worktrees/feat-okteto-cli
```

- [ ] **Step 2: 追加位置がアルファベット順で正しいことを確認する**

Run:
```bash
grep -n -E '^\s+- (nodenv|opentofu)' roles/homebrew/tasks/main.yaml
```
Expected: `nodenv` の行番号が `opentofu` の行番号より 1 小さい。この 2 行の間が `okteto` の挿入位置になる。

- [ ] **Step 3: パッケージ配列に okteto を追加する**

`roles/homebrew/tasks/main.yaml` の `nodenv` 行の直後に 1 行足す。既存行のコメント開始カラムに揃える。

Before:
```yaml
      - nodenv                  # Node.js version manager
      - opentofu                # Open-source Terraform-compatible IaC tool
```

After:
```yaml
      - nodenv                  # Node.js version manager
      - okteto                  # Develop and test code directly in Kubernetes
      - opentofu                # Open-source Terraform-compatible IaC tool
```

- [ ] **Step 4: 実際にインストールする**

Run:
```bash
brew install okteto
```
Expected: インストールが完了する。すでに入っている場合は「already installed」と出るのでそのまま次へ。

- [ ] **Step 5: CLI が動くことを確認する**

Run:
```bash
okteto version
```
Expected: バージョン文字列が出力される。エラー終了しないこと。

- [ ] **Step 6: OSS ビルドで利用できるコマンドを確認する**

Run:
```bash
okteto --help
```
Expected: `up`、`down`、`context` が一覧に出る。この 3 つが OSS CLI の対象範囲であり、他のコマンドが出ていても Platform 無しでは機能しない。

- [ ] **Step 7: コミットする**

```bash
git add roles/homebrew/tasks/main.yaml
git commit -s -m "feat(homebrew): add okteto CLI"
```

- [ ] **Step 8: push して Draft PR を作る**

```bash
git push -u origin HEAD
gh pr create --draft --title "feat(homebrew): add okteto CLI" --body "$(cat <<'BODY'
Kubernetes 上の開発 inner loop を評価するため、Okteto OSS CLI を homebrew の
パッケージ一覧に追加する。CLI は cluster 側へのインストールを必要とせず、
kubeconfig だけで動く。

評価設計: panicboat/platform の docs/superpowers/specs/2026-08-08-okteto-cli-evaluation-design.md
BODY
)"
```

---

### Task 2: Add zsh completion for okteto (REMOVED)

このタスクは実行しない。Task 1 の実測で不要と判明したため、人間の裁定により削除した。

`brew install okteto` は `_okteto` を `/opt/homebrew/share/zsh/site-functions/` に配置し、`.zshrc:56` は既にそのディレクトリを FPATH に入れている。`.zshrc` を無変更のまま `zsh -i -c` で `$_comps[okteto]` が解決することを確認済みである。当初の条件は「`okteto completion zsh` が存在しなければ取り下げる」だったが、実際は「存在するが不要」だった。

番号は ledger との対応を保つため振り直さない。

---

### Task 3: Create the sandbox component

**Files:**
- Create: `kubernetes/components/sandbox/production/namespace.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/deployment.yaml`
- Create: `kubernetes/components/sandbox/production/kustomization/service.yaml`
- Create: `kubernetes/components/sandbox/production/okteto.yml`
- Create: `kubernetes/components/sandbox/production/app/index.html`
- Generated: `kubernetes/manifests/production/sandbox/{manifest.yaml,kustomization.yaml}`
- Generated: `kubernetes/manifests/production/00-namespaces/namespaces.yaml`
- Generated: `kubernetes/manifests/production/kustomization.yaml`

**Interfaces:**
- Produces: namespace `sandbox`、Deployment `sandbox`、Service `sandbox`（ClusterIP :8080）、okteto manifest の dev key `sandbox`。Task 5 がすべて使う

作業は `platform` の既存 worktree `.claude/worktrees/feat-okteto-cli-evaluation` で行う。`hydrate-component.sh` は `helmfile.yaml` と `kustomization/` だけを読み、`hydrate-index.sh` は `namespace.yaml` だけを読む。したがって `okteto.yml` と `app/` は生成物に混入しない。

- [ ] **Step 1: namespace.yaml を作る**

```yaml
# =============================================================================
# sandbox Namespace
# =============================================================================
# okteto CLI の評価用 namespace。okteto up が development container に差し替える
# 対象の workload を 1 つだけ持つ。評価が終わったら component ごと削除する。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: sandbox
  labels:
    app.kubernetes.io/name: sandbox
```

- [ ] **Step 2: kustomization/kustomization.yaml を作る**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: sandbox

resources:
  - deployment.yaml
  - service.yaml
```

- [ ] **Step 3: kustomization/deployment.yaml を作る**

配信する `index.html` は起動コマンドが生成する。Pod に volume を持たせないのは、okteto が sync 先ディレクトリに自前の volume を mount するため、同じパスに別の volume があると衝突しうるからである。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sandbox
  labels:
    app.kubernetes.io/name: sandbox
  annotations:
    # =========================================================================
    # okteto up は対象 Deployment を 0 replica にし、development container を
    # 持つ複製を別名で作る。default の SSA policy (= Override) では Flux が
    # これを drift として毎 reconcile で戻すため、okteto が成立しない。
    #
    # Flux Kustomization の suspend は使えない。root は clusters/production の
    # 単一 Kustomization であり、suspend すると platform stack 全体が止まる。
    # ssa: Ignore も使えない。apply 自体を飛ばすため対象 Deployment が作られない。
    #
    # 副作用: 以後この manifest を変更しても Flux は反映しない。変更したい場合は
    # kubectl delete して Flux に再作成させる。
    # =========================================================================
    kustomize.toolkit.fluxcd.io/ssa: IfNotPresent
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: sandbox
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sandbox
    spec:
      containers:
        - name: sandbox
          image: python:3.13-slim
          command:
            - sh
            - -c
            - |
              mkdir -p /app
              printf '<!doctype html>\n<h1>sandbox: cluster</h1>\n' > /app/index.html
              exec python -m http.server 8080 --directory /app
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
```

- [ ] **Step 4: kustomization/service.yaml を作る**

selector は Deployment の pod label と同じにする。okteto の複製 pod も同じ label を継ぐため、`port-forward svc/sandbox` が差し替え後もそのまま届く。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sandbox
  labels:
    app.kubernetes.io/name: sandbox
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: sandbox
  ports:
    - name: http
      port: 8080
      targetPort: http
```

- [ ] **Step 5: okteto.yml を作る**

```yaml
# =============================================================================
# Okteto manifest for the sandbox evaluation
# =============================================================================
# dev の key (= sandbox) は差し替え対象の Deployment 名と一致させる。
# sync は "<local>:<remote>" 形式で、okteto.yml から見た相対パス app/ を
# development container の /app へ同期する。
#
# autocreate は指定しない。既存 Deployment の差し替えが評価対象であり、
# autocreate を有効にすると Deployment が無くても動いてしまい検証にならない。
# =============================================================================
dev:
  sandbox:
    image: python:3.13-slim
    command:
      - python
      - -m
      - http.server
      - "8080"
      - --directory
      - /app
    workdir: /app
    sync:
      - app:/app
```

- [ ] **Step 6: app/index.html を作る**

```html
<!doctype html>
<h1>sandbox: local</h1>
```

- [ ] **Step 7: kustomize build が通ることを確認する**

Run:
```bash
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
kustomize build kubernetes/components/sandbox/production/kustomization
```
Expected: Deployment と Service の 2 つの manifest が出力される。どちらも `namespace: sandbox` を持つ。エラーが出ないこと。

- [ ] **Step 8: hydrate 前にツールのバージョンを確認する**

Run:
```bash
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
helm version --template '{{.Version}}'
```
Expected: `v3.17.3`。異なる場合は `AQUA_CONFIG` の export が効いていない。そのまま hydrate すると CI が空行だけの差分で余分な commit を積む。

- [ ] **Step 9: hydrate を実行する**

Run:
```bash
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
./scripts/kubernetes-hydrate/hydrate-component.sh sandbox production
./scripts/kubernetes-hydrate/hydrate-index.sh production
```
Expected: エラー無く終了する。

- [ ] **Step 10: 生成物を確認する**

Run:
```bash
git status --porcelain
grep -n 'sandbox' kubernetes/manifests/production/kustomization.yaml
grep -c 'name: sandbox' kubernetes/manifests/production/00-namespaces/namespaces.yaml
grep -n 'kustomize.toolkit.fluxcd.io/ssa' kubernetes/manifests/production/sandbox/manifest.yaml
```
Expected:
- `kubernetes/manifests/production/sandbox/` 配下に `manifest.yaml` と `kustomization.yaml` が新規追加されている
- `kustomization.yaml` に `- ./sandbox` の行がある
- `namespaces.yaml` に `name: sandbox` が 1 件ある
- `manifest.yaml` に `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` が残っている
- 上記以外の component の manifest に差分が出ていない

最後の項目が満たされない場合、`AQUA_CONFIG` の設定漏れを疑う。`git checkout -- kubernetes/manifests/production/<該当 component>` で戻してから Step 8 をやり直す。

- [ ] **Step 11: コミットする**

```bash
git add kubernetes/components/sandbox kubernetes/manifests/production
git commit -s -m "feat(kubernetes/components/sandbox): add okteto evaluation sandbox"
```

---

### Task 4: Deploy the sandbox to production

**Files:** なし（PR 操作のみ）

**Interfaces:**
- Consumes: Task 3 がコミットした component と生成物
- Produces: cluster 上で Ready な Deployment `sandbox`。Task 5 が使う

このタスクは production cluster に変更を入れる。Step 4 のマージはユーザーの明示的な承認を得てから実行する。

- [ ] **Step 1: push して Draft PR を作る**

```bash
git push -u origin HEAD
gh pr create --draft --title "feat(kubernetes): add sandbox for okteto CLI evaluation" --body "$(cat <<'BODY'
Okteto OSS CLI が Flux 管理下の workload に使えるかを判定するための sandbox を
追加する。

okteto up は対象 Deployment を 0 replica にして development container の複製を
作る。Flux の default SSA policy ではこれが drift として毎 reconcile で戻される
ため、Deployment に ssa: IfNotPresent を付けて resource 単位で drift correction を
外した。root が単一 Kustomization であり Kustomization ごとの suspend が使えない
ことによる。

評価設計: docs/superpowers/specs/2026-08-08-okteto-cli-evaluation-design.md
BODY
)"
```

- [ ] **Step 2: CI が通ることを確認する**

Run:
```bash
gh pr checks --watch
```
Expected: 全 check が pass する。hydrate 済みなので hydrator が追加 commit を積まないこと。積まれた場合は Task 3 Step 8 の環境変数設定を確認する。

- [ ] **Step 3: PR を Ready にする**

```bash
gh pr ready
```

- [ ] **Step 4: マージする**

ユーザーに「production cluster に sandbox を反映してよいか」を確認し、承認を得てから実行する。

```bash
gh pr merge --squash
```

- [ ] **Step 5: Flux に同期させる**

Run:
```bash
flux reconcile kustomization flux-system --with-source
```
Expected: `Kustomization reconciliation completed` が出力される。

- [ ] **Step 6: Deployment が Ready になることを確認する**

Run:
```bash
kubectl -n sandbox rollout status deploy/sandbox --timeout=180s
kubectl -n sandbox get deploy,svc,pod
```
Expected: Deployment が `1/1`、Service `sandbox` が ClusterIP で存在し、Pod が Running。

---

### Task 5: Verify okteto against the Flux-managed workload

**Files:**
- Modify: `kubernetes/components/sandbox/production/app/index.html`（Step 6 で編集し、Step 11 で元に戻す）

**Interfaces:**
- Consumes: Task 1 の `okteto` コマンド、Task 4 でデプロイした Deployment `sandbox`

成功基準は Step 8 が通ることである。ここが落ちた場合、Flux 管理下の workload に okteto を使えないという結論になり、その事実自体が評価の成果になる。以降の Step は結論に関わらず最後まで実行し、結果を記録する。

- [ ] **Step 1: cluster への認証を通す**

Run:
```bash
eks-login
kubectl config current-context
```
Expected: production cluster の context 名が出力される。

- [ ] **Step 2: okteto に context を設定する**

Run:
```bash
cd kubernetes/components/sandbox/production
okteto context use "$(kubectl config current-context)"
okteto context list
```
Expected: 現在の kube context が okteto の context として選択済みになる。

- [ ] **Step 3: 差し替え前のレスポンスを確認する**

別ターミナルで port-forward を張る。
```bash
kubectl -n sandbox port-forward svc/sandbox 8080:8080
```

元のターミナルで:
```bash
curl -s localhost:8080
```
Expected: `<h1>sandbox: cluster</h1>` を含む HTML が返る。

- [ ] **Step 4: okteto up を実行する**

Run（フォアグラウンドで動き続けるので別ターミナルで実行する）:
```bash
cd kubernetes/components/sandbox/production
okteto up -n sandbox
```
Expected: 同期が完了し、development container の shell プロンプトに入る。

- [ ] **Step 5: Deployment がどう変わったかを記録する**

Run:
```bash
kubectl -n sandbox get deploy -o wide
kubectl -n sandbox get pvc
```
Expected: 元の `sandbox` が 0 replica になり、開発コンテナ用の Deployment が別名で存在する。PVC が 1 つ作られている。実際の名前とサイズを控える。

- [ ] **Step 6: 差し替え後のレスポンスを確認する**

port-forward を張り直してから:
```bash
kubectl -n sandbox port-forward svc/sandbox 8080:8080
```

```bash
curl -s localhost:8080
```
Expected: `<h1>sandbox: local</h1>` が返る。ローカルの `app/index.html` が配信されている。

Service の selector が複製 pod に届かず接続できない場合は、`kubectl -n sandbox port-forward deploy/<複製 Deployment 名> 8080:8080` に切り替える。この場合「Service 経由では届かない」ことを結果として記録する。

- [ ] **Step 7: 編集が即座に反映されることを確認する**

`app/index.html` を次のように書き換える。

```html
<!doctype html>
<h1>sandbox: edited</h1>
```

Run:
```bash
curl -s localhost:8080
```
Expected: `<h1>sandbox: edited</h1>` が返る。再ビルドも再デプロイもしていないこと。

- [ ] **Step 8: Flux の reconcile を跨いで生き残ることを確認する（成功基準）**

Run:
```bash
flux reconcile kustomization flux-system --with-source
sleep 10
flux reconcile kustomization flux-system --with-source
kubectl -n sandbox get deploy -o wide
curl -s localhost:8080
```
Expected: 元の `sandbox` が 0 replica のまま、複製 Deployment が Ready のまま。`curl` が `<h1>sandbox: edited</h1>` を返す。

元の Deployment が 1 replica に戻され複製が消えていたら、`ssa: IfNotPresent` が効いていない。`kubectl -n sandbox get deploy sandbox -o jsonpath='{.metadata.annotations}'` で annotation が付いているかを確認し、結果を記録する。

- [ ] **Step 9: okteto down で復元されることを確認する**

`okteto up` のターミナルで `exit` して抜けてから:
```bash
cd kubernetes/components/sandbox/production
okteto down -n sandbox -v
kubectl -n sandbox get deploy,pvc
kubectl -n sandbox rollout status deploy/sandbox --timeout=120s
```
Expected: 複製 Deployment が消え、`sandbox` が 1/1 に戻る。`-v` を付けたので PVC も消えている。

- [ ] **Step 10: 復元後のレスポンスを確認する**

port-forward を張り直してから:
```bash
curl -s localhost:8080
```
Expected: `<h1>sandbox: cluster</h1>` が返る。起動コマンドが生成した内容に戻っている。

- [ ] **Step 11: 編集したファイルを元に戻す**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
git checkout -- kubernetes/components/sandbox/production/app/index.html
git status --porcelain
```
Expected: 差分が無い。

---

### Task 6: Record the evaluation result

**Files:**
- Modify: `docs/superpowers/specs/2026-08-08-okteto-cli-evaluation-design.md`（末尾に節を追加）

**Interfaces:**
- Consumes: Task 5 の各 Step で控えた実測値

- [ ] **Step 1: 結果の節を spec の末尾に追記する**

次の骨組みで書く。角括弧の箇所を Task 5 で実際に観測した内容で置き換える。観測していない項目は「未確認」と書き、推測で埋めない。

```markdown
## Evaluation result

成功基準である Flux の reconcile を跨いだ生存は [通った / 通らなかった]。
[通らなかった場合は、元の Deployment が戻された挙動と annotation の状態をここに書く]

`okteto up` は複製 Deployment を `[実際の名前]` という名前で作り、元の `sandbox` を 0 replica にした。
sync 用の PVC は `[実際の名前]` として作られ、サイズは `[実測値]` だった。
`okteto down -v` で複製と PVC の両方が消え、元の Deployment が 1 replica に戻った。

Service の selector は複製 pod に [届いた / 届かなかった]。
[届かなかった場合は、port-forward の対象を Deployment に切り替えた旨を書く]

ローカルの `app/index.html` を保存してから `curl` の出力が変わるまでは [実測した体感] だった。

判断: okteto OSS CLI を [採用する / 採用しない]。
理由は [判断の根拠]。
```

- [ ] **Step 2: 判断が採用の場合、次の一歩を書き添える**

採用する場合のみ、上の節の末尾に次を追記する。採用しない場合はこの Step を飛ばす。

```markdown
実アプリへの適用は `panicboat/monorepo` の workload が production で動くようになってから着手する。
`okteto.yml` を対象 service のディレクトリへ移し、対象 Deployment に同じ SSA policy を付ける。
```

- [ ] **Step 3: コミットする**

```bash
git add docs/superpowers/specs/2026-08-08-okteto-cli-evaluation-design.md
git commit -s -m "docs(superpowers): record okteto CLI evaluation result"
git push
```

---

### Task 7: Retire the sandbox

**Files:**
- Delete: `kubernetes/components/sandbox/`
- Generated: `kubernetes/manifests/production/` の該当分が prune される

このタスクは Task 6 で不採用と判断した場合、または採用して `okteto.yml` を `panicboat/monorepo` 側へ移した場合に実行する。採用してこのまま sandbox を残すと決めた場合は実行しない。

- [ ] **Step 1: 開発コンテナが残っていないことを確認する**

Run:
```bash
kubectl -n sandbox get deploy,pvc
```
Expected: `sandbox` Deployment だけがあり、複製と PVC が無い。残っている場合は Task 5 Step 9 の `okteto down -n sandbox -v` を先に実行する。

- [ ] **Step 2: component を削除して hydrate する**

Run:
```bash
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
rm -rf kubernetes/components/sandbox
./scripts/kubernetes-hydrate/hydrate-index.sh production
git status --porcelain
```
Expected: `kubernetes/manifests/production/sandbox/` が削除され、`kustomization.yaml` から `- ./sandbox` が消え、`namespaces.yaml` から `sandbox` namespace が消えている。

- [ ] **Step 3: コミットして PR を出す**

```bash
git add -A kubernetes
git commit -s -m "chore(kubernetes/components/sandbox): remove okteto evaluation sandbox"
git push
```

- [ ] **Step 4: マージ後に cluster から消えたことを確認する**

ユーザーの承認を得てマージしたあと:
```bash
flux reconcile kustomization flux-system --with-source
kubectl get ns sandbox
```
Expected: `Error from server (NotFound): namespaces "sandbox" not found`。namespace ごと prune されている。

- [ ] **Step 5: 不採用の場合は CLI の導入も取り消す**

Task 6 で不採用と判断した場合のみ実行する。採用して sandbox だけを畳んだ場合は飛ばす。

`ansible` の `roles/homebrew/tasks/main.yaml` から `- okteto` の行を削除し、worktree でコミットして push する。

```bash
brew uninstall okteto
```

`_okteto` 補完は formula が同梱しているため、`brew uninstall` で一緒に消える。手で消すファイルは無い。

Task 1 の PR がまだ Draft のまま残っている場合は `gh pr close` で閉じる。
