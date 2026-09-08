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

### DO の `NOT IN (SELECT ...)` は、消すものがゼロでも全表を 2 回読む

**症状**: Cloudflare から「Durable Objects の 1 日 5,000,000 rows_read 無料枠を超えた」。relay がエラーを返し始める。イベントストリームを入れた翌日（2026-09-08）。

**原因**: `appendEvent` がイベント 1 件ごとに `trim()` を呼び、そこにこの形が **記録用の SELECT と削除用の DELETE で 2 本** あった。

```sql
DELETE FROM event WHERE session_id NOT IN (
  SELECT session_id FROM event GROUP BY session_id ORDER BY MAX(seq) DESC LIMIT 20
)
```

`EXPLAIN QUERY PLAN` で外が `SCAN event`、内が `SCAN event USING COVERING INDEX`。**1 文につき全表 2 周、2 本で 4 周。** しかも上限以下で消すものが 1 行も無くても毎回走る。（セッション単位の trim にも `NOT IN` が 2 本あって、これは 800 行ほど。合計 4 本）

**実測の取り方**: `sql.exec()` が返すカーソルの `rowsRead` / `rowsWritten` が課金カウンタそのもの。`runInDurableObject(stub, (instance, state) => ...)` の `state.storage.sql.exec` を包めば、本物の workerd で 1 操作あたりのコストが取れる。**カーソルは汲み終わってからでないと数を報告しない**ので、包む側で `toArray()` して配列で返す。

### 上限は 3 つある。fixture が 2 つしか埋めないとコストのテストは嘘をつく

**この修正自身が 1 回踏んだ。** 上のコスト上限テストの fixture は `event` の 2 つの上限（20 セッション × 200 件）だけを埋めていて、`maxEvictionMarks` = 200 のマーク表が空だった。その状態で 249 行。**マーク表を実際に上限まで埋めると同じ append が 651 行**で、差の 402 行は全部 `trimEvictionMarks` の 1 文（絶対値は 405 行、空の fixture では 3 行） — 消すものがゼロなのに `eviction` を 2 周する、まさにこの PR が消したのと同じ形。テストの天井は 500 だったので、**本番の定常状態はテストが落ちる値だったのに緑だった。**

`noteEviction` が毎回 `trimEvictionMarks()` を呼んでいたのが原因。**上限を越えさせられるのは新規 session_id の INSERT だけ**なので、主キー 1 行の存在確認でゲートすれば、定常状態（既にマークがある）では呼ばれない。405 → 0。

**fixture のもう一つの罠**: セッションを上限ちょうど（200 件）で止めると、そのセッションはまだ 1 度も evict していないのでマークを持たない。次の 1 件が「そのセッション唯一のマーク trim」を払う。測るなら **上限 +1 件まで**入れて、定常状態の append を測る。

**ゲートには wake 時の受け皿が要る。** 「新規 session_id の INSERT のときだけ trim」にすると、それ以外の理由で上限を超えた表が二度と縮まない。具体的には `maxEvictionMarks` をデプロイで下げたとき — ゲート前は次の append で戻っていた。`ensureSchema()` から 1 回呼んで埋める。append ごとではなく wake ごとなので、hot path には乗らない。

**インデックスは足さない（実測で判断）。** `eviction(through)` と `session(last_seq)` にインデックスを張ると読み込みは 405→204、40→20 に減る。**が、DO は書き込み行が読み込み行より桁違いに高い**（無料枠で 1 日 10 万 write 対 500 万 read = 50 倍）。どちらの索引も **append のたびに index 行の書き込みが 1 行増える** — `session.last_seq` は毎回 upsert、`eviction.through` も上限に達したセッションでは毎回。+1 write で −20 read（または滅多に走らない経路の −201 read）は差し引きマイナス。read だけ見て索引を足すと悪化する。

### `trimEvictionMarks` は `through` 順なので、生きているセッションのマークが先に消えることがある（既存）

`through` は seq。**上限に張り付いた長寿セッションの `through` は自分の 200 件ぶん後ろを指す**ので、その間に evict された短いセッション 200 本に順位で負ける。負けると書いた直後のマークが同じ呼び出しの中で消え、`evictedThrough` が 0 に戻る — 実際に落ちたイベントについて「欠落なし」と申告する。

実測（S を上限に張り付かせ、S の 1 append につき新規セッション 5 本を回す）: `marks=200 / S のマーク=無し / evictedThrough=0`。**`main` でも同じ値**。この PR が入れたものではなく、`ORDER BY through DESC` そのものの性質。直すなら「`session` にまだ居るセッションを優先する」順序が要る。

イベント 1 件 append あたりの rows_read（定常状態 = 各セッションが上限を越えて回り続けている状態）:

| | 修正前 | 修正後 |
|---|---:|---:|
| 1 セッション / 200 行 | ≈1,614 | 248 |
| 5 セッション / 1,000 行 | ≈4,824 | 248 |
| 20 セッション / 4,000 行 | **≈16,853** | **248** |

**2 つの列は fixture が違う。** 修正前はマーク表を埋めない 2 cap の fixture、修正後は 3 cap 全部埋めた fixture で測っている（修正前のコードで 3 cap を埋めると 20 セッションで 17,650）。改善幅を過小に見せる向きなのでそのままにしてあるが、厳密な同条件比較ではない。

修正後の内訳は `201 + 2×(session の行数) + 約 7`。セッション上限まで使っていて 248、生きているセッションが 1 本なら 210。**要点は 248 という数字ではなく、どの項も上限で抑えられていて、`event` や `eviction` の大きさが 1 つも入っていないこと。** 修正前の数字は DO の履歴でぶれる — マーク表が空か上限かだけで 77 行動く（16,853 対 16,930）。

**「フラット」と書きかけて 1 度間違えた。** 上の fixture は churn フェーズで `session` を上限まで埋めるので、そのあと何セッション動かしても `session` は 20 行のまま。1/5/20 セッションで 248 が揃うのは fixture の性質であってコードの性質ではない。**同じテストで同じ種類の間違いを 2 回やった。**

**修正**: `session (session_id PRIMARY KEY, last_seq)` を 1 枚足して、セッション上限の判定を 4,000 行の `event` ではなく 20 行の `session` の並べ替えでやる。per-session 側は `ORDER BY seq DESC LIMIT 1 OFFSET 200` で切る seq を直接引き、**返らなければ何もせず抜ける**。消した集合は `seq <= cutoff` ちょうどなので、eviction マークはその cutoff そのもの — 最大値を取り直すクエリが要らない。

**テストが 1 本も落ちなかった。** 遅い版も正しい行を消していて、判定に全表を読んでいただけ。だから **`rowsRead` に上限を張るテストがこのバグの唯一の網**。ミューテーション（`session` ではなく `event` を並べ替える版に戻す）で 4,229 まで跳ねて落ちることを確認済み。

**既存 DO には backfill が要る。** `session` は後から足したので、動いている DO はイベントを持っていて索引を持っていない。索引が空のときだけ `INSERT INTO session SELECT session_id, MAX(seq) FROM event GROUP BY session_id` を 1 回。これが無いと、**すでにディスクにあるセッションについてセッション数の上限だけが効かなくなる** — エラーは出ない。1 セッション 200 件の上限は `trimSessionEvents` が `event` を直接見るので生きたまま。増えるのは保持されるセッションの本数。

**索引が「空か」ではなく「最新か」を訊く。** 空かどうかで判定すると、索引を一度も持ったことのない DO しか拾えない。ロールバックや混在バージョンで旧バイナリが `event` だけ書くと、**索引が知らないセッション**（`trimSessions` から見えないので `maxSessions` が効かない）と、**`last_seq` が止まったままの既知セッション**（最古扱いされて先に落とされる）の 2 種類のずれが出る。どちらもエラーは出ない。

判定は 2 クエリで厳密にできる。`appendEvent` はイベント行と索引行を必ず一緒に書くので、**平常時は `event` の `MAX(seq)` と `session` の `MAX(last_seq)` が必ず一致する**（最新セッションの最新イベントを消す経路は無く、索引行はそのセッションの全イベントと一緒にしか消えない）。索引を飛ばして書いた瞬間に等号が壊れるので、1 回の比較で両方のずれを拾える。修復も `ON CONFLICT DO UPDATE SET last_seq = MAX(...)` の 1 文で両方直る。

**wake ごとに走るので安さが要る。** `MAX(seq)` は INTEGER PRIMARY KEY で 1 行、`MAX(last_seq)` は最大 20 行。`event` の grouped scan は実際にずれているときだけ。無条件に走らせると wake ごとに約 4,000 行で、**hibernation したDO はイベント到着のたびに起きる**ので、この修正が消したのと同じ形の請求になる。実測: wake 全体で 422 行（うち 405 はマーク trim）。

**この判定に至る前、ガードは `if (seeded === 0)`（索引が空か）で、それはコストのガードではなくクラッシュのガードだった。** 中身が裸の `INSERT ... SELECT` なので、索引がすでにある DO で走らせると `UNIQUE constraint failed` を投げる。場所が `blockConcurrencyWhile` の中なので、**構築が失敗してその Mac の全ルートが毎 wake 落ちる**。コメントは「空なら scan はタダ」としか書いておらず、最適化に見えていた。今は `ON CONFLICT ... DO UPDATE` なので投げない。

**false 分岐にテストが 1 本も無かった。** backfill に到達するテストが全部 `rebuildSessionIndex()` 経由で、あれは先に `DELETE FROM session` するので true 分岐しか通らない。**普通の wake が通る側**を踏むには、索引を消さずに `ensureSchema()` を呼び直すシームが要る（`rerunWakePath()`）。

### wake パスにも rows_read の天井を張る

**この修正は wake に仕事を載せた** — ドリフト判定、ずれたときの修復スキャン、マーク上限の受け皿、修復後のセッション上限。そして計器は append パスにしか付いていなかった。ドリフト判定を `if (true)` に変えて 4,000 行のスキャンを毎 wake 走らせても **116 本全部緑**。この PR が消したのと同じ形のバグが、1 つ隣の経路で見えなくなっていた。

**hibernation した DO はイベント到着ごとに構築し直される**ので、低トラフィックでは wake と append がほぼ 1:1 で並んで課金される。だから天井は append のそれと同じ桁に置く。実測: wake 222 行（判定 21 + マーク数え 200 + スキーマ）、append 248 行。

ずれには **3 つ形がある**。索引が知らないセッション、`last_seq` が止まった既知セッション、そして **イベントが全部消えているのに残っている索引行**。3 つめは旧バイナリがセッションごと `event` から消したときに残るもので、`INSERT ... SELECT` からは見えない。`trimSessions` はこの表で順位を付けるので、**幽霊行が枠を 1 つ占めて、代わりに生きているセッションが落とされる**。同じ枝で `DELETE FROM session WHERE session_id NOT IN (SELECT session_id FROM event)` する。

修復の代入は `MAX(last_seq, excluded.last_seq)` ではなく **`excluded.last_seq`**。他の場所でマークを前にしか動かさないのは、コードが手持ちの値より良い情報を持っていないから。ここは持っている — 副問い合わせが `event` 側の `MAX(seq)` そのもので、それが `last_seq` の定義。大きいほうを取ると、逆向きに間違った値がそのまま残る。

判定は **`!==` ではなく「`event` が先行しているとき」**。修復は `last_seq` を上げる方向にしか動かないので、索引が `event` より先に行っている状態を `!==` で拾うと、直せないまま毎 wake スキャンを走らせ続ける吸収状態になる。今のコードに到達経路は無いが、無いからこそ誰も気づかない。

**backfill テストは 1 セッション 1 イベントだと `MAX` と `MIN` を区別できない。** 全部の集約が同じ値になるので、`MIN(seq)` に変えても緑のまま通る（実測）。本番では「最初に喋ったセッション」を最新扱いすることになる。**どれか 1 セッションに 2 件目を足す**と両者が分かれる。

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

床は `.github/workflows/ci.yml` の `EXPECTED_TESTS` / `EXPECTED_SWIFT_TESTS`。**exit code だけでは足りない** — 0 件走っても exit 0 になる経路が両方にある。

## 残タスク

- **Canopy 側: appcast が公開されていないファイルに署名している（Canopy#188）。** `update_appcast.sh` の `strip_sh_xattrs` が DMG を作り直し、それに署名する。GitHub に上がるのは `release.sh` が作った元の DMG。Sparkle は検証に落ちた item を**黙って飛ばして**次に古い版を「最新」として出す。2.26.1 から続く
