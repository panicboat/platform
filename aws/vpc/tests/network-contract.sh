#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
module_source="$repository_root/aws/vpc/modules/main.tf"

module_vpc_configuration="$(
  awk '
    /^module "vpc" \{/ {
      in_module = 1
    }
    in_module {
      print
    }
    in_module && /^}/ {
      exit
    }
  ' "$module_source"
)"

if test -z "$module_vpc_configuration"; then
  echo 'module "vpc" block must be configured.' >&2
  exit 1
fi

required_configuration=(
  '  name = "vpc"'
  '  enable_nat_gateway     = var.enable_nat_gateway'
  '  single_nat_gateway     = var.single_nat_gateway'
  '  enable_ipv6            = true'
  '  create_egress_only_igw = true'
  '  private_subnet_ipv6_prefixes                   = [0, 1, 2]'
  '  private_subnet_assign_ipv6_address_on_creation = true'
  '  private_subnet_enable_dns64 = var.enable_nat_gateway'
)

for expected_line in "${required_configuration[@]}"; do
  if ! grep -Fxq "$expected_line" <<<"$module_vpc_configuration"; then
    printf 'missing VPC network configuration: %s\n' "$expected_line" >&2
    exit 1
  fi
done

for forbidden_argument in public_subnet_ipv6_prefixes database_subnet_ipv6_prefixes; do
  if grep -Eq "^[[:space:]]*${forbidden_argument}[[:space:]]*=" <<<"$module_vpc_configuration"; then
    printf '%s must not be configured.\n' "$forbidden_argument" >&2
    exit 1
  fi
done

echo "VPC network contract passed."
