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
    /resource "aws_eks_cluster" "this"/ { in_cluster = 1 }
    in_cluster && /^[[:space:]]+[+~]?[[:space:]]*security_group_ids[[:space:]]*=[[:space:]]*\[/ { capture = 1; next }
    capture && /]/ { exit }
    capture {
      gsub(/[+~ \",]/, "")
      if (length > 0) print
    }
  ' <<<"$plan_output"
)"

if ! grep -Fxq sg-private-trust <<<"$control_plane_security_groups"; then
  printf 'planned control plane security groups:\n%s\n' "$control_plane_security_groups" >&2
  exit 1
fi

echo "EKS security group contract passed."
