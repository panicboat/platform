# EKS Production: Falco Runtime Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `falcosecurity/falco` chart を専用 `falco` namespace に DaemonSet deploy し、node の syscall 由来 runtime security イベントを既存 Loki に堆積させ、Grafana の LogQL で追跡できる状態を作る。

**Architecture:** Falco DaemonSet (= 1 Pod per node) を modern eBPF driver で全 node に配置し、検知イベントを JSON で stdout に出力する。既存の OpenTelemetry Collector DaemonSet が `filelog` receiver で `/var/log/pods` を tail しているため、**Falco 側に配送コンポーネント (falcosidekick) を持たず**そのまま Loki へ届く。Falco 自身の metrics は ServiceMonitor で Prometheus → Mimir に流し、eBPF ring buffer の event drop を可視化する。AWS access 不要 (= no Pod Identity / no S3 / no IAM)、kustomization overlay 不要 (= chart 範囲外 resource なし)。

**Tech Stack:** Helm + helmfile / `falcosecurity/falco` chart 9.1.0 (appVersion Falco 0.44.1) / ルールセット `falco-rules:5.1.0` (OCI artifact) / container plugin 0.7.1 (chart default) / OpenTelemetry Collector v0.151.0 (既存) / Loki SingleBinary (既存) / kube-prometheus-stack ServiceMonitor (既存) / Flux CD

**Spec:** `docs/superpowers/specs/2026-08-08-eks-production-falco-runtime-security-design.md`

---

## Global Constraints

すべての Task に暗黙的に適用される。

- **作業場所**: worktree `.claude/worktrees/feat-falco-runtime-security` / branch `feat/falco-runtime-security`。他の worktree・main で作業しない
- **chart version**: `9.1.0` を pin。`version:` に range を書かない
- **ルール version**: `falco-rules:5.1.0` を exact pin。floating tag (`falco-rules:5`) を使わない
- **namespace**: `falco` (新規作成)。`monitoring` に相乗りさせない
- **toolchain**: hydrate 実行前に `export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"` を必須で設定する。未設定だと global の helm (v4 系) が使われ、CI pin (helm v3.17.3 / helmfile v0.169.2 / kustomize v5.6.0) と空行差分が出て CI が余分な hydrate commit を積む
- **commit**: `git commit -s` (signoff) を必須。`Co-Authored-By` トレーラーを付けない
- **PR**: `gh pr create --draft` で作成する。Draft 以外で作らない。タイトルは英語
- **GitOps**: Flux 管理下のリソースを `kubectl apply/edit/delete` で直接変更しない。検証用の使い捨て Pod のみ例外 (= Flux 管理外)
- **言語**: ドキュメント本文と commit message body は日本語、見出し / コード内要素 / PR タイトルは英語

---

## File Structure

**新規作成 (component source)**:

```
kubernetes/components/falco/
├── namespace.yaml                 # falco namespace。環境非依存のため component root に置く
                                   #   (cert-manager / external-secrets / prometheus-operator と同じ配置)
└── production/
    ├── helmfile.yaml              # falcosecurity/falco 9.1.0 を pin
    └── values.yaml.gotmpl         # production config
                                   #   - driver.kind: modern_ebpf (driver-loader init container を消す)
                                   #   - leastPrivileged: true (privileged を使わない)
                                   #   - falcoctl: follow 無効 + refs を exact pin
                                   #   - json_output: true / syslog_output: false
                                   #   - tolerations 全許容 + podPriorityClassName
                                   #   - metrics + serviceMonitor
```

**自動生成 (hydrate output、手書きしない)**:

```
kubernetes/manifests/production/falco/{kustomization.yaml, manifest.yaml}   # 新規
kubernetes/manifests/production/kustomization.yaml                          # ./falco を挿入
kubernetes/manifests/production/00-namespaces/namespaces.yaml               # falco namespace を追記
```

**変更**:

```
kubernetes/README.md               # Security layer 節 + 運用コマンド + troubleshooting 行を追加
```

**変更しないファイル**: `workflow-config.yaml` (= `stack_conventions` が pattern 定義のため新規 service を自動で拾う) / `.github/renovate.json` (= helmfile manager が既定で有効) / `aws/*` (= AWS access 不要) / 他すべての `kubernetes/components/*`

---

## Task 0: Pre-flight verification

**Files:** (確認のみ、変更なし)

**Context:** 実装開始前に worktree 状態・toolchain・cluster baseline を確認する。ここで前提が崩れていたら以降の Task の検証結果が信用できない。

**Interfaces:**
- Consumes: なし
- Produces: 以降の Task が前提とする baseline (= node 数、OTel Collector / Loki 稼働、falco namespace 不在)

- [ ] **Step 1: worktree と branch 状態を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git branch --show-current
git fetch origin main --quiet
git --no-pager log --oneline origin/main..HEAD
```

Expected: branch は `feat/falco-runtime-security`。commit は spec 関連の 2 つのみ ahead。

```
dc2e069 docs(superpowers): correct Falco API server rule assumption for Cilium
d51b6cd docs(superpowers): add Falco runtime security design
```

- [ ] **Step 2: toolchain の version を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
helm version --template '{{.Version}}'; echo
helmfile version --output json 2>/dev/null | head -3
kustomize version
```

Expected: helm が `v3.17.3` を返す。**`v4` 系が返ったら `AQUA_CONFIG` の設定漏れ**なので、先に解決してから次へ進む。

- [ ] **Step 3: cluster baseline を確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- node count ---"
kubectl get nodes --no-headers | wc -l
echo "--- OTel Collector (log funnel の担い手) ---"
kubectl get ds -n monitoring opentelemetry-collector
echo "--- Loki ---"
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
echo "--- falco namespace (未作成であること) ---"
kubectl get namespace falco 2>&1 | tail -1'
```

Expected: node 数を記録する (Task 4 で DaemonSet の DESIRED と突き合わせる)。OTel Collector DaemonSet が全 node で READY。Loki Pod が Running。`falco` namespace は `NotFound`。

- [ ] **Step 4: cluster-wide の default-deny NetworkPolicy が無いことを確認**

falcoctl init container が `ghcr.io` から OCI artifact を pull するため、egress が塞がれていると Pod が起動しない。

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get ciliumclusterwidenetworkpolicy 2>&1 | tail -2
kubectl get networkpolicy -A'
```

Expected: `CiliumClusterwideNetworkPolicy` は存在しない (`No resources found` か CRD 未使用)。`NetworkPolicy` は `flux-system` namespace の 3 件のみ。**それ以外の namespace に default-deny があれば、`falco` namespace の ghcr.io egress 許可を先に設計する必要がある**ので、その場合はここで停止して報告する。

---

## Task 1: Falco component source を作成し render 結果を検証

**Files:**
- Create: `kubernetes/components/falco/namespace.yaml`
- Create: `kubernetes/components/falco/production/helmfile.yaml`
- Create: `kubernetes/components/falco/production/values.yaml.gotmpl`

**Context:** component の source 3 ファイルを作る。この Task の合否は「render された manifest が spec の設計判断どおりか」で決まる。hydrate (= `manifests/` への書き出し) は Task 2 で行う。

**Interfaces:**
- Consumes: Task 0 の toolchain (`AQUA_CONFIG` 設定済 helm v3.17.3)
- Produces: `kubernetes/components/falco/production/helmfile.yaml` (Task 2 の `hydrate-component.sh falco production` が読む)

- [ ] **Step 1: 検証コマンドを先に走らせて失敗を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
helmfile -f kubernetes/components/falco/production/helmfile.yaml -e production template --include-crds --skip-tests > /tmp/falco-render.yaml
```

Expected: FAIL。`no such file or directory` でファイルが存在しないエラー。

- [ ] **Step 2: namespace.yaml を作成**

`kubernetes/components/falco/namespace.yaml`:

```yaml
# =============================================================================
# Falco Namespace
# =============================================================================
# Falco DaemonSet の専用 namespace。monitoring に相乗りさせない理由は 2 つ。
# 1. Falco は detective security control であり、signal を集めて貯める
#    monitoring namespace とは責務が異なる
# 2. Falco Pod は eBPF attach のため昇格した capability を持つ。将来 namespace
#    単位で PodSecurity / NetworkPolicy を締めるとき、権限の高い Pod が
#    monitoring 全体の設定を引きずるのを避ける
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    app.kubernetes.io/name: falco
```

- [ ] **Step 3: helmfile.yaml を作成**

`kubernetes/components/falco/production/helmfile.yaml`:

```yaml
# =============================================================================
# Falco Helmfile for production
# =============================================================================
# Falco を falco namespace に DaemonSet deploy。node の syscall を modern eBPF
# で観測し、検知イベントを JSON で stdout に出力する。配送は既存の OTel
# Collector (filelog receiver) が担うため falcosidekick を持たない。
# =============================================================================
environments:
  production:
---
repositories:
  - name: falcosecurity
    url: https://falcosecurity.github.io/charts

releases:
  - name: falco
    namespace: falco
    chart: falcosecurity/falco
    version: "9.1.0"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 4: values.yaml.gotmpl を作成**

`kubernetes/components/falco/production/values.yaml.gotmpl`:

```yaml
# Falco Runtime Security Configuration for production
# node の syscall を modern eBPF で観測し、検知イベントを JSON で stdout に出力。
# 既存の OTel Collector (filelog receiver) が /var/log/pods を tail して Loki へ
# 送るため、Falco 側に配送コンポーネント (falcosidekick) を持たない。

# =============================================================================
# Driver (= modern eBPF CO-RE)
# =============================================================================
# NOTE: chart default は kind: auto。auto のままだと driver-loader init container
# が残り、node 起動のたびに kernel module の build / download 経路に依存する。
# Karpenter が node を頻繁に入れ替える構成では外部依存を減らしたいため
# modern_ebpf を明示する (= chart の driverLoader helper が false を返し init
# container が生成されなくなる)。
# 前提: node は AL2023 (kernel 6.1 + BTF)、image は arm64 対応済。
driver:
  kind: modern_ebpf
  modernEbpf:
    # privileged: true を避け capabilities {BPF, SYS_RESOURCE, PERFMON,
    # SYS_PTRACE} のみで動かす。security tool 自身を production で常時特権 Pod
    # として走らせない。失敗時は BPF program の load エラーで CrashLoop するため
    # 静かに壊れることはない。
    leastPrivileged: true

# =============================================================================
# Rules (= OCI artifact、exact version に pin)
# =============================================================================
# Falco 0.36 以降ルールセットは image に同梱されず OCI artifact で配布される。
# NOTE: キーパスが 2 系統に分かれる。falcoctl.artifact.*.enabled は container の
# 有無を制御し、pin 対象の refs は falcoctl.config.artifact.install.refs 配下。
# falcoctl.artifact.install.refs は存在せず、書いても無視される。
# follow を無効化する理由: chart default は 168h ごとに rules を自動更新する。
# ルールが Git の外で変わると、manifests/ に render した YAML をレビューしてから
# 適用する hydration pattern の前提が崩れる。
# install の ref を exact version にする理由: chart default の falco-rules:5 は
# floating tag で、Pod 再起動のたびに major 5 系の最新を引く (= 同じ manifest
# から異なる挙動が出る)。
# NOTE: follow.refs は falco-rules:5 のまま render されるが、follow container が
# 存在しないため consume されず無害。
# Renovate の helmfile manager は OCI artifact を追えないため更新は手動。
falcoctl:
  artifact:
    install:
      enabled: true
    follow:
      enabled: false
  config:
    artifact:
      install:
        refs:
          - falco-rules:5.1.0

# =============================================================================
# Falco config
# =============================================================================
falco:
  # chart default false。OTel Collector が拾った本文を Loki 側で `| json` で
  # パースするために必須。
  json_output: true
  # chart default true。container 内に syslog daemon が存在せず出力先がないため
  # 明示的に潰す。
  syslog_output:
    enabled: false

# =============================================================================
# Scheduling (= 全 node をカバー)
# =============================================================================
# NOTE: chart default の tolerations は master / control-plane taint のみ。
# そのままでは system_critical MNG (= taint dedicated=system-critical:NoSchedule)
# に schedule されず、Karpenter controller / cilium-operator / CoreDNS が載る
# node が監視の死角になる。OTel Collector と同じ全許容に上書きする。
tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists

# NOTE: chart 固有の key 名は podPriorityClassName (= priorityClassName ではない)。
# 値は OTel Collector と同じ。schedule されなかった瞬間の syscall イベントは
# 後から取り直せないため、node レベル agent と同格に置く。
podPriorityClassName: system-node-critical

# =============================================================================
# Metrics (= event drop の可視化)
# =============================================================================
# eBPF ring buffer が溢れると Falco は検知イベントを黙って落とす。監査ログの
# 網羅性を主張するには drop 率の可視化が前提条件になる。
# NOTE: chart 固有の key 名に注意。serviceMonitor.create (= enabled ではない)、
# serviceMonitor.labels (= Beyla の additionalLabels / OTel Collector の
# extraLabels とも異なる)。他 component からのコピーで誤りやすい。
metrics:
  enabled: true
serviceMonitor:
  create: true
  labels:
    release: kube-prometheus-stack
```

- [ ] **Step 5: render が成功することを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
helmfile -f kubernetes/components/falco/production/helmfile.yaml -e production template --include-crds --skip-tests > /tmp/falco-render.yaml
grep -cE "^kind:" /tmp/falco-render.yaml
```

Expected: 終了コード 0。`kind:` が 6 行 (= ConfigMap x2 / DaemonSet / Service / ServiceAccount / ServiceMonitor)。

- [ ] **Step 6: render 結果が spec の設計判断どおりか検証**

```bash
python3 - <<'PYEOF'
import yaml, json, sys
docs = [d for d in yaml.safe_load_all(open("/tmp/falco-render.yaml")) if d]
ds = [d for d in docs if d["kind"] == "DaemonSet"][0]
pod = ds["spec"]["template"]["spec"]
falco = [c for c in pod["containers"] if c["name"] == "falco"][0]
cm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "falco"][0]
fc = yaml.safe_load(cm["data"]["falco.yaml"])
ctl = yaml.safe_load([d for d in docs if d["kind"] == "ConfigMap"
                      and d["metadata"]["name"] == "falco-falcoctl"][0]["data"]["falcoctl.yaml"])
sm = [d for d in docs if d["kind"] == "ServiceMonitor"][0]

checks = [
    ("driver-loader init container なし",
     [c["name"] for c in pod.get("initContainers", [])] == ["falcoctl-artifact-install"]),
    ("follow サイドカーなし", [c["name"] for c in pod["containers"]] == ["falco"]),
    ("privileged 不使用", "privileged" not in falco.get("securityContext", {})),
    ("capabilities が 4 つ",
     sorted(falco["securityContext"]["capabilities"]["add"])
     == ["BPF", "PERFMON", "SYS_PTRACE", "SYS_RESOURCE"]),
    ("engine.kind が modern_ebpf", fc["engine"]["kind"] == "modern_ebpf"),
    ("json_output 有効", fc["json_output"] is True),
    ("syslog_output 無効", fc["syslog_output"]["enabled"] is False),
    ("stdout_output 有効", fc["stdout_output"]["enabled"] is True),
    ("rules が exact pin", "falco-rules:5.1.0" in ctl["artifact"]["install"]["refs"]),
    ("floating tag 不使用", "falco-rules:5" not in ctl["artifact"]["install"]["refs"]),
    ("tolerations 全許容",
     pod["tolerations"] == [{"effect": "NoSchedule", "operator": "Exists"},
                            {"effect": "NoExecute", "operator": "Exists"}]),
    ("priorityClassName", pod["priorityClassName"] == "system-node-critical"),
    ("ServiceMonitor label", sm["metadata"]["labels"].get("release") == "kube-prometheus-stack"),
    ("container plugin 有効", fc["load_plugins"] == ["container"]),
]
bad = [n for n, ok in checks if not ok]
for n, ok in checks:
    print(("  OK   " if ok else "  FAIL") + f"  {n}")
sys.exit(1 if bad else 0)
PYEOF
```

Expected: 全 14 行が `OK`、終了コード 0。1 つでも `FAIL` があれば values を修正して Step 5 からやり直す。

- [ ] **Step 7: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git add kubernetes/components/falco/
git commit -s -m "feat(kubernetes/components/falco): add Falco runtime security component

cluster に host/syscall 層の可視性がなく、Pod 内で何が実行されたかを事後
追跡する材料が存在しなかった。Cilium/Hubble は network 層、Beyla+OTel は
application 層を担っており、この層だけ空白だった。

driver.kind を auto ではなく modern_ebpf に固定するのは、driver-loader init
container を消して node 起動時の外部ダウンロード依存を断つため。Karpenter が
node を頻繁に入れ替える構成では起動経路の外部依存が可用性リスクになる。

falcoctl の follow サイドカーを無効化し refs を exact version に pin するのは、
ルールが Git の外で変わると manifests/ を render してレビューしてから適用する
hydration pattern の前提が崩れるため。"
```

---

## Task 2: Hydration を実行し manifests 出力を検証

**Files:**
- Create: `kubernetes/manifests/production/falco/manifest.yaml` (自動生成)
- Create: `kubernetes/manifests/production/falco/kustomization.yaml` (自動生成)
- Modify: `kubernetes/manifests/production/kustomization.yaml` (自動生成)
- Modify: `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (自動生成)

**Context:** hydration scripts を走らせて Flux が実際に適用する YAML を生成する。手書きしない。生成物の中身と index への挿入位置を確認する。

**Interfaces:**
- Consumes: Task 1 の `kubernetes/components/falco/production/helmfile.yaml`
- Produces: `kubernetes/manifests/production/falco/` (Flux の root Kustomization が参照する)

- [ ] **Step 1: hydrate 前の index 状態を記録**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
grep -n "falco" kubernetes/manifests/production/kustomization.yaml
```

Expected: ヒットなし (= 終了コード 1)。まだ index に載っていない。

- [ ] **Step 2: hydration を実行**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
export AQUA_CONFIG="$(git rev-parse --show-toplevel)/.github/aqua.yaml"
helm version --template '{{.Version}}'; echo
bash scripts/kubernetes-hydrate/hydrate-component.sh falco production
bash scripts/kubernetes-hydrate/hydrate-index.sh production
```

Expected: helm が `v3.17.3` を返した上でエラーなく完了する。**`v4` 系なら中断して `AQUA_CONFIG` を設定し直す。**

- [ ] **Step 3: index への挿入位置を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
grep -n -B 1 -A 1 "falco" kubernetes/manifests/production/kustomization.yaml
```

Expected: `./external-secrets` と `./gateway-api` の間に `./falco` が入る (C locale sort)。

```
  - ./external-secrets
  - ./falco
  - ./gateway-api
```

- [ ] **Step 4: namespace が集約されたことを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
grep -A 4 "name: falco" kubernetes/manifests/production/00-namespaces/namespaces.yaml
```

Expected: `namespaces.yaml` に `name: falco` の Namespace が含まれる。

- [ ] **Step 5: 生成された manifest が Task 1 の検証を通ることを確認**

hydrate 出力は `helmfile template` と同一内容のはずだが、実際に Flux が適用するのはこちらなので改めて検証する。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
python3 - <<'PYEOF'
import yaml, json, sys
docs = [d for d in yaml.safe_load_all(
    open("kubernetes/manifests/production/falco/manifest.yaml")) if d]
ds = [d for d in docs if d["kind"] == "DaemonSet"][0]
pod = ds["spec"]["template"]["spec"]
falco = [c for c in pod["containers"] if c["name"] == "falco"][0]
cm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "falco"][0]
fc = yaml.safe_load(cm["data"]["falco.yaml"])
ctl = yaml.safe_load([d for d in docs if d["kind"] == "ConfigMap"
                      and d["metadata"]["name"] == "falco-falcoctl"][0]["data"]["falcoctl.yaml"])
sm = [d for d in docs if d["kind"] == "ServiceMonitor"][0]

checks = [
    ("driver-loader init container なし",
     [c["name"] for c in pod.get("initContainers", [])] == ["falcoctl-artifact-install"]),
    ("follow サイドカーなし", [c["name"] for c in pod["containers"]] == ["falco"]),
    ("privileged 不使用", "privileged" not in falco.get("securityContext", {})),
    ("capabilities が 4 つ",
     sorted(falco["securityContext"]["capabilities"]["add"])
     == ["BPF", "PERFMON", "SYS_PTRACE", "SYS_RESOURCE"]),
    ("engine.kind が modern_ebpf", fc["engine"]["kind"] == "modern_ebpf"),
    ("json_output 有効", fc["json_output"] is True),
    ("syslog_output 無効", fc["syslog_output"]["enabled"] is False),
    ("stdout_output 有効", fc["stdout_output"]["enabled"] is True),
    ("rules が exact pin", "falco-rules:5.1.0" in ctl["artifact"]["install"]["refs"]),
    ("floating tag 不使用", "falco-rules:5" not in ctl["artifact"]["install"]["refs"]),
    ("tolerations 全許容",
     pod["tolerations"] == [{"effect": "NoSchedule", "operator": "Exists"},
                            {"effect": "NoExecute", "operator": "Exists"}]),
    ("priorityClassName", pod["priorityClassName"] == "system-node-critical"),
    ("ServiceMonitor label", sm["metadata"]["labels"].get("release") == "kube-prometheus-stack"),
    ("container plugin 有効", fc["load_plugins"] == ["container"]),
]
bad = [n for n, ok in checks if not ok]
for n, ok in checks:
    print(("  OK   " if ok else "  FAIL") + f"  {n}")
sys.exit(1 if bad else 0)
PYEOF
```

Expected: 全 14 行が `OK`、終了コード 0。`helmfile template` の出力と同一内容のはずだが、Flux が実際に適用するのはこちらのファイルなので改めて検証する。

- [ ] **Step 6: 他 component の manifest に差分が出ていないことを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git status --short kubernetes/manifests/
```

Expected: 変更は `falco/` の新規 2 ファイル、`kustomization.yaml`、`00-namespaces/namespaces.yaml` の 4 つだけ。**他 component の manifest.yaml に差分が出ていたら toolchain version がずれている**ので、`AQUA_CONFIG` を確認して該当ファイルを `git checkout` で戻す。

- [ ] **Step 7: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git add kubernetes/manifests/
git commit -s -m "chore(kubernetes/manifests/production): hydrate falco manifests

Flux が適用する YAML を components/falco から render した生成物。
手書きではなく scripts/kubernetes-hydrate/ の出力。"
```

---

## Task 3: README を更新し Draft PR を作成、CI の label 解決を検証

**Files:**
- Modify: `kubernetes/README.md`

**Context:** README に Falco の役割・運用コマンド・troubleshooting を追記し、PR を出す。spec が REASONED 止まりにしていた「新規 component で deploy label が自動付与されるか」をここで実測する。

**Interfaces:**
- Consumes: Task 1 / Task 2 の commit
- Produces: Draft PR (Task 4 の merge 対象)

- [ ] **Step 1: README に Security layer 節を追加**

`kubernetes/README.md` の `#### Observability — Application Telemetry` テーブルの直後に、以下を挿入する。

```markdown
#### Security — Runtime security

| Component / Resource | 配置 | 役割 |
|---|---|---|
| `kubernetes/components/falco/production/` | `falco` namespace | chart `falcosecurity/falco` (DaemonSet)。modern eBPF driver で node の syscall を観測し、検知イベントを JSON で stdout に出力。既存 OTel Collector の filelog receiver が拾って Loki へ送るため falcosidekick を持たない。ルールセットは OCI artifact `falco-rules:5.1.0` を exact pin し、falcoctl の自動更新サイドカーは無効化 (= ルールが Git 外で変わると hydration pattern の前提が崩れるため) |
| Falco metrics | `falco:falco` Service :8765 → ServiceMonitor | eBPF ring buffer の event drop を可視化。drop が出ている状態では監査ログの網羅性を主張できない |

Falco は detective control であり、攻撃の遮断は担わない (= 遮断は Cilium NetworkPolicy / PodSecurity の責務)。`privileged` は使わず capabilities `{BPF, SYS_RESOURCE, PERFMON, SYS_PTRACE}` のみで動作する。
```

- [ ] **Step 2: README の運用コマンド節に Falco を追加**

`### Foundation addon operations` の bash ブロック末尾 (= Karpenter の `aws eks list-pod-identity-associations` 行の後) に追記する。

```bash
# Falco (runtime security)
kubectl get ds -n falco falco                            # DESIRED == READY == node 数
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=20
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i drop   # event drop の有無
```

- [ ] **Step 3: README の troubleshooting テーブルに 3 行追加**

`### Troubleshooting` テーブルの末尾に追記する。

```markdown
| Falco Pod が `CrashLoopBackOff` で BPF 関連のエラーを出す | `leastPrivileged: true` の capabilities で BPF program を load できていない。`kubectl logs -n falco -l app.kubernetes.io/name=falco` でエラーを確認し、暫定対処として `values.yaml.gotmpl` の `driver.modernEbpf.leastPrivileged` を `false` に戻す (= chart default の `privileged: true` にフォールバック) |
| Falco の init container `falcoctl-artifact-install` が失敗する | `ghcr.io` への egress が塞がれている。NetworkPolicy / SG / NAT の経路を確認する。ルールセットは image に同梱されないため、この init container が成功しないと Falco は起動しない |
| Falco の検知イベントが Loki に出てこない | Falco Pod のログには出ているか (`kubectl logs -n falco -l app.kubernetes.io/name=falco`) をまず確認。出ているなら OTel Collector の filelog 経路の問題、出ていないなら `json_output` 設定かルール側の問題。LogQL は `{k8s_namespace_name="falco"} \| json` で引く |
```

- [ ] **Step 4: README の変更を commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git add kubernetes/README.md
git commit -s -m "docs(kubernetes): document Falco runtime security layer

README は現在の状態を答える媒体のため、新規 component の役割・運用
コマンド・troubleshooting を追記する。Falco が detective control であり
遮断を担わない点を明記したのは、Cilium NetworkPolicy との役割混同を
避けるため。"
```

- [ ] **Step 5: push して Draft PR を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git push -u origin HEAD
gh pr create --draft \
  --title "feat(kubernetes): introduce Falco runtime security" \
  --body "$(cat <<'PRBODY'
## Why

cluster に host/syscall 層の可視性がなく、Pod 内で何が実行されたかを事後追跡する材料が存在しない。Cilium/Hubble は network 層、Beyla+OTel は application 層を担っており、この層だけが空白だった。

## What

`falcosecurity/falco` 9.1.0 (Falco 0.44.1) を専用 `falco` namespace に DaemonSet deploy する。

- **配送を追加しない**: Falco は JSON を stdout に出すだけで、既存の OTel Collector (filelog receiver) が Loki へ運ぶ。falcosidekick は本 PR の目的 (= 通知なし・監査ログ堆積) に対して本領が遊ぶため導入しない
- **driver は modern_ebpf を明示**: driver-loader init container が消え、node 起動時の外部ダウンロード依存が無くなる。Karpenter で node が頻繁に入れ替わる構成では起動経路の外部依存が可用性リスクになる
- **privileged を使わない**: capabilities `{BPF, SYS_RESOURCE, PERFMON, SYS_PTRACE}` のみ
- **ルールを exact pin**: `falco-rules:5.1.0`。falcoctl の 168h 自動更新サイドカーは無効化。ルールが Git 外で変わると hydration pattern の前提が崩れる

## Verification

- [ ] 全 node で DaemonSet が READY
- [ ] `leastPrivileged` の securityContext が反映されている
- [ ] event drop が発生していない
- [ ] 意図的な発火 (`kubectl exec -it` + `cat /etc/shadow`) が Loki の LogQL で引ける

## Known unknown

`Contact K8S API Server From Container` ルールは Cilium socket-LB の DNAT および in-cluster client が DNS を引かない点により、発火しない可能性がある。merge 後に実測し、結果を spec に反映する。これは noise 減ではなく**検知の死角**を意味する。

Spec: `docs/superpowers/specs/2026-08-08-eks-production-falco-runtime-security-design.md`
PRBODY
)"
```

- [ ] **Step 6: CI が falco を deploy target として解決したか確認**

spec が REASONED 止まりにしていた項目の実測。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
sleep 60
gh pr view --json number,labels --jq '{number: .number, labels: [.labels[].name]}'
gh run list --branch feat/falco-runtime-security --limit 5
```

Expected: kubernetes stack の deploy label が自動付与され、hydrator / builder workflow が起動している。**label が付かなければ `workflow-config.yaml` への明示登録が必要**という結論になるので、その場合は停止して報告する (= spec の REASONED 項目が否定されたことになる)。

- [ ] **Step 7: CI が余分な hydrate commit を積んでいないことを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git fetch origin feat/falco-runtime-security --quiet
git --no-pager log --oneline origin/feat/falco-runtime-security -5
```

Expected: 自分が積んだ commit のみ。`chore(kubernetes/manifests/...): hydrate manifests` が CI により追加されていたら **Task 2 の toolchain version がずれていた**ことを意味する。その場合は `AQUA_CONFIG` を設定して hydrate をやり直す。

---

## Task 4: Merge して deploy を検証

**Files:** (変更なし、cluster 側の確認のみ)

**Context:** PR を merge して Flux に適用させ、DaemonSet が全 node で意図どおりの構成で動いていることを確認する。

**Interfaces:**
- Consumes: Task 3 の Draft PR
- Produces: cluster 上で稼働する Falco DaemonSet (Task 5 / Task 6 の前提)

- [ ] **Step 1: PR を ready にして merge**

CI が green であることを確認してから実行する。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
gh pr checks
gh pr ready
gh pr merge --squash
```

Expected: merge 成功。

- [ ] **Step 2: Flux の適用を待つ**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
flux get kustomizations -A'
```

Expected: `flux-system` Kustomization が `Ready=True`、最新 revision が merge commit を指す。

- [ ] **Step 3: DaemonSet が全 node で READY か確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get ds -n falco falco
echo "--- node count ---"
kubectl get nodes --no-headers | wc -l
echo "--- pods ---"
kubectl get pods -n falco -o wide'
```

Expected: DaemonSet の DESIRED == CURRENT == READY == node 数 (Task 0 Step 3 で記録した値)。全 Pod が `Running`。`system_critical` MNG の node にも Pod が載っている。

- [ ] **Step 4: driver と権限が意図どおりか確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- securityContext (privileged が無く capabilities のみであること) ---"
kubectl get pods -n falco -o jsonpath="{.items[0].spec.containers[0].securityContext}"; echo
echo "--- init containers (falcoctl-artifact-install のみであること) ---"
kubectl get pods -n falco -o jsonpath="{.items[0].spec.initContainers[*].name}"; echo
echo "--- driver load ログ ---"
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=40 | grep -iE "modern|ebpf|driver|rule"'
```

Expected: securityContext は `{"capabilities":{"add":["BPF","SYS_RESOURCE","PERFMON","SYS_PTRACE"]}}` で `privileged` を含まない。init container は `falcoctl-artifact-install` のみ。ログに modern eBPF probe の起動とルール読み込み完了が出る。

**`CrashLoopBackOff` かつ BPF load エラーの場合**: `leastPrivileged: true` が AL2023/ARM64 で動かない (= spec の ASSUMED リスクが顕在化)。`values.yaml.gotmpl` の `driver.modernEbpf.leastPrivileged` を `false` に変更し、Task 1 Step 5-7 → Task 2 の手順で再度 PR を出す。

- [ ] **Step 5: event drop が発生していないことを確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i drop | tail -20'
```

Expected: drop に関する警告が出ていない。出ている場合は `driver.modernEbpf.bufSizePreset` の引き上げを別途検討する (= 本 Task では記録のみ)。

- [ ] **Step 6: ServiceMonitor が Prometheus に拾われたか確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get servicemonitor -n falco
kubectl get svc -n falco falco'
```

Expected: ServiceMonitor `falco` が存在し、Service が port 8765 (`metrics`) を expose している。

- [ ] **Step 7: node のメモリ余力を確認**

Cilium の BPF map と Falco の per-CPU ring buffer はいずれも kernel 側の確保で container の memory limit に計上されないが、node の実メモリは消費する (= spec の Cilium coexistence 表で「実測時に available memory を確認する」とした項目)。

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl top nodes
echo "--- Falco container の実使用量 (chart default requests 512Mi に対して) ---"
kubectl top pods -n falco'
```

Expected: node の MEMORY% に余力がある (= 目安として 85% 未満)。Falco container の実使用量を記録し、chart default の requests 512Mi / limits 1024Mi と乖離が大きければ right-size を別 PR で検討する。

**node の MEMORY% が逼迫している場合**: `driver.modernEbpf.bufSizePreset` (default 4) の引き下げ、または `cpusForEachBuffer` (default 2) の引き上げで ring buffer の総量を減らせる。本 Task では記録のみ行い、対処は別 PR とする。

---

## Task 5: E2E 発火と Loki 到達を検証

**Files:** (変更なし、cluster 側の確認のみ)

**Context:** **本 plan の成功基準**。意図的に検知を発火させ、そのイベントが Loki まで届き Grafana の LogQL で引けることを確認する。

**Interfaces:**
- Consumes: Task 4 で稼働している Falco DaemonSet
- Produces: 成功基準の達成証跡

- [ ] **Step 1: 検証用 Pod を起動**

Flux 管理外の使い捨てリソースのため、`kubectl` 直接操作でも GitOps の drift を生まない。

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl run falco-e2e --image=alpine:3 --restart=Never -n default -- sleep 300
kubectl wait --for=condition=Ready pod/falco-e2e -n default --timeout=60s'
```

Expected: Pod が Ready になる。

- [ ] **Step 2: 検知を発火させる**

`-it` は必須。`Terminal shell in container` の condition に `proc.tty != 0` が含まれるため、TTY を割り当てないと発火しない。

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl exec -it falco-e2e -n default -- sh -c "cat /etc/shadow"'
```

Expected: `/etc/shadow` の内容が表示される (= alpine のため実質空に近い)。コマンド自体の成否は問わない。

- [ ] **Step 3: Falco が検知したことを確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=200 | grep falco-e2e'
```

Expected: JSON 行が 2 種類出る。

- `"rule":"Terminal shell in container"` (priority NOTICE)
- `"rule":"Read sensitive file untrusted"` (priority WARNING)

いずれも `k8s.pod.name` / `container.name` に `falco-e2e` が含まれる (= container plugin による enrichment が効いている証跡)。

**2 種類とも出ない場合**: ルールが読み込まれていない可能性があるため `kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "rules"` でルールファイルの読み込み結果を確認する。

- [ ] **Step 4: Loki に到達したことを確認 (成功基準)**

https://grafana.panicboat.net の Explore で Loki datasource を選び、以下を実行する。時間範囲は直近 15 分。

```logql
{k8s_namespace_name="falco"} | json | rule="Terminal shell in container"
```

```logql
{k8s_namespace_name="falco"} | json | rule="Read sensitive file untrusted"
```

Expected: 両方とも Step 2 の実行時刻に一致するログ行を返す。`| json` 展開後に `rule` / `priority` / `output_fields` が構造化フィールドとして見える。

**ここが本 plan のゴール**。ヒットしなければ以下の順で切り分ける。

1. `{k8s_namespace_name="falco"}` だけで引く → 0 件なら OTel Collector の filelog 経路の問題
2. 引けるなら `| json` を外して生ログを見る → JSON でなければ `json_output` 設定の問題

- [ ] **Step 5: 検証用 Pod を削除**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl delete pod falco-e2e -n default'
```

Expected: 削除成功。

---

## Task 6: socket-LB 下での API server ルール実測と spec 更新

**Files:**
- Modify: `docs/superpowers/specs/2026-08-08-eks-production-falco-runtime-security-design.md`

**Context:** spec が REASONED 止まりにしていた「`Contact K8S API Server From Container` が Cilium socket-LB 下で発火するか」を実測し、検証レベルを確定させる。**どちらの結果でも本 plan の成功基準は満たされている**。この Task は Falco で何が見えて何が見えないかを記録するためのもの。

**Interfaces:**
- Consumes: Task 4 で稼働している Falco DaemonSet
- Produces: 更新された spec (検証レベル REASONED → VERIFIED)

- [ ] **Step 1: 定常運転の時間を確保**

Task 4 の merge から 30 分以上経過していることを確認する。Flux / Karpenter / external-secrets / external-dns / KEDA / cert-manager / OTel Collector が定常的に API server を叩く時間を取る。

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get pods -n falco -o jsonpath="{.items[0].status.startTime}"; echo
date -u +%Y-%m-%dT%H:%M:%SZ'
```

Expected: Pod の startTime から 30 分以上経過している。

- [ ] **Step 2: LogQL で実測**

Grafana Explore で以下を実行する。時間範囲は Falco 起動以降の全期間。

```logql
{k8s_namespace_name="falco"} | json | rule="Contact K8S API Server From Container"
```

- [ ] **Step 3: Loki のログ増加量を実測**

spec の Risks テーブルで ASSUMED としていた項目。Grafana Explore で以下を実行し、時間範囲を Falco 起動以降の全期間にする。

```logql
sum(count_over_time({k8s_namespace_name="falco"} [1h]))
```

rule 別の内訳も取る。

```logql
sum by (rule) (count_over_time({k8s_namespace_name="falco"} | json [24h]))
```

Expected: 1 時間あたりの件数と rule 別内訳を記録する。既存の全 namespace 合計と比べて増分が支配的でないことを確認する。

```logql
sum(count_over_time({k8s_namespace_name=~".+"} [1h]))
```

**Falco の占める割合が 10% を超える場合**: noise 源となっている rule を特定し、allowlist 追加 PR を別途立てる。10% は絶対的な閾値ではなく、Loki の 30 日 retention と S3 コストに対する目安として置いた判断基準。

- [ ] **Step 4: 結果に応じて spec を更新**

**ヒットなしの場合** — `docs/superpowers/specs/2026-08-08-eks-production-falco-runtime-security-design.md` の `### Contact K8S API Server From Container は機能しない可能性が高い` 節で、以下を書き換える。

- 節見出しを `### Contact K8S API Server From Container は機能しない (実測確定)` に変更
- `検証レベルは **REASONED**。` で始まる段落を、実測日と観測期間・0 件だった事実・Falco 起動から実測までの経過時間を記した VERIFIED の記述に置き換える
- Risks テーブルの該当行の検証レベルを `REASONED` から `VERIFIED` に変更し、内容を「検知の死角として確定。K8s API アクセス追跡が必要なら k8saudit-eks が正しい情報源」に更新

**ヒットありの場合** — 同じ節を以下のように書き換える。

- 節見出しを `### Contact K8S API Server From Container は発火する (実測確定)` に変更
- socket-LB / DNS 未使用の 2 つの推論が実測により否定されたことを明記し、実際に発火した送信元 Pod の一覧を記録する
- Risks テーブルの該当行を `VERIFIED` に更新し、「想定どおりの noise。allowlist 追加は別 PR」と記載する
- `### noise の allowlist は初回リリースに入れない` 節に、実測で判明した送信元を根拠とする allowlist PR を後続タスクとして追記する

加えて、結果に関わらず Risks テーブルの `Loki のログ増加量` 行を Step 3 の実測値 (= 1 時間あたり件数・rule 別内訳・全 log に占める割合) で置き換え、検証レベルを `ASSUMED` から `VERIFIED` に更新する。

- [ ] **Step 5: spec 更新を commit して PR を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-falco-runtime-security
git fetch origin main --quiet
git checkout -b docs/falco-api-server-rule-measurement origin/main
git add docs/superpowers/specs/2026-08-08-eks-production-falco-runtime-security-design.md
git commit -s -m "docs(superpowers): confirm Falco API server rule behavior by measurement

spec が REASONED 止まりにしていた Contact K8S API Server From Container の
発火可否を実測で確定させた。推論を重ねても確度が上がらない項目だったため、
deploy 後の定常運転を観測して判断した。"
git push -u origin HEAD
gh pr create --draft \
  --title "docs(kubernetes): confirm Falco API server rule behavior" \
  --body "Task 6 の実測結果を spec に反映。検証レベルを REASONED から VERIFIED に更新した。

Spec: \`docs/superpowers/specs/2026-08-08-eks-production-falco-runtime-security-design.md\`"
```

- [ ] **Step 6: worktree の後片付け**

すべての PR が merge されたら実行する。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-falco-runtime-security
git worktree prune
```

Expected: worktree が削除され、`git worktree list` に残らない。
