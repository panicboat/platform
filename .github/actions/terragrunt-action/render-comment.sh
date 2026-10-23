#!/usr/bin/env bash
# Usage: ACTION_TYPE=… SERVICE_NAME=… ENVIRONMENT=… RUN_URL=… render-comment.sh <log-file> <exit-code>
set -euo pipefail

log_file=$1
exit_code=$2
max_bytes=${MAX_BYTES:-60000}
notice=""

if [ ! -f "$log_file" ]; then
  status="❌ Failed before Terragrunt ran"
  output="Terragrunt did not run. See the workflow logs."
else
  if [ "$exit_code" = "0" ]; then
    status="✅ Success"
  else
    status="❌ Failed (exit code: ${exit_code})"
  fi
  plain=$(perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' "$log_file")
  # Keep the tail because the plan summary and the errors come last.
  output=$(printf '%s' "$plain" | tail -c "$max_bytes")
  if [ "$(printf '%s' "$plain" | wc -c)" -gt "$max_bytes" ]; then
    notice="> ⚠️ Showing the last ${max_bytes} bytes. [View full logs](${RUN_URL})"
  fi
fi

cat <<EOF
## 🏗️ Terragrunt ${ACTION_TYPE} Results

**Service**: \`${SERVICE_NAME}\`
**Environment**: \`${ENVIRONMENT}\`
**Status**: ${status}
**Workflow Run**: ${RUN_URL}

${notice}

<details>
<summary>📋 Terragrunt Output</summary>

\`\`\`\`hcl
${output}
\`\`\`\`
</details>
EOF
