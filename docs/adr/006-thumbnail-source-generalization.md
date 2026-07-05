# 006: ギャラリーのサムネイル取得を ImageSourceProvider に一般化し、生成をソースへ集約

## Status

Accepted

## Context

サムネイルのバッチ取得エンジン `ThumbnailLoader` は SMB 専用に書かれており、
`final SmbSource source` に加え `SmbProxyServer` と動画専用処理 (`_loadVideoThumbnail`、
`SmbSource.resizeToThumbnail`) を直接持つ。一方 Pixiv ギャラリーは同等の機能を
インライン直列ループで劣化コピーしており、サムネイル取得が遅い (TODO の P1)。

Pixiv にも `ThumbnailLoader` の並列バッチ/キャッシュ/cancel/retry を使わせたいが、
上記の SMB 依存がそれを阻んでいる。とくに「動画サムネイルの生成」が SMB 固有の
概念として `ThumbnailLoader` に漏れている点が本質的な結合。

`fetchThumbnail` の契約は「縮小画像を返す。元データに埋め込みサムネイルがあれば使い、
無ければ生成する」であり、これはソースに依存しない。動画フレームのキャプチャは
「元データからサムネイルを生成する」一形態なので、本来ソースの責務である。

## Alternatives

### A. サムネイル生成をソース (`fetchThumbnail`) に集約する

- 動画キャプチャ (proxyServer + VideoThumbnailService + resize) を `SmbSource.fetchThumbnail`
  へ移す。`ThumbnailLoader` は `source.fetchThumbnail` を一律に呼ぶだけの汎用実行器になる。
- **Good**: `ThumbnailLoader` が動画/PDF/ZIP を一切知らない。Pixiv がそのまま再利用でき P1 解消。
- **Good**: `resizeToThumbnail` が SmbSource private になり interface から消える。
- **Cost**: 「再生前 cancel での接続/プレーヤ解放」を `ThumbnailLoader` からソースへ委譲する
  仕組み (既定 no-op の中断フック) が必要。

### B. `ThumbnailLoader` に動画処理を残し、strategy を注入する

- `VideoThumbnailCapturer` 相当を注入し (Pixiv は null)、`ThumbnailLoader` の動画分岐は温存。
- **Good**: cancel 周りの現状ロジックをほぼ触らずに済む。
- **Bad**: `ThumbnailLoader` が「動画」という概念を持ち続ける。汎用化が中途半端で、
  将来ソースが増える (DMM 等) たびに strategy 分岐が増えうる。

### C. `ThumbnailLoader` が必ず何かを返す (呼び側が不能判定して切り替え)

- notSupported を型付き結果にせず、取得不能ならフル画像等で代替して常にサムネイルを返す。
- **Bad**: サムネイルのはずが数 MB のフル画像を DL しかねず、目的に反する。
- **Bad**: 「未 DL PDF はビューアで開いてからサムネイル可能」といった状態遷移
  (retryUnsupported) の意味が失われる。

## Decision

**A を採用する。** サムネイル生成の責務をソースの `fetchThumbnail` に集約し、
`ThumbnailLoader` を `ImageSourceProvider` 一般の汎用実行器にする。

- `ThumbnailLoader.source`: `SmbSource` → `ImageSourceProvider`。
- 動画キャプチャと `resizeToThumbnail` は `SmbSource` 内部へ。proxyServer 等は SmbSource に注入。
- `ThumbnailNotSupportedException` は `ImageSourceProvider` の契約として interface 側へ移動。
  `ThumbnailLoader` は成功→`ThumbnailData` / notSupported→`ThumbnailFailed(notSupported)` /
  その他→`ThumbnailFailed(timeout)` にマップするだけ。**描画は呼び側の責務** (C を否定)。
- 中断は `ImageSourceProvider` に既定 no-op の中断フックを 1 つ足し、`cancel()` から委譲。
- 「重い取得は直列」の最適化は `ImageSource.metadata['isVideo']` (モデル層の汎用ヒント) を
  見て維持する。生成方法は知らないが、スケジューリングだけ行う。

命名は変えない (一般化するのは取得元であって、対象がサムネイルである事実は不変)。

## Consequences

- **Good**: Pixiv がサムネイルバッチを再利用でき P1 (直列→並列) が解消。
- **Good**: `ThumbnailLoader` がソース非依存になり、今後のソース追加が容易。
- **Good**: 「利用不能」が型付き結果として残り、呼び側が描画とリトライ方針を持てる。
- **Bad/リスク**: 動画キャプチャ移設は proxy セッションの寿命管理に触れ回帰リスクが高い。
  独立コミット + 実機 verify (生成・再生前 cancel・トークン無効化) で守る。
- **Note**: `isVideo` メタデータへの依存が `ThumbnailLoader` に残るが、これは SMB API では
  なくモデル層のヒントなので許容する。
- **Note (2026-07-05)**: 汎用化 (2a-2c) は実施済み。Pixiv による採用は bolt-on ではなく
  [仮想化ギャラリー設計](../virtualized_gallery/design.md) の中で行う (Pixiv の追記
  ページネーションが固定リスト前提の loader と食い違うため。`addItems` 追加で吸収予定)。
  当座の P1 は Pixiv 側ループの行単位並列化で解消済み。
