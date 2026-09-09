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
| `docs/testflight.md` | TestFlight 配信。`asc` CLI、ASC の台帳、署名と orientation の罠 |

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

# TestFlight（手順と罠の全文は docs/testflight.md）
asc builds info --app 6810164313 --latest        # 届いたか。exit code は証拠にならない
asc builds add-groups --app 6810164313 --latest \
  --group dfd19ebb-1ca7-43c9-8d59-6ff83e98bd28   # 新しいビルドごとに要る
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
| App Store Connect | アプリ名 **Canopy for Saqoosha** / App ID `6810164313`。`Canopy Mobile` は他アカウントが使用中で 409。詳細は `docs/testflight.md` |
| ASC API キー | `76DV838N2N`（team、ADMIN）。issuer ID は `69a6de6e-6653-47e3-e053-5b8c7c11a4d1`。`asc` が keychain に保持 |
| シークレット | `docs/secrets.md` |
| Workers プラン | **Paid**（2026-09-08 に無料枠を焼き切って切り替え）。無料枠の 1 日 500 万 rows_read / 10 万 rows_written はもう壁ではないが、その比（write は read の 50 倍高い）は課金でも同じなので設計判断には使う |

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

**境目は 2.28.0。** イベントストリーム（`04ab152`）は 2.27.0 の**次**のコミットなので、2.27.0 にも 2.26.1 にも入っていない。全 Mac が 2.28.0 以上なら、この指紋が出たときの原因はバージョンではない。

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

### バックフィルの実機テストは push タップで無効になる

前面復帰を**通知タップ**でやると、アプリが会話画面を積み直して `onAppear` が発火する。修正前のコードでもバックフィルを要求してしまう。**App スイッチャーかホーム画面のアイコンから戻す。**

### コールドスタートの通知タップは `NotificationCenter` に間に合わない

**症状**: 通知をタップするとセッション一覧が開く。あるいは直前に見ていた別の会話がそのまま残る。会話に飛ばない。

**原因**: `didFinishLaunchingWithOptions` でデリゲートを立てた瞬間に iOS が待機中のレスポンスを配る。SwiftUI が `WindowGroup` の body を評価して `.onReceive` を張るのはそのあと。**`NotificationCenter` は観測者のいない post をキューしない** ので、タップは消える。

**修正**: `PushRegistrar.pendingTap` に保持し、post も従来どおり行う。シーンは `.task` と `scenePhase == .active` の両方で回収する。先に着いたほうが処理して nil にする。順序を当てにしない形にした。

**もう一つの顔**: 遷移側が `guard ... else { return }` で黙って帰ると `path` が変わらず、直前の会話が残る。**タップは必ず遷移する**（名前が取れなければ仮タイトル）。

### `print` は実機で読めない — 通知タップ起動なら特に

**症状**: 「surfaced, never swallowed」で足したログが、実機で 1 行も出ない。

**原因**: `print` は stdout。`devicectl process launch --console` で **devicectl 自身が起動した** プロセスでしか拾えない。通知タップで起動したアプリも、ロック画面から Allow を押したときのプロセスも、起動したのは OS なので stdout はどこにも繋がっていない。あとから復元する手段も無い。

**修正**: `NSLog`。os_log の default レベルに乗るのでディスクに残り、`log stream` でも sysdiagnose でも読める。`Sources/` のアプリ側は全部 `NSLog` に統一済み。

補間ではなく `%@` + 引数で書く。`NSLog` の第一引数は printf format string なので、値に `%` が入ると仕様子として読まれる。

### Darwin 通知は自プロセスにも返る。でも依存してはいけない

`CFNotificationCenterGetDarwinNotifyCenter` に post したものは、**同じプロセスの observer にも配送される**。これが常態であって例外ではない。

だが `HistoryUpdateBridge.postDarwinUpdate` はローカルにも `didUpdate` を直接 post する。**decision を書くのはアプリ本体**（`sendDecision` とロック画面ハンドラ）で、読むのも同じプロセス。libnotify の実装詳細に画面更新を賭けると、失敗が「答えたのに質問が消えない」という形でだけ現れる。

代償は `didUpdate` が 1 write につき 2 回鳴ること。`load()` は純粋な再読み込みなので害は無いが、`loadAll()`（最大 100 ファイルの同期 decode）が 2 周する。

`startBridge()` は **Darwin observer を登録して `didUpdate` を post する** 側。`didUpdate` を observe しているのは 2 つの SwiftUI `.onReceive` だけ。だから extension でローカル post が無意味なのは「view が無いから」であって「`startBridge()` を呼んでいないから」ではない。呼んでも何も変わらない。

### `updateDecision` は requestId が一致する全ファイルを更新する

`filename(for:)` は `<millis>-<id>.json` で、`asking` push では `id == requestId`。**`append` は今は upsert する**（既存ファイルがあればそれを残す）ので、同じ requestId から新しく 2 ファイルできることはもう無い。**それでもループは要る** — upsert 前に書かれた履歴がディスクに残っていて、そこには重複がある。片方だけ更新すると、もう片方が `decision == nil` のまま残って未回答の ask として描かれ続ける — しかも 1 件は見つかるので `entryNotFound` も throw されない。

**部分失敗も throw する。** 書けたものと書けなかったものが混ざったら `StoreError.partialUpdate(written:failed:)`。以前は正常終了していて、書けなかったコピーが `decision == nil` のまま未回答の ask として描かれ続けた — この関数自身の症状が、エラー無しで到達していた。ブロードキャストは throw の前に出すので、throw を無視する呼び出し側が以前より悪くなることは無い。

**UI に戻る型がある。** `onDecision` / `onAnswer` は `async throws`。`AskFormView` は失敗で `sent` を戻す（選択は残る、ボタンは「Send answer」に戻る）。成功では戻さない — フォームを消すのは記録された `decision` のほうで、先にボタンを解放すると答え済みのものをもう一度押せてしまう。**relay への POST 失敗は throw しない** — decision は `delivered: false` で記録され、それは履歴行が描ける状態であって、エラーにすると「ユーザーが何を選んだか」の記録ごと捨てることになる。

**upsert は「最初の到着が勝つ」で、上書きではない。** 上書きにすると、記録済みの `decision` が再配送で消えて、答えた ask が未回答に戻る — 重複ファイルが起こしていたのと同じ症状が、その修正自身の経路で復活する。再配送は同じ push なので更新するものが無い。例外は既存ファイルが decode できないときだけで、そのときは配送で書き直す。

ループは **per-file の `do/catch`**。1 件の decode 失敗で全体を落とすと、先に書いたものだけ更新されて broadcast がスキップされ、同じ症状が別経路で出る。`loadAll` も読めないエントリをログして続ける。

**重複配送の原因は特定できていない。** relay のスロットルリトライではない — `worker/src/apns.ts` が「429 は拒否であって、配送してから文句を言うわけではない」と明記している。ループの根拠は「`append` が重複排除しない」だけで足りる。

### `.xcodeproj` が古いと、ビルドは通るのに中身が違う

`.xcodeproj` は gitignore された生成物。**worktree を切っても、ブランチを移動しても、`project.yml` が変わっても、自動では追従しない。**

無い場合は素直に落ちる（`xcodebuild: error: 'CanopyMobile.xcodeproj' does not exist.`）。**古い場合が厄介で、exit 0 で成功する。** 2 通りの形で踏んだ。

- `Tests/` に置いた新しい `.swift` がターゲットに入らず、**緑のまま、テスト数も変わらない**。足したテストが 1 件も走っていないのに成功して見える
- アイコンを含む main に移った直後のビルドで、アプリ本体に**通知拡張の `Info.plist` が刺さった**。`GENERATE_INFOPLIST_FILE` が生むキーが丸ごと消え、アイコンも表示名も落ちる。`CompileAssetCatalog` は走るのに `Assets.car` が無い

後者の機構: xcodegen はターゲットの source path 配下を走査して `Info.plist` を見つけると `INFOPLIST_FILE` に自動設定する。`excludes:` はこの走査を止めない。`project.yml` の `INFOPLIST_FILE: ""` がその対策で、pbxproj が古いとそれが反映されていない。

**ブランチを切り替えたら `xcodegen generate`。** 生成できたかは pbxproj で見る。

```bash
grep -c "Assets.xcassets" CanopyMobile.xcodeproj/project.pbxproj   # 4。0 なら失敗
grep -n 'INFOPLIST_FILE = ""' CanopyMobile.xcodeproj/project.pbxproj
```

**ビルド結果はファイルの有無で判定しない。** 増分ビルドは古い成果物を消さないので、`AppIcon60x60@2x.png` があってもそれは前のビルドの残骸でありうる（実際にそれで「アイコンは入っている」と誤判定した）。`Info.plist` のキーを見る。

```bash
plutil -p <app>/Info.plist | grep -E "CFBundleIconName|CFBundleDisplayName|NSExtension"
# CFBundleIconName => AppIcon / CFBundleDisplayName => Canopy / NSExtension は出ない
```

疑わしいときは `-derivedDataPath` を新しいディレクトリにする。アイコン周りの罠は `docs/app-icon.md` にもある（`Contents.json` の `size` を落とすと actool が黙って何も出さない、など）。

**CI は捕まえない** — ワークフローが自分で `xcodegen generate` を走らせるので、CI では常に正しく見える。ローカルでだけ起きて、ローカルでだけ気づける。

**生成 `Info.plist` は足りないキーを黙って落とす。** `GENERATE_INFOPLIST_FILE: YES` は `INFOPLIST_KEY_*` で明示したものしか書かない。`UISupportedInterfaceOrientations` を宣言し忘れると、ローカルの archive は warning だけ出して成功し、**App Store のアップロードが最後まで進んでから** 90474 で弾かれる。輸出コンプライアンスの `ITSAppUsesNonExemptEncryption` も同じ形の穴。どちらも `project.yml` で入れてある — 詳細と実測は `docs/testflight.md`。

### 配送済みの通知は、配送時点のアイコンと名前のまま

**症状**: アプリのアイコンを直したのに、ロック画面の通知だけデフォルトアイコンのまま。ホーム画面は正しい。

**原因**: iOS は配送済みの通知を遡って描き直さない。修正前に届いた通知は、消すまで永久に古いアイコンで表示される。**キャッシュですらない。**

**切り分け**: Mac の通知ミラーリングで正しいアイコンが出るなら、データは iPhone のバンドルに正しく入っている。`xcrun devicectl device info apps` の表示名が正しければ LaunchServices も更新済み。その 2 つが揃っていて iOS のロック画面だけ古いなら、見ているのは古い通知そのもの。

**確認手順はこの順で。**

1. **ロック画面と通知センターの通知を全部消して、新しいのを 1 通出す。** 無料・非破壊で、これが一番あり得る
2. 端末の再起動（非破壊）
3. 削除 + 再インストール。**最後の手段** — `HistoryStore` は App Group を直に引くので、**通知履歴が全部消える**

1 を飛ばして 3 を 2 回やって履歴を飛ばした。

### アイコンを実機で検証するときの落とし穴

**ファイルの有無で判定しない。** 増分ビルドは古い成果物を消さないので、`AppIcon60x60@2x.png` があってもそれは前のビルドの残骸でありうる。実際それで「アイコンは入っている」と誤判定した。`Info.plist` のキーを見る。

`Contents.json` は **1024 の `universal` 1 枚が正**（`docs/app-icon.md`）。20/29/40/60pt を宣言して同じ 1024 PNG を指すと、actool は寸法不一致で**全レンディションを拒否し、アイコンが 1 枚も出なくなる**。警告は出るがビルドは成功する。iOS には Android の small icon に相当する通知専用アセットが無く、通知はホーム画面と同じアイコンを引くので、**カタログに足すものは無い**。

`strings` は Swift の文字列リテラルを拾わないことがある。シンボルを見るなら `nm`、デマングルは `swift demangle`。Xcode 16+ の Debug ビルドは実コードを `<App>.debug.dylib` に置き、メイン実行ファイルは 90KB 程度の launcher なので、**バイナリを検証するならそちらを見る**。

### 1 本の fallback が 5 本の代役をしていた

**症状**: `shortenWithLLM` の 5 つの失敗経路（非 200 / error envelope / 読めない content / strip して空 / catch とタイムアウト）が全部 `fallbackBanner` を返すのに、テストが 1 件も無かった。`/notify` 経由では書けもしない。

**原因**: そのルートの fetch スパイは**空の 200** を返す。`shortenWithLLM` はそれを JSON パース失敗として受け、catch に落ちて fallback を返す。だから **1 本の経路が 5 本分の代役をしていて、ステータス判定が壊れていても動いているのと同じ絵になる**。

**修正**: `llm.test.ts` で fetch をケースごとに差し替える。合成の env と stub された fetch — `apns.test.ts` と同じ理由で、`.dev.vars`（テストプールに読み込まれ、本物の鍵を持つ）に触らず Anthropic にも到達しない。

**テストの形が要点**: 非 200 と error envelope のケースは**読める content ブロックを載せる**。空ボディだと「content が読めない」分岐に落ちて同じ fallback に着くので、**判定を消してもテストが通る** — 別の行を pin していることになる。mutation で確かめる。

### `@MainActor` の型に純関数を足すと、テストから呼べない

`PushRegistrar` は delegate コールバックのために `@MainActor`。そこへ `static func` を足すと swift-testing から呼べず `call to main actor-isolated static method ... in a synchronous nonisolated context` で落ちる。`nonisolated` を付ける。純関数ならそれが正しい記述でもある。

`UNNotificationResponse` はシステム外で構築できないので、`didReceive` の分岐そのものはテストできない。**判定だけ純関数に出す** のが手（`missingTapKeys(in:)`、`NotificationHistoryItem.answerableForm` と同じ）。

### DO の全表スキャンが append パスに乗ると、1 日で無料枠が飛ぶ

**症状**: Cloudflare から「Durable Objects の 1 日 5,000,000 rows_read 無料枠を超えた」。DO を触るルートが全部 500 を返す（KV だけのルートは 200 のまま — これが切り分けになる）。

**原因**: `appendEvent` がイベント 1 件ごとに `trim()` を呼び、そこに `session_id NOT IN (SELECT ... FROM event GROUP BY session_id ...)` が記録用の SELECT と削除用の DELETE で 2 本あった。`EXPLAIN QUERY PLAN` で外が `SCAN event`、内が `SCAN event USING COVERING INDEX` — **1 文につき全表 2 周、2 本で 4 周**。上限以下で消すものがゼロでも毎回走る。セッション単位の trim にも同じ形が 2 本（800 行ほど）。

**実測の取り方**: `sql.exec()` が返すカーソルの `rowsRead` / `rowsWritten` が課金カウンタそのもの。`runInDurableObject(stub, (instance, state) => ...)` の `state.storage.sql.exec` を包めば本物の workerd で 1 操作あたりが取れる。**カーソルは汲み終わってからでないと数を報告しない**ので、包む側で `toArray()` して配列で返す。

**修正**: `session (session_id PRIMARY KEY, last_seq)` を足して、セッション上限の判定を 4,000 行の `event` ではなく 20 行の `session` の並べ替えでやる。per-session 側は `ORDER BY seq DESC LIMIT 1 OFFSET 200` で切る seq を直接引き、返らなければ抜ける。消した集合が `seq <= cutoff` ちょうどなので、eviction マークはその cutoff そのもの。

イベント 1 件 append あたりの rows_read（定常状態）:

| | 修正前 | 修正後 |
|---|---:|---:|
| 1 セッション / 200 行 | ≈1,614 | 210 |
| 5 セッション / 1,000 行 | ≈4,824 | 218 |
| 20 セッション / 4,000 行 | **≈16,853** | **248** |

内訳は `201 + 2×(session の行数) + 約 7`。**要点は 248 という数字ではなく、どの項も上限で抑えられていて `event` や `eviction` の大きさが 1 つも入っていないこと。** 修正前の数字は DO の履歴でぶれる（マーク表が空か上限かだけで 77 行）。2 つの列は fixture が違う（修正前は 2 cap、修正後は 3 cap）ので厳密な同条件比較ではない。

**インデックスは足さない（実測で判断）。** `eviction(through)` と `session(last_seq)` に張ると読み込みは 405→204、40→20 に減る。**が、DO は書き込み行が読み込み行より桁違いに高い**（無料枠で 1 日 10 万 write 対 500 万 read）。どちらも **append のたびに index 行の書き込みが 1 行増える**ので差し引きマイナス。read だけ見て索引を足すと悪化する。

### コストのテストは、fixture が埋めた上限のぶんしか主張しない

**この修正自身が同じ穴に 3 回落ちた。** どれも「測っていないものを測ったと書く」形。

1. **3 つめの上限を埋めていなかった。** fixture が `event` の 2 つ（20 セッション × 200 件）だけを埋め、`maxEvictionMarks` = 200 のマーク表が空。その状態で 249 行、実際に埋めると **651 行**。差の 402 行は `trimEvictionMarks` の 1 文 — 消すものがゼロなのに `eviction` を 2 周する、この PR が消したのと同じ形。天井は 500 だったので、**本番の定常状態はテストが落ちる値なのに緑だった**
2. **セッションを上限ちょうどで止めていた。** 上限 200 で止めるとそのセッションはまだ evict していないのでマークを持たず、次の 1 件が「唯一のマーク trim」を払う。定常状態を測るなら **上限 +1 件まで**入れる
3. **「1/5/20 セッションでフラット」は fixture の性質だった。** churn フェーズが `session` を上限まで埋めるので、そのあと何セッション動かしても 20 行のまま

**wake パスにも同じ天井が要る。** この修正は wake に仕事を載せた（ドリフト判定・修復スキャン・マーク上限の受け皿・修復後のセッション上限）のに、計器は append パスにしか無かった。ドリフト判定を `if (true)` にして 4,000 行のスキャンを毎 wake 走らせても全テスト緑。**hibernation した DO はイベント到着ごとに構築し直される**ので、低トラフィックでは wake と append がほぼ 1:1 で並んで課金される。天井は append と同じ桁に置く。実測 wake 222 行。

**backfill テストは 1 セッション 1 イベントだと `MAX` と `MIN` を区別できない。** 全部の集約が同じ値になるので `MIN(seq)` に変えても緑。どれか 1 セッションに 2 件目を足すと分かれる。

**`noteEviction` の `MAX(through, excluded.through)` はどのテストでも plain assignment と区別できない** — 呼び出し元が単調な値しか渡さないので raw SQL 無しでは到達不能。テストできないことは書いて残す。

### 索引のドリフトは「空か」ではなく「最新か」で判定する

`session` は後付けなので、動いている DO はイベントを持っていて索引を持っていない。**索引が空かどうかで判定すると、一度も索引を持ったことのない DO しか拾えない。** ロールバックや混在バージョンで旧バイナリが `event` だけ書くと、ずれが **3 つの形** で出る。どれもエラーは出ない。

1. 索引が知らないセッション → `trimSessions` から見えず `maxSessions` が効かない
2. `last_seq` が止まった既知セッション → 最古扱いされて先に落とされる
3. **イベントが全部消えているのに残っている索引行** → 幽霊が枠を 1 つ占めて、代わりに生きているセッションが落とされる

**判定は 2 クエリ。** `appendEvent` はイベント行と索引行を必ず一緒に書くので、平常時は `event` の `MAX(seq)` と `session` の `MAX(last_seq)` が一致する（最新セッションの最新イベントを消す経路は無く、索引行は全イベントと一緒にしか消えない）。索引を飛ばして書いた瞬間に壊れる。成立の前提は **「索引無しの書き込みの後に、構築を挟まずに索引付きの書き込みは来ない」** — `ensureSchema()` は constructor で走り、リクエストはその後だから。`appendEvent` 以外の書き込み経路を足すとこれは崩れる。

**`!==` ではなく「`event` が先行しているとき」。** 修復は `last_seq` を上げる方向にしか動かないので、索引が先に行っている状態を `!==` で拾うと直せないまま毎 wake スキャンを走らせ続ける吸収状態になる。今は到達経路が無いが、無いからこそ誰も気づかない。

**修復の代入は `excluded.last_seq`**（`MAX(...)` ではない）。他所でマークを前にしか動かさないのはコードが手持ちより良い情報を持っていないから。ここは持っている — 副問い合わせが `event` 側の `MAX(seq)` そのもので、それが `last_seq` の定義。3 つめの形は同じ枝で `DELETE FROM session WHERE session_id NOT IN (SELECT session_id FROM event)`。

**ゲートには wake 時の受け皿が要る。** 「新規 session_id の INSERT のときだけ trim」にすると、それ以外の理由で上限を超えた表が二度と縮まない（`maxEvictionMarks` をデプロイで下げたとき）。`ensureSchema()` から呼ぶ。`COUNT(*)` で数えてから（200 行）trim する（405 行）ので、普段は走らない。

**旧ガード `if (seeded === 0)` はコストではなくクラッシュのガードだった。** 中身が裸の `INSERT ... SELECT` なので、索引がある DO で走らせると `UNIQUE constraint failed` を投げる。場所が `blockConcurrencyWhile` の中なので **構築が失敗してその Mac の全ルートが毎 wake 落ちる**。コメントは「空なら scan はタダ」としか書いていなかった。**false 分岐にテストが 1 本も無かった** — backfill に到達するテストが全部 `rebuildSessionIndex()` 経由で、あれは先に `DELETE FROM session` するので true 分岐しか通らない。索引を消さずに `ensureSchema()` を呼び直すシーム（`rerunWakePath()`）が要る。

### `trimEvictionMarks` は `through` 順なので、生きているセッションのマークが先に消える（既存）

`through` は seq。**上限に張り付いた長寿セッションの `through` は自分の 200 件ぶん後ろを指す**ので、その間に evict された短いセッション 200 本に順位で負ける。負けると書いた直後のマークが同じ呼び出しの中で消え、`evictedThrough` が 0 に戻る — 実際に落ちたイベントについて「欠落なし」と申告する。

実測（S を上限に張り付かせ、S の 1 append につき新規セッション 5 本）: `marks=200 / S のマーク=無し / evictedThrough=0`。**`main` でも同じ値**なのでこの PR が入れたものではなく、`ORDER BY through DESC` そのものの性質。直すなら「`session` にまだ居るセッションを優先する」順序が要る。
### `cd X && ...` が失敗すると、後続の編集が丸ごと落ちる（しかもコミットは通る）

**症状**: コメントを直したコミットを積んだのに、実際のファイルは元のまま。コミットメッセージだけが「直した」と主張している。あとのレビューで、ドキュメントとコードが矛盾していると指摘されて発覚。

**原因**: `cd worker && python3 - <<PY ... PY` の `cd` が失敗した（シェルの cwd がすでに `worker/`）。`&&` チェーンなので **python が 1 行も走らない**。直後の `npx vitest` は別行だったので緑を返し、こちらは成功だと思い込んだ。

**修正**: ファイルを触るスクリプトは **絶対パスで書き、`cd` に依存しない**。編集は `assert old in s` を必ず入れて、置換対象が見つからなければ落とす。このセッションではそれで 2 回目以降を捕まえた。

### レビューのサブエージェントが共有ワーキングツリーを汚す

**症状**: `git status` に身に覚えのない `machine.ts` の変更。中身は `noteEviction(sessionId, cutoff + 1)` — ミューテーションテストの残骸。ほかに `zz-review-probe.test.ts` のような未追跡ファイルが `worker/src/` に残り、**`.scratch` が付いていないので vitest の glob に拾われてテスト数の床を壊しかける**。

**原因**: レビュー用サブエージェントが本体のツリーで直接ミューテーションを走らせ、戻し忘れた。並列で 8 本走らせていたので、誰の仕業か特定に手間がかかる。

**修正**: レビューの brief に **「リポジトリ配下を一切変更するな。scratch ディレクトリにコピーして、終わったら消せ」** を明記する。それでも commit 前に `git status` と `ls worker/src/` を必ず見る。

### vitest が 1Password のロックで空振りする

`worker/.dev.vars` は 1Password の mount（FIFO）へのシンボリックリンク。1Password がロックされていると open でブロックし、vitest-pool-workers がタイムアウトして **exit 0 で "no tests"** を出す。緑に見える。テスト数の床（下記）がこれを捕まえる。

### Mac で打ったプロンプトも `user` イベントになる（検証済み）

`publishSessionEvents` は `handleShimMessage(type: "webview_message")` = **CLI → webview 方向でしか呼ばれない**。webview で打った入力は逆方向なので、コードを読むだけだと「Mac 入力はイベントにならない」と読める。

**ならない、が正解ではない。** CLI は webview 発の user フレームを**エコーして返す**ので、その復路で `publishSessionEvents` が拾う。2026-09-07 に MBP を 2.28.0 に上げて実測：1 ターンで `{"user":1,"assistant":2,"tool":2}`、`user` の text は Mac のチャット欄に打った文字列そのもの。

webview→CLI 側に publish を張る必要は**無い**。`stampUser`（phone reply の id を echo に付け直す機構）が成立しているのも同じエコーが前提。

**ただし「打った文字列そのもの」は slash command では成り立たない。** CLI はモデルに渡す前に `/remember-session push` を展開するので、エコーで返るのは展開形のほう。

```
<command-message>remember-session</command-message>
<command-name>/remember-session</command-name>
<command-args>push</command-args>
```

電話はこれをそのまま描いて、"You" の下に XML が 4 行出た（実機で報告）。`SlashCommandText` が `/remember-session push` に戻し、`SlashCommandBlock` が等幅の箱で描く。同じコマンドを実機で打ち直して確認済み。`<command-args>` は任意（ローカルの transcript 5258 件中 3259 件）、`<command-name>` はスラッシュ付きが普通だが無い綴りもある。

**判定は全文一致で、`contains` は禁止。** Canopy が `ShimProcess.isRecapEcho` で先に踏んでいて、理由もそこに書いてある — 部分一致だとラッパーを**引用しただけ**のメッセージ（transcript の貼り付け、この機能のバグ報告、パーサ自身のレビュー）を壊す。

## 並行 PR と worktree

**stack した PR の base ブランチを消すと、上の PR は死ぬ。** `gh pr merge <n> --squash --delete-branch` は base を消し、GitHub はそれを向いていた PR を**自動で close する**。閉じた PR は base を変えられず（`Cannot change the base branch of a closed pull request`）、base が無いので開き直せもしない（`Could not open the pull request`）。**復旧は PR の作り直しだけ**で、番号が変わる。**stack がある間は `--delete-branch` を付けない。**

順番は「下をマージ → 上を `gh pr edit <n> --base main` → rebase → force-push」。

**スタック全体の rebase は `--update-refs`。** 中間ブランチの ref も一緒に動く。squash 済みのコミットは patch-id が一致するので `skipped previously applied commit` として勝手に落ちる。

```bash
git rebase origin/main --update-refs
```

**`## 検証で使える基準値` のテーブルは、並行 PR が必ずコンフリクトする。** Swift 行と worker 行が隣接しているので、テスト数を動かす PR が 2 本あれば必ずぶつかる。`ci.yml` の `EXPECTED_*` も同じ。**解決は足し算** — 両方入るなら 109 と 97 ではなく 111。1 本ずつマージして残りを rebase するのが結局いちばん速い。

**worktree 隔離セッションは `main` を動かせない。** `git fetch origin main:main` は `refusing to fetch into branch 'refs/heads/main' checked out at <本体>` で落ちる。checkout 中のブランチはその worktree からしか動かせないので、**本体の更新は人間の `git pull` が要る**。`gh pr merge --delete-branch` も同じ理由で `fatal: 'main' is already used by worktree` を出すが、**マージ自体は成功している** — この行だけ見て失敗と判断しない。

**`--force-with-lease` は URL 直指定の push では効かない。** リモート追跡 ref を名前で解決できず `stale info` で拒否される。`--force-with-lease=<branch>:<sha>` と明示する。sha は記憶で書かない（`cannot parse expected object name` で落ちる）— `git rev-parse origin/<branch>` で取る。

## 検証で使える基準値

| | |
|---|---|
| Swift テスト | 136 |
| worker テスト | 118 |
| `relay-event-probe.mjs` | 12 チェック全 PASS |
| DO の append 1 件 | 248 rows_read（3 つの上限すべて満杯）/ 210（生きているセッション 1 本） |
| DO の wake 1 回 | 222 rows_read（ドリフト無し）|

append と wake の数字は `machine.test.ts` の 2 本のコスト上限テストが 300 で pin している。手で測り直すときは **3 つの上限を全部埋める** — でないと 248 ではなく 249 が出て、しかもそれは嘘（上記「コストのテストは…」）。

床は `.github/workflows/ci.yml` の `EXPECTED_TESTS` / `EXPECTED_SWIFT_TESTS`。**exit code だけでは足りない** — 0 件走っても exit 0 になる経路が両方にある。

## 残タスク

- **`trimEvictionMarks` の `through` 順（上記の節）。** 生きているセッションのマークが短命セッション 200 本に負けて消え、`evictedThrough` が 0 に戻る。`main` から続く既存の穴で、rows_read の修正では触っていない。直すなら `session` にまだ居るセッションを優先する順序
- **索引ドリフトの取りこぼし 1 件。** `MAX` 比較は「索引無しの書き込みが次の wake の時点でまだ最新」に依存する。`appendEvent` 以外の書き込み経路（bulk import、管理用の修復）を足すと成立しなくなり、安く厳密に検出する手は無い（`event` に居て `session` に居ないセッションを探すのはスキャン）
- **ドリフト検出も修復もログを出さない。** 発火したかどうかを本番から知る手段が無い。`console.error` 1 行で足りるが、この PR の範囲外として見送った
