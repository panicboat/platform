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
      gsub(/[+~ ",]/, "")
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
