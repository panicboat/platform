# iam-service-linked-roles

Account 単位の IAM service-linked role (`aws_iam_service_linked_role`) を管理する stack。IAM は global service なので、service-linked role は region ではなく AWS account に1つだけ存在する。

## production 環境のみを使う

`production` 以外の環境ディレクトリ (`staging` 等) を追加しないこと。account 単位の singleton resource を複数 env から apply すると、2 つ目以降が `EntityAlreadyExists` で確実に失敗する。

複数 AWS account を使う構成になった場合のみ、その account 用に新しい env を追加してよい。

## 新しい service-linked role が必要になったら

新規 stack を作らず、`modules/main.tf` に `resource "aws_iam_service_linked_role"` block を追加する。
