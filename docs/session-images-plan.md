# セッション画像 —— 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude が Read した画像を、電話の会話画面の該当行にサムネイルで出し、タップで原寸を見せる。

**Architecture:** Mac が `tool_result` の base64 から原寸とサムネイルの 2 枚を作って relay の R2 に PUT し、成功したあとにイベントを 1 行送る。イベント行が運ぶのは寸法だけで、バイトは R2 にある。relay は `image` フィールドを解釈せず不透明に通す。

**Tech Stack:** Swift 6 / SwiftUI / ImageIO（Mac と電話）、Cloudflare Workers + Durable Objects + R2、vitest（`@cloudflare/vitest-pool-workers`）、swift-testing、Canopy 側は `_SidebarLogicProbe`。

**Spec:** [docs/session-images.md](session-images.md)

## Global Constraints

- 対象ツールは `Read` のみ。allowlist は `SessionEvent.imageToolAllowlist = ["Read"]` 1 箇所
- 拡張子は `ImagePreviewScript` の `IMG_EXT` と同じ集合 —— `png` `jpg` `jpeg` `gif` `webp` `bmp` `avif`（大文字小文字を無視）
- イベントの `kind` は `tool` のまま。**新しい `kind` を作らない**
- R2 オブジェクトキーは `<machine>/<sessionId>/<eventId>/<variant>`、`variant` は `full` か `thumb` のみ
- サムネイルは最大辺 320px、JPEG 品質 0.65
- 原寸の上限 8MiB。超えたら画像なしの素の行を出す
- 認証は既存の `SHARED_SECRET` の Bearer 1 本。新しい credential を作らない
- relay は `image` の中身を検証しない。オブジェクトならそのまま保存し、そのまま返す
- `docs/session-images.md` の設計から逸れる変更は、先にその文書を直す

---

### Task 1: worker の `/image` エンドポイント

R2 バケットと PUT/GET。イベント側には一切触らない。これ単体でデプロイしても既存の挙動は変わらない。

**Files:**
- Modify: `worker/wrangler.toml`
- Modify: `worker/src/index.ts`（`Env`、および `/decide` ルートの直後）
- Modify: `worker/src/index.test.ts`

**Interfaces:**
- Consumes: 既存の `authorized(request, env)`、`json(value, status)`
- Produces:
  - `PUT /image?machine=<id>&session=<sid>&event=<eid>&variant=full|thumb` —— 本文は生バイト。`200 {"ok":true}`
  - `GET /image?machine=<id>&session=<sid>&event=<eid>&variant=full|thumb` —— バイトと元の `Content-Type`
  - R2 バインディング名 `IMAGES`

- [ ] **Step 1: R2 バケットを作る**

```bash
cd worker && npx wrangler r2 bucket create canopy-mobile-images
```

- [ ] **Step 2: バインディングを wrangler.toml に足す**

`[[kv_namespaces]]` ブロックの直後に置く。

```toml
# Read された画像の原寸とサムネイル。イベント行は寸法だけを運び、バイトは
# ここにある。キーは <machine>/<sessionId>/<eventId>/<full|thumb>。
# 保持は 7 日のライフサイクル規則（Task 8）。
[[r2_buckets]]
binding = "IMAGES"
bucket_name = "canopy-mobile-images"
```

- [ ] **Step 3: 失敗するテストを書く**

`worker/src/index.test.ts` の末尾に足す。

```ts
describe("session images", () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const put = (query: string, body: BodyInit = png, headers: HeadersInit = auth) =>
    SELF.fetch(`https://relay/image?${query}`, { method: "PUT", body, headers });

  it("round-trips a variant and keeps its content type", async () => {
    const res = await put("machine=M1&session=s1&event=e1&variant=full", png, {
      ...auth,
      "Content-Type": "image/png",
    });
    expect(res.status).toBe(200);
    const got = await SELF.fetch(
      "https://relay/image?machine=M1&session=s1&event=e1&variant=full",
      { headers: auth },
    );
    expect(got.status).toBe(200);
    expect(got.headers.get("Content-Type")).toBe("image/png");
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(png);
  });

  // full と thumb は別のオブジェクト。同じ event の下で衝突しない。
  it("keeps full and thumb apart", async () => {
    const thumb = new Uint8Array([0xff, 0xd8, 0xff]);
    await put("machine=M2&session=s1&event=e1&variant=full", png);
    await put("machine=M2&session=s1&event=e1&variant=thumb", thumb);
    const got = await SELF.fetch(
      "https://relay/image?machine=M2&session=s1&event=e1&variant=thumb",
      { headers: auth },
    );
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(thumb);
  });

  // 別の Mac が同じ session/event 名を使っても混ざらない。seq と違い
  // eventId は UUID なので実際には衝突しないが、キーの機械スコープが
  // 消えたことに気づく手段がこれしかない。
  it("scopes the key by machine", async () => {
    await put("machine=A&session=s1&event=e1&variant=full", png);
    const other = await SELF.fetch(
      "https://relay/image?machine=B&session=s1&event=e1&variant=full",
      { headers: auth },
    );
    expect(other.status).toBe(404);
  });

  it("404s a variant that was never uploaded", async () => {
    const res = await SELF.fetch(
      "https://relay/image?machine=M3&session=s1&event=nope&variant=full",
      { headers: auth },
    );
    expect(res.status).toBe(404);
  });

  it("refuses an unknown variant", async () => {
    const res = await put("machine=M4&session=s1&event=e1&variant=original");
    expect(res.status).toBe(400);
  });

  it("refuses a request missing an id", async () => {
    const res = await put("machine=M5&session=s1&variant=full");
    expect(res.status).toBe(400);
  });

  // 認証は両方向に効く。GET だけ素通しだと、画像は URL を知る誰でも
  // 読めることになる。
  it("refuses an unauthenticated upload", async () => {
    const res = await put("machine=M6&session=s1&event=e1&variant=full", png, {});
    expect(res.status).toBe(401);
  });

  it("refuses an unauthenticated read", async () => {
    const res = await SELF.fetch(
      "https://relay/image?machine=M6&session=s1&event=e1&variant=full",
    );
    expect(res.status).toBe(401);
  });

  it("refuses an upload over the size cap", async () => {
    const big = new Uint8Array(13 * 1024 * 1024);
    const res = await put("machine=M7&session=s1&event=e1&variant=full", big);
    expect(res.status).toBe(413);
  });
});
```

- [ ] **Step 4: テストが落ちることを確かめる**

Run: `cd worker && npx vitest run src/index.test.ts -t "session images"`
Expected: FAIL。ルートが無いので全ケースが 404（`refuses an unknown variant` などは 400 を期待して 404 を得る）。

R2 バインディングがテストプールに現れず `env.IMAGES is undefined` で落ちる場合は、`worker/vitest.config.ts` の `miniflare` に `r2Buckets: ["IMAGES"]` を足す（`bindings` と並べる）。wrangler.toml から自動で拾われるなら不要。

- [ ] **Step 5: Env に R2 を足す**

`worker/src/index.ts` の `interface Env`:

```ts
interface Env extends ApnsEnv, LlmEnv {
  MACHINE: DurableObjectNamespace;
  MACHINES: KVNamespace;
  IMAGES: R2Bucket;
  SHARED_SECRET: string;
}
```

- [ ] **Step 6: ルートを実装する**

`worker/src/index.ts`、`/decide` ルートの直後に置く。

```ts
    // Read された画像の原寸とサムネイル。**Durable Object を通らない。**
    // イベント行は寸法しか運ばず、バイトはここにある —— 200 件のリング
    // バッファに base64 を積むと DO 1 台で 5MB になり、バックフィル 1 ページ
    // も同じ大きさの JSON になる。実測は docs/session-images.md。
    if (url.pathname === "/image") {
      const machine = url.searchParams.get("machine");
      const session = url.searchParams.get("session");
      const event = url.searchParams.get("event");
      const variant = url.searchParams.get("variant");
      // 名前を列挙するのは、キーがオブジェクトの置き場所そのものだから。
      // 任意の文字列を通すと、呼び出し側の綴り間違いが「別のバケット領域に
      // 静かに書かれて、二度と読まれないオブジェクト」になる。
      if (variant !== "full" && variant !== "thumb") {
        return json({ error: "variant must be full or thumb" }, 400);
      }
      if (!machine || !session || !event) {
        return json({ error: "machine, session and event required" }, 400);
      }
      const key = `${machine}/${session}/${event}/${variant}`;
      if (request.method === "PUT") {
        const declared = request.headers.get("Content-Length");
        if (declared && Number(declared) > MAX_IMAGE_BYTES) {
          return json({ error: "image too large" }, 413);
        }
        // Content-Length を信じない二段目。チャンク転送では宣言が無く、
        // 上の判定はそのとき何も守らない。
        const body = await request.arrayBuffer();
        if (body.byteLength > MAX_IMAGE_BYTES) {
          return json({ error: "image too large" }, 413);
        }
        await env.IMAGES.put(key, body, {
          httpMetadata: {
            contentType: request.headers.get("Content-Type") ?? "application/octet-stream",
          },
        });
        return json({ ok: true });
      }
      if (request.method === "GET") {
        const object = await env.IMAGES.get(key);
        // 期限切れ（7 日のライフサイクル）と一度も上がらなかったものは
        // 区別しない。電話に出せる言葉は同じ「もう無い」だけ。
        if (!object) return json({ error: "not found" }, 404);
        const headers = new Headers();
        object.writeHttpMetadata(headers);
        // eventId は UUID で、同じキーの中身が変わることは無い。
        headers.set("Cache-Control", "private, max-age=31536000, immutable");
        return new Response(object.body, { headers });
      }
      return json({ error: "method not allowed" }, 405);
    }
```

`fitPushPayload` の直前に定数を置く。

```ts
/** 1 枚の上限、バイト。relay がバイトの捨て場になるのを防ぐだけの数字で、
 *  Mac 側は 8MiB で自分を止める（`RosterImageUploader.maxFullBytes`）。
 *  ここが緩いのは意図的 —— relay は Canopy より後から出るので、Mac の上限を
 *  relay の上限で追い越せないようにしておく。 */
const MAX_IMAGE_BYTES = 12 * 1024 * 1024;
```

- [ ] **Step 7: テストが通ることを確かめる**

Run: `cd worker && npx vitest run src/index.test.ts -t "session images"`
Expected: PASS（10 件）

- [ ] **Step 8: 型検査**

Run: `cd worker && npx tsc --noEmit`
Expected: エラーなし。`R2Bucket` は `@cloudflare/workers-types` にある。

- [ ] **Step 9: コミット**

```bash
git add worker/wrangler.toml worker/src/index.ts worker/src/index.test.ts worker/vitest.config.ts
git commit -m "$(cat <<'MSG'
Add an R2-backed /image endpoint to the relay

- PUT and GET one variant, keyed <machine>/<session>/<event>/<variant>
- Both directions behind the existing shared secret
- Two size checks, because a chunked upload declares no length

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: イベント行の `image` パススルー

DO が `image` を不透明に運ぶ。**中身を解釈しない** —— Mac が先に出るので、relay が検証すると relay のデプロイが Canopy の新機能の前提条件になる（`worker/src/types.ts` が既にこの向きを宣言している）。

**Files:**
- Modify: `worker/src/types.ts`
- Modify: `worker/src/machine.ts`（`ensureSchema`、`appendEvent`、`backfill` の SELECT）
- Modify: `worker/src/machine.test.ts`

**Interfaces:**
- Consumes: Task 1 の何も使わない（独立）
- Produces: `SessionEventMessage.image?: unknown`。`event` テーブルの `image TEXT` カラム（JSON 文字列、または NULL）

- [ ] **Step 1: 失敗するテストを書く**

`worker/src/machine.test.ts` の末尾に足す。既存のヘルパ名（`runInDurableObject` を使うテストの書き方、イベント投入のヘルパ）は同ファイルの先頭を読んで合わせる。

```ts
describe("event image pass-through", () => {
  const image = { width: 1440, height: 900, bytes: 434831 };

  it("returns an image field it was given, unchanged", async () => {
    // 投入と取得は既存のヘルパで。`image` を持つイベントを 1 件 append し、
    // backfill で読み戻す。
    const back = await backfillOne({ sessionId: "s1", kind: "tool", text: "Read: shot.png", image });
    expect(back.image).toEqual(image);
  });

  it("leaves an event with no image field without one", async () => {
    const back = await backfillOne({ sessionId: "s2", kind: "assistant", text: "hi" });
    expect(back.image).toBeUndefined();
  });

  // relay はパイプ。中身の形を判定しないので、知らないキーも通る。
  // これが消えると Canopy が先に新フィールドを足せなくなる。
  it("passes an image object with unknown keys through", async () => {
    const exotic = { width: 1, height: 2, bytes: 3, rotation: 90 };
    const back = await backfillOne({ sessionId: "s3", kind: "tool", text: "Read: x.png", image: exotic });
    expect(back.image).toEqual(exotic);
  });

  // 非オブジェクトは落とす。ここだけは判定する —— 列は TEXT で、
  // 文字列をそのまま入れると読み戻しで JSON.parse が投げる。
  it("drops a non-object image field", async () => {
    const back = await backfillOne({ sessionId: "s4", kind: "tool", text: "Read: x.png", image: "nope" });
    expect(back.image).toBeUndefined();
  });

  // 同じイベントがライブと backfill で違うものになってはいけない。
  // machine.ts の「STORED row, not the message that arrived」と同じ理由。
  it("fans out the same image field it stores", async () => {
    const live = await liveFanoutOne({ sessionId: "s5", kind: "tool", text: "Read: shot.png", image });
    expect(live.image).toEqual(image);
  });
});
```

`backfillOne` と `liveFanoutOne` がまだ無ければ、同ファイルの既存テストが使っている投入・取得の手順をそのまま関数に切り出して作る。**新しい足場を発明しない。**

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `cd worker && npx vitest run src/machine.test.ts -t "event image"`
Expected: FAIL。`back.image` が `undefined`。

- [ ] **Step 3: カラムを足す**

`worker/src/machine.ts` の `ensureSchema`、`event_by_session` インデックスの直後。

```ts
    // **後付けのカラム。`CREATE TABLE IF NOT EXISTS` は既存の表に列を
    // 足さない** ので、動いている DO には無い。
    //
    // 存在判定を `PRAGMA table_info` や `sqlite_master` でやらないのは、
    // DO の SQL がどちらを許すか測っていないから。`LIMIT 0` の SELECT は
    // 普通の SQL で、列が無ければ投げ、あれば 0 行で返る —— 定常状態の
    // コストがゼロ行なのが要点で、ここは wake ごとに走る。
    let hasImageColumn = true;
    try {
      this.ctx.storage.sql.exec(`SELECT image FROM event LIMIT 0`).toArray();
    } catch {
      hasImageColumn = false;
    }
    if (!hasImageColumn) {
      this.ctx.storage.sql.exec(`ALTER TABLE event ADD COLUMN image TEXT`);
    }
```

`CREATE TABLE` 側の列定義にも `image TEXT` を足す（新しい DO は ALTER を通らない）。

```ts
      `CREATE TABLE IF NOT EXISTS event (
         seq        INTEGER PRIMARY KEY AUTOINCREMENT,
         session_id TEXT NOT NULL,
         event_id   TEXT NOT NULL,
         resume_id  TEXT,
         kind       TEXT NOT NULL,
         text       TEXT NOT NULL,
         created_at REAL NOT NULL,
         image      TEXT
       )`
```

- [ ] **Step 4: 型に足す**

`worker/src/types.ts` の `SessionEventMessage`、`at` の直後。

```ts
  /** Read された画像の寸法。**relay はこの中身を見ない** —— オブジェクトなら
   *  そのまま保存してそのまま返す。Canopy が先に出るので、ここで形を検証
   *  すると relay のデプロイが Mac の新機能の前提条件になる（`kind` を
   *  enum で弾かないのと同じ向きの判断）。
   *
   *  バイトは R2 にある。`GET /image?machine=&session=&event=&variant=`。
   *  このフィールドの存在が「この行には画像がある」を意味する。 */
  image?: unknown;
```

- [ ] **Step 5: append と backfill に通す**

`appendEvent` の INSERT:

```ts
    const image =
      msg.image !== null && typeof msg.image === "object" ? JSON.stringify(msg.image) : null;
    const rows = this.ctx.storage.sql
      .exec<{ seq: number }>(
        `INSERT INTO event (session_id, event_id, resume_id, kind, text, created_at, image)
         VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING seq`,
        msg.sessionId, msg.eventId, msg.resumeId ?? null, msg.kind, text, at, image
      )
      .toArray();
```

正規化して返す箇所（ライブのファンアウトと backfill の両方が読む 1 箇所）で `image` を復元する。読み戻しは per-row の try/catch —— 1 行の壊れた JSON でページ全体を落とすと、`SessionEventRecord.Kind` の `.other` が防いでいるのと同じ「200 件まとめて消える」が別経路で復活する。

```ts
    // 書いたのはこのコードなので普通は壊れていない。それでも投げないのは、
    // 1 行のせいで最大 200 件のページが消えるのを避けるため。
    const decodeImage = (raw: string | null): unknown => {
      if (raw === null) return undefined;
      try {
        return JSON.parse(raw);
      } catch {
        console.error("event: undecodable image column, dropping the field");
        return undefined;
      }
    };
```

backfill の SELECT に `image` を足す。

```ts
        `SELECT seq, session_id, event_id, resume_id, kind, text, created_at, image
           FROM event WHERE session_id = ? AND seq > ? ORDER BY seq ASC`,
```

行の型注釈にも `image: string | null` を足す。`image` が `undefined` のときはキーを出さない（`JSON.stringify` が省く）ので、古い電話のデコードは変わらない。

- [ ] **Step 6: テストが通ることを確かめる**

Run: `cd worker && npx vitest run src/machine.test.ts -t "event image"`
Expected: PASS（5 件）

- [ ] **Step 7: コスト上限が動いていないことを確かめる**

Run: `cd worker && npx vitest run src/machine.test.ts -t "cost"`
Expected: PASS。append 248 / wake 222 のまま 300 を下回る。

**上がっていたら止まって原因を書く。** `LIMIT 0` の SELECT が 0 行で返ることが前提で、そこが崩れたなら wake ごとに払う。数字を上げて通すのは禁止 —— この上限は `AGENTS.md` の incident そのもの。

- [ ] **Step 8: 全テストと型検査**

Run: `cd worker && npx vitest run && npx tsc --noEmit`
Expected: 両方 PASS

- [ ] **Step 9: コミット**

```bash
git add worker/src/types.ts worker/src/machine.ts worker/src/machine.test.ts
git commit -m "$(cat <<'MSG'
Carry an opaque image field on session events

- New nullable `image` column, added by ALTER on an existing DO
- Column presence probed with a LIMIT 0 select, not a PRAGMA
- The relay stores and returns the object without reading it
- Per-row decode, so one bad row cannot drop a 200-event page

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: Canopy の画像 Read 判定（純関数）

`SessionEvent` に allowlist と 2 つの純関数を足す。**ネットワークもファイル I/O も無い。** 既定の挙動は今と同一 —— 新しいクロージャ引数を渡さない呼び出し側は素のレンチ行を出し続ける。

**Files:**
- Modify: `Sources/Canopy/Roster/SessionEvent.swift`（Canopy リポジトリ）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces:
  - `SessionEvent.imageToolAllowlist: Set<String>`
  - `SessionEvent.ImageInfo` —— `Codable, Equatable, Sendable`、`let width: Int`、`let height: Int`、`let bytes: Int`
  - `SessionEvent.image: ImageInfo?`（新しい格納プロパティ。`init` の引数は既定 nil）
  - `static func imageReadFileName(name: String, input: [String: Any]?) -> String?`
  - `static func firstImageResult(inFrame: [String: Any]) -> (toolUseId: String, mediaType: String, data: Data)?`
  - `events(fromFrame:…)` に `onImageRead: ((_ toolUseId: String, _ fileName: String) -> Void)? = nil`

- [ ] **Step 1: 失敗するテストを書く**

`_SidebarLogicProbe.swift` の既存の `event:` ブロック（`SessionEvent.events(fromFrame:` を並べている `do { }`）の末尾に足す。

```swift
            // 画像 Read。行は tool_use ではなく tool_result の時点で出る。
            let imageRead: [String: Any] = [
                "type": "assistant",
                "message": ["content": [
                    ["type": "tool_use", "id": "toolu_1", "name": "Read",
                     "input": ["file_path": "/Users/hiko/shot.PNG"]],
                ]],
            ]
            record("event: an image Read is recognised by extension, case-insensitively",
                   SessionEvent.imageReadFileName(name: "Read",
                                                  input: ["file_path": "/x/shot.PNG"]) == "shot.PNG")
            record("event: a non-image Read is not an image Read",
                   SessionEvent.imageReadFileName(name: "Read",
                                                  input: ["file_path": "/x/main.swift"]) == nil)
            // allowlist の外は、拡張子が画像でも画像 Read ではない。
            // これが緩むと、上流が足したどのツールの出力も R2 に上がりうる。
            record("event: an unlisted tool is never an image read",
                   SessionEvent.imageReadFileName(name: "Bash",
                                                  input: ["file_path": "/x/shot.png"]) == nil)
            record("event: a Read with no file_path is not an image read",
                   SessionEvent.imageReadFileName(name: "Read", input: nil) == nil)

            // 既定では今と同じ。クロージャを渡さない呼び出し側は行を失わない。
            let plain = SessionEvent.events(fromFrame: imageRead, sessionId: "S", resumeId: nil,
                                            at: now, nextId: ids)
            record("event: with no image handler an image Read still emits its row",
                   plain.count == 1 && plain.first?.text == "Read: shot.PNG")

            // クロージャを渡すと、行は出ずに tool_use_id が報告される。
            var noted: [(String, String)] = []
            let suppressed = SessionEvent.events(fromFrame: imageRead, sessionId: "S", resumeId: nil,
                                                 at: now, nextId: ids,
                                                 onImageRead: { noted.append(($0, $1)) })
            record("event: an image Read emits no row at tool_use time", suppressed.isEmpty)
            record("event: an image Read reports its tool_use id and file name",
                   noted.count == 1 && noted[0].0 == "toolu_1" && noted[0].1 == "shot.PNG")

            // 同じ assistant フレームに画像 Read と別のツールが並んでいても、
            // 抑止されるのは画像 Read の行だけ。
            let mixedTools: [String: Any] = [
                "type": "assistant",
                "message": ["content": [
                    ["type": "tool_use", "id": "toolu_a", "name": "Read",
                     "input": ["file_path": "/x/shot.png"]],
                    ["type": "tool_use", "id": "toolu_b", "name": "Bash",
                     "input": ["command": "ls"]],
                ]],
            ]
            let onlyBash = SessionEvent.events(fromFrame: mixedTools, sessionId: "S", resumeId: nil,
                                               at: now, nextId: ids, onImageRead: { _, _ in })
            record("event: suppression is per block, not per frame",
                   onlyBash.count == 1 && onlyBash.first?.text == "Bash: ls")

            // tool_result 側。ImagePreviewScript が実測した形。
            let resultFrame: [String: Any] = [
                "type": "user",
                "message": ["content": [
                    ["type": "tool_result", "tool_use_id": "toolu_1", "content": [
                        ["type": "image", "source": [
                            "type": "base64", "media_type": "image/png",
                            "data": Data([0x89, 0x50, 0x4e, 0x47]).base64EncodedString(),
                        ]],
                    ]],
                ]],
            ]
            let found = SessionEvent.firstImageResult(inFrame: resultFrame)
            record("event: a tool_result's base64 image is decoded",
                   found?.toolUseId == "toolu_1" && found?.mediaType == "image/png"
                       && found?.data == Data([0x89, 0x50, 0x4e, 0x47]))

            // 失敗した Read は content が文字列。ImagePreviewScript と同じ扱い。
            let errorResult: [String: Any] = [
                "type": "user",
                "message": ["content": [
                    ["type": "tool_result", "tool_use_id": "toolu_1", "content": "File not found"],
                ]],
            ]
            record("event: a string-content tool_result yields no image",
                   SessionEvent.firstImageResult(inFrame: errorResult) == nil)

            record("event: undecodable base64 yields no image",
                   SessionEvent.firstImageResult(inFrame: [
                       "type": "user",
                       "message": ["content": [
                           ["type": "tool_result", "tool_use_id": "toolu_1", "content": [
                               ["type": "image", "source": [
                                   "type": "base64", "media_type": "image/png",
                                   "data": "!!!not base64!!!",
                               ]],
                           ]],
                       ]],
                   ]) == nil)

            // 画像フィールドを持つイベントが JSON に往復すること。
            // ここが壊れると relay には届くが電話が読めない、という形になる。
            let withImage = SessionEvent(eventId: "e1", sessionId: "S", resumeId: nil,
                                         kind: .tool, text: "Read: shot.png", at: now,
                                         image: SessionEvent.ImageInfo(width: 1440, height: 900,
                                                                       bytes: 434_831))
            let roundTripped = (try? JSONEncoder().encode(withImage))
                .flatMap { try? JSONDecoder().decode(SessionEvent.self, from: $0) }
            record("event: an image event round-trips through JSON",
                   roundTripped?.image == withImage.image)
            // 画像の無いイベントは image キーを出さない。古い relay と
            // 古い電話のデコードを変えないため。
            let bare = SessionEvent(eventId: "e2", sessionId: "S", resumeId: nil,
                                    kind: .tool, text: "Bash: ls", at: now)
            record("event: an image-less event writes no image key",
                   !(String(data: (try? JSONEncoder().encode(bare)) ?? Data(),
                            encoding: .utf8)?.contains("image") ?? true))
```

- [ ] **Step 2: テストが落ちることを確かめる**

```bash
cd ~/repos/Personal/Canopy && xcodebuild -project Canopy.xcodeproj -scheme Canopy \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```
Expected: コンパイルエラー。`imageReadFileName` などが存在しない。

`Canopy.xcodeproj` が無い、または `project.yml` より古い場合は先に `xcodegen generate`。

- [ ] **Step 3: 実装する**

`Sources/Canopy/Roster/SessionEvent.swift`。

`Kind` の直後に足す。

```swift
    /// 画像を運んでよいツールの名前。
    ///
    /// **`toolLabel` の switch と同じ向きの判断で、同じ理由で狭い。** あちらは
    /// 80 文字の要約について「デフォルトは名前だけ、列挙したものだけが中身を
    /// 出す」と決めている。こちらが運ぶのは数百 KB の画像なので、同じ慎重さが
    /// 要る。**削除は常に安全、追加だけが判断を要する。**
    ///
    /// 広げる先は chrome-devtools の `take_screenshot` などだが、**電話側には
    /// この判定が無い** —— 届いたものを描くだけなので、広げるのは Mac の変更
    /// だけで済み、App Store のリリースを待たない。もう 1 箇所は
    /// `ImagePreviewScript` の `IMG_EXT`。
    static let imageToolAllowlist: Set<String> = ["Read"]

    /// 画像として扱う拡張子。`ImagePreviewScript` の `IMG_EXT` と同じ集合。
    /// 片方だけ広げると、Mac の webview には出るのに電話には出ない（あるいは
    /// その逆）という、どちらもエラーを出さない形のずれになる。
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "avif"]

    /// 画像 Read なら最後のパス要素、そうでなければ nil。
    ///
    /// `toolLabel` が `Read` に対して出すのと同じ最後のパス要素を返す ——
    /// ディレクトリは機械の説明であって、作業対象の名前ではない。
    static func imageReadFileName(name: String, input: [String: Any]?) -> String? {
        guard imageToolAllowlist.contains(name),
              let path = input?["file_path"] as? String
        else { return nil }
        let url = URL(fileURLWithPath: path)
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let component = url.lastPathComponent
        return component.isEmpty ? nil : component
    }

    /// 1 つの `tool_result` フレームから最初の base64 画像を取り出す。
    ///
    /// **最初の 1 枚だけ。** 1 回の Read が複数枚返すことはあり（`ImagePreviewScript`
    /// は配列で持っている）、そのときは 1 行 1 枚という前提を守って残りを捨てる。
    ///
    /// 失敗した Read は `content` が配列ではなく文字列で来る —— これも
    /// `ImagePreviewScript` の実測。
    static func firstImageResult(inFrame message: [String: Any])
        -> (toolUseId: String, mediaType: String, data: Data)? {
        guard message["type"] as? String == "user",
              let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return nil }
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let toolUseId = block["tool_use_id"] as? String,
                  let items = block["content"] as? [[String: Any]]
            else { continue }
            for item in items where item["type"] as? String == "image" {
                guard let source = item["source"] as? [String: Any],
                      source["type"] as? String == "base64",
                      let mediaType = source["media_type"] as? String,
                      let encoded = source["data"] as? String,
                      let data = Data(base64Encoded: encoded)
                else { continue }
                return (toolUseId, mediaType, data)
            }
        }
        return nil
    }
```

`ImageInfo` を `Kind` の隣に足す。

```swift
    /// 1 枚の画像について電話が知る必要のあること。**バイトは含まない** ——
    /// R2 にあり、`GET /image` で取る。この値の存在が「この行には画像がある」。
    ///
    /// `width` / `height` は原寸のピクセル数で、行が絵を読み込む前に正しい
    /// 縦横比の場所を確保するためにある。`bytes` は原寸のバイト数で、タップ
    /// する前に大きさを見せるため。
    struct ImageInfo: Codable, Equatable, Sendable {
        let width: Int
        let height: Int
        let bytes: Int
    }
```

格納プロパティと `init`。

```swift
    let at: Date
    /// 画像 Read の行だけが持つ。**`kind` は `tool` のまま。**
    ///
    /// 新しい `kind` にしないのは互換のため —— 古い電話は知らない `kind` を
    /// `.other` に落として「image: Read: shot.png」という意味不明の行を描く。
    /// 未知のフィールドは Codable が黙って無視するので、古い電話はいつもの
    /// レンチ行のままになる。
    let image: ImageInfo?
```

既存の `init` に `image` を足すだけ。**`text` の行には触らない** —— cap は `make` の側でかかっていて、ここで `capped(text)` を挟むと二重にかかる。

```swift
    init(eventId: String, sessionId: String, resumeId: String?, kind: Kind, text: String,
         at: Date, image: ImageInfo? = nil) {
        self.type = "event"
        self.eventId = eventId
        self.sessionId = sessionId
        self.resumeId = resumeId
        self.kind = kind
        self.text = text
        self.at = at
        self.image = image
    }
```

`events(fromFrame:)` の `tool_use` ループを差し替える。

```swift
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                // 画像 Read は、結果が来るまで行を出さない。画像はこのフレーム
                // ではなく次の `tool_result` に来るので、行と絵を 1 行にする
                // には結果まで待つしかない。**`onImageRead` が nil のときは
                // 今と同じ挙動** —— 画像を扱わない呼び出し側が行を失わない。
                if let onImageRead,
                   let fileName = imageReadFileName(name: name, input: block["input"] as? [String: Any]),
                   let toolUseId = block["id"] as? String {
                    onImageRead(toolUseId, fileName)
                    continue
                }
                guard let event = make(.tool, toolLabel(name: name, input: block["input"] as? [String: Any]))
                else { continue }
                out.append(event)
            }
```

シグネチャに引数を足す。`events(from:)`（envelope をはがす方）にも同じ引数を足して素通しする。

```swift
    static func events(fromFrame message: [String: Any],
                       sessionId: String,
                       resumeId: String?,
                       at: Date,
                       nextId: () -> String,
                       stampUser: ((String) -> String?)? = nil,
                       onImageRead: ((_ toolUseId: String, _ fileName: String) -> Void)? = nil) -> [SessionEvent] {
```

`make` は `image` を取らない（画像イベントは Task 5 で別に組む）。

- [ ] **Step 4: ビルドしてプローブを回す**

```bash
cd ~/repos/Personal/Canopy && xcodebuild -project Canopy.xcodeproj -scheme Canopy \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -3 \
  && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```
Expected: `BUILD SUCCEEDED`、プローブは FAIL 0。新しい 14 件が PASS に並ぶ。

- [ ] **Step 5: 既存のアサーションが 1 件も落ちていないことを確かめる**

プローブの出力で `FAIL` が 0 件であること。特に既存の `event: a tool_use becomes one tool event` と `event: Edit carries the file name` —— どちらも `onImageRead` を渡さない呼び出しなので、既定の挙動が変わっていれば落ちる。

- [ ] **Step 6: コミット**

```bash
cd ~/repos/Personal/Canopy && git add Sources/Canopy/Roster/SessionEvent.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "$(cat <<'MSG'
Recognise an image Read, and carry its dimensions on an event

- `imageToolAllowlist` is `["Read"]`, widened here and nowhere else
- Extensions mirror ImagePreviewScript's IMG_EXT
- `onImageRead` suppresses the tool_use-time row; nil keeps today's behaviour
- `firstImageResult` decodes the measured tool_result shape

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: Canopy のサムネイル生成

`Data` から `Data` の純粋な変換 2 つ。ImageIO だけで、AppKit も画面も要らない。

**Files:**
- Create: `Sources/Canopy/Roster/RosterImageUploader.swift`（Canopy リポジトリ。Task 5 でアップロードを同じファイルに足す）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces:
  - `RosterImageUploader.thumbnailMaxPixelSize: Int` = 320
  - `RosterImageUploader.thumbnailQuality: Double` = 0.65
  - `RosterImageUploader.maxFullBytes: Int` = 8 × 1024 × 1024
  - `static func pixelSize(of data: Data) -> (width: Int, height: Int)?`
  - `static func thumbnail(from data: Data) -> Data?`

- [ ] **Step 1: 失敗するテストを書く**

`_SidebarLogicProbe.swift` に新しい `do { }` ブロックとして足す。フィクスチャは ImageIO で作るので外部ファイルに依存しない。

```swift
        // 画像アップロードの純粋な部分。ネットワークには触らない。
        do {
            /// 単色 PNG を作る。ImageIO で作るので、リポジトリに画像を置かない。
            func makePNG(width: Int, height: Int) -> Data? {
                let bytesPerRow = width * 4
                var pixels = [UInt8](repeating: 0x80, count: bytesPerRow * height)
                guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                      let image = CGImage(width: width, height: height,
                                          bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil,
                                          shouldInterpolate: false, intent: .defaultIntent)
                else { return nil }
                let out = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
                else { return nil }
                CGImageDestinationAddImage(dest, image, nil)
                guard CGImageDestinationFinalize(dest) else { return nil }
                pixels.removeAll()
                return out as Data
            }

            guard let wide = makePNG(width: 1440, height: 900) else {
                record("image: fixture PNG could be built", false, "makePNG returned nil")
                return (lines.joined(separator: "\n"), fail + 1)
            }

            record("image: pixelSize reads the real dimensions",
                   RosterImageUploader.pixelSize(of: wide).map { $0 == (1440, 900) } ?? false)
            record("image: pixelSize refuses non-image bytes",
                   RosterImageUploader.pixelSize(of: Data("not an image".utf8)) == nil)

            let thumb = RosterImageUploader.thumbnail(from: wide)
            // 長辺が上限で、縦横比が保たれている。320×200 を期待する。
            record("image: a thumbnail's long edge is the cap",
                   RosterImageUploader.pixelSize(of: thumb ?? Data())
                       .map { max($0.width, $0.height) == RosterImageUploader.thumbnailMaxPixelSize } ?? false)
            record("image: a thumbnail keeps the aspect ratio",
                   RosterImageUploader.pixelSize(of: thumb ?? Data())
                       .map { $0.width == 320 && $0.height == 200 } ?? false)
            // 縮小の目的そのもの。ここが逆転していたら R2 に置く意味が無い。
            record("image: a thumbnail is smaller than the original",
                   (thumb?.count ?? .max) < wide.count)
            record("image: thumbnail refuses non-image bytes",
                   RosterImageUploader.thumbnail(from: Data("not an image".utf8)) == nil)

            // 上限より小さい画像は拡大しない。320 を下回る絵を 320 に伸ばすと
            // バイトが増えるだけで、行に出る大きさは変わらない。
            if let small = makePNG(width: 100, height: 60) {
                record("image: an already-small image is not upscaled",
                       RosterImageUploader.pixelSize(of: RosterImageUploader.thumbnail(from: small) ?? Data())
                           .map { $0.width == 100 && $0.height == 60 } ?? false)
            } else {
                record("image: small fixture PNG could be built", false, "makePNG returned nil")
            }
        }
```

ファイル先頭の import に `import ImageIO`、`import CoreGraphics`、`import UniformTypeIdentifiers` が必要なら足す。

- [ ] **Step 2: テストが落ちることを確かめる**

Run: 上と同じビルドコマンド
Expected: コンパイルエラー。`RosterImageUploader` が存在しない。

- [ ] **Step 3: 実装する**

`Sources/Canopy/Roster/RosterImageUploader.swift` を作る。

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RosterImage")

/// Read された画像を relay の R2 に置く。
///
/// **`RosterNotifier` と違って、これは fire-and-forget ではない。** 呼び出し側は
/// 成功を待ってからイベントを送る —— 行が出た = バイトは在る、という関係を
/// 守るため。壊れたサムネイルが出る状態を作らない。
enum RosterImageUploader {
    /// サムネイルの長辺、ピクセル。実測で 1440×900 のスクショが JPEG 19KB に
    /// なる値（`docs/session-images.md` の表）。行に出る大きさに対して十分で、
    /// 480 にすると 35KB、800 で 77KB。
    static let thumbnailMaxPixelSize = 320
    /// サムネイルの JPEG 品質。上の実測と同じ 0.65。
    static let thumbnailQuality = 0.65
    /// 原寸の上限、バイト。超えたら何もアップロードせず、呼び出し側は素の
    /// レンチ行を出す。relay 側の上限（12MiB）より低いのは意図的 —— Mac が
    /// 先に出るので、こちらの上限を relay の上限で追い越せないようにする。
    static let maxFullBytes = 8 * 1024 * 1024

    /// 画像の実ピクセル寸法。デコードせずにヘッダだけ読む。
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    /// 長辺 `thumbnailMaxPixelSize` の JPEG。**元より大きくはしない** ——
    /// `kCGImageSourceCreateThumbnailFromImageIfAbsent` ではなく `Always` を
    /// 使うと小さい絵も上限まで引き伸ばされ、バイトが増えるだけで行に出る
    /// 大きさは変わらない。
    static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = pixelSize(of: data)
        else { return nil }
        let longEdge = min(max(size.width, size.height), thumbnailMaxPixelSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            // EXIF の向きを焼き込む。しないと、電話が向きを知らないまま
            // 横倒しのサムネイルを描く。
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: thumbnailQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
        return out as Data
    }
}
```

`project.yml` は `Sources` 配下を走査するので、ターゲットへの追加作業は無い。

- [ ] **Step 4: テストが通ることを確かめる**

Run: Step 2 と同じビルド + プローブ
Expected: `BUILD SUCCEEDED`、FAIL 0、新しい 7 件が PASS。

- [ ] **Step 5: コミット**

```bash
cd ~/repos/Personal/Canopy && git add Sources/Canopy/Roster/RosterImageUploader.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "$(cat <<'MSG'
Build a 320px thumbnail with ImageIO

- Long edge capped, aspect ratio kept, EXIF orientation baked in
- An already-small image is not upscaled
- Constants carry the measured sizes from the design doc

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: Canopy のアップロードと ShimProcess の配線

ここで初めて 2 フレームが繋がって、画像付きの行が実際に relay へ出る。

**Files:**
- Modify: `Sources/Canopy/Roster/RosterImageUploader.swift`（`upload` を足す）
- Modify: `Sources/Canopy/ShimProcess.swift`（`publishSessionEvents` の周り、6103 行付近）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: Task 3 の `imageReadFileName` / `firstImageResult` / `ImageInfo` / `onImageRead`、Task 4 の `thumbnail` / `pixelSize` / `maxFullBytes`、既存の `RosterPublisher.sharedSecretForNotifier()` と `CanopySettings.shared.rosterEndpoint`、`MachineIdentity.stableId()`
- Produces:
  - `RosterImageUploader.upload(sessionId:eventId:full:thumb:mediaType:) async -> Bool`
  - `ShimProcess.pendingImageReads`（private）
  - `ShimProcess.maxPendingImageReads: Int` = 32

- [ ] **Step 1: 失敗するテストを書く（純粋な部分だけ）**

`upload` はネットワークなのでプローブから叩けない。**pending の枝刈りだけを純粋な形に出して pin する。** `_SidebarLogicProbe.swift` の Task 4 のブロックに足す。

```swift
            // pending の上限。結果が来ないまま溜まる Read があるので、
            // 無限には持たない。**古いものから落とす** —— 新しいものを
            // 落とすと、直前に始まった Read の絵が永久に出ない。
            var pending = [(id: String, file: String)]()
            for i in 0..<40 { pending.append((id: "t\(i)", file: "f\(i).png")) }
            let pruned = ShimProcess.prunedImageReads(pending, cap: ShimProcess.maxPendingImageReads)
            record("image: pending reads are capped",
                   pruned.count == ShimProcess.maxPendingImageReads)
            record("image: pruning drops the oldest, not the newest",
                   pruned.first?.id == "t8" && pruned.last?.id == "t39")
            record("image: a list under the cap is untouched",
                   ShimProcess.prunedImageReads([(id: "a", file: "a.png")], cap: 32).count == 1)
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: Task 4 と同じビルド
Expected: コンパイルエラー。`prunedImageReads` が存在しない。

- [ ] **Step 3: `upload` を実装する**

`RosterImageUploader` に足す。

```swift
    /// full と thumb を PUT する。両方成功したときだけ true。
    ///
    /// **片方だけ成功した状態を成功と呼ばない。** thumb だけ在れば行に絵は
    /// 出るがタップが 404 になり、full だけ在れば行に穴が空く。どちらも
    /// 「行が出た = バイトは在る」を破る。
    static func upload(sessionId: String, eventId: String,
                       full: Data, thumb: Data, mediaType: String) async -> Bool {
        guard let target = await resolvedTarget() else { return false }
        async let a = put(target: target, sessionId: sessionId, eventId: eventId,
                          variant: "full", body: full, mediaType: mediaType)
        async let b = put(target: target, sessionId: sessionId, eventId: eventId,
                          variant: "thumb", body: thumb, mediaType: "image/jpeg")
        return await a && b
    }

    /// `RosterNotifier.resolvedTarget` と同じ 3 つ組を同じ順で確かめる。
    /// https の拒否も同じ理由（CWE-319）—— ここも Bearer secret を運ぶ。
    @MainActor
    private static func resolvedTarget() -> (machineId: String, base: URLComponents, secret: String)? {
        let settings = CanopySettings.shared
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint)
        else { return nil }
        components.path = "/image"
        guard components.scheme == "https" else {
            logger.error("roster endpoint must be https; refusing to send the secret over \(components.scheme ?? "no scheme", privacy: .public)")
            return nil
        }
        guard let secret = RosterPublisher.sharedSecretForNotifier() else { return nil }
        return (machineId, components, secret)
    }

    private static func put(target: (machineId: String, base: URLComponents, secret: String),
                            sessionId: String, eventId: String, variant: String,
                            body: Data, mediaType: String) async -> Bool {
        var components = target.base
        components.queryItems = [
            URLQueryItem(name: "machine", value: target.machineId),
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "event", value: eventId),
            URLQueryItem(name: "variant", value: variant),
        ]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(target.secret)", forHTTPHeaderField: "Authorization")
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 {
                logger.notice("roster image \(variant, privacy: .public) returned \(code, privacy: .public)")
                return false
            }
            return true
        } catch {
            logger.notice("roster image \(variant, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
```

- [ ] **Step 4: ShimProcess を配線する**

`publishSessionEvents` の近くに足す。

```swift
    /// 結果を待っている画像 Read。`tool_use` で入り、`tool_result` で出る。
    ///
    /// **フレームを跨ぐ状態がここに要るのは、画像が行と別のフレームに来る
    /// から。** `pendingPhoneReply` と `lastAssistantEventId` が同じ形。
    private var pendingImageReads: [(id: String, file: String)] = []

    /// pending の上限。結果が来ない Read（セッションが死んだ、CLI が落ちた）
    /// があるので、無限には持たない。
    static let maxPendingImageReads = 32

    /// 上限を超えたぶんを古い側から落とす。
    ///
    /// **新しい側を落とさない。** 直前に始まった Read こそ画面に出る番なので、
    /// そこを捨てると「最近の絵だけ出ない」という一番気づきにくい形になる。
    static func prunedImageReads(_ reads: [(id: String, file: String)],
                                 cap: Int) -> [(id: String, file: String)] {
        guard reads.count > cap else { return reads }
        return Array(reads.suffix(cap))
    }
```

`publishSessionEvents` を書き換える。**既存の `[event]` ログ行の位置と理由は変えない。**

```swift
    private func publishSessionEvents(_ message: [String: Any]) {
        guard let session = boundSession else { return }
        let pending = pendingPhoneReply
        let events = SessionEvent.events(from: message,
                                         sessionId: session.id.uuidString,
                                         resumeId: session.resumeId,
                                         at: Date(),
                                         nextId: { UUID().uuidString },
                                         stampUser: { text in
                                             guard let pending, text == pending.text else { return nil }
                                             return pending.id
                                         },
                                         onImageRead: { [weak self] toolUseId, fileName in
                                             guard let self else { return }
                                             self.pendingImageReads.append((id: toolUseId, file: fileName))
                                             self.pendingImageReads = Self.prunedImageReads(
                                                 self.pendingImageReads, cap: Self.maxPendingImageReads)
                                         })
        // 画像の結果は `events` が空を返すフレーム（tool_result を含む user
        // フレーム）に来るので、**空の guard より先に見る。**
        if let frame = SessionEvent.ioFrame(in: message) {
            publishImageResultIfAny(frame, session: session)
        }
        logger.debug("[event] \(events.count, privacy: .public) event(s) from \((SessionEvent.ioFrame(in: message)?["type"] as? String) ?? "none", privacy: .public)")
        guard !events.isEmpty else { return }
        if let pending, events.contains(where: { $0.kind == .user && $0.eventId == pending.id }) {
            pendingPhoneReply = nil
        }
        for event in events {
            if event.kind == .assistant { lastAssistantEventId = event.eventId }
            RosterPublisher.current?.sendEvent(event)
        }
    }

    /// 待っていた画像 Read の結果が来たら、2 枚アップロードして 1 行出す。
    ///
    /// **アップロードの成功を待ってから行を出す。** 行が出た = バイトは在る、
    /// という関係が、壊れたサムネイルの出ない唯一の根拠。失敗したら画像なしの
    /// 素のレンチ行を出す —— 行そのものを落とすと、Read があったことすら
    /// 伝わらない。
    private func publishImageResultIfAny(_ frame: [String: Any], session: OpenSession) {
        guard let result = SessionEvent.firstImageResult(inFrame: frame),
              let index = pendingImageReads.firstIndex(where: { $0.id == result.toolUseId })
        else { return }
        let file = pendingImageReads[index].file
        pendingImageReads.remove(at: index)

        let eventId = UUID().uuidString
        let sessionId = session.id.uuidString
        let resumeId = session.resumeId
        let text = "Read: \(file)"
        let at = Date()

        func emit(_ image: SessionEvent.ImageInfo?) {
            RosterPublisher.current?.sendEvent(
                SessionEvent(eventId: eventId, sessionId: sessionId, resumeId: resumeId,
                             kind: .tool, text: text, at: at, image: image))
        }

        guard result.data.count <= RosterImageUploader.maxFullBytes,
              let size = RosterImageUploader.pixelSize(of: result.data),
              let thumb = RosterImageUploader.thumbnail(from: result.data)
        else {
            emit(nil)
            return
        }
        let info = SessionEvent.ImageInfo(width: size.width, height: size.height,
                                          bytes: result.data.count)
        Task { @MainActor in
            let ok = await RosterImageUploader.upload(
                sessionId: sessionId, eventId: eventId,
                full: result.data, thumb: thumb, mediaType: result.mediaType)
            emit(ok ? info : nil)
        }
    }
```

`OpenSession` の型名が違う場合は、`boundSession` の宣言に合わせる。

- [ ] **Step 5: ビルドしてプローブを回す**

Run: Task 4 と同じビルド + プローブ
Expected: `BUILD SUCCEEDED`、FAIL 0、新しい 3 件が PASS。

- [ ] **Step 6: 実機（この Mac）で 1 枚流して確かめる**

Debug ビルドは別 bundle id（`sh.saqoo.Canopy.debug`）なので Release を止めずに立てられる。ただし **machine id は共通なので roster を取り合う** ——確認が済んだら閉じる。

```bash
# 別の窓で、イベントのログを拾う
/usr/bin/log stream --predicate 'process == "Canopy" AND subsystem == "sh.saqoo.Canopy"' \
  --level debug --style compact | grep -E "\[event\]|RosterImage"
```

Debug ビルドのセッションで画像を Read させ、`[event]` が出て `RosterImage` のエラーが出ないことを見る。そのあと R2 に載ったかを直接確かめる。

```bash
cd worker && npx wrangler r2 object get canopy-mobile-images/<machine>/<session>/<event>/thumb \
  --remote --file /tmp/thumb.jpg && open /tmp/thumb.jpg
```

`<machine>` は `ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformUUID`。`<session>` と `<event>` はログから。

- [ ] **Step 7: コミット**

```bash
cd ~/repos/Personal/Canopy && git add Sources/Canopy/Roster/RosterImageUploader.swift Sources/Canopy/ShimProcess.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "$(cat <<'MSG'
Upload a Read image, then emit its row

- Both variants must land before the event is sent
- A failed upload emits the plain wrench row, never nothing
- Pending reads are capped, dropping the oldest

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: 電話のデコード

`SessionEventRecord` が新しいフィールドを読む。**描画はまだしない。**

**Files:**
- Modify: `Sources/SessionEventStore.swift`
- Create: `Tests/SessionImageTests.swift`

**Interfaces:**
- Produces:
  - `SessionEventImage` —— `Codable, Hashable, Sendable`、`let width: Int`、`let height: Int`、`let bytes: Int`
  - `SessionEventRecord.image: SessionEventImage?`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/SessionImageTests.swift` を作る。

```swift
import Foundation
import Testing
@testable import CanopyMobile

struct SessionEventImageTests {
    private func decode(_ json: String) throws -> SessionEventRecord {
        let decoder = JSONDecoder()
        return try decoder.decode(SessionEventRecord.self, from: Data(json.utf8))
    }

    @Test("An image field decodes into the record")
    func decodesAnImage() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"tool","text":"Read: shot.png",
         "at":0,"image":{"width":1440,"height":900,"bytes":434831}}
        """)
        #expect(record.image?.width == 1440)
        #expect(record.image?.height == 900)
        #expect(record.image?.bytes == 434831)
    }

    // 画像を持たないイベントが圧倒的多数。ここが optional でないと
    // 全イベントのデコードが落ちる。
    @Test("An event with no image field decodes with a nil image")
    func decodesWithoutAnImage() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"assistant","text":"hi","at":0}
        """)
        #expect(record.image == nil)
    }

    // 相手は Mac で、先に出るのはあちら。知らないキーで落ちてはいけない。
    @Test("An image field with unknown keys still decodes")
    func toleratesUnknownKeys() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"tool","text":"Read: shot.png",
         "at":0,"image":{"width":10,"height":20,"bytes":30,"rotation":90}}
        """)
        #expect(record.image?.width == 10)
    }

    // **これが一番大事。** 画像フィールドが壊れていても、そのページの
    // 残りは生きなければいけない。backfill は配列でデコードされるので、
    // 1 件の throw が最大 200 件を落とす（`Kind.other` と同じ理由）。
    @Test("A malformed image field does not fail the whole record")
    func survivesAMalformedImage() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"tool","text":"Read: shot.png",
         "at":0,"image":{"width":"wide"}}
        """)
        #expect(record.image == nil)
        #expect(record.text == "Read: shot.png")
    }
}
```

- [ ] **Step 2: テストが落ちることを確かめる**

```bash
cd ~/repos/Personal/Canopy-Mobile && xcodegen generate && \
  xcodebuild test -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print([x["udid"] for k in d for x in d[k] if x.get("isAvailable")][0])')" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: コンパイルエラー。`SessionEventImage` が存在しない。

- [ ] **Step 3: 実装する**

`Sources/SessionEventStore.swift`、`SessionEventRecord` の直前に足す。

```swift
/// 1 枚の画像について、この電話が知っていること。
///
/// **バイトはここに無い。** R2 にあり、`GET /image?machine=&session=&event=&variant=`
/// で取る。この値の存在が「この行には画像がある」を意味する。
///
/// `width` / `height` は原寸のピクセル数で、絵が届く前に正しい縦横比の場所を
/// 確保するためにある。`bytes` は原寸のバイト数で、タップする前に大きさを
/// 見せるため。
struct SessionEventImage: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let bytes: Int
}
```

`SessionEventRecord` に足す。

```swift
    let at: Date
    /// 画像 Read の行だけが持つ。**`kind` は `tool` のまま** なので、この
    /// フィールドを知らないビルドはいつものレンチ行を描く。
    ///
    /// **デコードは全体主義的でない。** 壊れた画像フィールド 1 件で
    /// `SessionEventRecord` の init が throw すると、backfill は配列で
    /// デコードされるので最大 `maxEventsPerSession` 件のページが丸ごと
    /// 消える —— `Kind.other` が防いでいるのと同じ形が別のフィールドで
    /// 復活する。だから読めなければ nil にして、行そのものは残す。
    let image: SessionEventImage?
```

`Codable` を手で書く必要がある（合成された `init(from:)` は壊れた `image` で throw する）。**`image` だけを `try?` にする。**

```swift
    enum CodingKeys: String, CodingKey {
        case seq, eventId, sessionId, resumeId, kind, text, at, image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        eventId = try c.decode(String.self, forKey: .eventId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        resumeId = try c.decodeIfPresent(String.self, forKey: .resumeId)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Date.self, forKey: .at)
        // 上の全部と違って `try?`。理由はプロパティのドキュメントに。
        image = try? c.decodeIfPresent(SessionEventImage.self, forKey: .image)
    }
```

既存の memberwise init はテストが使っているので、`image: SessionEventImage? = nil` を末尾に足して残す。

- [ ] **Step 4: テストが通ることを確かめる**

Run: Step 2 と同じコマンド
Expected: PASS。新しい 4 件を含む。

- [ ] **Step 5: 既存の Swift テストが落ちていないことを確かめる**

出力のテスト数が **136 + 4 = 140** 以上であること。減っていたら memberwise init の既定引数が効いていない。

- [ ] **Step 6: コミット**

```bash
git add Sources/SessionEventStore.swift Tests/SessionImageTests.swift
git commit -m "$(cat <<'MSG'
Decode an event's image dimensions, tolerantly

- New optional `SessionEventImage` on the record
- Only that field uses `try?`, so one bad value cannot drop a page

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 7: 電話の画像行と原寸表示

行にサムネイル、タップで原寸。これで機能が繋がる。

**Files:**
- Create: `Sources/SessionImageLoader.swift`
- Modify: `Sources/SessionConversationView.swift`（`SessionEventBlock` の `case .tool`、551-566 行）
- Modify: `Tests/SessionImageTests.swift`

**Interfaces:**
- Consumes: Task 6 の `SessionEventRecord.image`、既存の `RosterClient` の `baseURL` / `secret` の取り回し
- Produces:
  - `SessionImageLoader.url(base:machine:session:event:variant:) -> URL?`
  - `@MainActor final class SessionImageLoader` —— `static let shared`、`func data(at url: URL, secret: String) async -> Data?`

- [ ] **Step 1: 失敗するテストを書く**

URL の組み立ては純関数なので pin できる。ネットワークとキャッシュは pin しない。

```swift
struct SessionImageURLTests {
    private let base = URL(string: "https://relay.example")!

    @Test("The variant URL carries every id the relay needs")
    func buildsTheURL() throws {
        let url = try #require(SessionImageLoader.url(
            base: base, machine: "M1", session: "s1", event: "e1", variant: "thumb"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let pairs = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(url.path == "/image")
        #expect(pairs["machine"] == "M1")
        #expect(pairs["session"] == "s1")
        #expect(pairs["event"] == "e1")
        #expect(pairs["variant"] == "thumb")
    }

    // machine id は IOPlatformUUID で、セッション id は UUID。どちらも
    // 今は安全な文字だけだが、エスケープを外すとクエリが壊れる形で
    // 静かに 400 になる。
    @Test("Ids are percent-escaped")
    func escapesIds() throws {
        let url = try #require(SessionImageLoader.url(
            base: base, machine: "a b&c", session: "s1", event: "e1", variant: "full"))
        #expect(!url.absoluteString.contains("a b"))
        #expect(url.absoluteString.contains("a%20b") || url.absoluteString.contains("a+b"))
    }
}
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: Task 6 の xcodebuild test
Expected: コンパイルエラー。`SessionImageLoader` が存在しない。

- [ ] **Step 3: ローダを実装する**

`Sources/SessionImageLoader.swift` を作る。

```swift
import Foundation

/// R2 に置かれた画像を取ってくる。
///
/// **`AsyncImage` を使えない理由**: relay は Bearer secret を要求し、
/// `AsyncImage` はヘッダを付けられない。だから最小のローダを 1 つ持つ。
///
/// **キャッシュはメモリだけ。** ディスク永続化を作らないのは、
/// `SessionEventStore` 自体が durable store ではなく、オフラインで見えるのは
/// `HistoryStore` の通知（元から画像が無い）だけだから。`URLCache` も別に
/// 効く —— relay は `Cache-Control: immutable` を返す。
@MainActor
final class SessionImageLoader {
    static let shared = SessionImageLoader()

    /// 100 枚ぶん。サムネイルが 1 枚 20KB 程度なので約 2MB。原寸も同じ
    /// キャッシュに入るが、`totalCostLimit` がバイトで抑える。
    private let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// 同じ URL に同時に来た要求を 1 本にまとめる。会話をスクロールすると
    /// 同じ行が何度も現れる。
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    static func url(base: URL, machine: String, session: String,
                    event: String, variant: String) -> URL? {
        guard var components = URLComponents(url: base.appendingPathComponent("image"),
                                             resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [
            URLQueryItem(name: "machine", value: machine),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "event", value: event),
            URLQueryItem(name: "variant", value: variant),
        ]
        return components.url
    }

    func data(at url: URL, secret: String) async -> Data? {
        if let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        if let running = inFlight[url] { return await running.value }
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty
            else { return nil }
            return data
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        if let data { cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count) }
        return data
    }
}
```

- [ ] **Step 4: 行にサムネイルを足す**

`Sources/SessionConversationView.swift`。**`SessionConversationView` は既に `machine: String` を持っている**（77 行）。足りないのは 2 つだけ。

```swift
struct SessionConversationView: View {
    let machine: String
    /// 画像の取得先。**demo モードでは nil** —— `CanopyMobileApp.baseURL` が
    /// そこで nil を返すので、fixture が生の relay と間違われることがない。
    /// nil のときはサムネイルを描かない。
    let base: URL?
    let secret: String
```

呼び出し側は `Sources/CanopyMobileApp.swift` の `conversation(_:)`（622 行）。`machine: target.machine` の隣に足す。

```swift
        return SessionConversationView(
            machine: target.machine,
            base: baseURL,
            secret: secret,
```

`baseURL` は同ファイルの `private var baseURL: URL?`（79 行）、`secret` は `@State private var secret: String`（59 行）。どちらも既にある。

`SessionEventBlock(event: event)`（232 行）に 3 つ渡す。

```swift
                                SessionEventBlock(event: event, machine: machine,
                                                  base: base, secret: secret)
```

`SessionEventBlock` にも同じ 3 つを `let` で足す。

`case .tool` を差し替える。

```swift
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(event.text)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
                // 画像を持つ行だけがここに来る。持たない行の見た目は
                // 1 ピクセルも変わらない。
                // `base` が nil = demo モード。fixture に画像は無いし、
                // 取りに行く先も無い。
                if let image = event.image, let base {
                    SessionImageThumbnail(event: event, image: image,
                                          machine: machine, base: base, secret: secret)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
```

`SessionImageThumbnail` を同ファイルの private view として足す。

```swift
/// 行に埋まるサムネイルと、タップで開く原寸。
///
/// **場所は絵より先に決まる。** `image.width` / `image.height` で縦横比を
/// 決めてから読み込むので、絵が届いた瞬間に行の高さが飛ばない。
private struct SessionImageThumbnail: View {
    let event: SessionEventRecord
    let image: SessionEventImage
    let machine: String
    let base: URL
    let secret: String

    @State private var thumbnail: Data?
    @State private var failed = false
    @State private var showingFull = false

    private var aspect: CGFloat {
        guard image.width > 0, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    var body: some View {
        Group {
            if let thumbnail, let ui = UIImage(data: thumbnail) {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(aspect, contentMode: .fit)
            } else if failed {
                // 期限切れ（7 日）と一度も上がらなかったものを区別しない。
                // 電話に出せる言葉は同じ。
                Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
                    .aspectRatio(aspect, contentMode: .fit)
            }
        }
        .frame(maxWidth: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { if thumbnail != nil { showingFull = true } }
        .task {
            guard thumbnail == nil, !failed,
                  let url = SessionImageLoader.url(base: base, machine: machine,
                                                   session: event.sessionId,
                                                   event: event.eventId, variant: "thumb")
            else { return }
            if let data = await SessionImageLoader.shared.data(at: url, secret: secret) {
                thumbnail = data
            } else {
                failed = true
            }
        }
        .fullScreenCover(isPresented: $showingFull) {
            SessionImageFullScreen(event: event, image: image, machine: machine,
                                   base: base, secret: secret,
                                   placeholder: thumbnail)
        }
    }
}

/// 原寸。**サムネイルを下に敷いてから原寸を読む** —— 435KB の取得中に
/// 灰色を見せるより、ぼやけた絵から始まって差し替わるほうがよい。
private struct SessionImageFullScreen: View {
    let event: SessionEventRecord
    let image: SessionEventImage
    let machine: String
    let base: URL
    let secret: String
    let placeholder: Data?

    @Environment(\.dismiss) private var dismiss
    @State private var full: Data?
    @State private var failed = false

    private var shown: Data? { full ?? placeholder }

    var body: some View {
        NavigationStack {
            Group {
                if let shown, let ui = UIImage(data: shown) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: ui)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                } else if failed {
                    Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(event.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard full == nil,
                  let url = SessionImageLoader.url(base: base, machine: machine,
                                                   session: event.sessionId,
                                                   event: event.eventId, variant: "full")
            else { return }
            if let data = await SessionImageLoader.shared.data(at: url, secret: secret) {
                full = data
            } else if placeholder == nil {
                failed = true
            }
        }
    }
}
```

- [ ] **Step 5: テストが通ることを確かめる**

Run: Task 6 の xcodebuild test
Expected: PASS。新しい 2 件を含む。

- [ ] **Step 6: 実機で見る**

`.xcodeproj` は gitignore された生成物なので、**必ず先に `xcodegen generate`**。

```bash
cd ~/repos/Personal/Canopy-Mobile && xcodegen generate && \
  grep -c "Assets.xcassets" CanopyMobile.xcodeproj/project.pbxproj
```
Expected: `4`。0 なら生成に失敗している。

```bash
xcodebuild -project CanopyMobile.xcodeproj -scheme CanopyMobile -configuration Debug \
  -destination 'platform=iOS,id=88CF0177-6AA8-5D02-926C-27E21B989A53' \
  -derivedDataPath build-device -allowProvisioningUpdates build && \
xcrun devicectl device install app --device 88CF0177-6AA8-5D02-926C-27E21B989A53 \
  build-device/Build/Products/Debug-iphoneos/CanopyMobile.app
```

Mac 側で画像を Read させ、会話画面にサムネイルが出てタップで原寸が出ることを見る。

**戻るときは通知タップを使わない** —— App スイッチャーかホーム画面のアイコンから。通知タップは会話画面を積み直して `onAppear` を発火させる。

ログは `print` ではなく `NSLog` でしか読めない。

- [ ] **Step 7: コミット**

```bash
git add Sources/SessionImageLoader.swift Sources/SessionConversationView.swift Tests/SessionImageTests.swift
git commit -m "$(cat <<'MSG'
Draw a Read image in its tool row, full size on tap

- A small authenticated loader, because AsyncImage cannot set headers
- Aspect ratio comes from the event, so the row does not jump
- The full-screen view shows the thumbnail while the original loads

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 8: 保持規則、基準値、ドキュメント

R2 のライフサイクル、テスト数の床、AGENTS.md。

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `AGENTS.md`（Canopy-Mobile）
- Modify: `AGENTS.md`（Canopy）
- Modify: `docs/session-images.md`

- [ ] **Step 1: 7 日のライフサイクル規則を入れる**

```bash
cd worker && npx wrangler r2 bucket lifecycle --help
```

出力を読んで、`canopy-mobile-images` に 7 日で失効する規則を足す。`add` サブコマンドのフラグ名は wrangler のバージョンで変わるので、**help の出力に合わせる**。実行した正確なコマンドを `docs/session-images.md` の「コストと保持」節に書き足す。

規則が入ったことを確かめる。

```bash
cd worker && npx wrangler r2 bucket lifecycle list canopy-mobile-images
```

- [ ] **Step 2: テスト数を測る**

```bash
cd worker && npx vitest run 2>&1 | grep -E "Tests +[0-9]+ passed"
cd ~/repos/Personal/Canopy-Mobile && xcodebuild test -project CanopyMobile.xcodeproj \
  -scheme CanopyMobile -destination "platform=iOS Simulator,id=<udid>" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "Test Suite .* passed|Executed [0-9]+ test"
```

- [ ] **Step 3: 床を上げる**

`.github/workflows/ci.yml` の `EXPECTED_TESTS`（118 から）と `EXPECTED_SWIFT_TESTS`（136 から）を **測った数** に書き換える。

**推測で書かない。** 並行 PR がある場合の解決は足し算（AGENTS.md の「並行 PR と worktree」）。

- [ ] **Step 4: Canopy-Mobile の AGENTS.md を直す**

`## 検証で使える基準値` のテーブルを測った数に更新し、`## データの意味論` に節を足す。

```markdown
### 画像はイベント行に乗らない —— R2 に居る

`Read` した画像の行は `kind: "tool"` のまま、`image` フィールド（`width` /
`height` / `bytes`）だけが増える。**バイトは R2** で、`GET /image?machine=&session=&event=&variant=full|thumb`。

**`kind` を増やさなかったのは互換のため。** 新しい `kind` なら古い電話が
`.other("image")` に落として「image: Read: shot.png」という行を描く。未知の
フィールドは Codable が黙って無視するので、古い電話はいつものレンチ行になる。

**relay は `image` の中身を見ない。** オブジェクトならそのまま `image` カラム
（TEXT、JSON 文字列）に入れてそのまま返す。`kind` を enum で弾かないのと同じ
向きの判断 —— Mac が先に出るので、ここで検証すると relay のデプロイが Canopy の
新機能の前提条件になる。

`image` カラムは後付けなので `ensureSchema` が `ALTER TABLE` する。存在判定は
`SELECT image FROM event LIMIT 0` の成否 —— `PRAGMA table_info` と
`sqlite_master` が DO の SQL で使えるかを測っていないため。定常状態は 0 行なので
wake のコストに乗らない。

**行は `tool_use` ではなく `tool_result` の時点で出る。** 画像は次のフレームに
来るので、1 行に絵を付けるには結果を待つしかない。代償は 2 つ —— 行が Read の
完了時に出ること、そして結果が来ないまま死んだ Read は行が消えること。

アップロードは **2 枚とも成功してから行を出す**。行が出た = バイトは在る、と
いう関係が、壊れたサムネイルの出ない唯一の根拠。失敗したら画像なしの素の行。

設計と実測は `docs/session-images.md`。
```

- [ ] **Step 5: Canopy の AGENTS.md を直す**

`SessionEvent.swift` の行に、allowlist と広げ方を足す。

```markdown
`imageToolAllowlist`（いまは `["Read"]`）と `imageExtensions` が画像を運んで
よい範囲を決める。**`toolLabel` の switch と同じ向き** —— 削除は常に安全、
追加だけが判断を要る。広げても電話側の変更は要らない（あちらは届いたものを
描くだけ）ので、**App Store のリリースを待たない**。もう 1 箇所は
`ImagePreviewScript` の `IMG_EXT`。設計は Canopy-Mobile の
`docs/session-images.md`。
```

- [ ] **Step 6: 両方のリポジトリで全テストを回す**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npx vitest run && npx tsc --noEmit
cd ~/repos/Personal/Canopy && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```
Expected: 全部 PASS、プローブは FAIL 0。

- [ ] **Step 7: relay の end-to-end チェック**

```bash
cd worker && npx wrangler deploy && cd .. && node scripts/relay-event-probe.mjs
```
Expected: 12 チェック全 PASS。

**後始末が要る** —— probe は `machine:PROBE-…` を KV に書く。

```bash
cd worker && npx wrangler kv key list --binding MACHINES --remote
cd worker && npx wrangler kv key delete --binding MACHINES --remote "machine:PROBE-<id>"
```

- [ ] **Step 8: コミット**

```bash
git add .github/workflows/ci.yml AGENTS.md docs/session-images.md
git commit -m "$(cat <<'MSG'
Record the image path's retention, floors, and semantics

- 7-day R2 lifecycle, with the command that set it
- Test floors raised to the measured counts
- Why the kind stayed `tool` and why the relay does not read the field

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

## リリース順

**worker → Canopy → 電話。** worker の `/image` が先でなければ Canopy はアップロード先を持たない。電話は最後 —— 画像フィールドを知らない電話は既存のレンチ行を描くので、Mac が先に出ていても壊れない。

Task 1 と Task 2 は独立なので順不同。Task 3 と Task 4 も独立。Task 5 は 3 と 4 の両方に依存する。Task 6 は 2 に依存し、Task 7 は 6 に依存する。

## この計画が pin しないもの

- **`RosterImageUploader.upload` の HTTP 経路。** ネットワークなのでプローブから叩けない。実機で 1 枚流す手順が Task 5 Step 6 にある
- **`SessionImageLoader` のキャッシュと同時要求の合流。** `@MainActor` の状態なので純関数に出せていない。壊れても症状は「同じ画像を何度も取る」で、正しさではなく通信量
- **サムネイルの見た目。** 320px / q65 は実測のバイト数で選んだ値で、画質の判断は実機で見るまでできない
