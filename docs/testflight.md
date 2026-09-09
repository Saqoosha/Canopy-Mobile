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

# 2. アップロード（scripts/ExportOptions.plist が destination: upload）
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath /tmp/canopy-export \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates

# 3. 届いたか確認（exit code を信用しない。下記）
asc builds info --app 6810164313 --latest

# 4. 内部テスターに配る（新しいビルドごとに要る）
asc builds add-groups --app 6810164313 --latest --group dfd19ebb-1ca7-43c9-8d59-6ff83e98bd28
```

`ExportOptions.plist` が `destination: upload` なので、**issuer ID なしで** Xcode にサインイン済みの Apple ID がそのままアップロードする。ローカルに `.ipa` を出して中身を見たいときだけ `export` に変える。

グループは `hasAccessToAllBuilds: false` なので、**ビルドを上げるたびに手順 4 が要る**。

`asc builds upload --app ID --ipa app.ipa` も存在する（WWDC25 の Build Upload API と思われる）。**未検証。** 通れば xcodebuild の export ごと不要になる。

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

### アップロードの exit code は証拠にならない

Xcode 26 の `altool` は**成功後に HTTP 500 を返す**、**似た bundle ID があると別のアプリを選ぶ**という報告がある。このチームには `sh.saqoo.canopy-app` と `sh.saqoo.pager-app` が並んでいるので他人事ではない。`Upload succeeded` を見たら必ず `asc builds info --app 6810164313 --latest` で `processingState: VALID` と build number を突き合わせる。

（2026-09-09 の初回アップロードでは実際には食い違わなかった。踏んでいない罠だが、確認のコストが安いので手順に残す。）

### `asc` の JSON はコマンドごとにトップレベルキーが違う

`asc builds groups list` は `{"groups":[...]}`、`asc testflight groups list` は `{"data":[...]}`。`data` 決め打ちでパースすると**空に見えて「紐付いていない」と誤読する**。実際にそれで一度誤判定した。

## 検証で使える基準値

| | |
|---|---|
| アップロード後にビルドが見えるまで | 約 157 秒 |
| `.ipa` サイズ | 約 4.4MB |
| 初回リリース | `0.1.0 (202609091843)`、`processingState: VALID`、`internalBuildState: IN_BETA_TESTING` |

## 輸出コンプライアンス

app（`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`）と extension（`Sources/CanopyMobileNotificationService/Info.plist`）の**両方**に入っている。これが無いとアップロードのたびに手で答えることになる。`false` が正しいのは、暗号は Apple 提供の `URLSession` HTTPS と Keychain しか使っていないから。独自の暗号、VPN、DRM を足したら見直す。

## 残タスク

- **`asc builds upload --ipa` が使えるか未検証。** 通れば archive → export の 2 段が 1 コマンドになる
- **App Store のバージョン欄が `1.0` のまま。** `asc web apps create --version 0.1.0` を渡したが `1.0` で作られた。TestFlight には影響しないが、審査に出す前に揃える
- **`xcrun mcpbridge`（Xcode 26.3+ の Apple 純正 MCP）は未導入。** ローカルのビルド・LLDB・SwiftUI プレビューを MCP で公開する。ASC には触れない
