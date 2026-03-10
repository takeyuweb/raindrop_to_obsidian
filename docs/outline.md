# Raindrop.io のブックマークを Claude Haiku で自動要約し、Obsidian デイリーノートに記録する

リード文: 日々のブックマークを自動で要約・整理し、Obsidian のナレッジベースに蓄積するシステムを Ruby スクリプトと obsidian-headless で構築した。

## 背景
### ブックマークは溜まるが見返さない問題
### 目指す仕組み: Raindrop → LLM要約 → Obsidian → 同期

## システム全体の構成
### 処理の流れ
### 使用する技術とサービス
  - Raindrop.io API / Claude Haiku / Obsidian / obsidian-headless

## Raindrop.io API でブックマークを取得する
### API トークンの取得
### 日付指定でブックマークを検索する
  - search パラメータのテキスト演算子 created:YYYY-MM-DD
### ハイライト・ノートの取得

## Claude Haiku で要約を自動生成する
### Anthropic API の呼び出し
### プロンプト設計: 何を要約させるか

## Obsidian デイリーノートに書き込む
### デイリーノートのパス構造とテンプレート対応
### Markdown セクションの生成
### 重複書き込みの防止

## cron で毎日自動実行する
### 環境変数とラッパースクリプト
### crontab の設定

## obsidian-headless で同期を永続化する
### インストールとセットアップ
### systemd ユーザーサービスの設定
### ハマりポイント: Node.js バージョンと PATH の問題

## まとめ
### 運用してみて
### 今後の改善案

## 参考資料
