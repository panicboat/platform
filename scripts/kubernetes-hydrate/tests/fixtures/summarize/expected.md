### Images

Collected from `image` fields and from other string values shaped like `registry/repository:tag` (args, env).

| Repository | Base | Head |
|---|---|---|
| localhost:5000/sidecar | - | 0.1@sha256:abc |
| nginx | - | (untagged) |
| quay.io/example/reloader | v0.93.1 | v0.94.1 |
| quay.io/prometheus/prometheus | v3.14.0 | v3.15.0 |
| registry.example.com/app | 1.0 | 2.0 |

### CustomResourceDefinitions

`*` marks the storage version.

| Name | Base | Head |
|---|---|---|
| gadgets.example.com | v1* | - |
| widgets.example.com | v1alpha1* | v1alpha1 (not served), v1* |

### Resources

Added:
- ConfigMap ns-a/new

Removed:
- ConfigMap ns-a/old
- CustomResourceDefinition gadgets.example.com
