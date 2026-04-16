# aws/vpc — Production VPC Design

## Purpose

Establish a production VPC in `ap-northeast-1` that will host future workloads (EKS / ECS clusters, RDS, etc.). This is the foundational network for the account and supersedes the default VPC that was removed on 2026-04-16.

## Scope

- New Terragrunt service at `aws/vpc/` following the existing `aws/{service}/modules + envs/{env}` convention used by `claude-code`, `claude-code-action`, and `github-oidc-auth`.
- `production` environment only for now. `develop` / `staging` can be added later by copying `envs/production/`.
- VPC, subnets (3 tiers x 3 AZ), IGW, single NAT Gateway, route tables, DB subnet group.

## Out of Scope

- EKS, ECS, RDS resources themselves (separate services).
- VPC endpoints (S3, ECR, etc.) — add on demand when a workload needs them.
- Transit Gateway / VPC peering.
- Flow logs — to be added later if an audit requirement arises.
- Subnet tags for EKS (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`) — added by the EKS module, not here.

## Architecture

### Network layout

| Tier | AZ 1a | AZ 1c | AZ 1d | Route |
|---|---|---|---|---|
| Public | `10.0.0.0/24` | `10.0.1.0/24` | `10.0.2.0/24` | IGW |
| Database (isolated) | `10.0.10.0/24` | `10.0.11.0/24` | `10.0.12.0/24` | **no default route** |
| Private (compute) | `10.0.32.0/19` | `10.0.64.0/19` | `10.0.96.0/19` | NAT GW |

- **VPC CIDR**: `10.0.0.0/16`
- **IGW**: 1, attached to VPC; public subnets route `0.0.0.0/0` to it.
- **NAT GW**: 1 shared NAT Gateway placed in public-1a. All three private subnets route `0.0.0.0/0` to it. Trade-off accepted: AZ 1a outage breaks egress for private subnets in 1c/1d.
- **Database subnets**: fully isolated. Their dedicated route table has no default route. External egress (for secrets rotation etc.) is deliberately not provided here; add VPC endpoints later if needed.
- **DNS**: `enable_dns_support = true`, `enable_dns_hostnames = true` (EKS requirement).

### CIDR allocation (10.0.0.0/16)

```
10.0.0.0/24   - 10.0.2.0/24    public   (3 x /24)
10.0.3.0/24   - 10.0.9.0/24    reserved
10.0.10.0/24  - 10.0.12.0/24   database (3 x /24)
10.0.13.0/24  - 10.0.31.0/24   reserved
10.0.32.0/19                   private-1a
10.0.64.0/19                   private-1c
10.0.96.0/19                   private-1d
10.0.128.0/17                  reserved
```

Private subnets are sized `/19` (8192 IPs each) to accommodate EKS VPC CNI (one ENI IP per pod).

## Implementation

### Module

- Source: [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws) version `~> 6.0`.
- Chosen over raw `aws_vpc`/`aws_subnet` resources for brevity and edge-case coverage; this is a conscious departure from the raw-resource convention used by the other three services in this repo.

### Key module inputs

```hcl
name = "${var.project_name}-${var.environment}"
cidr = var.vpc_cidr                    # "10.0.0.0/16"
azs  = var.availability_zones          # ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]

public_subnets   = var.public_subnet_cidrs
private_subnets  = var.private_subnet_cidrs
database_subnets = var.database_subnet_cidrs

enable_nat_gateway     = true
single_nat_gateway     = true
one_nat_gateway_per_az = false

enable_dns_support   = true
enable_dns_hostnames = true

create_database_subnet_group           = true
create_database_subnet_route_table     = true
create_database_internet_gateway_route = false
create_database_nat_gateway_route      = false
```

### Files

```
aws/vpc/
├── Makefile                        # copy of existing services' Makefile (ENV=production)
├── root.hcl                        # same pattern as aws/claude-code/root.hcl; project_name = "vpc"
├── modules/
│   ├── main.tf                     # module "vpc" { source = "terraform-aws-modules/vpc/aws" ... }
│   ├── variables.tf                # vpc_cidr, availability_zones, *_subnet_cidrs, single_nat_gateway
│   ├── outputs.tf                  # see below
│   └── terraform.tf                # terraform >= 1.14.8, aws ~> 6.40 (matches existing services)
└── envs/
    └── production/
        ├── terragrunt.hcl          # include root + env; terraform.source = "../../modules"
        └── env.hcl                 # environment = "production", aws_region = "ap-northeast-1"
```

### Outputs

- `vpc_id`, `vpc_cidr_block`
- `public_subnet_ids`, `private_subnet_ids`, `database_subnet_ids`
- `public_subnet_cidrs`, `private_subnet_cidrs`, `database_subnet_cidrs`
- `database_subnet_group_name` (for RDS module consumers)
- `nat_public_ips` (IP allowlisting)
- `availability_zones`

### State

Reuses the existing shared backend (see `aws/claude-code/root.hcl`):
- Bucket: `terragrunt-state-<account_id>`
- Key: `platform/vpc/production/terraform.tfstate`
- Lock table: `terragrunt-state-locks`

## Data Flow / Failure Modes

- Public subnets: egress and ingress via IGW.
- Private subnets: egress via NAT GW. Single-NAT trade-off: AZ 1a failure severs egress for all private subnets. Acceptable given cost priority; revisit by flipping `single_nat_gateway = false` if availability requirements tighten.
- Database subnets: no internet path by design. RDS/ElastiCache placed here must be reached from private subnets within the same VPC. Cross-region replication or SaaS-triggered rotation requires adding a VPC endpoint later.

## Testing

- `terragrunt validate` in `envs/production/`.
- `terragrunt plan` review before apply.
- Post-apply verification: `aws ec2 describe-vpcs`, `describe-subnets`, `describe-nat-gateways`, `describe-route-tables` to confirm the expected topology.

## Dependencies

- `workflow-config.yaml` already enables the `production` environment (uncommitted edit on this branch). This is required for CI to target the new service's production stack.
