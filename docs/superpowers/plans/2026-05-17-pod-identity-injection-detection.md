# Pod Identity Injection Detection Implementation Plan

> **Spec**: `docs/superpowers/specs/2026-05-17-pod-identity-injection-detection-design.md`
>
> **Goal**: 引き継ぎ事項 #15 の初期着手として、 Pod Identity injection 状態を probe する ad-hoc shell script を 1 本作成。

---

## Tasks

### Task 1: scripts/post-flight/ directory + script 実装

**Files**:
- Create: `scripts/post-flight/check-pod-identity-injection.sh`

**Steps**:

- [ ] **Step 1: directory 作成 + script file**

```bash
mkdir -p scripts/post-flight
# script content は spec doc Section 2 + 3 参照
```

- [ ] **Step 2: shebang + set -euo pipefail + 引数 parse**

```bash
#!/usr/bin/env bash
set -euo pipefail
cluster_name="${1:-eks-production}"
region="${AWS_REGION:-ap-northeast-1}"
```

- [ ] **Step 3: AWS API で Pod Identity Association list 取得 (= namespace + SA)**

- [ ] **Step 4: 各 (ns, sa) で kubectl で Pod list 取得**

- [ ] **Step 5: 各 Pod の env field に `AWS_CONTAINER_CREDENTIALS_FULL_URI` 存在 check**

- [ ] **Step 6: OK / FAIL / INFO line 出力 + fail count carry-over (= temp file 経由、 subshell scope 問題回避)**

- [ ] **Step 7: chmod +x で実行権限付与**

**Test**:
- `bash scripts/post-flight/check-pod-identity-injection.sh eks-production` 実行
- 既存 Pod Identity Association 全件で "OK" 出力されること確認 (= cilium-operator 等)
- exit code 0 確認

---

### Task 2: README に script 解説追加 (= 任意、 scope 軽い場合のみ)

**Files**:
- Modify: `scripts/post-flight/README.md` (= 新規 directory なので新規作成、 directory level の解説)

**Steps**:

- [ ] **Step 1: README 簡潔に**: directory purpose (= post-flight check 群)、 個別 script の usage、 future expansion note

---

## Out of scope (= 別 phase)

- K8s CronJob 化
- Prometheus metrics expose
- AlertManager rule
- 他 post-flight check (= cert mTLS chain verify 等)

---

## Validation checklist

- [ ] script 実行で all Pod 健全時 exit 0
- [ ] script の AWS API call (= `aws eks list-pod-identity-associations`) が eks-admin role で動くこと、 もしくは IAM 権限不足を明確に error 表示
- [ ] script の output が CI / cron 整合 (= stderr / stdout 適切に分離)
- [ ] spec doc が現実装と整合 (= 実装後 spec の "現状" を update する必要があれば反映)
