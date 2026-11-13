# Changelog

## [0.1.1](https://github.com/panicboat/platform/compare/eks-logs-v0.1.0...eks-logs-v0.1.1) (2026-11-13)


### Code Refactoring

* **aws:** build common tags only in root.hcl and drop undeclared inputs ([#1250](https://github.com/panicboat/platform/issues/1250)) ([a7240a7](https://github.com/panicboat/platform/commit/a7240a71a5ade1d37074f13f83de1a499063fb52))
* derive terragrunt state keys from the unit path ([#1200](https://github.com/panicboat/platform/issues/1200)) ([25f159d](https://github.com/panicboat/platform/commit/25f159d1a81181ef15c4f576bba655d855dfcf82))
* drop environment names from the EKS stacks and the GCP OAuth project ([#1248](https://github.com/panicboat/platform/issues/1248)) ([6cceba6](https://github.com/panicboat/platform/commit/6cceba61145068e9efa11f6c37ed8ee90a33bdad))


### Miscellaneous Chores

* **aws/eks-logs/modules:** update terraform aws to v6.70.0 ([#1149](https://github.com/panicboat/platform/issues/1149)) ([40cf4fa](https://github.com/panicboat/platform/commit/40cf4fa843d2f5032ee4b2653d1d33321d774b8e))
* **aws/eks-logs/modules:** update terraform aws to v6.71.0 ([#1227](https://github.com/panicboat/platform/issues/1227)) ([98f4af6](https://github.com/panicboat/platform/commit/98f4af6058430ad0de431ce268919f3ca9946991))
* **aws/eks-logs/modules:** update terraform aws to v6.72.0 ([#1281](https://github.com/panicboat/platform/issues/1281)) ([387f025](https://github.com/panicboat/platform/commit/387f0258caa69efd4641d7062e49713fedad78a2))
* **aws/eks-logs/modules:** update terraform hashicorp/terraform to v1.13.9 ([#1262](https://github.com/panicboat/platform/issues/1262)) ([923acf6](https://github.com/panicboat/platform/commit/923acf63a1416a2064c12f1fa50be7c74736898c))
