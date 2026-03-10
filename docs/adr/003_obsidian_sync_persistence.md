# ADR-003: obsidian-headless + systemd による同期永続化

## ステータス

承認済み

## 日付

2026-03-09

## コンテキスト

raindrop_to_obsidian スクリプトが生成したデイリーノートを、他のデバイス（PC、モバイル）からも参照できるようにするため、Obsidian Sync で Vault を同期する必要がある。Linux サーバー上で GUI なしに同期を継続的に実行する方法が必要である。

### 現状の問題点

- スクリプトが cron で自動生成したノートは、同期しなければ他デバイスから参照できない
- 手動で同期コマンドを実行する運用は忘れる

### 制約条件

- Linux サーバーで GUI なしに動作する必要がある
- 同期はスクリプト実行後に自動的に行われる必要がある
- Obsidian Sync のサブスクリプションを既に保有している

## 決定

obsidian-headless（`ob` CLI）を systemd ユーザーサービスとして常駐させ、`ob sync --continuous` で継続的に同期することを決定した。

### 実装方針

1. `npm install -g obsidian-headless` でインストールする
2. `ob login` / `ob sync-setup` で Vault をリンクする
3. systemd ユーザーサービスとして `ob sync --continuous` を常駐させる
4. `Restart=on-failure` でクラッシュ時の自動復旧を設定する
5. `Environment="PATH=..."` で nvm 版 Node.js が使われるよう PATH を明示する

## 結果

### ポジティブな影響

1. **完全自動の同期**
   - cron でノートが生成されると、obsidian-headless がファイル変更を検知して自動的に同期する

2. **GUI リソースが不要**
   - デスクトップアプリを常時起動する必要がない

3. **systemd による信頼性**
   - クラッシュ時の自動再起動、ログ管理、OS 起動時の自動開始が標準機能で実現できる

### ネガティブな影響・トレードオフ

1. **Node.js バージョン管理の注意が必要**
   - Node.js 22 以上が必須（WebSocket のグローバル対応が必要）。nvm でバージョンを変更した場合、systemd の設定も更新する必要がある
   - 対策: service ファイルに Node.js のフルパスと PATH を明示的に設定する

2. **オープンベータの不安定さ**
   - obsidian-headless は v0.0.6（オープンベータ）であり、stale lock 問題など未解決のイシューがある
   - 対策: Obsidian Sync 自体がバージョン履歴を保持しているため、データ損失のリスクは低い。定期的にアップデートを確認する

3. **デスクトップアプリとの併用不可**
   - 同一デバイスで Obsidian デスクトップの Sync と Headless Sync を同時に使用するとデータ競合が発生する
   - 対策: このサーバーでは Obsidian デスクトップを使用しない

## 代替案

### 案1: Obsidian デスクトップアプリの常時起動

**概要**: Linux デスクトップ環境で Obsidian アプリを常時起動し、内蔵の Sync 機能を利用する

**メリット**:
- 安定版の Sync 機能を使用できる
- 追加のセットアップが不要

**デメリット**:
- GUI リソース（X11/Wayland）が必要
- ヘッドレスサーバーでは利用できない
- デスクトップ環境でも不要なリソースを消費する

**却下理由**: サーバー環境では GUI が不要であり、同期のためだけにデスクトップアプリを起動するのは過剰

### 案2: 手動で `ob sync` を実行

**概要**: cron スクリプトの後に `ob sync` を1回実行するか、必要な時に手動実行する

**メリット**:
- 常駐プロセスが不要
- シンプルな構成

**デメリット**:
- 手動実行は忘れる
- cron 連携の場合、他デバイスからの変更を受信するタイミングが限定される

**却下理由**: 手動同期は忘れるため自動化の目的に反する。`--continuous` モードであれば双方向の変更をリアルタイムに同期できる

### 案3: Claude Cowork のスケジュール実行機能

**概要**: Claude Desktop の Cowork 機能で AI エージェントタスクとしてスケジュール実行する

**メリット**:
- AI エージェントによる柔軟なタスク自動化が可能
- 追加のスクリプトやサービス設定が不要になる可能性

**デメリット**:
- 現時点で Windows 11 ARM 環境に未対応
- Claude Desktop に依存する

**却下理由**: 開発環境（Windows 11 ARM）で未対応のため利用できない

## 参考資料

- [Obsidian Headless ヘルプ](https://help.obsidian.md/headless)
- [obsidian-headless npm パッケージ](https://www.npmjs.com/package/obsidian-headless)
- [docs/obsidian-sync-report.md](../obsidian-sync-report.md)
