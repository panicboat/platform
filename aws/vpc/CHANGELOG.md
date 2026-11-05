# Changelog

## [0.2.0](https://github.com/panicboat/platform/compare/vpc-v0.1.0...vpc-v0.2.0) (2026-11-05)


### Features

* **aws/vpc:** share an IPv6-egress VPC without NAT and drop environment names ([#1247](https://github.com/panicboat/platform/issues/1247)) ([0892b1a](https://github.com/panicboat/platform/commit/0892b1a7b690daadba48b1bcb8a43beb160132b9))


### Code Refactoring

* **aws:** build common tags only in root.hcl and drop undeclared inputs ([#1250](https://github.com/panicboat/platform/issues/1250)) ([a7240a7](https://github.com/panicboat/platform/commit/a7240a71a5ade1d37074f13f83de1a499063fb52))
* derive terragrunt state keys from the unit path ([#1200](https://github.com/panicboat/platform/issues/1200)) ([25f159d](https://github.com/panicboat/platform/commit/25f159d1a81181ef15c4f576bba655d855dfcf82))


### Miscellaneous Chores

* **aws/vpc/modules:** update terraform aws to v6.70.0 ([#1162](https://github.com/panicboat/platform/issues/1162)) ([8c5c641](https://github.com/panicboat/platform/commit/8c5c6413e57e2fb911b02fd7e9ae9b5c888a5f56))
* **aws/vpc/modules:** update terraform aws to v6.71.0 ([#1236](https://github.com/panicboat/platform/issues/1236)) ([bdc5bdb](https://github.com/panicboat/platform/commit/bdc5bdbd3ffd8a61d9877eea3e658987384c2c29))
* **aws/vpc/modules:** update terraform hashicorp/terraform to v1.13.2 ([#1136](https://github.com/panicboat/platform/issues/1136)) ([d182ce4](https://github.com/panicboat/platform/commit/d182ce45de0f2eed76356a25ccb20eaf63aa41c6))
