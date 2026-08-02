# Thumbnail Architecture

ギャラリーのサムネイルは**プル型**で供給する: タイルが描かれることが要求であり、
スケジューラがビューポートに近いものから応える。決定と理由は
[ADR 011](adr/011-thumbnail-pull-pipeline.md)、設計の詳細と不変条件は
[docs/thumbnails/design.md](thumbnails/design.md)。

## 構成

```
GalleryView のタイル (ThumbnailOf)
   │ (1) session.thumbnailFor(item)  … プールを引くだけ (純粋な読み取り)
   │     session.wantThumbnail(item) … 頼む。描かれること自体が要求
   ▼
ThumbnailPool (アプリで 1 つ・32MB 上限の LRU、CacheManager.thumbnails)
   │ 持っていれば即返す。無ければ ↓
   ▼
ThumbnailScheduler (場所ごとに 1 つ)     ── 同時 8、うち取得は 5、動画は直列
   │ 近い順のキュー                       ── フォルダは尋ねない
   ├─ L2 (thumb:<id>) にあれば読む
   └─ 無ければ provider.fetchThumbnail() → L2 に保存
        ├── SmbSource: EXIF 抽出 / リサイズ / ZIP の先頭画像 / PDF ページ 0
        ├── PixivSource: サムネイル URL を取得 (陳腐化時は取り直し)
        └── VideoThumbnailService: media_kit でフレームキャプチャ
   ▼
プールに入れる → その id を見ているタイルだけが再描画
```

**要求を作るのは 2 か所だけ**:

1. タイルが描かれたとき (`ThumbnailOf` → `thumbnailFor`)。距離 0
2. `GalleryView._wantThumbnails()` の帯 — 見えている行 + 前後 1 画面。距離 1。
   スクロール位置から計算し、先頭行が変わったときだけ更新する。帯から外れた
   **未着手の**要求は捨てる (また見えれば描画がまた要求する)

配布済みの帳簿もバッチ水位も持たない。**描かれる = 要求される**なので、
キャッシュを消しても次の描画で勝手に埋まり直す。

## ThumbnailPool

| | |
|---|---|
| 置き場 | `CacheManager.thumbnails` (アプリ全体で 1 つ) |
| 上限 | 32MB (バイト単位の LRU) + 2048 件 (失敗エントリ用) |
| 内容 | `ThumbnailData` / `ThumbnailFailed` — **失敗も答えとして保持**する。`notSupported` (確定) と `notYet` (材料が後で揃いうる) を区別し、後者は描画のたびに聞き直す |
| 通知 | id 単位 (`watch`/`unwatch`)。押し出しとクリアでも通知する |
| 寿命 | ビューやタブより長い。**離れても捨てない**のがプールの存在理由 |

サムネイルは L1 (`MemoryCache`、10 件、フル画像と共用) には**書かない**。
L1 がサムネイルに対して果たせなくなった役割をプールが引き継いでいる。

## ThumbnailScheduler

| メソッド | 用途 |
|---|---|
| `want(item, distance)` | 要求。プールに**確定した**答えがあれば何もしない。`notYet` なら聞き直す。フォルダは無視 |
| `keepOnly(pred)` | 帯から外れた未着手の要求を捨てる |
| `cancel()` | ビューが離れた。未着手を捨て、着手済みは完走させる |
| `pauseStills()` / `resumeStills()` | 動画再生中はキャプチャを止める |

- レーン: 同時 8 (`lanes`)、うち共有への取得は 5 (`fetchLanes`) まで
- 動画は画像が尽きてから 1 本ずつ (デコーダと接続を 1 本占有するため)
- キューの起動はマイクロタスクで 1 回にまとめる。帯 80 件で 80 回起動すると、
  1 回ごとにキュー全体を走査するので描画スレッドを食う

## 計測ログ

性能問題はこの 3 行に対して質問する。実際、2026-08-02 の調査はこれで
「思い込み 3 つ」を潰した。

```
wave: 30 wanted = 1520 held + 0 cached + 30 fetched + 0 failed + 0 dropped, 687ms
pool: 512 entries, 9.9MB
frame: build 69ms + raster 9ms          ← 32ms 超のフレームだけ
metadata: 10863 entries encoded in 127ms (1006KB)   ← 8ms 超の索引書き出しだけ
```

## Cache Key Convention

| プレフィックス | 用途 |
|---|---|
| `thumb:<id>` | サムネイル (長辺はタイルの実寸、PNG。ADR 012) |
| `full:<id>` | 表示用データ (画像/ZIP/PDF バイト) |

サムネイル取得時は `thumb:` キーのみ検索。`full:` は検索しない (PDF/ZIP は
`full:` にコンテナ本体が入るため)。

## VideoThumbnailService

media_kit の Player を再利用して動画サムネイルをキャプチャする。
`Completer<void>` ロックで直列化し、複数の capture が同時に来ても 1 つずつ処理する。

```
1. player.open(url, start: 3s)
2. position >= 2s を待つ (15s timeout)
3. 200ms delay (フレームバッファ安定待ち)
4. player.pause()
5. screenshot (最大5回リトライ, 200ms間隔)
6. player.stop()
7. JPEG bytes を返す
```

外部から dispose された場合 (動画再生開始時)、`_player == null` を検知して
info ログのみ出力する。

## SmbProxyServer

media_kit は SMB を直接読めないため、localhost HTTP プロキシで中継する。

```
media_kit → HTTP GET http://127.0.0.1:{port}/{token}
                ↓
         SmbProxyServer._handleRequest()
                ↓
         SmbSource.readRange() → SMB2 読み取り
```

- ランダムポート + ワンタイムトークンで認証
- Range Request 対応 (シーク可能)
- `invalidateToken()` で `cancelled = true` → ストリーミング中断
