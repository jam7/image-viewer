# iOS/iPad 開発メモ

## 初回セットアップ

1. `ios/DeveloperSettings.xcconfig` を作成し `DEVELOPMENT_TEAM = <your team ID>` を記載（gitignore済み）
2. iPad の Developer Mode をオンにする
3. 証明書を信頼する（設定 > 一般 > VPN とデバイス管理）

## Wi-Fi デバッグ

Xcode > Devices and Simulators でネットワーク接続を有効化。

## project.pbxproj の管理

Xcode が頻繁に書き換えるため `--assume-unchanged` 設定済み。

```bash
# 正当にコミットしたい時:
git update-index --no-assume-unchanged ios/Runner.xcodeproj/project.pbxproj

# 再設定:
git update-index --assume-unchanged ios/Runner.xcodeproj/project.pbxproj
```
