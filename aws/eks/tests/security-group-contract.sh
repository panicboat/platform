#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
module_dir="$repository_root/aws/eks/modules"
module_source="$module_dir/main.tf"

for module_file in "$module_dir"/*.tf; do
  if grep -Eq '^[[:space:]]*resource[[:space:]]+"aws_security_group"[[:space:]]+"cluster"' "$module_file"; then
    printf 'root cluster security group resource must not be configured: %s\n' "$module_file" >&2
    exit 1
  fi
done

module_eks_configuration="$(
  awk '
    /^module "eks" \{/ {
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

if test -z "$module_eks_configuration"; then
  echo 'module "eks" block must be configured.' >&2
  exit 1
fi

required_configuration=(
  '  create_security_group      = false'
  '  security_group_id          = module.vpc.security_groups.private_trust.id'
  '  create_node_security_group = false'
  '  node_security_group_id     = module.vpc.security_groups.private_trust.id'
)

for expected_line in "${required_configuration[@]}"; do
  if ! grep -Fxq "$expected_line" <<<"$module_eks_configuration"; then
    printf 'missing EKS security group configuration: %s\n' "$expected_line" >&2
    exit 1
  fi
done

if grep -Eq '^[[:space:]]*additional_security_group_ids[[:space:]]*=' "$module_source"; then
  echo 'additional_security_group_ids must not be configured.' >&2
  exit 1
fi

plan_output="$(
  cd "$module_dir"
  aqua exec -- tofu test \
    -no-color \
    -verbose \
    -filter=tests/private_trust_security_group.tftest.hcl
)"

control_plane_security_groups="$(
  awk '
    /^  # module\.eks\.aws_eks_cluster\.this/ { in_cluster = 1; next }
    /^  # / { in_cluster = 0; capture = 0; next }
    in_cluster && /^[[:space:]]+[+~]?[[:space:]]*security_group_ids[[:space:]]*=[[:space:]]*\[/ { capture = 1; next }
    capture && /^[[:space:]]+\]/ { exit }
    capture {
      gsub(/[+~ \",]/, "")
      if (length > 0) print
    }
  ' <<<"$plan_output"
)"

expected_security_groups="sg-private-trust"
if test "$control_plane_security_groups" != "$expected_security_groups"; then
  printf 'planned control plane security groups:\n%s\n' "$control_plane_security_groups" >&2
  exit 1
fi

echo "EKS security group contract passed."
