# TestFlight 配信

## App Store Connect の台帳

| | |
|---|---|
| ASC アプリ名 | **Canopy for Saqoosha**（グローバルユニーク。ホーム画面の表示名 `Canopy` とは別物） |
| App ID | `6810164313` |
| Bundle ID | `sh.saqoo.canopy-app` |
| SKU | `sh.saqoo.canopy-app` |
| Primary locale | `en-US` |
| Internal group | `Internal` / `dfd19ebb-1ca7-43c9-8d59-6ff83e98bd28` |
| Tester | `a@saqoo.sh` のみ |
| TestFlight | <https://appstoreconnect.apple.com/apps/6810164313/testflight/ios> |

`Canopy Mobile` は**他アカウントが使用中**で、409 `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE.DIFFERENT_ACCOUNT` で弾かれた。Pager の ASC 名が `Pager for Saqoosha` なのも同じ壁を踏んだ跡。名前を変えるときはこの形に倣う。

## ツールは `asc`

[rorkai の `asc` CLI](https://github.com/rorkai/App-Store-Connect-CLI)（`brew install asc`、homebrew-core なので tap 不要）。Claude Code のスキルパックもある。

```bash
claude plugin marketplace add rorkai/app-store-connect-cli-skills
claude plugin install asc@rorkai
```

**Blitz は 2026-09-09 に削除した。** `asc` が同じ web セッション機能（アプリ作成、API キー一覧、契約状態、プライバシー申告、サンドボックステスター）を全部内包していて、失うものが無かった。Blitz 由来の `asc-app-create-ui` などのローカルスキルも一緒に消してある。

### 認証は 2 系統ある

| | 用途 | 期限 |
|---|---|---|
| ASC API キー（JWT） | 読み取り・ビルド・TestFlight・メタデータ | 無期限 |
| Apple web セッション | **アプリレコード作成**、API キー一覧、契約状態 | 約 30 日、2FA あり |

```bash
# API キー（1 回だけ。keychain に入る）
asc auth login --name canopy --key-id 76DV838N2N --key-type team \
  --issuer-id 69a6de6e-6653-47e3-e053-5b8c7c11a4d1 \
  --private-key ~/.appstoreconnect/private_keys/AuthKey_76DV838N2N.p8 --network

# web セッション（対話。パスワードと 2FA を手で入れる）
asc web auth login --apple-id a@saqoo.sh
```

キーは `76DV838N2N` = "Saqoosha-Personal-Mac"、ADMIN ロール。issuer ID は `asc web api-keys view --key-id 76DV838N2N` で取れる（`asc web auth status` の `publicProviderId` と同じ値）。**`--key-type individual` では通らない** — team キーなので issuer ID が必須。

**`asc web apps create --version` は効かない。** `0.1.0` を渡したのにアプリは `1.0` で作られた（理由は未確認 — iris が既定値を使うのか、作成時にこのフラグを見ないのか切り分けていない）。App Store のバージョンはビルドの `CFBundleShortVersionString` と一致していないとビルドを紐付けられないので、作成後に直す。

```bash
asc versions list --app 6810164313          # version-id を取る
asc versions update --version-id <ID> --version "0.1.0"
```

**`POST /v1/apps` は存在しない。** Apple の公式 API はアプリレコードを作れず、Admin ロールのキーでも `403 FORBIDDEN_ERROR — does not allow CREATE` が返る。だから `asc web apps create` は private な iris エンドポイントを web セッションで叩いている（`asc` はそれを `web` グループに隔離して不公式だと明示している）。要望は FB24429185 で未回答。調査の全文は [research/2026-09-09-asc-automation-2026.md](../research/2026-09-09-asc-automation-2026.md)。

## 手順

```bash
# 1. archive（ビルド番号はタイムスタンプで毎回ユニークに）
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
ARCHIVE=/tmp/canopy-$BUILD_NUMBER.xcarchive
xcodebuild archive -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates

# 2. .ipa を出す（scripts/ExportOptions.plist は destination: export）
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath /tmp/canopy-export \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates

# 3. アップロード。処理完了まで待って、exit code で判定してよい
asc builds upload --app 6810164313 --ipa /tmp/canopy-export/CanopyMobile.ipa \
  --wait --verify-timeout 60s

# 4. 内部テスターに配る（新しいビルドごとに要る）
asc builds add-groups --app 6810164313 --latest --group dfd19ebb-1ca7-43c9-8d59-6ff83e98bd28
```

グループは `hasAccessToAllBuilds: false` なので、**ビルドを上げるたびに手順 4 が要る**。

### アップロードに `asc` を使う理由

`asc builds upload` は WWDC25 の Build Upload API を叩く。ASC API キーの JWT だけで動き、`altool` も Transporter も web セッションも経由しない。`--dry-run` を付けると presigned URL の予約だけして中身を見せる（PUT の本数、チャンクの offset と length、7 日の期限）。

`xcodebuild -exportArchive` に `destination: upload` を書く道もあり、issuer ID なしで Xcode のサインイン済みアカウントが上げてくれる。**それでも `asc` を既定にしたのは exit code の信頼性のため。** xcodebuild のアップロードは `altool` に乗っていて、Xcode 26 の `altool` は成功後に HTTP 500 を返す、似た bundle ID があると別のアプリを選ぶ、という報告がある。`asc` は `--wait` で処理完了まで待ち、build id を返す。

実測（4.4MB の `.ipa`、アップロードからビルド発見・処理完了まで込み）: **97 秒、exit 0**。同時に `asc builds list` が 2 件に増え、`internalBuildState: READY_FOR_BETA_TESTING` になっていることも確認した。

`xcodebuild` の側で上げるときは **exit code を証拠にしない**。`Upload succeeded` を見たあとに `asc builds info --app 6810164313 --latest` で `processingState` と build number を突き合わせる。このチームには `sh.saqoo.canopy-app` と `sh.saqoo.pager-app` が並んでいるので、bundle ID の取り違えは他人事ではない。（初回アップロードでは実際には食い違わなかった。踏んでいない罠。）

**export の段は消えない** — `asc builds upload` は `.ipa` を要求するので、archive → export → upload の 3 段は変わらない。得られるのは往復の短縮ではなく、判定の確かさと `.ipa` を手元で検証できること。

## ハマりどころ（実体験）

### orientation 未宣言でサーバー側だけが落ちる（90474）

**症状**: `Upload succeeded` の直前まで行って `Invalid bundle. No orientations were specified in the sh.saqoo.canopy-app bundle`（code 90474）。

**原因**: `TARGETED_DEVICE_FAMILY = "1,2"` に iPad が含まれると、iPad マルチタスキングのために全 4 方向の宣言が要る。`GENERATE_INFOPLIST_FILE: YES` が生成する Info.plist には orientation キーが **1 つも入らない**。

**タチが悪いのは検出の遅さ。** ローカルの archive は `warning: All interface orientations must be supported unless the app requires full screen.` を出すだけで成功し、**アップロードし切ってから** Apple のサーバーに弾かれる。往復が長い。

**修正**: `project.yml` で iPhone は縦のみ、iPad だけ全 4 方向。iPad 側は検証を通すためだけの宣言で、UI が横向きを想定しているわけではない。Pager は Info.plist を手で持っていて最初から解いていたので、Canopy が `GENERATE_INFOPLIST_FILE` に寄せた時点で開いた穴だった。

### entitlements の `aps-environment` は export が上書きする

**`project.yml` に書いた値は最終成果物に届かない。** archive は automatic signing が Development profile を選ぶので `development` のまま焼かれ、`-exportArchive` が App Store distribution profile で**署名し直すときに** `production` に書き換わる。実測:

| | `aps-environment` |
|---|---|
| archive の `.app` | `development` |
| export 後の `.ipa` | `production`（+ `beta-reports-active: true`、`get-task-allow: false`）|

このセッションで Debug/Release の entitlements を config で分ける実装を一度入れたが、**不要だと分かって削除した**。Pager も `development` 単一のまま TestFlight に出ている。分けたくなったら、まずこの表を思い出す。

（XcodeGen の `entitlements:` プロパティは `settings.configs` の `CODE_SIGN_ENTITLEMENTS` を**後勝ちで潰す**ので、そもそも config 分岐は素直に書けない。分けるなら `entitlements:` を捨てて 2 ファイルを手で持つことになる。）

### `asc status` の `internalBuildState` は遅れる

**症状**: `asc status --app` が `internalBuildState: PROCESSING` を返し続ける。これを待つループは終わらない。

**原因**: 同時刻に `asc testflight distribution view --build-id <id>`（Apple の `buildBetaDetails` 直読み）は `READY_FOR_BETA_TESTING` を返していた。サマリー側が古い。

**判定に使うのは `distribution view` のほう。** ビルド到着そのものの判定は `asc builds info --app ID --latest` か、`asc status` の `No builds found` が消えるかで見る（実測 157 秒で出た）。

### `asc` の JSON はコマンドごとにトップレベルキーが違う

`asc builds groups list` は `{"groups":[...]}`、`asc testflight groups list` は `{"data":[...]}`。`data` 決め打ちでパースすると**空に見えて「紐付いていない」と誤読する**。実際にそれで一度誤判定した。

## APNs は production 経路に切り替わる

Xcode から入れた開発ビルドは sandbox のデバイストークンを登録し、**TestFlight と App Store のビルドは production のトークンを登録する**。relay は片方に固定していない — `worker/src/apns.ts` が `BadDeviceToken` を見て環境を切り替え、判定結果を `MACHINES` KV にキャッシュする。

**2026-09-09、TestFlight から入れたビルドで通知が届くことを実測した。** それまで production 経路は一度も本番で通っていない（実機テストが全部 Xcode の development インストールだった）。届かない場合に疑うのは自動判定か KV キャッシュで、切り分けは Worker のログで付く。

`aps-environment` を `project.yml` で production に変える必要は無い。上記のとおり export の再署名が入れてくれる。

## 検証で使える基準値

| | |
|---|---|
| アップロード後にビルドが見えるまで | 約 157 秒 |
| `.ipa` サイズ | 約 4.4MB |
| 初回リリース | `0.1.0 (202609091843)`、`processingState: VALID`、`internalBuildState: IN_BETA_TESTING` |

## 輸出コンプライアンス

app（`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`）と extension（`Sources/CanopyMobileNotificationService/Info.plist`）の**両方**に入っている。これが無いとアップロードのたびに手で答えることになる。`false` が正しいのは、暗号は Apple 提供の `URLSession` HTTPS と Keychain しか使っていないから。独自の暗号、VPN、DRM を足したら見直す。
