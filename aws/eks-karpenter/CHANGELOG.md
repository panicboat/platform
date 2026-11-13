# Changelog

## [0.2.0](https://github.com/panicboat/platform/compare/eks-karpenter-v0.1.0...eks-karpenter-v0.2.0) (2026-11-13)


### Features

* **aws/vpc:** share an IPv6-egress VPC without NAT and drop environment names ([#1247](https://github.com/panicboat/platform/issues/1247)) ([0892b1a](https://github.com/panicboat/platform/commit/0892b1a7b690daadba48b1bcb8a43beb160132b9))


### Code Refactoring

* **aws:** build common tags only in root.hcl and drop undeclared inputs ([#1250](https://github.com/panicboat/platform/issues/1250)) ([a7240a7](https://github.com/panicboat/platform/commit/a7240a71a5ade1d37074f13f83de1a499063fb52))
* derive terragrunt state keys from the unit path ([#1200](https://github.com/panicboat/platform/issues/1200)) ([25f159d](https://github.com/panicboat/platform/commit/25f159d1a81181ef15c4f576bba655d855dfcf82))
* drop environment names from the EKS stacks and the GCP OAuth project ([#1248](https://github.com/panicboat/platform/issues/1248)) ([6cceba6](https://github.com/panicboat/platform/commit/6cceba61145068e9efa11f6c37ed8ee90a33bdad))


### Miscellaneous Chores

* **aws/eks-karpenter/modules:** update terraform aws to v6.70.0 ([#1147](https://github.com/panicboat/platform/issues/1147)) ([a26022e](https://github.com/panicboat/platform/commit/a26022ee285ecfcc82f66426a692084bf55c68b0))
* **aws/eks-karpenter/modules:** update terraform aws to v6.71.0 ([#1226](https://github.com/panicboat/platform/issues/1226)) ([e4656b1](https://github.com/panicboat/platform/commit/e4656b1c4adcb23ea6d9e2f9e74f2c495661f6e2))
* **aws/eks-karpenter/modules:** update terraform aws to v6.72.0 ([#1280](https://github.com/panicboat/platform/issues/1280)) ([3934723](https://github.com/panicboat/platform/commit/3934723f20d0adf1d296d584459561892ee5a79f))
* **aws/eks-karpenter/modules:** update terraform hashicorp/terraform to v1.13.9 ([#1261](https://github.com/panicboat/platform/issues/1261)) ([5d47b63](https://github.com/panicboat/platform/commit/5d47b63839f3389c435bb84016e3558c61b9ac7a))
