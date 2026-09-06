# Private Trust Security Group Implementation Plan

> **For agentic workers:** 実装時の必須 sub-skill は `superpowers:subagent-driven-development` または `superpowers:executing-plans` とし、Task ごとに実行する。進捗は checkbox（`- [ ]`）で記録する。

**Goal:** production VPC の EKS control plane、system-critical managed node、Karpenter node、Cilium Pod ENI、monolith RDS を、VPC owner の private trust Security Group へ無停止で段階移行する。

**Architecture:** `platform/aws/vpc` が `private-trust-${environment}` を所有し、self ingress all と IPv4 egress all だけを管理する。Amazon EKS primary cluster Security Group は node / Pod ENI に残して AWS Load Balancer Controller の識別・rule 管理を受け持ち、private trust SG には cluster discovery tag を付けない。既存 SG を全 consumer に共通 SG と併用させて runtime checkpoint を通過した後、旧 RDS SG と EKS module cluster / node SG を別 PR で除去する。

**Tech Stack:** OpenTofu 1.12.6、AWS provider 6.62.0（platform）/ 6.60.0（monorepo）、Terragrunt 1.0.2、terraform-aws-modules/vpc ~> 6.7、terraform-aws-modules/eks 21.25.0、Karpenter EC2NodeClass、Kustomize 5.6.0、AWS CLI、kubectl

**Spec:** `docs/superpowers/specs/2026-09-06-private-trust-security-group-design.md`

## Global Constraints

- 対象 account は `337169763788`、region は `ap-northeast-1`、environment は `production` とする。
- VPC default SG `default-vpc-production-locked` の ingress / egress は常にゼロを維持する。
- private trust SG の Name は `private-trust-production` とし、self ingress all と IPv4 `0.0.0.0/0` egress all だけを Terraform 管理する。
- private trust SG に `kubernetes.io/cluster/*` または `aws:eks:cluster-name` tag を付けない。
- EKS primary cluster SG と AWS Load Balancer Controller 管理の frontend / backend SG は削除・統合しない。
- system-critical node と Karpenter node は最終状態でも EKS primary SG と private trust SG の二つを持つ。
- production inventory が取得できない場合、または想定外 ENI attachment が一件でもある場合は apply を開始しない。
- 各 code task は独立した branch / worktree / Draft PR とし、前の PR の merge、GitHub Actions apply、runtime gate 完了後に次の branch を最新 `origin/main` から作る。
- platform の複数 Terragrunt target は matrix で並列 apply されるため、順序依存する stack を一つの PR にまとめない。
- commit は `git commit -s` を使い、`Co-Authored-By` trailer を付けない。初回 push は `git push -u origin HEAD`、PR は `gh pr create --draft` だけを使う。
- OpenTofu test は mock provider と `command = plan` を使い、実 AWS resource を作成しない。
- 移行用の `// TODO:` は Task 2 / 3 / 5 で一つずつ追加し、それぞれ Task 9 / 7 / 8 で削除する。Task 10 では残存ゼロを確認する。
- 新しい dependency は追加せず、platform / monorepo の `aqua.yaml` にある OpenTofu pin だけを `v1.12.6` へ更新する。
- `aws/eks-secrets/modules/main.tf` の既存 format failure は変更せず、変更対象 file の format 結果と分離して報告する。
- 実行結果は `VERIFIED`、code / plan 読解は `REASONED`、production access 不足は `ASSUMED` として記録する。

### Runtime Command Prelude

Task 1 Step 7 以降の runtime code block は、新しい shell ごとに先に次を実行する。これにより、PR 間で shell variable が保持されることを前提にしない。
全ての `bash` code block は Bash で実行し、zsh に貼り付けて shell 固有の array semantics に依存させない。

```bash
set -euo pipefail

expected_account_id="337169763788"
actual_account_id="$(aws sts get-caller-identity --query Account --output text)"
test "$actual_account_id" = "$expected_account_id"

production_vpc_id="$(
  aws ec2 describe-vpcs \
    --region ap-northeast-1 \
    --filters Name=tag:Name,Values=vpc-production \
    --output json \
    | jq -r 'if (.Vpcs | length) == 1 then .Vpcs[0].VpcId else empty end'
)"
test -n "$production_vpc_id"

private_trust_sg_id="$(
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --filters \
      "Name=vpc-id,Values=$production_vpc_id" \
      Name=tag:Name,Values=private-trust-production \
    --output json \
    | jq -r 'if (.SecurityGroups | length) == 1 then .SecurityGroups[0].GroupId else empty end'
)"
test -n "$private_trust_sg_id"

primary_sg_id="$(
  aws eks describe-cluster \
    --region ap-northeast-1 \
    --name eks-production \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text
)"
test -n "$primary_sg_id"

system_node_group_name="$(
  aws eks list-nodegroups \
    --region ap-northeast-1 \
    --cluster-name eks-production \
    --output json \
    | jq -r '
        [.nodegroups[] | select(startswith("eks-production-system-critical"))]
        | if length == 1 then .[0] else empty end
      '
)"
test -n "$system_node_group_name"

kubectl config current-context | grep -F eks-production

export production_vpc_id private_trust_sg_id primary_sg_id system_node_group_name
```

## Pull Request Sequence

| Order | Repository | Branch | Deployment target | Completion gate |
|---|---|---|---|---|
| 1 | platform | `feat/private-trust-security-group` | `deploy:vpc` | SG と二つの rule が存在し、default SG が空 |
| 2 | platform | `refactor/attach-private-trust-to-eks` | `deploy:eks` | EKS control plane additional SG に旧 module SG と共通 SG が存在 |
| 3 | platform | `refactor/attach-private-trust-to-mng` | `deploy:eks-karpenter` | 全 system-critical node が primary + module node + common SG |
| 4 | platform | `refactor/attach-private-trust-to-karpenter` | `deploy:karpenter` | 全 Karpenter node / Cilium Pod ENI が primary + common SG |
| 5 | monorepo | `refactor/attach-private-trust-to-rds` | `deploy:monolith` | RDS が dedicated + common SG、実 query 成功 |
| 6 | none | runtime checkpoint | none | 全 attachment、Kubernetes、RDS、ALB、egress が正常 |
| 7 | platform | `refactor/detach-eks-node-security-group` | `deploy:eks-karpenter` | module node SG の ENI attachment がゼロ |
| 8 | monorepo | `refactor/remove-monolith-db-security-group` | `deploy:monolith` | RDS が common SG のみ、dedicated SG が不存在 |
| 9 | platform | `refactor/remove-eks-module-security-groups` | `deploy:eks` | module cluster / node SG が不存在 |
| 10 | none | final verification | none | 全 stack plan が差分ゼロ、runtime checks 再成功 |

---

### Task 0: Production Inventory Gate

**Files:**
- Modify: none

**Interfaces:**
- Consumes: AWS credential、production kubeconfig、現行 Terraform state
- Produces: 一意な VPC ID、現行 SG ID、ENI attachment inventory、移行前 HTTP status

- [ ] **Step 1: Verify the AWS account and locate exactly one production VPC**

```bash
set -euo pipefail

expected_account_id="337169763788"
actual_account_id="$(aws sts get-caller-identity --query Account --output text)"
test "$actual_account_id" = "$expected_account_id"

production_vpc_ids="$(
  aws ec2 describe-vpcs \
    --region ap-northeast-1 \
    --filters Name=tag:Name,Values=vpc-production \
    --query 'Vpcs[].VpcId' \
    --output text | tr '\t' '\n' | sed '/^$/d'
)"
test "$(printf '%s\n' "$production_vpc_ids" | wc -l | tr -d ' ')" -eq 1
production_vpc_id="$production_vpc_ids"
printf 'production_vpc_id=%s\n' "$production_vpc_id"
```

完了条件: account が `337169763788`、VPC ID が一件だけ出力される。失敗した場合は Task 1 へ進まない。

- [ ] **Step 2: Capture all Security Groups and ENI attachments in the VPC**

```bash
aws ec2 describe-security-groups \
  --region ap-northeast-1 \
  --filters "Name=vpc-id,Values=$production_vpc_id" \
  --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,NameTag:Tags[?Key==`Name`]|[0].Value,Ingress:IpPermissions,Egress:IpPermissionsEgress}' \
  --output json

aws ec2 describe-network-interfaces \
  --region ap-northeast-1 \
  --filters "Name=vpc-id,Values=$production_vpc_id" \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Description:Description,Type:InterfaceType,Owner:OwnerId,Groups:Groups[].GroupId,Status:Status}' \
  --output json
```

完了条件: EKS primary、module cluster、module node、RDS、default、controller-created SG と全 attachment の owner を説明できる。owner 不明の attachment があれば停止する。

- [ ] **Step 3: Confirm the EKS, MNG, Karpenter, Cilium, and RDS identities**

```bash
aws eks describe-cluster \
  --region ap-northeast-1 \
  --name eks-production \
  --query 'cluster.{Status:status,VpcId:resourcesVpcConfig.vpcId,PrimarySecurityGroupId:resourcesVpcConfig.clusterSecurityGroupId,AdditionalSecurityGroupIds:resourcesVpcConfig.securityGroupIds}' \
  --output json

kubectl config current-context | grep -F eks-production

system_node_group_name="$(
  aws eks list-nodegroups \
    --region ap-northeast-1 \
    --cluster-name eks-production \
    --output json \
    | jq -r '
        [.nodegroups[] | select(startswith("eks-production-system-critical"))]
        | if length == 1 then .[0] else empty end
      '
)"
test -n "$system_node_group_name"

aws eks describe-nodegroup \
  --region ap-northeast-1 \
  --cluster-name eks-production \
  --nodegroup-name "$system_node_group_name" \
  --query 'nodegroup.{Status:status,Health:health,AutoScalingGroups:resources.autoScalingGroups[].name}' \
  --output json

kubectl get nodes -o wide
kubectl get nodeclaims -o wide

aws rds describe-db-instances \
  --region ap-northeast-1 \
  --db-instance-identifier monolith-production \
  --query 'DBInstances[0].{Status:DBInstanceStatus,VpcSecurityGroups:VpcSecurityGroups}' \
  --output json

aws ec2 describe-network-interfaces \
  --region ap-northeast-1 \
  --filters \
    "Name=vpc-id,Values=$production_vpc_id" \
    Name=tag-key,Values=io.cilium/cilium-managed \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Groups:Groups[].GroupId}' \
  --output json
```

完了条件: EKS と RDS が available / active、全 Node / NodeClaim が Ready、Cilium 管理 ENI の現在の SG set を記録できる。

- [ ] **Step 4: Search for output consumers outside the known modules**

```bash
rg -n 'cluster_security_group_id|node_security_group_id' aws kubernetes \
  --glob '!docs/superpowers/**'

gh search code 'cluster_security_group_id org:panicboat' --limit 100
gh search code 'node_security_group_id org:panicboat' --limit 100
```

完了条件: repository 内の実行時 consumer は `aws/eks-karpenter` だけである。追加 consumer があれば Task 2 と Task 9 の interface migration 対象へ加える。

- [ ] **Step 5: Record the application baseline without mutating infrastructure**

```bash
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' https://dystopia.city/
kubectl get deployment monolith -n dystopia -o jsonpath='{.status.readyReplicas}{"/"}{.status.replicas}{"\n"}'
kubectl exec deployment/monolith -n dystopia -c monolith -- \
  sh -c 'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc "select 1"'
```

完了条件: HTTP status を記録し、Deployment が全 replica Ready、SQL 出力が `1`。失敗した場合は migration 前の障害として解消する。

### Task 1: Create the VPC-owned Private Trust Security Group

**Files:**
- Modify: `aqua.yaml`
- Modify: `aws/vpc/modules/main.tf`
- Modify: `aws/vpc/modules/outputs.tf`
- Modify: `aws/vpc/lookup/main.tf`
- Modify: `aws/vpc/lookup/outputs.tf`
- Create: `aws/vpc/modules/tests/private_trust.tftest.hcl`
- Create: `aws/vpc/lookup/tests/private_trust.tftest.hcl`

**Interfaces:**
- Consumes: `module.vpc.vpc_id`、`var.environment`、`var.common_tags`
- Produces: `private_trust_security_group_id`、`module.vpc.security_groups.private_trust.id`、`Name=private-trust-${environment}`

- [ ] **Step 1: Align the platform OpenTofu executable with module requirements**

`aqua.yaml` の package entry を変更する。

```yaml
  - name: opentofu/opentofu@v1.12.6
```

次を実行する。

```bash
aqua install
aqua exec -- tofu version
```

完了条件: `OpenTofu v1.12.6` が出力される。

- [ ] **Step 2: Write failing VPC producer and lookup tests**

`aws/vpc/modules/tests/private_trust.tftest.hcl` を作成する。

```hcl
mock_provider "aws" {}

override_module {
  target = module.vpc
  outputs = {
    vpc_id                       = "vpc-test"
    vpc_cidr_block               = "10.0.0.0/16"
    public_subnets               = ["subnet-public"]
    private_subnets              = ["subnet-private"]
    database_subnets             = ["subnet-database"]
    public_subnets_cidr_blocks   = ["10.0.0.0/24"]
    private_subnets_cidr_blocks  = ["10.0.32.0/19"]
    database_subnets_cidr_blocks = ["10.0.10.0/24"]
    database_subnet_group_name   = "vpc-production"
    nat_public_ips               = ["203.0.113.10"]
    azs                          = ["ap-northeast-1a"]
    private_route_table_ids      = ["rtb-private"]
  }
}

variables {
  environment = "production"
  aws_region  = "ap-northeast-1"
  common_tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

run "creates_private_trust_security_group" {
  command = plan

  assert {
    condition     = aws_security_group.private_trust.name == "private-trust-production"
    error_message = "The private trust security group must use the stable production name."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.private_trust_self.ip_protocol == "-1" &&
      aws_vpc_security_group_ingress_rule.private_trust_self.referenced_security_group_id == aws_security_group.private_trust.id
    )
    error_message = "The private trust ingress rule must allow every protocol from itself."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.private_trust_ipv4.ip_protocol == "-1" &&
      aws_vpc_security_group_egress_rule.private_trust_ipv4.cidr_ipv4 == "0.0.0.0/0"
    )
    error_message = "The private trust egress rule must allow all IPv4 destinations."
  }

  assert {
    condition     = output.private_trust_security_group_id == aws_security_group.private_trust.id
    error_message = "The producer output must expose the private trust security group ID."
  }

  assert {
    condition = (
      !contains(keys(aws_security_group.private_trust.tags), "aws:eks:cluster-name") &&
      alltrue([
        for key in keys(aws_security_group.private_trust.tags) :
        !startswith(key, "kubernetes.io/cluster/")
      ])
    )
    error_message = "The private trust security group must not carry EKS discovery tags."
  }
}
```

`aws/vpc/lookup/tests/private_trust.tftest.hcl` を作成する。

```hcl
mock_provider "aws" {}

override_data {
  target = data.aws_vpc.this
  values = {
    id = "vpc-test"
  }
}

override_data {
  target = data.aws_security_group.private_trust
  values = {
    id     = "sg-private-trust"
    name   = "private-trust-production"
    vpc_id = "vpc-test"
    tags = {
      Name = "private-trust-production"
    }
  }
}

variables {
  environment = "production"
}

run "finds_private_trust_security_group" {
  command = plan

  assert {
    condition     = data.aws_security_group.private_trust.vpc_id == data.aws_vpc.this.id
    error_message = "The lookup must constrain the private trust security group to the selected VPC."
  }

  assert {
    condition     = output.security_groups.private_trust.id == "sg-private-trust"
    error_message = "The lookup output must expose the private trust security group data source."
  }
}
```

次を実行する。

```bash
cd aws/vpc/modules
aqua exec -- tofu init -backend=false
aqua exec -- tofu test -filter=tests/private_trust.tftest.hcl

cd ../lookup
aqua exec -- tofu init -backend=false
aqua exec -- tofu test -filter=tests/private_trust.tftest.hcl
```

完了条件: private trust resource と output が未実装であるため、二つの test が失敗する。

- [ ] **Step 3: Implement the Security Group, rules, and producer output**

`aws/vpc/modules/main.tf` に追記する。

```hcl
resource "aws_security_group" "private_trust" {
  name        = "private-trust-${var.environment}"
  description = "Private trust boundary for VPC resources"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.common_tags, {
    Name = "private-trust-${var.environment}"
  })
}

resource "aws_vpc_security_group_ingress_rule" "private_trust_self" {
  security_group_id            = aws_security_group.private_trust.id
  referenced_security_group_id = aws_security_group.private_trust.id
  ip_protocol                  = "-1"
  description                  = "Allow traffic within the private trust boundary"
}

resource "aws_vpc_security_group_egress_rule" "private_trust_ipv4" {
  security_group_id = aws_security_group.private_trust.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all IPv4 egress"
}
```

`aws/vpc/modules/outputs.tf` に追記する。

```hcl
output "private_trust_security_group_id" {
  description = "ID of the private trust security group"
  value       = aws_security_group.private_trust.id
}
```

- [ ] **Step 4: Implement the typed lookup contract**

`aws/vpc/lookup/main.tf` に追記する。

```hcl
data "aws_security_group" "private_trust" {
  vpc_id = data.aws_vpc.this.id

  tags = {
    Name = "private-trust-${var.environment}"
  }
}
```

`aws/vpc/lookup/outputs.tf` に追記する。

```hcl
output "security_groups" {
  description = "Security groups owned by the VPC stack."
  value = {
    private_trust = data.aws_security_group.private_trust
  }
}
```

`aws_security_group` data source は単数検索のままにする。該当 SG がゼロ件または複数件なら、任意の SG を選ばず失敗させる。

- [ ] **Step 5: Run tests and static verification**

```bash
cd aws/vpc/modules
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/private_trust.tftest.hcl

cd ../lookup
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/private_trust.tftest.hcl

cd ../../..
aqua exec -- terragrunt hcl format --check --file aws/vpc/production/terragrunt.hcl
git diff --check
```

完了条件: 全 command が成功する。

- [ ] **Step 6: Commit, push, and open the VPC Draft PR**

```bash
git add aqua.yaml aws/vpc/modules aws/vpc/lookup
git commit -s -m "feat: add private trust security group"
git push -u origin HEAD
gh pr create --draft \
  --title "Add the private trust security group" \
  --body "Creates the VPC-owned trust boundary without changing existing attachments."
gh pr edit --add-label deploy:vpc
```

完了条件: CI plan は `aws_security_group` 一つ、ingress rule 一つ、egress rule 一つ、output / lookup contract の追加だけを含む。VPC、subnet、route table、default SG に change / replace / destroy があれば merge しない。

- [ ] **Step 7: Verify the applied VPC phase before Task 2**

ユーザー review、Draft 解除、merge、main push apply の完了後に実行する。

```bash
set -euo pipefail

private_trust_sg_json="$(
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --filters \
      "Name=vpc-id,Values=$production_vpc_id" \
      Name=tag:Name,Values=private-trust-production \
    --output json
)"

private_trust_sg_id="$(jq -r '.SecurityGroups | if length == 1 then .[0].GroupId else empty end' <<<"$private_trust_sg_json")"
test -n "$private_trust_sg_id"

jq -e --arg sg_id "$private_trust_sg_id" '
  .SecurityGroups[0] as $sg
  | ($sg.IpPermissions | length) == 1
  and ($sg.IpPermissions[0].IpProtocol == "-1")
  and ($sg.IpPermissions[0].UserIdGroupPairs | map(.GroupId) | index($sg_id) != null)
  and ($sg.IpPermissionsEgress | length) == 1
  and ($sg.IpPermissionsEgress[0].IpProtocol == "-1")
  and ($sg.IpPermissionsEgress[0].IpRanges | map(.CidrIp) | index("0.0.0.0/0") != null)
  and ($sg.Tags | map(.Key) | index("aws:eks:cluster-name") == null)
  and ($sg.Tags | map(.Key) | map(startswith("kubernetes.io/cluster/")) | any | not)
' <<<"$private_trust_sg_json"

aws ec2 describe-security-groups \
  --region ap-northeast-1 \
  --filters "Name=vpc-id,Values=$production_vpc_id" Name=group-name,Values=default \
  --output json \
  | jq -e '.SecurityGroups | length == 1 and .[0].IpPermissions == [] and .[0].IpPermissionsEgress == []'
```

完了条件: 全 assertion が exit code 0 を返す。後続 gate でも `private_trust_sg_id` を Runtime Command Prelude から取得する。

### Task 2: Attach Private Trust to the EKS Control Plane

**Files:**
- Modify: `aws/eks/modules/main.tf`
- Modify: `aws/eks/modules/outputs.tf`
- Modify: `aws/eks/lookup/outputs.tf`
- Create: `aws/eks/modules/tests/private_trust_security_group.tftest.hcl`
- Create: `aws/eks/lookup/tests/security_groups.tftest.hcl`
- Create: `aws/eks/tests/security-group-contract.sh`

**Interfaces:**
- Consumes: `module.vpc.security_groups.private_trust.id`
- Produces: EKS control plane additional SG attachment、`cluster_primary_security_group_id` compatibility output
- Preserves temporarily: 移行中は module cluster SG、module node SG、`cluster_security_group_id`、`node_security_group_id` を維持

- [ ] **Step 1: Write the failing EKS attachment and lookup tests**

`aws/eks/modules/tests/private_trust_security_group.tftest.hcl` を作成する。

```hcl
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
}

mock_provider "time" {}
mock_provider "tls" {}

override_module {
  target = module.vpc
  outputs = {
    vpc = {
      id = "vpc-test"
    }
    subnets = {
      private = {
        ids = ["subnet-a", "subnet-b"]
      }
    }
    security_groups = {
      private_trust = {
        id = "sg-private-trust"
      }
    }
  }
}

override_data {
  target = data.aws_iam_roles.sso_admin
  values = {
    arns = ["arn:aws:iam::337169763788:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_test"]
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "337169763788"
  }
}

variables {
  environment           = "production"
  aws_region            = "ap-northeast-1"
  cluster_version       = "1.33"
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"
  common_tags = {
    Environment = "production"
  }
}

run "plans_private_trust_as_additional_control_plane_security_group" {
  command = plan
}
```

`aws/eks/lookup/tests/security_groups.tftest.hcl` を作成する。

```hcl
mock_provider "aws" {}

override_data {
  target = data.aws_eks_cluster.this
  values = {
    arn      = "arn:aws:eks:ap-northeast-1:337169763788:cluster/eks-production"
    endpoint = "https://eks.example.test"
    vpc_config = [{
      vpc_id                    = "vpc-test"
      cluster_security_group_id = "sg-primary"
    }]
    certificate_authority = [{
      data = "Y2E="
    }]
    kubernetes_network_config = [{
      service_ipv4_cidr = "10.100.0.0/16"
      ip_family         = "ipv4"
    }]
    identity = [{
      oidc = [{
        issuer = "https://oidc.eks.ap-northeast-1.amazonaws.com/id/test"
      }]
    }]
  }
}

override_data {
  target = data.aws_security_group.node
  values = {
    id = "sg-module-node"
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "337169763788"
  }
}

variables {
  environment = "production"
}

run "exposes_cluster_primary_security_group_id" {
  command = plan

  assert {
    condition     = output.cluster.cluster_primary_security_group_id == "sg-primary"
    error_message = "The lookup must identify the EKS-owned primary security group explicitly."
  }

  assert {
    condition     = output.cluster.cluster_security_group_id == output.cluster.cluster_primary_security_group_id
    error_message = "The compatibility field must keep its current value until consumers migrate."
  }

  assert {
    condition     = output.cluster.node_security_group_id == "sg-module-node"
    error_message = "The module node security group lookup must remain during the attachment phase."
  }
}
```

実行可能な `aws/eks/tests/security-group-contract.sh` を作成する。

```bash
#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
module_dir="$repository_root/aws/eks/modules"

plan_output="$(
  cd "$module_dir"
  aqua exec -- tofu test \
    -no-color \
    -verbose \
    -filter=tests/private_trust_security_group.tftest.hcl
)"

control_plane_security_groups="$(
  awk '
    /^[[:space:]]+[+~]?[[:space:]]*security_group_ids[[:space:]]*=[[:space:]]*\[/ { capture = 1; next }
    capture && /]/ { exit }
    capture {
      gsub(/[ ",]/, "")
      if (length > 0) print
    }
  ' <<<"$plan_output"
)"

if ! grep -Fxq sg-private-trust <<<"$control_plane_security_groups"; then
  printf 'planned control plane security groups:\n%s\n' "$control_plane_security_groups" >&2
  exit 1
fi

echo "EKS security group contract passed."
```

次を実行する。

```bash
chmod +x aws/eks/tests/security-group-contract.sh

cd aws/eks/modules
aqua exec -- tofu init -backend=false

cd ../../..
bash aws/eks/tests/security-group-contract.sh

cd aws/eks/lookup
aqua exec -- tofu init -backend=false
aqua exec -- tofu test -filter=tests/security_groups.tftest.hcl
```

完了条件: EKS plan contract は control plane の common SG attachment が未実装であるため失敗し、lookup test は `cluster_primary_security_group_id` が未実装であるため失敗する。source text の一致だけでは成功扱いしない。

- [ ] **Step 2: Add the compatibility outputs and common SG attachment**

`aws/eks/modules/main.tf` の `module "eks"` block に追記する。

```hcl
  // TODO: Replace the module cluster SG with the private trust SG after every consumer carries the private trust SG.
  additional_security_group_ids = [module.vpc.security_groups.private_trust.id]
```

既存の二つの SG output を維持したまま、`aws/eks/modules/outputs.tf` に追記する。

```hcl
output "cluster_primary_security_group_id" {
  description = "EKS-owned primary cluster security group ID"
  value       = module.eks.cluster_primary_security_group_id
}
```

既存 field を維持したまま、`aws/eks/lookup/outputs.tf` の `cluster` object に次の field を追加する。

```hcl
cluster_primary_security_group_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
```

- [ ] **Step 3: Run tests and inspect the EKS plan**

```bash
cd aws/eks/lookup
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/security_groups.tftest.hcl

cd ../modules
aqua exec -- tofu fmt -check -recursive

cd ../../..
bash aws/eks/tests/security-group-contract.sh
git diff --check
```

完了条件: test が成功する。PR の CI plan は `private_trust_sg_id` を追加する `aws_eks_cluster.this` VPC configuration の in-place update を示す。module cluster SG と node SG の destroy、または EKS cluster の replace を含む場合は merge しない。

- [ ] **Step 4: Commit, push, and open the EKS attachment Draft PR**

```bash
git add aws/eks/modules aws/eks/lookup aws/eks/tests
git commit -s -m "refactor: attach private trust security group to eks"
git push -u origin HEAD
gh pr create --draft \
  --title "Attach the private trust SG to the EKS control plane" \
  --body "Adds the shared SG alongside the existing module SG and introduces an explicit primary SG output."
gh pr edit --add-label deploy:eks
```

- [ ] **Step 5: Verify the control plane attachment before Task 3**

merge と apply の完了後に実行する。

```bash
set -euo pipefail

cluster_vpc_config="$(
  aws eks describe-cluster \
    --region ap-northeast-1 \
    --name eks-production \
    --query 'cluster.resourcesVpcConfig' \
    --output json
)"

module_cluster_sg_id="$(
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --filters \
      "Name=vpc-id,Values=$production_vpc_id" \
      Name=tag:Name,Values=eks-production \
    --output json \
    | jq -r 'if (.SecurityGroups | length) == 1 then .SecurityGroups[0].GroupId else empty end'
)"
test -n "$module_cluster_sg_id"

jq -e \
  --arg common "$private_trust_sg_id" \
  --arg module_cluster "$module_cluster_sg_id" '
    (.clusterSecurityGroupId | length) > 0
    and (.securityGroupIds | index($common) != null)
    and (.securityGroupIds | index($module_cluster) != null)
  ' <<<"$cluster_vpc_config"

aws eks describe-cluster \
  --region ap-northeast-1 \
  --name eks-production \
  --query 'cluster.status' \
  --output text | grep -Fx ACTIVE

kubectl get --raw=/readyz
kubectl wait --for=condition=Ready nodes --all --timeout=10m
```

完了条件: control plane は EKS primary + module cluster + private trust SG、cluster は ACTIVE、全 node は Ready である。

### Task 3: Attach Private Trust Alongside the MNG Node Security Group

**Files:**
- Modify: `aws/eks-karpenter/modules/main.tf`
- Create: `aws/eks-karpenter/modules/tests/security_group_attachments.tftest.hcl`
- Create: `aws/eks-karpenter/tests/security-group-contract.sh`

**Interfaces:**
- Consumes: `module.eks.cluster.cluster_primary_security_group_id`、`module.eks.cluster.node_security_group_id`、`module.vpc.security_groups.private_trust.id`
- Produces: system-critical MNG node ENI の EKS primary + module node + private trust SG attachment

- [ ] **Step 1: Write the failing MNG planned-attachment test**

`aws/eks-karpenter/modules/tests/security_group_attachments.tftest.hcl` を作成する。

```hcl
mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "337169763788"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "1.33.7-20250920"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
}

mock_provider "cloudinit" {}

override_module {
  target = module.karpenter
  outputs = {
    node_iam_role_name = "Karpenter-eks-production"
    queue_name         = "Karpenter-eks-production"
  }
}

override_module {
  target = module.eks
  outputs = {
    cluster = {
      name                              = "eks-production"
      endpoint                          = "https://eks.example.test"
      certificate_authority_data        = "Y2E="
      service_cidr                      = "10.100.0.0/16"
      ip_family                         = "ipv4"
      cluster_security_group_id         = "sg-primary"
      cluster_primary_security_group_id = "sg-primary"
      node_security_group_id            = "sg-module-node"
    }
  }
}

override_module {
  target = module.vpc
  outputs = {
    subnets = {
      private = {
        ids = ["subnet-a", "subnet-b"]
      }
    }
    security_groups = {
      private_trust = {
        id = "sg-private-trust"
      }
    }
  }
}

variables {
  environment = "production"
  aws_region  = "ap-northeast-1"
  common_tags = {
    Environment = "production"
  }
}

run "plans_three_security_groups_for_system_nodes" {
  command = plan
}
```

実行可能な `aws/eks-karpenter/tests/security-group-contract.sh` を作成する。

```bash
#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
module_dir="$repository_root/aws/eks-karpenter/modules"

plan_output="$(
  cd "$module_dir"
  aqua exec -- tofu test \
    -no-color \
    -verbose \
    -filter=tests/security_group_attachments.tftest.hcl
)"

actual_security_groups="$(
  awk '
    /^[[:space:]]+[+~]?[[:space:]]*vpc_security_group_ids[[:space:]]*=[[:space:]]*\[/ { capture = 1; next }
    capture && /]/ { exit }
    capture {
      gsub(/[ ",]/, "")
      if (length > 0) print
    }
  ' <<<"$plan_output" | sort
)"

expected_security_groups="$(
  printf '%s\n' \
    sg-module-node \
    sg-primary \
    sg-private-trust \
    | sort
)"

if test "$actual_security_groups" != "$expected_security_groups"; then
  printf 'expected security groups:\n%s\n' "$expected_security_groups" >&2
  printf 'planned security groups:\n%s\n' "$actual_security_groups" >&2
  exit 1
fi

echo "MNG security group contract passed."
```

次を実行する。

```bash
chmod +x aws/eks-karpenter/tests/security-group-contract.sh

cd aws/eks-karpenter/modules
aqua exec -- tofu init -backend=false

cd ../../..
bash aws/eks-karpenter/tests/security-group-contract.sh
```

完了条件: rendered launch template plan に private trust SG がまだ含まれないため失敗する。source text の一致だけでは成功扱いしない。

- [ ] **Step 2: Change the MNG inputs without removing either existing SG**

`module "system_critical"` の二つの SG input を次の内容へ変更する。

```hcl
  # The standalone module does not inherit cluster SG attachments, so every migration SG remains explicit during rollout.
  cluster_primary_security_group_id = module.eks.cluster.cluster_primary_security_group_id

  // TODO: Remove the module node SG after every system-critical node carries the private trust SG.
  vpc_security_group_ids = [
    module.eks.cluster.node_security_group_id,
    module.vpc.security_groups.private_trust.id,
  ]
```

既存の node SG を恒久的な node 間通信 contract とする comment は、上記の standalone module 制約を説明する comment へ置換する。

同じ file の IAM role name comment にある AWS physical MNG name の説明は、次へ置換する。`use_name_prefix = false` は既存 MNG replacement を起こすため追加しない。

```hcl
  # The MNG base name is an external contract. `use_name_prefix` remains at
  # the module default to avoid replacing the existing MNG, so runtime tooling
  # resolves the generated physical name by its stable prefix.
```

- [ ] **Step 3: Run the contract test and inspect the MNG plan**

```bash
bash aws/eks-karpenter/tests/security-group-contract.sh

cd aws/eks-karpenter/modules
aqua exec -- tofu fmt -check -recursive

cd ../../..
git diff --check
```

完了条件: PR の CI plan は launch template version / managed node group update だけを含む。EKS cluster、node group、IAM role、Karpenter queue の replace / destroy、および module node SG の destroy があれば merge しない。

- [ ] **Step 4: Commit, push, and open the MNG attachment Draft PR**

```bash
git add aws/eks-karpenter/modules aws/eks-karpenter/tests/security-group-contract.sh
git commit -s -m "refactor: attach private trust security group to system nodes"
git push -u origin HEAD
gh pr create --draft \
  --title "Attach the private trust SG to system critical nodes" \
  --body "Adds the common SG alongside the EKS primary and module node SG before any detach operation."
gh pr edit --add-label deploy:eks-karpenter
```

- [ ] **Step 5: Wait for the managed node group update owner to finish**

merge と apply の完了後に実行する。

```bash
aws eks wait nodegroup-active \
  --region ap-northeast-1 \
  --cluster-name eks-production \
  --nodegroup-name "$system_node_group_name"

aws eks describe-nodegroup \
  --region ap-northeast-1 \
  --cluster-name eks-production \
  --nodegroup-name "$system_node_group_name" \
  --query 'nodegroup.{Status:status,Issues:health.issues}' \
  --output json | jq -e '.Status == "ACTIVE" and .Issues == []'

kubectl wait \
  --for=condition=Ready \
  nodes \
  --selector=node-role/system-critical=true \
  --timeout=15m
```

完了条件: AWS waiter が成功し、health issue がゼロ、system-critical node が全て Ready である。

- [ ] **Step 6: Verify all system-critical EC2 ENIs carry the three expected SGs**

```bash
set -euo pipefail

primary_sg_id="$(
  aws eks describe-cluster \
    --region ap-northeast-1 \
    --name eks-production \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text
)"

module_node_sg_id="$(
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --filters \
      "Name=vpc-id,Values=$production_vpc_id" \
      Name=tag:Name,Values=eks-production-node \
    --output json \
    | jq -r 'if (.SecurityGroups | length) == 1 then .SecurityGroups[0].GroupId else empty end'
)"
test -n "$module_node_sg_id"

read -r -a system_instance_ids <<<"$(
  kubectl get nodes \
    --selector=node-role/system-critical=true \
    -o json \
    | jq -r '.items[].spec.providerID | split("/")[-1]' \
    | tr '\n' ' '
)"
test "${#system_instance_ids[@]}" -gt 0

aws ec2 describe-instances \
  --region ap-northeast-1 \
  --instance-ids "${system_instance_ids[@]}" \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg module_node "$module_node_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.Reservations[].Instances[]
          | .SecurityGroups | map(.GroupId) as $groups
          | ($groups | length) == 3
            and ($groups | index($primary) != null)
            and ($groups | index($module_node) != null)
            and ($groups | index($common) != null)
        ] | all
      '
```

完了条件: assertion が成功する。失敗時は旧 SG を維持したまま MNG update event と launch template version を調べる。

### Task 4: Attach Private Trust to Karpenter Nodes

**Files:**
- Modify: `kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml`
- Create: `kubernetes/components/karpenter/tests/security-group-selectors.sh`

**Interfaces:**
- Consumes: EKS primary SG の `aws:eks:cluster-name=eks-production` tag、private trust SG の `Name=private-trust-production` tag
- Produces: rendered EC2NodeClass の二つの OR selector、Karpenter node ENI の primary + private trust SG attachment

- [ ] **Step 1: Write the failing rendered selector contract test**

実行可能な `kubernetes/components/karpenter/tests/security-group-selectors.sh` を作成する。

```bash
#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
rendered_file="$(mktemp)"
selector_file="$(mktemp)"
trap 'rm -f "$rendered_file" "$selector_file"' EXIT

kustomize build \
  "$repository_root/kubernetes/components/karpenter/production/kustomization" \
  >"$rendered_file"

awk '
  /^  securityGroupSelectorTerms:$/ { capture = 1; next }
  capture && /^  [A-Za-z]/ { exit }
  capture { print }
' "$rendered_file" >"$selector_file"

test "$(grep -c '^  - tags:$' "$selector_file")" -eq 2
grep -Fxq '      aws:eks:cluster-name: eks-production' "$selector_file"
grep -Fxq '      Name: private-trust-production' "$selector_file"

if grep -Fq 'kubernetes.io/cluster/' "$selector_file"; then
  echo "The private trust selector must not use a Kubernetes cluster tag." >&2
  exit 1
fi

echo "Security group selector contract passed."
```

次を実行する。

```bash
chmod +x kubernetes/components/karpenter/tests/security-group-selectors.sh
bash kubernetes/components/karpenter/tests/security-group-selectors.sh
```

完了条件: EKS primary selector しか存在しないため失敗する。

- [ ] **Step 2: Add the private trust selector without removing the primary selector**

`ec2nodeclass.yaml` の `securityGroupSelectorTerms` を次の内容にする。

```yaml
  securityGroupSelectorTerms:
    - tags:
        "aws:eks:cluster-name": eks-production
    - tags:
        Name: private-trust-production
```

file header comment を、EKS primary と private trust SG の両方を attach する内容へ更新する。private trust SG に cluster discovery tag は追加しない。

- [ ] **Step 3: Run the Kustomize contract and static checks**

```bash
bash kubernetes/components/karpenter/tests/security-group-selectors.sh
kustomize build kubernetes/components/karpenter/production/kustomization >/dev/null
git diff --check
```

完了条件: 全 command が成功する。

- [ ] **Step 4: Commit, push, and open the Karpenter attachment Draft PR**

```bash
git add \
  kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml \
  kubernetes/components/karpenter/tests/security-group-selectors.sh
git commit -s -m "refactor: attach private trust security group to karpenter nodes"
git push -u origin HEAD
gh pr create --draft \
  --title "Attach the private trust SG to Karpenter nodes" \
  --body "Selects both the EKS primary SG and the untagged VPC trust SG."
gh pr edit --add-label deploy:karpenter
```

- [ ] **Step 5: Wait for Karpenter-owned replacement to converge**

merge と Kubernetes deployment の完了後に実行する。

```bash
kubectl wait \
  --for=condition=Ready \
  ec2nodeclass/system-components \
  --timeout=10m

kubectl get nodeclaims -o json \
  | jq -e '.items | length > 0 and all(.[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))'

kubectl wait \
  --for=condition=Ready \
  nodes \
  --selector=karpenter.sh/nodepool=system-components \
  --timeout=20m
```

完了条件: EC2NodeClass、全 NodeClaim、全 Karpenter node が Ready である。manual node deletion は行わず、収束しない場合は NodeClaim condition と controller log を調べる。

- [ ] **Step 6: Verify Karpenter node and Cilium Pod ENI attachments**

```bash
set -euo pipefail

read -r -a karpenter_instance_ids <<<"$(
  kubectl get nodes \
    --selector=karpenter.sh/nodepool=system-components \
    -o json \
    | jq -r '.items[].spec.providerID | split("/")[-1]' \
    | tr '\n' ' '
)"
test "${#karpenter_instance_ids[@]}" -gt 0

aws ec2 describe-instances \
  --region ap-northeast-1 \
  --instance-ids "${karpenter_instance_ids[@]}" \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.Reservations[].Instances[]
          | .SecurityGroups | map(.GroupId) as $groups
          | ($groups | length) == 2
            and ($groups | index($primary) != null)
            and ($groups | index($common) != null)
        ] | all
      '

aws ec2 describe-network-interfaces \
  --region ap-northeast-1 \
  --filters \
    "Name=vpc-id,Values=$production_vpc_id" \
    Name=tag-key,Values=io.cilium/cilium-managed \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.NetworkInterfaces[]
          | .Groups | map(.GroupId) as $groups
          | ($groups | index($primary) != null)
            and ($groups | index($common) != null)
        ] as $checks
        | ($checks | length) > 0 and ($checks | all)
      '
```

完了条件: node と Cilium-managed ENI の全てが primary + common SG を持つ。Pod ENI が common SG を継承しない場合は Task 5 へ進まず、Cilium 1.19.4 の実動作を根拠に設計 amendment を作る。

### Task 5: Attach Private Trust Alongside the Monolith RDS Security Group

**Files:**
- Repository: `panicboat/monorepo`
- Modify: `aqua.yaml`
- Modify: `dystopia/monolith/infrastructure/aws/modules/main.tf`
- Create: `dystopia/monolith/infrastructure/aws/modules/tests/private_trust_security_group.tftest.hcl`

**Interfaces:**
- Consumes: `Name=private-trust-${var.environment}` constrained by `data.aws_vpc.eks_production.id`
- Produces: 既存 dedicated SG と private trust SG を含む RDS attachment set
- Preserves temporarily: `aws_security_group.monolith_db`、`aws_security_group_rule.monolith_db_ingress`、`db_security_group_name`

- [ ] **Step 1: Align the monorepo OpenTofu executable with module requirements**

monorepo の `aqua.yaml` にある package entry を変更する。

```yaml
  - name: opentofu/opentofu@v1.12.6
```

monorepo root から次を実行する。

```bash
aqua install
aqua exec -- tofu version
```

完了条件: `OpenTofu v1.12.6` が出力される。

- [ ] **Step 2: Write the failing dual-attachment RDS test**

`dystopia/monolith/infrastructure/aws/modules/tests/private_trust_security_group.tftest.hcl` を作成する。

```hcl
mock_provider "aws" {}
mock_provider "random" {}

override_data {
  target = data.aws_vpc.eks_production
  values = {
    id = "vpc-test"
  }
}

override_data {
  target = data.aws_subnets.private
  values = {
    ids = ["subnet-a", "subnet-b"]
  }
}

override_data {
  target = data.aws_subnet.private_details["subnet-a"]
  values = {
    id         = "subnet-a"
    cidr_block = "10.0.32.0/19"
  }
}

override_data {
  target = data.aws_subnet.private_details["subnet-b"]
  values = {
    id         = "subnet-b"
    cidr_block = "10.0.64.0/19"
  }
}

override_data {
  target = data.aws_security_group.private_trust
  values = {
    id     = "sg-private-trust"
    vpc_id = "vpc-test"
    tags = {
      Name = "private-trust-production"
    }
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "337169763788"
  }
}

override_data {
  target = data.aws_eks_cluster.this
  values = {
    arn = "arn:aws:eks:ap-northeast-1:337169763788:cluster/eks-production"
  }
}

override_resource {
  target = random_password.monolith_db_master
  values = {
    result = "TestPassword-0123456789"
  }
}

variables {
  project_name           = "services"
  environment            = "production"
  aws_region             = "ap-northeast-1"
  db_identifier          = "monolith-production"
  db_subnet_group_name   = "monolith-production"
  db_security_group_name = "monolith-database-production"
  cognito_user_pool_arn  = "arn:aws:cognito-idp:ap-northeast-1:337169763788:userpool/test"
  common_tags = {
    Environment = "production"
  }
}

run "attaches_private_trust_security_group_alongside_rds" {
  command = plan

  assert {
    condition     = length(aws_db_instance.monolith.vpc_security_group_ids) == 2
    error_message = "RDS must retain the dedicated SG while adding the private trust SG."
  }

  assert {
    condition     = contains(aws_db_instance.monolith.vpc_security_group_ids, aws_security_group.monolith_db.id)
    error_message = "RDS must retain the dedicated SG during the attachment phase."
  }

  assert {
    condition     = contains(aws_db_instance.monolith.vpc_security_group_ids, data.aws_security_group.private_trust.id)
    error_message = "RDS must attach the private trust SG during the attachment phase."
  }
}
```

次を実行する。

```bash
cd dystopia/monolith/infrastructure/aws/modules
aqua exec -- tofu init -backend=false
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl
```

完了条件: `data.aws_security_group.private_trust` と二つ目の RDS attachment が未実装であるため失敗する。

- [ ] **Step 3: Add the VPC-scoped SG lookup and dual RDS attachment**

`main.tf` の `data.aws_vpc.eks_production` の後へ追記する。

```hcl
data "aws_security_group" "private_trust" {
  vpc_id = data.aws_vpc.eks_production.id

  tags = {
    Name = "private-trust-${var.environment}"
  }
}
```

RDS attachment を次の内容へ変更する。

```hcl
  // TODO: Remove the dedicated RDS SG after the private trust runtime checkpoint passes.
  vpc_security_group_ids = [
    aws_security_group.monolith_db.id,
    data.aws_security_group.private_trust.id,
  ]
```

この Task では既存の RDS SG、ingress rule、private subnet detail lookup、variable を削除しない。

- [ ] **Step 4: Run tests and static verification**

```bash
cd dystopia/monolith/infrastructure/aws/modules
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl

cd ../production
aqua exec -- terragrunt hcl format --check --file terragrunt.hcl

cd "$(git rev-parse --show-toplevel)"
git diff --check
```

完了条件: 全 command が成功する。

- [ ] **Step 5: Commit, push, and open the RDS attachment Draft PR**

```bash
git add \
  aqua.yaml \
  dystopia/monolith/infrastructure/aws/modules/main.tf \
  dystopia/monolith/infrastructure/aws/modules/tests/private_trust_security_group.tftest.hcl
git commit -s -m "refactor: attach private trust security group to rds"
git push -u origin HEAD
gh pr create --draft \
  --title "Attach the private trust SG to monolith RDS" \
  --body "Adds the common SG alongside the dedicated RDS SG before the connectivity checkpoint."
gh pr edit --add-label deploy:monolith
```

完了条件: CI plan は `aws_db_instance.monolith.vpc_security_group_ids` の in-place update だけを含む。DB replacement、dedicated SG / rule destroy、subnet group replacement があれば merge しない。

- [ ] **Step 6: Verify RDS availability and a real query before Task 6**

merge と apply の完了後に実行する。

```bash
aws rds wait db-instance-available \
  --region ap-northeast-1 \
  --db-instance-identifier monolith-production

aws rds describe-db-instances \
  --region ap-northeast-1 \
  --db-instance-identifier monolith-production \
  --query 'DBInstances[0].VpcSecurityGroups' \
  --output json \
  | jq -e \
      --arg common "$private_trust_sg_id" '
        length == 2
        and all(.[]; .Status == "active")
        and (map(.VpcSecurityGroupId) | index($common) != null)
      '

kubectl exec deployment/monolith -n dystopia -c monolith -- \
  sh -c 'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc "select 1"'
```

完了条件: SG association は二件とも active、SQL 出力は `1` である。

### Task 6: Runtime Verification Checkpoint

**Files:**
- Modify: none

**Interfaces:**
- Consumes: Tasks 1–5 の apply 済み state
- Produces: 旧 SG detach を開始してよいという明示的な runtime gate

- [ ] **Step 1: Verify Kubernetes control plane, nodes, NodeClaims, and workloads**

```bash
kubectl get --raw=/readyz
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodeclaims -o json \
  | jq -e '.items | length > 0 and all(.[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))'
kubectl get pods --all-namespaces -o json \
  | jq -e '
      all(.items[];
        if any(.metadata.ownerReferences[]?; .kind == "Job") then
          .status.phase == "Succeeded"
        else
          .status.phase == "Running"
          and any(.status.conditions[]?; .type == "Ready" and .status == "True")
        end
      )
    '
kubectl exec deployment/monolith -n dystopia -c monolith -- \
  getent hosts kubernetes.default.svc.cluster.local
```

完了条件: API、全 node、全 NodeClaim、常駐 Pod、cluster DNS が正常である。Job 所有の Pod は `Succeeded` の場合だけ許容する。

- [ ] **Step 2: Verify RDS, ALB, and Load Balancer Controller behavior**

```bash
kubectl exec deployment/monolith -n dystopia -c monolith -- \
  sh -c 'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc "select 1"'

curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' https://dystopia.city/

if kubectl -n kube-system logs deployment/aws-load-balancer-controller --since=30m \
  | grep -Fq 'expected exactly one securityGroup'; then
  echo "AWS Load Balancer Controller reported ambiguous target security groups." >&2
  exit 1
fi

read -r -a target_group_arns <<<"$(
  aws resourcegroupstaggingapi get-resources \
    --region ap-northeast-1 \
    --resource-type-filters elasticloadbalancing:targetgroup \
    --tag-filters Key=elbv2.k8s.aws/cluster,Values=eks-production \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output text
)"
test "${#target_group_arns[@]}" -gt 0

for target_group_arn in "${target_group_arns[@]}"; do
  aws elbv2 describe-target-health \
    --region ap-northeast-1 \
    --target-group-arn "$target_group_arn" \
    --output json \
    | jq -e '.TargetHealthDescriptions | length > 0 and all(.[]; .TargetHealth.State == "healthy")'
done
```

完了条件: SQL は `1`、HTTP status は Task 0 baseline と一致し、SG ambiguity error がなく、全 target が healthy である。

- [ ] **Step 3: Verify private workload egress**

```bash
kubectl exec deployment/monolith -n dystopia -c monolith -- \
  ruby -rnet/http -ruri -e '
    response = Net::HTTP.get_response(URI("https://checkip.amazonaws.com"))
    abort("unexpected status: #{response.code}") unless response.is_a?(Net::HTTPSuccess)
    abort("empty response") if response.body.strip.empty?
  '
```

完了条件: exit code は 0 で、DNS、TLS、NAT egress が既存経路で成功する。

- [ ] **Step 4: Verify every migration target carries the private trust SG**

```bash
cluster_vpc_config="$(
  aws eks describe-cluster \
    --region ap-northeast-1 \
    --name eks-production \
    --query 'cluster.resourcesVpcConfig' \
    --output json
)"
jq -e --arg common "$private_trust_sg_id" \
  '.securityGroupIds | index($common) != null' <<<"$cluster_vpc_config"

read -r -a cluster_instance_ids <<<"$(
  kubectl get nodes -o json \
    | jq -r '.items[].spec.providerID | split("/")[-1]' \
    | tr '\n' ' '
)"
test "${#cluster_instance_ids[@]}" -gt 0

aws ec2 describe-instances \
  --region ap-northeast-1 \
  --instance-ids "${cluster_instance_ids[@]}" \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.Reservations[].Instances[]
          | .SecurityGroups | map(.GroupId) as $groups
          | ($groups | index($primary) != null)
            and ($groups | index($common) != null)
        ] as $checks
        | ($checks | length) > 0 and ($checks | all)
      '

aws ec2 describe-network-interfaces \
  --region ap-northeast-1 \
  --filters \
    "Name=vpc-id,Values=$production_vpc_id" \
    Name=tag-key,Values=io.cilium/cilium-managed \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.NetworkInterfaces[]
          | .Groups | map(.GroupId) as $groups
          | ($groups | index($primary) != null)
            and ($groups | index($common) != null)
        ] as $checks
        | ($checks | length) > 0 and ($checks | all)
      '

aws rds describe-db-instances \
  --region ap-northeast-1 \
  --db-instance-identifier monolith-production \
  --query 'DBInstances[0].VpcSecurityGroups' \
  --output json \
  | jq -e \
      --arg common "$private_trust_sg_id" '
        length == 2
        and all(.[]; .Status == "active")
        and (map(.VpcSecurityGroupId) | index($common) != null)
      '
```

完了条件: control plane、全 node、全 Cilium-managed ENI、RDS が common SG を持つ。いずれかが失敗した場合は全ての旧 SG を attach したまま Task 7 を停止する。

### Task 7: Detach the EKS Module Node SG from System-critical Nodes

**Files:**
- Modify: `aws/eks-karpenter/modules/main.tf`
- Modify: `aws/eks-karpenter/modules/tests/security_group_attachments.tftest.hcl`
- Modify: `aws/eks-karpenter/tests/security-group-contract.sh`

**Interfaces:**
- Consumes: 全 system-critical node で検証済みの primary + private trust attachment
- Produces: 最終 MNG attachment set、module node SG attachment count zero

- [ ] **Step 1: Change the MNG test to require the final attachment set**

`aws/eks-karpenter/modules/tests/security_group_attachments.tftest.hcl` の run 名を `plans_primary_and_private_trust_security_groups_for_system_nodes` に変更する。

`aws/eks-karpenter/tests/security-group-contract.sh` の `expected_security_groups` block を次の内容へ変更する。

```bash
expected_security_groups="$(
  printf '%s\n' \
    sg-primary \
    sg-private-trust \
    | sort
)"
```

それ以外の test 処理は維持する。

次を実行する。

```bash
bash aws/eks-karpenter/tests/security-group-contract.sh
```

完了条件: rendered launch template plan が module node SG をまだ含むため失敗する。

- [ ] **Step 2: Remove only the module node SG from the MNG inputs**

移行用の MNG SG configuration を次の最終構成へ変更する。

```hcl
  # The standalone module does not inherit cluster SG attachments, so both final SGs remain explicit.
  cluster_primary_security_group_id = module.eks.cluster.cluster_primary_security_group_id

  vpc_security_group_ids = [module.vpc.security_groups.private_trust.id]
```

完了した `// TODO:` marker を削除する。この Task では EKS SG 作成設定を変更しない。

- [ ] **Step 3: Run the contract test and inspect the detach plan**

```bash
bash aws/eks-karpenter/tests/security-group-contract.sh

cd aws/eks-karpenter/modules
aqua exec -- tofu fmt -check -recursive

cd ../../..
git diff --check
```

完了条件: PR の CI plan は launch template version / managed node group update だけを含む。SG destroy または node group replacement があれば merge しない。

- [ ] **Step 4: Commit, push, and open the MNG detach Draft PR**

```bash
git add aws/eks-karpenter/modules/main.tf \
  aws/eks-karpenter/modules/tests/security_group_attachments.tftest.hcl \
  aws/eks-karpenter/tests/security-group-contract.sh
git commit -s -m "refactor: detach eks module node security group"
git push -u origin HEAD
gh pr create --draft \
  --title "Detach the EKS module node SG" \
  --body "Keeps the EKS primary and private trust SGs while removing the obsolete module node SG from system nodes."
gh pr edit --add-label deploy:eks-karpenter
```

- [ ] **Step 5: Wait for the MNG rollout and verify final node attachments**

merge と apply の完了後に実行する。

```bash
aws eks wait nodegroup-active \
  --region ap-northeast-1 \
  --cluster-name eks-production \
  --nodegroup-name "$system_node_group_name"

kubectl wait \
  --for=condition=Ready \
  nodes \
  --selector=node-role/system-critical=true \
  --timeout=15m

read -r -a system_instance_ids <<<"$(
  kubectl get nodes \
    --selector=node-role/system-critical=true \
    -o json \
    | jq -r '.items[].spec.providerID | split("/")[-1]' \
    | tr '\n' ' '
)"
test "${#system_instance_ids[@]}" -gt 0

aws ec2 describe-instances \
  --region ap-northeast-1 \
  --instance-ids "${system_instance_ids[@]}" \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.Reservations[].Instances[]
          | .SecurityGroups | map(.GroupId) as $groups
          | ($groups | length) == 2
            and ($groups | index($primary) != null)
            and ($groups | index($common) != null)
        ] as $checks
        | ($checks | length) > 0 and ($checks | all)
      '
```

完了条件: 現在の全 system-critical node が primary + common SG の二つだけを持つ。

- [ ] **Step 6: Prove the module node SG has no ENI attachments**

```bash
module_node_sg_id="$(
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --filters \
      "Name=vpc-id,Values=$production_vpc_id" \
      Name=tag:Name,Values=eks-production-node \
    --output json \
    | jq -r 'if (.SecurityGroups | length) == 1 then .SecurityGroups[0].GroupId else empty end'
)"
test -n "$module_node_sg_id"

aws ec2 describe-network-interfaces \
  --region ap-northeast-1 \
  --filters Name=group-id,Values="$module_node_sg_id" \
  --query 'length(NetworkInterfaces)' \
  --output text | grep -Fx 0
```

完了条件: `0` が出力される。ゼロ以外なら Task 9 を停止し、残る全 ENI の owner を特定する。

### Task 8: Remove the Dedicated Monolith RDS Security Group

**Files:**
- Repository: `panicboat/monorepo`
- Modify: `dystopia/monolith/infrastructure/aws/modules/main.tf`
- Modify: `dystopia/monolith/infrastructure/aws/modules/variables.tf`
- Modify: `dystopia/monolith/infrastructure/aws/production/terragrunt.hcl`
- Modify: `dystopia/monolith/infrastructure/aws/modules/tests/private_trust_security_group.tftest.hcl`

**Interfaces:**
- Consumes: 検証済みの private trust attachment と成功した PostgreSQL query
- Produces: RDS common-only attachment、dedicated SG / rule の削除、不要 variable の削除

- [ ] **Step 1: Change the test to require the final RDS attachment**

既存 test の run block を次の内容へ変更する。

```hcl
run "uses_private_trust_security_group_for_rds" {
  command = plan

  assert {
    condition = (
      length(aws_db_instance.monolith.vpc_security_group_ids) == 1 &&
      aws_db_instance.monolith.vpc_security_group_ids[0] == data.aws_security_group.private_trust.id
    )
    error_message = "RDS must use only the private trust security group."
  }
}
```

次を実行する。

```bash
cd dystopia/monolith/infrastructure/aws/modules
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl
```

完了条件: RDS が二つの SG を持つため失敗する。

- [ ] **Step 2: Remove the dedicated SG and connect RDS only to private trust**

RDS argument を次の内容にする。

```hcl
  vpc_security_group_ids = [data.aws_security_group.private_trust.id]
```

`main.tf` から `data "aws_subnet" "private_details"`、`resource "aws_security_group" "monolith_db"`、`resource "aws_security_group_rule" "monolith_db_ingress"` の block 全体を削除する。

`variables.tf` から `variable "db_security_group_name"`、production `terragrunt.hcl` から `db_security_group_name` を削除する。完了した `// TODO:` marker も削除する。

`private_trust_security_group.tftest.hcl` から二つの `data.aws_subnet.private_details[...]` override block と `db_security_group_name` test variable を削除する。

- [ ] **Step 3: Run tests and static verification**

```bash
cd dystopia/monolith/infrastructure/aws/modules
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl

cd ../production
aqua exec -- terragrunt hcl format --check --file terragrunt.hcl

cd "$(git rev-parse --show-toplevel)"
git diff --check
```

完了条件: 全 command が成功する。

- [ ] **Step 4: Commit, push, and open the RDS cleanup Draft PR**

```bash
git add \
  dystopia/monolith/infrastructure/aws/modules \
  dystopia/monolith/infrastructure/aws/production/terragrunt.hcl
git commit -s -m "refactor: remove monolith database security group"
git push -u origin HEAD
gh pr create --draft \
  --title "Remove the monolith RDS dedicated SG" \
  --body "Uses only the verified VPC trust SG and removes the obsolete RDS SG and ingress rule."
gh pr edit --add-label deploy:monolith
```

完了条件: CI plan は RDS SG association の in-place update、SG rule 一つの destroy、SG 一つの destroy だけを含む。RDS instance / subnet group replacement があれば merge しない。

- [ ] **Step 5: Verify RDS after the destructive cleanup**

merge と apply の完了後に実行する。

```bash
aws rds wait db-instance-available \
  --region ap-northeast-1 \
  --db-instance-identifier monolith-production

aws rds describe-db-instances \
  --region ap-northeast-1 \
  --db-instance-identifier monolith-production \
  --query 'DBInstances[0].VpcSecurityGroups' \
  --output json \
  | jq -e \
      --arg common "$private_trust_sg_id" '
        length == 1
        and .[0].Status == "active"
        and .[0].VpcSecurityGroupId == $common
      '

aws ec2 describe-security-groups \
  --region ap-northeast-1 \
  --filters \
    "Name=vpc-id,Values=$production_vpc_id" \
    Name=group-name,Values=monolith-database-production \
  --query 'length(SecurityGroups)' \
  --output text | grep -Fx 0

kubectl exec deployment/monolith -n dystopia -c monolith -- \
  sh -c 'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc "select 1"'
```

完了条件: RDS は common SG 一件だけを持ち、旧 SG は存在せず、SQL 出力は `1` である。

### Task 9: Remove the EKS Module Security Groups and Cleanup Workaround

**Files:**
- Modify: `aws/eks/modules/main.tf`
- Modify: `aws/eks/modules/outputs.tf`
- Modify: `aws/eks/lookup/main.tf`
- Modify: `aws/eks/lookup/outputs.tf`
- Modify: `aws/eks/lookup/tests/security_groups.tftest.hcl`
- Modify: `aws/eks/tests/security-group-contract.sh`
- Modify: `aws/eks/modules/tests/private_trust_security_group.tftest.hcl`

**Interfaces:**
- Consumes: module node SG attachment count zero、control plane common SG attachment、`module.vpc.security_groups.private_trust.id`
- Produces: EKS module cluster / node SG の削除、最終 primary-only EKS output contract、`local-exec` の削除

- [ ] **Step 1: Change the EKS tests to require the final SG state**

`aws/eks/modules/tests/private_trust_security_group.tftest.hcl` の既存 run block を次の内容へ変更する。

```hcl
run "uses_private_trust_security_group_for_eks" {
  command = plan

  assert {
    condition     = module.eks.cluster_security_group_id == module.vpc.security_groups.private_trust.id
    error_message = "The EKS module must use the private trust SG instead of creating a cluster SG."
  }

  assert {
    condition     = module.eks.node_security_group_id == module.vpc.security_groups.private_trust.id
    error_message = "The EKS module must use the private trust SG instead of creating a node SG."
  }

  assert {
    condition     = output.cluster_primary_security_group_id == module.eks.cluster_primary_security_group_id
    error_message = "The root output must expose the EKS-owned primary SG explicitly."
  }
}
```

`aws/eks/tests/security-group-contract.sh` の末尾にある common SG check を、次の exact-set assertion へ変更する。

```bash
expected_security_groups="sg-private-trust"
if test "$control_plane_security_groups" != "$expected_security_groups"; then
  printf 'expected control plane security groups:\n%s\n' "$expected_security_groups" >&2
  printf 'planned control plane security groups:\n%s\n' "$control_plane_security_groups" >&2
  exit 1
fi
```

それ以外の test 処理は維持する。

次を実行する。

```bash
bash aws/eks/tests/security-group-contract.sh

cd aws/eks/modules
aqua exec -- tofu init -backend=false
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl
```

完了条件: EKS plan contract は移行用 module cluster SG が残るため失敗し、OpenTofu assertion は module が作成した cluster と node SG ID が `sg-private-trust` と異なるため失敗する。

- [ ] **Step 2: Switch the EKS module to existing SG inputs**

移行用の `additional_security_group_ids` configuration を次の最終構成へ変更する。

```hcl
  create_security_group = false
  security_group_id     = module.vpc.security_groups.private_trust.id

  create_node_security_group = false
  node_security_group_id     = module.vpc.security_groups.private_trust.id
```

`data "aws_security_group" "node_sg"` と `resource "terraform_data" "node_sg_cluster_tag_removal"` の block 全体を削除する。完了した `// TODO:` marker と error を握りつぶす `|| true` command も同時に削除する。

- [ ] **Step 3: Finalize the EKS output contracts**

`aws/eks/modules/outputs.tf` では `cluster_primary_security_group_id` を残し、`output "cluster_security_group_id"` と `output "node_security_group_id"` の block 全体を削除する。

`aws/eks/lookup/main.tf` から `data "aws_security_group" "node"` と、その前提を説明する不要になった comment を削除する。

`aws/eks/lookup/outputs.tf` の `cluster` object には次を残す。

```hcl
cluster_primary_security_group_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
```

旧 `cluster_security_group_id` alias と `node_security_group_id` field を削除する。certificate、network、OIDC field は変更しない。

`aws/eks/lookup/tests/security_groups.tftest.hcl` から `data.aws_security_group.node` override と二つの compatibility assertion を削除する。`cluster_primary_security_group_id == "sg-primary"` assertion は残す。

- [ ] **Step 4: Run all EKS and lookup tests**

```bash
bash aws/eks/tests/security-group-contract.sh

cd aws/eks/modules
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl

cd ../lookup
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/security_groups.tftest.hcl

cd ../../..
git diff --check
```

完了条件: 全 command が成功する。

- [ ] **Step 5: Inspect the destructive EKS cleanup plan**

完了条件: PR の CI plan は次だけを含む。

- EKS control plane additional SG set を module cluster + common から common へ変更する in-place update
- module cluster SG rule と SG の destroy
- module node SG rule と SG の destroy
- `terraform_data.node_sg_cluster_tag_removal` の destroy
- output だけの変更

EKS cluster replacement、control plane ENI replacement、IAM replacement、addon replacement、`DependencyViolation` risk のいずれかがあれば merge しない。

- [ ] **Step 6: Commit, push, and open the EKS cleanup Draft PR**

```bash
git add aws/eks/modules aws/eks/lookup aws/eks/tests/security-group-contract.sh
git commit -s -m "refactor: remove eks module security groups"
git push -u origin HEAD
gh pr create --draft \
  --title "Remove the EKS module security groups" \
  --body "Uses the VPC trust SG as the existing EKS SG and removes the node tag cleanup workaround."
gh pr edit --add-label deploy:eks
```

- [ ] **Step 7: Verify EKS cleanup after merge and apply**

```bash
aws eks describe-cluster \
  --region ap-northeast-1 \
  --name eks-production \
  --query 'cluster.resourcesVpcConfig' \
  --output json \
  | jq -e \
      --arg common "$private_trust_sg_id" '
        (.clusterSecurityGroupId | length) > 0
        and .securityGroupIds == [$common]
      '

for removed_name in eks-production eks-production-node; do
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --filters \
      "Name=vpc-id,Values=$production_vpc_id" \
      "Name=tag:Name,Values=$removed_name" \
    --query 'length(SecurityGroups)' \
    --output text | grep -Fx 0
done

kubectl get --raw=/readyz
kubectl wait --for=condition=Ready nodes --all --timeout=10m
```

完了条件: EKS primary と common SG が control plane に残り、module cluster / node SG は存在せず、cluster と全 node が Ready である。

### Task 10: Final Verification and Handoff

**Files:**
- Modify: none

**Interfaces:**
- Consumes: Tasks 1–9 の merge / apply 済み state
- Produces: automated test evidence、zero-diff plan、runtime completion evidence

- [ ] **Step 1: Run the complete local test set in platform**

```bash
cd aws/vpc/modules
aqua exec -- tofu test -filter=tests/private_trust.tftest.hcl

cd ../lookup
aqua exec -- tofu test -filter=tests/private_trust.tftest.hcl

cd ../../eks/modules
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl

cd ../lookup
aqua exec -- tofu test -filter=tests/security_groups.tftest.hcl

cd ../../..
bash aws/eks/tests/security-group-contract.sh
bash aws/eks-karpenter/tests/security-group-contract.sh
bash kubernetes/components/karpenter/tests/security-group-selectors.sh
kustomize build kubernetes/components/karpenter/production/kustomization >/dev/null
git diff --check
```

完了条件: 追加した全 test と static check が成功する。

- [ ] **Step 2: Run the complete local test set in monorepo**

```bash
cd dystopia/monolith/infrastructure/aws/modules
aqua exec -- tofu fmt -check -recursive
aqua exec -- tofu test -filter=tests/private_trust_security_group.tftest.hcl

cd "$(git rev-parse --show-toplevel)"
git diff --check
```

完了条件: 全 command が成功する。

- [ ] **Step 3: Confirm old runtime contracts no longer exist in active code**

platform repository root から次を実行する。

```bash
if rg -n 'module\.eks\.cluster\.node_security_group_id' aws kubernetes \
  --glob '!docs/superpowers/**'; then
  exit 1
fi

if rg -n '^output "(cluster_security_group_id|node_security_group_id)"' aws/eks; then
  exit 1
fi

if rg -n 'terraform_data\.node_sg_cluster_tag_removal|data\.aws_security_group\.node_sg' aws/eks; then
  exit 1
fi

if rg -n 'TODO: (Replace the module cluster SG|Remove the module node SG)' aws; then
  exit 1
fi
```

monorepo root から次を実行する。

```bash
if rg -n 'aws_security_group\.monolith_db|db_security_group_name' \
  dystopia/monolith/infrastructure/aws; then
  exit 1
fi

if rg -n 'TODO: Remove the dedicated RDS SG' \
  dystopia/monolith/infrastructure/aws; then
  exit 1
fi
```

完了条件: 各 command group は一致結果を出さず exit code 0 で終了する。過去状態の記録は current runtime code ではなく Git history が所有するため、historical spec / plan は検索対象から除外する。

- [ ] **Step 4: Run zero-diff Terragrunt plans**

platform では次を実行する。

```bash
for stack_dir in \
  aws/vpc/production \
  aws/eks/production \
  aws/eks-karpenter/production; do
  (
    cd "$stack_dir"
    TG_TF_PATH=tofu aqua exec -- terragrunt plan -detailed-exitcode
  )
done
```

monorepo では次を実行する。

```bash
cd dystopia/monolith/infrastructure/aws/production
TG_TF_PATH=tofu aqua exec -- terragrunt plan -detailed-exitcode
```

完了条件: 全 plan が差分なしの exit code 0 で終了する。exit code 2 なら drift が残っているため完了を停止する。

- [ ] **Step 5: Verify the final runtime state**

```bash
kubectl get --raw=/readyz
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodeclaims -o json \
  | jq -e '.items | length > 0 and all(.[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))'
kubectl get pods --all-namespaces -o json \
  | jq -e '
      all(.items[];
        if any(.metadata.ownerReferences[]?; .kind == "Job") then
          .status.phase == "Succeeded"
        else
          .status.phase == "Running"
          and any(.status.conditions[]?; .type == "Ready" and .status == "True")
        end
      )
    '

kubectl exec deployment/monolith -n dystopia -c monolith -- \
  getent hosts kubernetes.default.svc.cluster.local
kubectl exec deployment/monolith -n dystopia -c monolith -- \
  sh -c 'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc "select 1"'

if kubectl -n kube-system logs deployment/aws-load-balancer-controller --since=30m \
  | grep -Fq 'expected exactly one securityGroup'; then
  echo "AWS Load Balancer Controller reported ambiguous target security groups." >&2
  exit 1
fi

curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' https://dystopia.city/
```

```bash
aws eks describe-cluster \
  --region ap-northeast-1 \
  --name eks-production \
  --query 'cluster.resourcesVpcConfig' \
  --output json \
  | jq -e \
      --arg common "$private_trust_sg_id" '
        (.clusterSecurityGroupId | length) > 0
        and .securityGroupIds == [$common]
      '

read -r -a cluster_instance_ids <<<"$(
  kubectl get nodes -o json \
    | jq -r '.items[].spec.providerID | split("/")[-1]' \
    | tr '\n' ' '
)"
test "${#cluster_instance_ids[@]}" -gt 0

aws ec2 describe-instances \
  --region ap-northeast-1 \
  --instance-ids "${cluster_instance_ids[@]}" \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.Reservations[].Instances[]
          | .SecurityGroups | map(.GroupId) as $groups
          | ($groups | length) == 2
            and ($groups | index($primary) != null)
            and ($groups | index($common) != null)
        ] as $checks
        | ($checks | length) > 0 and ($checks | all)
      '

aws ec2 describe-network-interfaces \
  --region ap-northeast-1 \
  --filters \
    "Name=vpc-id,Values=$production_vpc_id" \
    Name=tag-key,Values=io.cilium/cilium-managed \
  --output json \
  | jq -e \
      --arg primary "$primary_sg_id" \
      --arg common "$private_trust_sg_id" '
        [.NetworkInterfaces[]
          | .Groups | map(.GroupId) as $groups
          | ($groups | index($primary) != null)
            and ($groups | index($common) != null)
        ] as $checks
        | ($checks | length) > 0 and ($checks | all)
      '

aws rds describe-db-instances \
  --region ap-northeast-1 \
  --db-instance-identifier monolith-production \
  --query 'DBInstances[0].VpcSecurityGroups' \
  --output json \
  | jq -e \
      --arg common "$private_trust_sg_id" '
        length == 1
        and .[0].Status == "active"
        and .[0].VpcSecurityGroupId == $common
      '
```

```bash
private_trust_sg_json="$(
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --group-ids "$private_trust_sg_id" \
    --output json
)"

jq -e --arg sg_id "$private_trust_sg_id" '
  .SecurityGroups[0] as $sg
  | ($sg.IpPermissions | length) == 1
  and ($sg.IpPermissions[0].IpProtocol == "-1")
  and ($sg.IpPermissions[0].UserIdGroupPairs | map(.GroupId) | index($sg_id) != null)
  and ($sg.IpPermissionsEgress | length) == 1
  and ($sg.IpPermissionsEgress[0].IpProtocol == "-1")
  and ($sg.IpPermissionsEgress[0].IpRanges | map(.CidrIp) | index("0.0.0.0/0") != null)
  and ($sg.Tags | map(.Key) | index("aws:eks:cluster-name") == null)
  and ($sg.Tags | map(.Key) | map(startswith("kubernetes.io/cluster/")) | any | not)
' <<<"$private_trust_sg_json"

aws ec2 describe-security-groups \
  --region ap-northeast-1 \
  --filters "Name=vpc-id,Values=$production_vpc_id" Name=group-name,Values=default \
  --output json \
  | jq -e '.SecurityGroups | length == 1 and .[0].IpPermissions == [] and .[0].IpPermissionsEgress == []'

for removed_name in eks-production eks-production-node; do
  aws ec2 describe-security-groups \
    --region ap-northeast-1 \
    --filters \
      "Name=vpc-id,Values=$production_vpc_id" \
      "Name=tag:Name,Values=$removed_name" \
    --query 'length(SecurityGroups)' \
    --output text | grep -Fx 0
done

aws ec2 describe-security-groups \
  --region ap-northeast-1 \
  --filters \
    "Name=vpc-id,Values=$production_vpc_id" \
    Name=group-name,Values=monolith-database-production \
  --query 'length(SecurityGroups)' \
  --output text | grep -Fx 0
```

完了条件: coexistence 中だけでなく旧 SG 削除後も全 check が成功する。HTTP status は Task 0 baseline と一致し、SQL は `1` を返す。

- [ ] **Step 6: Produce the final evidence report**

次を報告する。

- `VERIFIED`: 実行した test / format / plan / AWS / kubectl command と、関連する出力
- `REASONED`: 残る EKS primary と controller SG を custom SG 統合対象外とする理由
- `ASSUMED`: 必要な production access がなく未確認の事実だけ
- 削除した resource: module cluster SG、module node SG、RDS dedicated SG、および再作成時に新 ID になること
- 残る resource: EKS primary、private trust、locked default、controller-created load balancer SG

完了条件: 未完了の code task、失敗した gate、zero-diff plan の失敗がいずれも残っていない。
