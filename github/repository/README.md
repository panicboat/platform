# GitHub Repository

## Actions Variables and Secrets

`master/<repo>.hcl` の `variables` と `secrets` に書いた名前と値が、その repo の Actions variable と secret になる。

`secrets` の値は repo ごとの public key で暗号化した暗号文で、復号できるのは GitHub だけなので git と state に置ける。
GitHub API は secret の値を返さないため、UI 等で外部から上書きすると更新時刻の差分として検知され、次の apply で hcl の値に戻る。

### Adding a Secret

1. 次のコマンドで暗号文を出力する

   ```sh
   gh secret set <NAME> --no-store -R panicboat/<repo> < <value-file>
   ```

2. 出力を `master/<repo>.hcl` の `secrets` に `<NAME> = "<ciphertext>"` として追加する

暗号文は作成時の repo の public key に紐づくため、GitHub が public key を変えた場合も同じ手順で作り直す。

## GitHub App Credentials

workflow が `actions/create-github-app-token` で使う App の認証情報は、`variables` の `APP_ID` と `secrets` の `APP_PRIVATE_KEY` に置く。

### Rotating the Private Key

CI の apply 自体がこの App の token で認証するため、古い鍵は新しい鍵の配布後に削除する。

1. GitHub App の設定画面で新しい private key を発行する
2. `APP_PRIVATE_KEY` を持つ全 repo について暗号文を作り直し、置き換えた PR を merge する
3. apply の完了後、古い private key を削除する

古い鍵を先に削除した場合は、新しい鍵で発行した token を `GITHUB_TOKEN` に設定して手元から apply する。
