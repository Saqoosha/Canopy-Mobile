# セッション画像 —— 設計

2026-09-10。Claude が Read した画像を電話の会話画面に出す。行にサムネイル、タップで原寸。

## 対象

`Read` ツールが読んだ画像だけ。allowlist は `SessionEvent.imageToolAllowlist`（いまは `["Read"]`）1 箇所。

**広げるのは Mac だけの変更で済む。** 電話は届いたものを描くだけで allowlist を持たない。将来 chrome-devtools のスクショを足すとき、App Store のリリースを待たない。広げる場所は Mac の 2 箇所 —— この定数と `ImagePreviewScript` の `IMG_EXT`。

電話から画像を*送る*のは別機能。この設計には入らない。

## 相関 —— 行は `tool_result` 時に 1 行

`tool` イベントは `assistant` フレームの `tool_use` から出るが、**画像は次のフレームの `tool_result` に来る**。そして `events(fromFrame:)` は `tool_result` を含む user フレームを丸ごと捨てている。1 行に絵を付けるには 2 フレームを跨いで結ぶ必要がある。

`tool_use` の時点で拡張子から「これは画像」と分かる。**そのときは行を出さず `tool_use_id` を覚える。** 結果が来たら 1 行出す —— `kind` は `tool` のまま、`text` も `Read: shot.png` のまま、画像フィールドだけ増える。

`kind` を増やさないのが要点。**古い電話は新しいフィールドを Codable が黙って無視して、いつもと同じレンチ行を描く。** 新しい `kind` にすると `.other("image")` に落ちて「image: …」という意味不明の行になる。既存イベントを後から書き換える案は、relay に eventId で更新する概念が無く、append-only のリングバッファの前提を壊すので却下。

代償を 2 つ受け入れる。

- 行が Read の開始時ではなく完了時に出る。画像 Read は速い
- **結果が来ないまま死んだ Read は、上限に達するまで行が出ない。** `ImagePreviewScript` が「失敗した Read は装飾されないまま残る」を既に受け入れているのと同じ性質。結果に画像が無ければ素のレンチ行を出す。上限で追い出された分には素の行が出る（下記）

**受け入れないのは、その Read が他人を巻き込む形。** 行を `tool_result` まで遅らせるので、pending から追い出されたエントリは「行が 1 本も出ない」になり、「必ず行は出る」を直接破る。しかも結果が来ない Read は永久に居座るので、長いセッションでそれが上限ぶん溜まると **結果がまだ来る途中のエントリを追い出す** —— 上の受容は「その Read 自身が消える」話で、他人の行を消す話ではない。だから **追い出す時点で素の行を出し、件数を 1 行ログに出す**。ファイル名は出さない（件数はこの経路が発火したことを示すが、ファイル名は会話の中身に近い）。

**残っている制限がもう 1 つある。** `firstImageResult` は 1 フレームから **1 枚しか**返さないので、複数の画像 Read の結果が同じフレームに載ると、1 件を除いて画像の付かない行になる。「1 行 1 枚」の判断は **1 つの `tool_result` が複数枚返す**場合について書いたもので、**1 フレームに複数の `tool_result` が載る**場合は別問題 —— 最初はこの 2 つを混同していた。追い出し時の素の行が入ったので最悪でも素の行に落ち、それは上で受容した degradation と同じ形。直すなら `imageResults(inFrame:)` が全ペアを返して呼び出し側が回る。

フレームを跨ぐ状態は `ShimProcess` の `pendingImageReads`。`pendingPhoneReply` / `lastAssistantEventId` と同じ形の先例がある。抽出関数は `stampUser` と同じくクロージャで状態を受け渡して純粋に保つ。

## バイトの居場所 —— R2 に 2 枚、DO には鍵だけ

イベント行が運ぶのは **鍵と寸法だけ**（約 100 バイト）。full と thumb は R2。

サムネイルを base64 で埋め込む案を測って捨てた。幅 320 で 25KB/行、200 件のリングバッファで DO 1 台 5MB、バックフィル 1 ページも 5MB の JSON になり、`maxTextBytes` = 8KB を 3 倍超える。

実測（1440×900 のスクショ 1 枚、`sips -Z <w> --setProperty formatOptions 65`）:

| | JPEG | base64 |
|---|---:|---:|
| 元の PNG | 435KB | 580KB |
| 幅 800 | 77KB | 102KB |
| 幅 480 | 35KB | 46KB |
| 幅 320 | 19KB | 25KB |
| 幅 240 | 14KB | 18KB |

**オフラインで見えなくなるが、失うものは無い。** `SessionEventStore` は「これは durable store ではない」と自分で宣言していて、オフラインで見えるのは `HistoryStore` の通知だけ。通知には元から画像が無い。

鍵は `<machine>/<sessionId>/<eventId>/{full,thumb}`。イベント行だけから導ける。

## アップロード —— Mac が先、行はそのあと

Workers は画像を縮小できない（Cloudflare Images は別課金）ので **Mac が 2 枚作る**。ImageIO で幅 320 / JPEG q65。

`PUT /image?machine=&session=&event=&variant=full|thumb` に生バイト。電話は同じ形の `GET` で取る。
認証は両方向とも既存の `SHARED_SECRET` 1 本。新しい credential は要らない。

**アップロードが成功したあとに行を出す。** 行が出た = バイトは在る。壊れたサムネイルが出る状態を作らない。失敗したら素のレンチ行。代償は 1 RTT ぶん行が遅れること。

`publishSessionEvents` は同期なので、アップロードはそこで待たない。完了時にイベントを送る。

## コストと保持

R2 公称価格（実装時に確認する）: storage $0.015/GB-month、Class A $4.50/M、Class B $0.36/M、egress 無料。

1 日 100 枚（full 435KB + thumb 19KB）、7 日保持で storage 0.3GB = $0.005、Class A 6,000 回 = $0.027。**月 5 円未満。** だから eager にアップロードする。タップ時に Mac へ取りに行く遅延取得は Mac が起きている必要があり、この金額のために払う複雑さではない。

保持は R2 のライフサイクルで **7 日**。リングバッファ 200 件は忙しい Mac なら数時間ぶんなので 7 日は十分に長い。期限切れをタップしたら「expired」を出す。

設定したコマンド（2026-09-11、wrangler 4.128.0。フラグ名はバージョンで変わるので
`npx wrangler r2 bucket lifecycle add --help` で確認してから合わせる）:

```bash
npx wrangler r2 bucket lifecycle add canopy-mobile-images expire-images --expire-days=7
```

確認:

```bash
npx wrangler r2 bucket lifecycle list canopy-mobile-images
```

`Default Multipart Abort Rule`（7 日、bucket 作成時からの既定）に加えて
`expire-images`（7 日で失効）が出れば入っている。

## 電話側

`SessionEventRecord` に optional なフィールドを足す（鍵、幅、高さ、バイト数）。無い relay からのイベントでも落ちないこと。

行はいまの細いレンチ行（`SessionEventBlock` の `case .tool`）にサムネイルを足す。タップで原寸のフルスクリーン表示。

**キャッシュは `NSCache` のメモリだけ。** ディスク永続化は作らない —— `AsyncImage` は認証ヘッダを付けられないので小さなローダは要るが、そこで止める。

## テスト

- **Canopy**: `tool_result` → 画像イベントの純関数、拡張子判定、サムネイル寸法、結果に画像が無い場合の素の行、結果が来ない場合
- **worker**: R2 の put/get、鍵の machine スコープ、認証、期限切れの 404、**コストテスト 248/221 が動かないこと**
- **電話**: 新フィールドの寛容なデコード、画像行の描画、タップの拡大、キャッシュ

## リリース順

触るのは **Canopy と Canopy-Mobile と worker**。Mac が先に出る（このプロジェクトの常態）。worker の `/image` は Canopy より先に出す —— Canopy がアップロード先を必要とするため。
