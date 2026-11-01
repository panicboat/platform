# Changelog

## [0.2.0](https://github.com/panicboat/platform/compare/github-oidc-auth-v0.1.0...github-oidc-auth-v0.2.0) (2026-11-01)


### Features

* add the claude-code role and the OAuth token secret for the review workflows ([#1187](https://github.com/panicboat/platform/issues/1187)) ([e898425](https://github.com/panicboat/platform/commit/e8984259c79fc7b094734d56f73216227971e217))
* **aws:** let the monorepo docs sync check assume the bedrock role ([#1103](https://github.com/panicboat/platform/issues/1103)) ([df105f8](https://github.com/panicboat/platform/commit/df105f8f3414672088427e2501b0a3a0d26c069b))
* review renovate major updates with claude on bedrock ([#1101](https://github.com/panicboat/platform/issues/1101)) ([79acecb](https://github.com/panicboat/platform/commit/79acecbd7cf722590703465aea874374850f4193))


### Code Refactoring

* derive terragrunt state keys from the unit path ([#1200](https://github.com/panicboat/platform/issues/1200)) ([25f159d](https://github.com/panicboat/platform/commit/25f159d1a81181ef15c4f576bba655d855dfcf82))
* name the Claude Code OAuth token secret like the production secrets ([#1197](https://github.com/panicboat/platform/issues/1197)) ([2eef633](https://github.com/panicboat/platform/commit/2eef633c40187b77920b1bafa08cd752f0ae4510))


### Miscellaneous Chores

* **aws/github-oidc-auth/modules:** update terraform aws to v6.70.0 ([#1155](https://github.com/panicboat/platform/issues/1155)) ([75c7cfc](https://github.com/panicboat/platform/commit/75c7cfca2c905f1c6737c8217abeb9568113338b))
* **aws/github-oidc-auth/modules:** update terraform aws to v6.71.0 ([#1232](https://github.com/panicboat/platform/issues/1232)) ([b80a787](https://github.com/panicboat/platform/commit/b80a787be2df1ee4c915e25c9fb803789717f7e0))
* **aws/github-oidc-auth/modules:** update terraform hashicorp/terraform to v1.13.2 ([#1130](https://github.com/panicboat/platform/issues/1130)) ([49f45c0](https://github.com/panicboat/platform/commit/49f45c025bd80d24a8ab1025406fc8867e64e058))
* remove the Bedrock role for the review workflows ([#1184](https://github.com/panicboat/platform/issues/1184)) ([9ca1613](https://github.com/panicboat/platform/commit/9ca16133941679c9afa89194ac089c0ed30df462))
