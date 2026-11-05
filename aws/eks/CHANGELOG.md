# Changelog

## [0.2.0](https://github.com/panicboat/platform/compare/eks-v0.1.0...eks-v0.2.0) (2026-11-05)


### Features

* **aws/vpc:** share an IPv6-egress VPC without NAT and drop environment names ([#1247](https://github.com/panicboat/platform/issues/1247)) ([0892b1a](https://github.com/panicboat/platform/commit/0892b1a7b690daadba48b1bcb8a43beb160132b9))


### Code Refactoring

* **aws:** build common tags only in root.hcl and drop undeclared inputs ([#1250](https://github.com/panicboat/platform/issues/1250)) ([a7240a7](https://github.com/panicboat/platform/commit/a7240a71a5ade1d37074f13f83de1a499063fb52))
* derive terragrunt state keys from the unit path ([#1200](https://github.com/panicboat/platform/issues/1200)) ([25f159d](https://github.com/panicboat/platform/commit/25f159d1a81181ef15c4f576bba655d855dfcf82))
* drop environment names from the EKS stacks and the GCP OAuth project ([#1248](https://github.com/panicboat/platform/issues/1248)) ([6cceba6](https://github.com/panicboat/platform/commit/6cceba61145068e9efa11f6c37ed8ee90a33bdad))


### Miscellaneous Chores

* **aws/eks/modules:** update terraform aws to v6.70.0 ([#1154](https://github.com/panicboat/platform/issues/1154)) ([d921c4d](https://github.com/panicboat/platform/commit/d921c4dc3eac78def395ab1dfcbf6136e2c508ab))
* **aws/eks/modules:** update terraform aws to v6.71.0 ([#1231](https://github.com/panicboat/platform/issues/1231)) ([34af10e](https://github.com/panicboat/platform/commit/34af10eebc5079e9b60a06b1c08b16a525780f12))
* **aws/eks/modules:** update terraform hashicorp/terraform to v1.13.2 ([#1129](https://github.com/panicboat/platform/issues/1129)) ([737fc01](https://github.com/panicboat/platform/commit/737fc01b7d0acbecf9c1f1c4b7cc6a0004fd96de))
