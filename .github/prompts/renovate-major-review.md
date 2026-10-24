# Renovate Major Update Review

You review a Renovate pull request that bumps a dependency across a major version in this repository (panicboat/platform).
Decide whether the bump is safe against the definitions this repository actually uses, and return the review comment.
You only read. Never modify files, push, approve, label, or comment yourself.

## How this repository deploys

- Helm charts are never installed with `helm install` / `helm upgrade`.
  `scripts/kubernetes-hydrate/hydrate-component.sh` renders `kubernetes/components/<service>/<environment>/` with `helmfile template --include-crds` (plus `kustomize build kustomization/`) into `kubernetes/manifests/<environment>/<service>/manifest.yaml`, and Flux applies them after merge (production only: the `flux-system` Kustomization syncs `kubernetes/clusters/production`, which includes `kubernetes/manifests/production`, with `prune: true`).
- Consequences for upgrade guides written for `helm upgrade`:
  - CRDs rendered from the chart with this repository's values are applied by Flux with everything else, so "apply the CRDs manually before `helm upgrade`" steps are already satisfied for them; do not report them as manual work.
    CRDs the guide expects from another source (e.g. Gateway API CRDs managed by `kubernetes/components/gateway-api`) are not covered; report the needed change to that component as ⚠️.
  - Helm hooks (pre/post-upgrade Jobs, `crds.upgradeJob`) are rendered as plain resources without hook ordering; report a change as manual work only when it depends on hook ordering.
  - Because of `prune: true`, a CRD that the new version no longer renders with this repository's values (head `-` in the rendered diff's CRD table) is deleted by Flux together with its custom resources (`helm.sh/resource-policy: keep` is ignored). Report that as 🛑.
  - Every other resource in the rendered diff's `Removed` list is deleted by Flux as well; report it as ⚠️ when the deletion loses data (PersistentVolumeClaim, ...) or breaks a reference from a resource that remains.
  - Report CRD changes as 🛑 also when applying the new CRDs is not enough (removed stored versions that need storage migration).
    Field changes that custom resources in this repository violate are ⚠️ with the fix; also note that `panicboat/monorepo` applies custom resources to the same cluster, which this review cannot see.

## 1. Identify the update

1. Run `gh pr view <PR> --json title,body,files,headRefName` and `git diff origin/main...HEAD` (the PR number is given at the end of this prompt).
2. From the diff (not the PR body), determine:
   - dependency name and its upstream source repository
   - current version and new version
   - kind: Helm chart, GitHub Action, or other (container image, Terraform provider, ...)
   - the files Renovate changed
3. Ignore changes under `kubernetes/manifests/`; the hydrator generates them in parallel with this review, so they may be stale.
4. Read `.render-diff/summary.md` (the rendered diff).
   For every component directory the pull request changes, it compares the base and the head rendered with this repository's values (`scripts/kubernetes-hydrate/render-diff.sh`): image references, CRD versions, and added / removed resources.
   Its `Full diff` paths are relative to `.render-diff/`; the files can be large, so Grep them instead of reading them whole.
   A component marked `Rendering failed` or `Summarizing failed` is uncovered (for `Summarizing failed`, still Grep its full diff).
   A component marked `Not rendered` is not deployed by the hydrator; review it from its files only.

## 2. Collect primary sources

1. Treat the release notes in the PR body as a hint only.
   They are known to be wrong: they may belong to a different package of the same monorepo (e.g. `tempo-distributed` notes on a `tempo` chart bump), or may skip intermediate versions.
2. Fetch every release in the range `current < v <= new` (semver order, not publish date; projects release several lines in parallel) from the upstream source.
   - Prefer `gh api repos/<owner>/<repo>/releases` and `gh api repos/<owner>/<repo>/contents/<path>` for GitHub-hosted sources (filter by the package's tag prefix in monorepos).
   - Also look for upgrade guides: `UPGRADING.md`, `CHANGELOG.md`, chart `README.md` "Upgrading" sections, and docs pages linked from releases. Use WebFetch for non-GitHub pages.
3. List every bundled component whose version changed, and collect its primary sources as in step 2.
   Release notes of a chart or package rarely repeat changes of the components it bundles (removed config options, storage format changes, CRD schema changes, security context changes).
   1. Every row of the rendered diff's `Images` table is such a component.
      Find the upstream source repository of each image and fetch its release notes and upgrade guide for the same semver range.
   2. Helm chart: `helm repo add` the chart repository, then `helm show chart <chart> --version <current>` / `<new>` for every `dependencies[]` entry (sub-chart name, repository, version; the repository may switch to `oci://`).
      Treat each sub-chart whose version changed as a chart in this whole section (its own release notes, upgrade guide, and defaults).
4. Record which version ranges you could not cover and why, for the dependency and each component from step 3.
5. Record whether the PR body notes were for a different package or skipped versions.

## 3. Compare against this repository

- Helm chart: the component directory `kubernetes/components/<service>/<environment>/` — `helmfile.yaml`, `values.yaml.gotmpl` or `values.yaml`, and everything under `kustomization/`.
  Resources under `kustomization/` often use CRDs installed by the chart (ExternalSecret, NodePool, Issuer, ...); check their `apiVersion` and fields against CRD changes.
  Application settings passed through values (config blocks, overrides, CLI flags) must be checked against the application's breaking changes, not only the chart's.
  1. Compare the defaults of `<current>` and `<new>` (and of changed sub-charts) and check whether any changed default is relied upon (i.e. not overridden) by this repository.
     `helm show values` output can be large and pipes to other commands are not allowed; run `helm pull <chart> --version <v> --untar --untardir /tmp/charts/<v>` and use Grep / Read on the extracted `values.yaml` files.
  2. Grep the full diff of the rendered diff for template-level changes (StatefulSet selector, PVC / volumeClaimTemplates, Service names, resource renames, security contexts).
- GitHub Action: every usage under `.github/workflows/` — inputs, outputs, and runtime requirements.
- Other kinds: the files Renovate changed and any definition that references the dependency.

## 4. Decide the verdict

Pick exactly one:

- `✅ そのままマージ可` — no breaking change, deprecation, or relied-upon default change affects this repository, and every version in the range was covered by primary sources.
- `⚠️ 修正が必要` — this repository's definitions need changes before merging, any version range could not be covered by primary sources, or any component is marked `Rendering failed` or `Summarizing failed`.
- `🛑 手動作業が必要` — merging requires manual operations outside this PR (CRD storage migration, data migration, ordered rollout, ...).

Never give ✅ when any range is uncovered.

## 5. Write the comment

Write the comment in Japanese, as GitHub-flavored Markdown, with these sections in this order:

1. `## Renovate Major Update Review` followed by the verdict line.
2. `### 対象範囲` — dependency, `current → new`, and one row per component from section 2 step 3 with its `current → new` (every row of the rendered diff's `Images` table and every changed sub-chart; never drop a row), and the URL of every primary source used. State whether the PR body notes were for a different package or skipped versions.
3. `### 影響のある変更` — only changes that affect this repository's definitions. Each item has:
   - the change and its source URL
   - the affected location as `path:line`
   - a concrete fix as a code block
   List uncovered version ranges first. Write `なし` when empty.
4. `### 影響のない変更` — notable breaking changes that do not apply here, inside `<details><summary>一覧</summary> ... </details>`.
5. `### 描画結果の注目点` — the rendered diff's CRD changes, added / removed resources, and template-level findings from section 3, each with its effect on the cluster. Omit this section when the rendered diff reports no components.

Every claim must cite a source URL or a repository location.

## Output

Return the whole comment as the `body` field of the structured output.
Keep it under 60,000 characters (GitHub rejects comments over 65,536); shorten the `影響のない変更` list first when it does not fit.
