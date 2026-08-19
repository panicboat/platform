# cost_optimization_hub.tf - AWS Cost Optimization Hub enrollment

# `status` は provider 6.60.0 で computed 属性 (= 設定不可)。リソースが存在する
# こと自体が Active を意味し、destroy で Inactive に戻る。
#
# `include_member_accounts` は optional + computed。省略すると AWS API が返す値を
# そのまま採用するため、省略した状態で plan に差分が出ない。org 横断の登録
# (= member アカウントを一括 opt-in) を有効にする場合のみ true を明示する。
# 有効化には Organizations 側で cost-optimization-hub.amazonaws.com の信頼された
# サービスアクセスが別途必要。
resource "aws_costoptimizationhub_enrollment_status" "this" {}

# aws_costoptimizationhub_preferences is intentionally NOT managed here.
#
# `member_account_discount_visibility` は optional + computed だが、AWS API の
# GetPreferences がこの属性を返さないため、リソースを追加すると provider が
# 毎回 "All" を書き込もうとする (= plan に `+ member_account_discount_visibility
# = "All"` が出続ける)。AWS 既定値も "All" のため、管理しても得られるものが無い。
#
# savings_estimation_mode も AWS 既定の "AfterDiscounts" のまま
# (= `aws cost-optimization-hub get-preferences` で確認)。既定から変える要件が
# 出た時点で、上記の書き込みを許容するかと併せて再検討する。
