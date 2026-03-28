# Viewer / Video Player Architecture

## Overview

フルスクリーンの画像ビューア（ViewerScreen）と動画プレーヤー（VideoPlayerScreen）。
画像ビューアは多ページ対応（Pixiv複数ページ、ZIP、PDF）でプリフェッチ・キャッシュを管理する。
動画プレーヤーは media_kit + SMB プロキシでストリーミング再生する。

## Class Structure

```
ViewerScreen (フルスクリーン画像ビューア)
    │
    ├─→ SourceRegistry.resolve(sourceKey)
    │       └─→ ImageSourceProvider (SmbSource / PixivSource)
    │               ├── resolvePages()  ── 作品をページに展開
    │               ├── fetchFullImage() ── フル画像取得（進捗コールバック付き）
    │               └── openReadStream() ── 大容量DL用ストリーム
    │
    ├─→ CacheManager (L1 → L2 → L3 → ネットワーク)
    │       ├── get(key)          ── 3層フォールバック検索
    │       ├── fetchAndCache()   ── DL＋キャッシュ保存
    │       └── l3.toggle()       ── ダウンロード管理
    │
    └─→ FavoritesStore ── お気に入りトグル（Pixiv はブックマーク API も呼ぶ）


VideoPlayerScreen (動画プレーヤー)
    │
    ├─→ SmbProxyServer.registerSession()
    │       └─→ http://127.0.0.1:{port}/{token}
    │
    └─→ media_kit
            ├── Player       ── 再生制御
            ├── VideoController ── Flutter ブリッジ
            └── Video widget ── レンダリング
```

## ViewerScreen

### Page Resolution

作品（ImageSource）をページに展開する。作品の種類によって展開結果が異なる。

| 作品種別 | resolvePages() の結果 |
|---|---|
| 単一画像 | `[image]`（1ページ） |
| Pixiv 複数ページ | `[page0, page1, ...]`（各ページの高解像度URL） |
| ZIP | `[entry0, entry1, ...]`（画像エントリのみ、自然順ソート） |
| PDF | `[page0, page1, ...]`（各ページの metadata に pageIndex） |

### Preload Strategy (Sliding Window)

```
[破棄][ N-1 ][ 現在 ][ N+1 ][ N+2 ][ N+3 ][ N+4 ][未取得]
                ↑表示中
     ← 後方1枚 →         ← 前方4枚 →
```

- ロード順: 現在ページ → 前方 → 後方（表示ページを最優先）
- 前方枚数: 画像/ZIP は 4枚、PDF は 2枚（PDFium レンダリングが遅いため）
- 後方: 1枚をキャッシュ保持
- ±5 ページを超えた画像はメモリから破棄（OOM 防止）

### Image Load Flow

```
_loadFullImage(page)
    │
    ├── cacheManager.get("full:{page.id}")
    │       L1 hit → 即表示
    │       L2 hit → L1 に昇格 → 表示
    │       L3 hit → L1 に昇格 → 表示
    │
    └── cache miss
            └── provider.fetchFullImage(page, onProgress)
                    → DL 中は進捗リング + KB 表示
                    → 完了 → L1 + L2 に保存 → 表示
```

### Download (L3)

作品単位でトグル。種別によって保存方法が異なる。

| 作品種別 | L3 保存内容 |
|---|---|
| 単一画像 | `full:<work id>` に画像バイト |
| ZIP | `full:<work id>` に ZIP バイト全体（ストリームで保存） |
| PDF | `full:<work id>` に PDF バイト全体（L2 から読み出し） |
| 複数ページ | 各ページを `full:<page id>` で個別保存 + `full:<work id>` に空マーカー |

### Navigation

| 入力 | 動作 |
|---|---|
| ↑ / Space | 次ページ（最後のページなら次の作品） |
| ↓ | 前ページ（最初のページなら前の作品） |
| PageDown / PageUp | 10ページ飛ばし |
| Home / End | 先頭ページ / 末尾ページ |
| ← → | 作品送り |
| マウスホイール | ページ送り（端で作品送り） |
| Ctrl + ホイール | ズーム（0.5x〜8.0x） |
| ESC / マウスバック | 一覧に戻る |
| 上下スワイプ (>300 px/s) | ページ送り |
| 左右スワイプ (>500 px/s) | 作品送り |

### Page Sidebar

右端に常時薄いインジケーター（4px）。ホバーで拡大（40px）してページ番号表示。ドラッグで任意ページにジャンプ。

```
通常:   |     (4px, 不透明度 0.3)
ホバー: |███| (40px, ページ番号表示, ドラッグ可能)
```

インジケーター位置は `pageIndex / totalPages` に比例。

## VideoPlayerScreen

### Playback Flow

```
_startPlayback()
    │
    ├── proxyServer.registerSession(source, filePath)
    │       → ファイルサイズ取得 + トークン生成
    │       → http://127.0.0.1:{port}/{token}
    │
    └── _player.open(Media(url))
            → media_kit が HTTP GET → プロキシが SMB を中継
            → Range Request 対応（シーク可能）
```

### Keyboard Controls

| キー | 動作 |
|---|---|
| Space | 再生 / 一時停止 |
| → | 10秒先送り |
| ← | 10秒巻き戻し |
| ESC | 戻る |

### Lifecycle

```
dispose()
    ├── proxyServer.invalidateToken(token)
    │       → プロキシストリーミング中断
    └── _player.dispose()
            → media_kit リソース解放
```

## ImageSourceProvider (Abstract Interface)

全ソース共通のインターフェース。

```dart
abstract class ImageSourceProvider {
  Future<List<ImageSource>> listImages({String? path});
  Future<Uint8List> fetchThumbnail(ImageSource source);
  Future<Uint8List> fetchFullImage(ImageSource source, {onProgress?});
  Future<(Stream<Uint8List>, int, Function)> openReadStream(ImageSource source);
  Future<List<ImageSource>> resolvePages(ImageSource source);
  Future<void> dispose();
}
```

| メソッド | 用途 |
|---|---|
| `listImages` | ディレクトリ一覧 / フィード取得 |
| `fetchThumbnail` | サムネイル取得 |
| `fetchFullImage` | フル画像取得（進捗コールバック付き） |
| `openReadStream` | 大容量ファイルのストリームDL（L3保存用） |
| `resolvePages` | 作品 → ページ展開 |

### Implementations

| クラス | プロトコル | 特徴 |
|---|---|---|
| SmbSource | SMB 2.0/2.1 | Range Read、ZIP/PDF/動画対応 |
| PixivSource | Pixiv Web API | Cookie 認証、複数ページ展開、ブックマーク連携 |

## ImageSource (Data Model)

```dart
class ImageSource {
  String id;           // "smb:123:path/file.jpg"
  String name;         // "file.jpg"
  String uri;          // ファイルパス or URL
  ImageSourceType type; // smb, pixiv, http, ...
  String? sourceKey;   // "smb:1234567890" → SourceRegistry で Provider を解決
  Map<String, dynamic>? metadata;
}
```

### metadata の主なフラグ

| キー | 型 | セット元 | 用途 |
|---|---|---|---|
| `isDirectory` | bool | SmbSource | ディレクトリ表示 |
| `isVideo` | bool | SmbSource | 動画判定 |
| `isZip` | bool | SmbSource | ZIP アーカイブ |
| `isPdf` | bool | SmbSource | PDF ファイル |
| `isZipEntry` | bool | SmbSource | ZIP 内のエントリ（viewer 用） |
| `isPdfPage` | bool | SmbSource | PDF レンダリング済みページ |
| `unsupported` | bool | SmbSource | 表示不可（ZIP in ZIP 等） |
| `illustId` | int | PixivSource | Pixiv 作品 ID |
| `author` | String | PixivSource | 作者名 |
| `path` | String | SmbSource | SMB ファイルパス |

## CacheManager (3-Layer)

```
┌─────────────────────────────────────────────────┐
│  get(key) の探索順                                │
│                                                   │
│  L1: MemoryCache  → L2: DiskCache → L3: DownloadStore → Network │
│  (メモリ, ~10枚)    (ディスク, LRU)   (DL永久保存)      (fetch)  │
│                                                   │
│  L2/L3 ヒット時は L1 に昇格                         │
└─────────────────────────────────────────────────┘
```

| 層 | 保存先 | 排出 | 用途 |
|---|---|---|---|
| L1 | メモリ | LRU 自動（~10枚） | 現在表示中 + 近傍ページ |
| L2 | ディスク | LRU 自動（500MB〜5GB） | セッション中のキャッシュ |
| L3 | ディスク | 手動トグル | ユーザーが明示的にDLした作品 |

### Key Convention

| プレフィックス | 用途 |
|---|---|
| `thumb:<id>` | サムネイル（長辺 600px PNG） |
| `full:<id>` | 表示用データ（画像/ZIP/PDF バイト） |

## SmbSource: PDF / ZIP の処理

### PDF

```
resolvePages()
    → L2 にキャッシュなければ SMB から全DL → L2 保存
    → PdfDocument.openFile(path) で開く（メモリに全体を載せない）
    → 各ページを ImageSource として返す

fetchFullImage(pdfPage)
    → _openPdfCached(filePath) で PdfDocument を再利用
    → page.render() → PNG エンコード
    → レンダリング速度: ~500ms/ページ
```

PdfDocument はキャッシュして同一 PDF のページめくりを高速化。

### ZIP

```
resolvePages()
    → ZipReader でセントラルディレクトリ解析（Range Read、全体DL不要）
    → 画像エントリを自然順ソートで列挙

fetchFullImage(zipEntry)
    → ZipReader.readEntry() で個別エントリを Range Read + 展開
    → L2 にキャッシュ
```

ZipReader は Future キャッシュで重複パースを防止。
