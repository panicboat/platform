# Post-flight checks

Cluster deploy / reconcile 後の自動 verify script 群。

## Scripts

| script | purpose |
|---|---|
| `check-pod-identity-injection.sh` | AWS EKS Pod Identity webhook が target Pod に `AWS_CONTAINER_CREDENTIALS_FULL_URI` env を inject しているか probe (= 引き継ぎ事項 #15) |

## Usage

```bash
# 認証 (eks-admin role assume)
eks-login

# probe 実行 (default cluster: eks-production、 region: ap-northeast-1)
bash scripts/post-flight/check-pod-identity-injection.sh

# exit code 0 = all OK、 1 = injection 不在 Pod あり、 2 = tool / AWS API error
```

## Convention

- 各 script は **single purpose** (= 1 probe / 1 verify)
- stdout に OK / FAIL / INFO line、 stderr に error / summary
- exit code: 0 (= success)、 1 (= fail)、 2 (= prerequisite error)
- ad-hoc manual run + CI / cron 統合の両方で再利用可

## Related

- spec: `docs/superpowers/specs/2026-05-17-pod-identity-injection-detection-design.md`
- backlog: 引き継ぎ事項 #5 (= post-flight check framework 全般) と統合検討
