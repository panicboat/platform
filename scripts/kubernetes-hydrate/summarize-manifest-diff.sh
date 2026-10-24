#!/usr/bin/env bash
set -euo pipefail

base="${1:?base manifest required}"
head="${2:?head manifest required}"

export LC_ALL=C

image_refs() {
    {
        yq -N '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' "$1"
        yq -N '.. | select(tag == "!!str") | select(test("^(--[A-Za-z0-9-]+=)?[a-z0-9.-]+(:[0-9]+)?/[a-z0-9./_-]+:[A-Za-z0-9._-]+(@sha256:[a-f0-9]+)?$")) | sub("^--[A-Za-z0-9-]+=", "")' "$1"
    } | sort -u
}

split_image_refs() {
    awk -v side="$1" '{
        ref = $0; digest = ""; tag = ""; repo = ref
        at = index(ref, "@")
        if (at > 0) { digest = substr(ref, at); ref = substr(ref, 1, at - 1); repo = ref }
        n = split(ref, parts, "/"); last = parts[n]
        colon = index(last, ":")
        if (colon > 0) { tag = substr(last, colon + 1); repo = substr(ref, 1, length(ref) - length(last) + colon - 1) }
        tag = tag digest
        if (tag == "") tag = "(untagged)"
        print repo "\t" side "\t" tag
    }'
}

crd_versions() {
    yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name + "\t" + ([.spec.versions[] | .name + (if .served == false then " (not served)" else "" end) + (if .storage then "*" else "" end)] | join(", "))' "$1" | sort -u
}

resources() {
    yq -N 'select(.kind != null) | .kind + " " + (if .metadata.namespace then .metadata.namespace + "/" else "" end) + .metadata.name' "$1" | sort -u
}

pair_rows() {
    awk -F '\t' '{
        key[$1] = 1
        if ($2 == "base") base[$1] = (base[$1] == "" ? $3 : base[$1] ", " $3)
        else head[$1] = (head[$1] == "" ? $3 : head[$1] ", " $3)
    }
    END {
        for (k in key) if (base[k] != head[k]) print k "\t" (base[k] == "" ? "-" : base[k]) "\t" (head[k] == "" ? "-" : head[k])
    }' | sort
}

print_table() {
    local header="$1" rows="$2"
    if [ -z "${rows}" ]; then
        echo "No changes."
        return
    fi
    echo "| ${header} | Base | Head |"
    echo "|---|---|---|"
    printf '%s\n' "${rows}" | awk -F '\t' '{ print "| " $1 " | " $2 " | " $3 " |" }'
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# Extracting into files first lets set -e catch yq failures that command substitutions and process substitutions would hide.
for side in base head; do
    if [ "${side}" = base ]; then manifest="${base}"; else manifest="${head}"; fi
    image_refs "${manifest}" | split_image_refs "${side}" > "${tmp}/${side}.images"
    crd_versions "${manifest}" | awk -F '\t' -v side="${side}" '{ print $1 "\t" side "\t" $2 }' > "${tmp}/${side}.crds"
    resources "${manifest}" > "${tmp}/${side}.resources"
done

image_rows="$(cat "${tmp}/base.images" "${tmp}/head.images" | pair_rows)"
crd_rows="$(cat "${tmp}/base.crds" "${tmp}/head.crds" | pair_rows)"
added="$(comm -13 "${tmp}/base.resources" "${tmp}/head.resources")"
removed="$(comm -23 "${tmp}/base.resources" "${tmp}/head.resources")"

echo "### Images"
echo
if [ -n "${image_rows}" ]; then
    echo 'Collected from `image` fields and from other string values shaped like `registry/repository:tag` (args, env).'
    echo
fi
print_table "Repository" "${image_rows}"
echo
echo "### CustomResourceDefinitions"
echo
if [ -n "${crd_rows}" ]; then
    echo '`*` marks the storage version.'
    echo
fi
print_table "Name" "${crd_rows}"
echo
echo "### Resources"
echo
if [ -z "${added}" ] && [ -z "${removed}" ]; then
    echo "No changes."
fi
if [ -n "${added}" ]; then
    echo "Added:"
    printf '%s\n' "${added}" | sed 's/^/- /'
fi
if [ -n "${added}" ] && [ -n "${removed}" ]; then
    echo
fi
if [ -n "${removed}" ]; then
    echo "Removed:"
    printf '%s\n' "${removed}" | sed 's/^/- /'
fi
