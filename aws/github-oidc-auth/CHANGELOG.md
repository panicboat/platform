# Changelog

## [0.2.0](https://github.com/panicboat/platform/compare/github-oidc-auth-v0.1.0...github-oidc-auth-v0.2.0) (2026-11-13)


### Features

* add the claude-code role and the OAuth token secret for the review workflows ([#1187](https://github.com/panicboat/platform/issues/1187)) ([e898425](https://github.com/panicboat/platform/commit/e8984259c79fc7b094734d56f73216227971e217))
* **aws/github-oidc-auth:** add a Bedrock-only role for the dystopia e2e workflow ([#1300](https://github.com/panicboat/platform/issues/1300)) ([ad81ca3](https://github.com/panicboat/platform/commit/ad81ca324bb80066af5017426da582b0220bb2ee))
* **aws:** let the monorepo docs sync check assume the bedrock role ([#1103](https://github.com/panicboat/platform/issues/1103)) ([df105f8](https://github.com/panicboat/platform/commit/df105f8f3414672088427e2501b0a3a0d26c069b))
* review renovate major updates with claude on bedrock ([#1101](https://github.com/panicboat/platform/issues/1101)) ([79acecb](https://github.com/panicboat/platform/commit/79acecbd7cf722590703465aea874374850f4193))


### Code Refactoring

* **aws:** build common tags only in root.hcl and drop undeclared inputs ([#1250](https://github.com/panicboat/platform/issues/1250)) ([a7240a7](https://github.com/panicboat/platform/commit/a7240a71a5ade1d37074f13f83de1a499063fb52))
* derive terragrunt state keys from the unit path ([#1200](https://github.com/panicboat/platform/issues/1200)) ([25f159d](https://github.com/panicboat/platform/commit/25f159d1a81181ef15c4f576bba655d855dfcf82))
* name the Claude Code OAuth token secret like the production secrets ([#1197](https://github.com/panicboat/platform/issues/1197)) ([2eef633](https://github.com/panicboat/platform/commit/2eef633c40187b77920b1bafa08cd752f0ae4510))


### Miscellaneous Chores

* **aws/github-oidc-auth/modules:** update terraform aws to v6.70.0 ([#1155](https://github.com/panicboat/platform/issues/1155)) ([75c7cfc](https://github.com/panicboat/platform/commit/75c7cfca2c905f1c6737c8217abeb9568113338b))
* **aws/github-oidc-auth/modules:** update terraform aws to v6.71.0 ([#1232](https://github.com/panicboat/platform/issues/1232)) ([b80a787](https://github.com/panicboat/platform/commit/b80a787be2df1ee4c915e25c9fb803789717f7e0))
* **aws/github-oidc-auth/modules:** update terraform aws to v6.72.0 ([#1286](https://github.com/panicboat/platform/issues/1286)) ([8d5a0f5](https://github.com/panicboat/platform/commit/8d5a0f5e8396ffd5662459df3f5ed459db61444a))
* **aws/github-oidc-auth/modules:** update terraform hashicorp/terraform to v1.13.2 ([#1130](https://github.com/panicboat/platform/issues/1130)) ([49f45c0](https://github.com/panicboat/platform/commit/49f45c025bd80d24a8ab1025406fc8867e64e058))
* **aws/github-oidc-auth/modules:** update terraform hashicorp/terraform to v1.13.9 ([#1267](https://github.com/panicboat/platform/issues/1267)) ([14646be](https://github.com/panicboat/platform/commit/14646be76d875b1917625430368ff5e203bf280a))
* remove the Bedrock role for the review workflows ([#1184](https://github.com/panicboat/platform/issues/1184)) ([9ca1613](https://github.com/panicboat/platform/commit/9ca16133941679c9afa89194ac089c0ed30df462))
