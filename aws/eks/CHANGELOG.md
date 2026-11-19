# Changelog

## [0.2.0](https://github.com/panicboat/platform/compare/eks-v0.1.0...eks-v0.2.0) (2026-11-18)


### Features

* **aws/vpc:** share an IPv6-egress VPC without NAT and drop environment names ([#1247](https://github.com/panicboat/platform/issues/1247)) ([0892b1a](https://github.com/panicboat/platform/commit/0892b1a7b690daadba48b1bcb8a43beb160132b9))


### Code Refactoring

* **aws:** build common tags only in root.hcl and drop undeclared inputs ([#1250](https://github.com/panicboat/platform/issues/1250)) ([a7240a7](https://github.com/panicboat/platform/commit/a7240a71a5ade1d37074f13f83de1a499063fb52))
* derive terragrunt state keys from the unit path ([#1200](https://github.com/panicboat/platform/issues/1200)) ([25f159d](https://github.com/panicboat/platform/commit/25f159d1a81181ef15c4f576bba655d855dfcf82))
* drop environment names from the EKS stacks and the GCP OAuth project ([#1248](https://github.com/panicboat/platform/issues/1248)) ([6cceba6](https://github.com/panicboat/platform/commit/6cceba61145068e9efa11f6c37ed8ee90a33bdad))


### Miscellaneous Chores

* **aws/eks/modules:** update terraform aws to v6.70.0 ([#1154](https://github.com/panicboat/platform/issues/1154)) ([d921c4d](https://github.com/panicboat/platform/commit/d921c4dc3eac78def395ab1dfcbf6136e2c508ab))
* **aws/eks/modules:** update terraform aws to v6.71.0 ([#1231](https://github.com/panicboat/platform/issues/1231)) ([34af10e](https://github.com/panicboat/platform/commit/34af10eebc5079e9b60a06b1c08b16a525780f12))
* **aws/eks/modules:** update terraform aws to v6.72.0 ([#1285](https://github.com/panicboat/platform/issues/1285)) ([bdf37b5](https://github.com/panicboat/platform/commit/bdf37b5aa3ab2b28d61ee055f4b6ea59dced37a6))
* **aws/eks/modules:** update terraform aws to v6.73.0 ([#1320](https://github.com/panicboat/platform/issues/1320)) ([1f28bed](https://github.com/panicboat/platform/commit/1f28beddcca8fc1119c8cb0ddabe653226b4128f))
* **aws/eks/modules:** update terraform hashicorp/terraform to v1.13.2 ([#1129](https://github.com/panicboat/platform/issues/1129)) ([737fc01](https://github.com/panicboat/platform/commit/737fc01b7d0acbecf9c1f1c4b7cc6a0004fd96de))
* **aws/eks/modules:** update terraform hashicorp/terraform to v1.13.9 ([#1266](https://github.com/panicboat/platform/issues/1266)) ([8114b85](https://github.com/panicboat/platform/commit/8114b85fb7d785ec3191ed101a5be5e47c4425c2))
* **aws/eks/modules:** update terraform terraform-aws-modules/eks/aws to v21.30.0 ([#1335](https://github.com/panicboat/platform/issues/1335)) ([35afcfd](https://github.com/panicboat/platform/commit/35afcfd1aab75b970cea89e075f9c15795bd6b7d))
* **aws/eks/modules:** update terraform terraform-aws-modules/eks/aws to v21.30.2 ([#1337](https://github.com/panicboat/platform/issues/1337)) ([e5b6206](https://github.com/panicboat/platform/commit/e5b6206705bfc8c636447dcb7c05aad105ac1a3e))
* **aws/eks/modules:** update terraform terraform-aws-modules/iam/aws to ~&gt; 6.11 ([#1341](https://github.com/panicboat/platform/issues/1341)) ([cc48729](https://github.com/panicboat/platform/commit/cc487297e15ec3693e29b2d40bb8405cb15c5157))
