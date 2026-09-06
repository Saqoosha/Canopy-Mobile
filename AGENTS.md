# AGENTS.md — Canopy-Mobile プロジェクト知識

## これは何

Mac の [Canopy](https://github.com/Saqoosha/Canopy) で動いているセッションを iPhone から見る／答えるための、iOS アプリと Cloudflare Worker のリレー。

データは 2 経路ある。**どちらも他方の代わりにはならない。**

- **APNs push** — アプリが閉じていても届く。耐久性がある。`asking` は答えられる。`completed` / `asking` / `sent` の 3 種だけ
- **WebSocket のセッションイベント** — 前面のアプリにだけ届く。会話をそのまま流す。relay のリングバッファが持っている間だけ生きる

会話画面は両方を `eventId` で突き合わせてマージする。**レンチアイコンの細い行（tool）はストリーム経由でしか出ない** ので、ストリームが生きているかの目視判定に使える。

## スタック / 構成

| | |
|---|---|
| `worker/` | Cloudflare Worker。`MachineDO` は Mac 1 台につき 1 つの Durable Object で、roster スナップショットとセッションイベントのリングバッファ（SQLite）を持つ |
| `Sources/` | SwiftUI の iOS アプリ。`project.yml` から xcodegen で生成、**`.xcodeproj` は gitignore** |
| `Tests/` | swift-testing |
| `scripts/relay-event-probe.mjs` | **デプロイ済みの** relay に対する end-to-end チェック |
| `docs/secrets.md` | 1Password Environment とシークレットの流し込み |

## コマンド

```bash
# worker
cd worker && npm test                 # vitest
cd worker && npx tsc --noEmit         # 型検査。テストが緑でもここで落ちることがある
cd worker && npx wrangler deploy

# Swift（シミュレータ。udid は xcrun simctl list devices available から）
xcodebuild test -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination "platform=iOS Simulator,id=<udid>" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# 実機ビルドと転送
xcodebuild -project CanopyMobile.xcodeproj -scheme CanopyMobile -configuration Debug \
  -destination 'platform=iOS,id=<device-udid>' -derivedDataPath build-device \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> \
  build-device/Build/Products/Debug-iphoneos/CanopyMobile.app
xcrun devicectl list devices            # udid はここ

# デプロイ済み relay の検証（後始末が要る。下記）
node scripts/relay-event-probe.mjs
```

`npm test` が緑でも `npx tsc --noEmit` は別に落ちうる。CI は両方回すので、テストだけ通して push すると CI で気付くことになる。

## インフラ台帳

| | |
|---|---|
| Worker | `canopy-mobile-relay` / <https://canopy-mobile-relay.saqoosha.workers.dev> |
| Cloudflare account | `0f56ad2619afc619cc2975dd0728f8a9`（`wrangler.toml` に固定。デプロイ時に選択を訊かれない） |
| KV namespace `MACHINES` | `34a34a05b2194af6b9f2c89847a57ea1`。電話が列挙できる唯一の機械一覧 |
| Bundle ID | `sh.saqoo.canopy-app`（+ `.NotificationService` / `.tests`） |
| Development team | `VCFY2GFR89` |
| 実機 | iPhone Air "S" — `88CF0177-6AA8-5D02-926C-27E21B989A53` |
| Mac の machine id | `IOPlatformUUID`。オーバーライドは無いので、**同じ Mac で 2 つの Canopy を起動すると同じ machine として publish し合い、roster が取り合いになる** |
| シークレット | `docs/secrets.md` |

**probe は後始末が要る。** `/publish` は `machine:<id>` を KV に書くので、実行のたびに電話の機械一覧に `PROBE-…` が増える。

```bash
cd worker && npx wrangler kv key list --binding MACHINES --remote     # 確認
cd worker && npx wrangler kv key delete --binding MACHINES --remote "machine:PROBE-<id>"
```

## データの意味論

### `seq` は Mac 単位のグローバル連番 — ここを間違えると全部間違う

`event` テーブルの `seq` は Durable Object（= Mac 1 台）につき 1 本の autoincrement。バックフィルはセッションで絞る（`WHERE session_id = ? AND seq > ?`）。

つまり **1 つのセッションの seq は連続しない。** 他のセッションが 1〜9 を使えば、このセッションの最初は 10 になる。

だから「まだ持っている一番古い seq」から欠落を推測してはいけない。**Mac で最初のセッション以外は全部、失っていないのに失ったように見える。** リレー側が `evictedThrough`（そのセッションについて実際に削除した最大 seq）を記録して申告する。判定は `evictedThrough > since` — そのイベントはこのセッションのもので、要求範囲の中にいて、消えている。推測が入らない。

`oldestSeq` はワイヤーに残っているが**使っていない**（古い電話ビルドがデコードに必要とするだけ）。

### 応答は要求 seq を返す

`EventsResponse.since` は要求した seq のエコー。電話側でマークを保持すると、**送られなかった要求のマークが別の応答と突き合わされて、既知の欠落が消える。** 応答と一緒に運べばペアがずれない。

### 未知の `kind` は電話側で寛容に受ける。リレーは素通し

バックフィル応答は**配列**でデコードされる。厳密な enum だと未知の 1 件が **ページ丸ごと（最大 200 件）** を落とす。`SessionEventRecord.Kind` は `.other(String)` に落ちる。

リレーで弾かないのは**向きの問題**。Mac が先に出るので、リレーで検証するとリレーのデプロイが Canopy の新機能の前提条件になってしまう。

### 上限

| | |
|---|---|
| `maxEventsPerSession` | 200（リレー・電話とも） |
| `maxSessions` | 20 |
| `maxEvictionMarks` | 200。マークを失うと「欠落なし」に退化する（安全側） |

## ハマりどころ（実体験）

### 送信側のバイナリに機能が無い

**症状**: 電話に push は届くが、ストリームのイベントが 1 件も来ない。socket は繋がっている。

**原因**: インストール済みの Canopy がその機能を持たないリリース版だった。push は `/notify` の HTTP POST で WebSocket を使わないので、**push だけ生きているのはこの形の指紋**。

**確認**: Mac 側で `[event]` のログ行が出ているかを見る。roster の接続行があるのに `[event]` が 0 なら送信側。

**回避**: Canopy の Debug ビルド（`sh.saqoo.Canopy.debug`、別 bundle id）を隣に立てればリリース版を止めずに検証できる。ただし machine id は共通なので roster を取り合う。

### `log show` は `.debug` レベルを出さない

**症状**: `log show --debug` で `[event]` が 0 件。実際には出ている。

**原因**: macOS は既定で debug メッセージを保存しない。`--debug` は「保存されたものを見せる」フラグであって、保存を有効にはしない。

**修正**: `log stream --level debug` を使う。生で拾う。実測（同じ 30 分窓）: `log stream` が 688 行、`log show --info --debug` が 0 行。

```bash
/usr/bin/log stream --predicate 'process == "Canopy" AND subsystem == "sh.saqoo.Canopy"' \
  --level debug --style compact > /tmp/ev.log
```

`log` はシェル組み込みに食われるので**絶対パスで呼ぶ**。同じプロセス名のビルドが 2 つ動いているときは `Canopy[<pid>` で絞る。

### Worker のデプロイが全 WebSocket を切る

DO が再起動するので publisher も watcher も落ちる。Canopy 側は ping 駆動で復帰する（数十秒）。**デプロイ直後にストリームが死んで見えても、それは復帰待ち。**

### git worktree に `.xcodeproj` が無い

gitignore された生成物なので、worktree を切っただけではビルドできない。`xcodegen generate` を先に走らせる。症状は `xcodebuild: error: 'CanopyMobile.xcodeproj' does not exist.`

### バックフィルの実機テストは push タップで無効になる

前面復帰を**通知タップ**でやると、アプリが会話画面を積み直して `onAppear` が発火する。修正前のコードでもバックフィルを要求してしまう。**App スイッチャーかホーム画面のアイコンから戻す。**

### vitest が 1Password のロックで空振りする

`worker/.dev.vars` は 1Password の mount（FIFO）へのシンボリックリンク。1Password がロックされていると open でブロックし、vitest-pool-workers がタイムアウトして **exit 0 で "no tests"** を出す。緑に見える。テスト数の床（下記）がこれを捕まえる。

## 検証で使える基準値

| | |
|---|---|
| Swift テスト | 95 |
| worker テスト | 65 |
| `relay-event-probe.mjs` | 12 チェック全 PASS |

床は `.github/workflows/ci.yml` の `EXPECTED_TESTS` / `EXPECTED_SWIFT_TESTS`。**exit code だけでは足りない** — 0 件走っても exit 0 になる経路が両方にある。

## 残タスク

- **Canopy 側にイベントストリームを含むリリースがまだ無い。** インストール版は 2.26.1 で、機能は main にしか入っていない。リリースするまで実機は Debug ビルドを立てないとストリームが出ない
