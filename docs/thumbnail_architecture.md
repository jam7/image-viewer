# Thumbnail Architecture

## Overview

ギャラリー画面のサムネイル表示は、バッチ読み込み・キャンセル・リトライを `ThumbnailLoader` に集約し、画面側は結果の受け取りと表示のみを担当する。

## Class Structure

```
SmbGalleryScreen (UI)
    │
    └─→ ThumbnailLoader (バッチ制御、キャンセル、リトライ)
            ├─→ SmbSource.fetchThumbnail() ── 画像サムネイル取得
            │       ├── JPEG: EXIF サムネイル抽出 → リサイズ
            │       ├── PNG/GIF/WebP/BMP: フルDL → リサイズ
            │       ├── ZIP: 最初の画像を Range Read → リサイズ
            │       └── PDF: ページ0をレンダリング（キャッシュ必須）
            │
            ├─→ VideoThumbnailService.capture() ── 動画サムネイル取得
            │       └── Player + VideoController (media_kit)
            │              ↓
            │       SmbProxyServer (SMB → localhost HTTP ブリッジ)
            │
            ├─→ SmbSource.resizeToThumbnail() ── 長辺600px, 400KB以下ならスキップ
            │
            └─→ CacheManager (L1/L2 に保存)
                    ├── L1: MemoryCache (デコード済み、即表示)
                    └── L2: DiskCache (PNG、永続化)
```

## ThumbnailLoader

バッチ読み込みの状態管理を一手に引き受ける。画面側はフラグを一切持たない。

### API

| メソッド | 用途 |
|---|---|
| `setItems(items)` | 対象アイテム設定。全状態リセット |
| `loadNextBatch()` | 次のバッチを開始 |
| `cancel()` | 進行中バッチを中断（動画再生前に呼ぶ） |
| `retryInterrupted()` | 中断されたアイテムをリトライ |
| `retryUnsupported(predicate)` | notSupported のアイテムをリトライ |
| `needsBatch(itemIndex)` | build トリガー用：このアイテムは未ディスパッチか |
| `allDispatched` | 全アイテムがバッチに入ったか |
| `dispose()` | リソース解放 |

### Internal State

| フィールド | 役割 |
|---|---|
| `_items` | 対象アイテム一覧 |
| `_loadedCount` | ディスパッチ済み位置 |
| `_resultIds` | 結果を受け取ったアイテムの ID（重複防止） |
| `_generation` | キャンセル用カウンター。インクリメントでループが中断 |
| `_isLoading` | バッチ進行中フラグ。次バッチの多重起動を防止 |
| `_videoThumbService` | Player の再利用。cancel 時に dispose |

### Batch Processing

```
バッチ (30 items)
    │
    ├── 画像: 行単位で並列 (Future.wait, 5枚ずつ)
    │     帯域を有効活用。各行の完了を待ってから次の行へ
    │
    └── 動画: 末尾で1枚ずつ順次処理
          帯域を占有するため並列にしない
          cancel() で即中断可能（generation チェック）
```

### Result Callback

```dart
ThumbnailLoader(
  onResult: (id, result) {
    if (mounted) setState(() => _thumbnailData[id] = result);
  },
);
```

画面側は `_thumbnailData` マップだけ管理。結果は `ThumbnailResult` sealed class:
- `null` → ローディング中（スピナー表示）
- `ThumbnailData(bytes)` → 成功（画像表示）
- `ThumbnailFailed(notSupported)` → 未対応（ビューア表示後にリトライ可能）
- `ThumbnailFailed(timeout)` → エラー

## VideoThumbnailService

media_kit の Player を再利用して動画サムネイルをキャプチャする。

### Serialization

`Completer<void>` ロックで直列化。複数の capture 呼び出しが同時に来ても、1つずつ処理する（Player.open の並行実行を防止）。

### Capture Flow

```
1. player.open(url, start: 3s)
2. position >= 2s を待つ (15s timeout)
3. 200ms delay (フレームバッファ安定待ち)
4. player.pause()
5. screenshot (最大5回リトライ, 200ms間隔)
6. player.stop()
7. JPEG bytes を返す
```

外部から dispose された場合（動画再生開始時）、`_player == null` を検知して info ログのみ出力。

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
- Range Request 対応（シーク可能）
- `invalidateToken()` で `cancelled = true` → ストリーミング中断

## Batch Trigger (Build)

スクロールで新しいアイテムが見えた時にバッチを起動する仕組み。

```dart
// GridView.builder の itemBuilder 内
if (!isDir && _thumbLoader.needsBatch(itemIndex)) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _thumbLoader.loadNextBatch();
  });
}
```

`needsBatch` は `itemIndex >= _loadedCount && !_isLoading` を返す。

## Playback Interruption Flow

```
1. ユーザーが動画をタップ
2. _thumbLoader.cancel()
   → _generation++ でバッチループ中断
   → VideoThumbnailService dispose
3. VideoPlayerScreen に遷移
4. 戻る
5. _thumbLoader.retryUnsupported() → notSupported のリトライ
6. _thumbLoader.retryInterrupted() → 中断されたアイテムのリトライ
   → _isLoading = true（次バッチの起動をブロック）
   → リトライ完了 → _isLoading = false
   → build トリガーが必要に応じて次バッチを起動
```

## Cache Key Convention

| プレフィックス | 用途 |
|---|---|
| `thumb:<id>` | サムネイル（長辺 600px PNG） |
| `full:<id>` | 表示用データ（画像/ZIP/PDF バイト） |

サムネイル取得時は `thumb:` キーのみ検索。`full:` は検索しない（PDF/ZIP は `full:` にコンテナ本体が入るため）。
