# アプリアイコン

紺〜藍のグラデーションの上に、クリームとコーラルの布のキャノピー。画像生成でつくったものを、そのままネイティブのアセットに落としている。

元画は Canopy 本家の `images/appiconbase.png` が正。この repo が持つ 1024 PNG はそのバイト単位のコピーで、変形は一切かけていない。

## iOS

`Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` — 不透明な 1024×1024 の 1 枚だけ。角丸は iOS がマスクするので焼き込まない。アルファチャンネルを持つアイコンは App Store が弾く。

`project.yml` 側は 3 つ。`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`、`INFOPLIST_KEY_CFBundleDisplayName: Canopy`、そして `INFOPLIST_FILE: ""`。

**3 つめが無いと 1 つめも 2 つめも効かない。** xcodegen はターゲットの source path 配下を走査して `Info.plist` を見つけると `INFOPLIST_FILE` に設定する。`excludes` はこの走査を止めない。放っておくとアプリ本体に通知拡張の Info.plist が刺さり、`GENERATE_INFOPLIST_FILE` が生むキーが丸ごと消える —— `CFBundleIcons` も表示名も。空文字を明示して初めて生成 plist に戻る。

症状は「ビルドは通る、`CompileAssetCatalog` も走る、なのにバンドルに `Assets.car` が無い」。アプリの `Info.plist` に `NSExtension` が入っていたらこれ。

## macOS

Canopy 本家が同じ元画を使う。あちらで `/usr/bin/python3 scripts/generate_icon.py` を走らせるとアイコンカタログができる。構図はそのままに、macOS 用の squircle と余白を足して 1x / 2x を書く。`images/appicon.png` は README のプレビュー。

**iOS と macOS で加工が違う。** macOS は角丸と余白を画像に焼き込む慣習、iOS はしない。だから同じ元画から別々に生成する。片方の成果物をもう片方に流用しない。

## Contents.json

iOS の単一サイズは `"idiom": "universal"` + `"platform": "ios"` + `"size": "1024x1024"`。`scale` は書かない。`size` を落とすと actool は黙って何も出さず、ビルドは成功したままアイコンだけ消える。
