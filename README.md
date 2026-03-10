# raindrop_to_obsidian

前日の Raindrop.io ブックマークを取得し、Claude Haiku で要約して Obsidian のデイリーノートに追記するスクリプト。

## 機能

- Raindrop.io API から指定日のブックマークを取得
- 各ブックマークのハイライト・ノートも取得
- Claude Haiku で日本語要約を自動生成
- Obsidian デイリーノートに Markdown セクションとして追記
- テンプレートからのデイリーノート新規作成に対応
- 重複書き込み防止

## 必要な環境変数

| 変数名 | 説明 |
|---|---|
| `RAINDROP_TOKEN` | Raindrop.io API トークン |
| `ANTHROPIC_API_KEY` | Anthropic API キー |
| `OBSIDIAN_VAULT` | Obsidian Vault のパス（例: `~/Documents/My Vault`） |

## 使い方

```bash
# 前日分を取得（デフォルト）
ruby raindrop_to_obsidian.rb

# 日付を指定して取得
ruby raindrop_to_obsidian.rb 2026-03-08
```

## デイリーノートの構造

- パス: `Daily/YYYY/YYYY-MM-DD.md`
- テンプレート: `Templates/Daily.md`
- テンプレート内の `{{date}}`, `{{title}}`, `{{date:YYYY-MM-DD}}` を自動置換

## 出力例

```markdown
## 📚 Raindrop (2026-03-08)

### [記事タイトル](https://example.com)
_コレクション名_ #tag1 #tag2

LLMによる要約文がここに入ります。

**ノート:**
ユーザーがRaindropで記入したメモ

**ハイライト:**
> ハイライトしたテキスト

---
```

## cron 設定

`raindrop_to_obsidian_cron.sh` を使って毎朝自動実行:

```
3 7 * * * /home/yuichi/Documents/Projects/raindrop_to_obsidian/raindrop_to_obsidian_cron.sh >> ~/.local/log/raindrop_to_obsidian.log 2>&1
```

## ファイル構成

| ファイル | 説明 |
|---|---|
| `raindrop_to_obsidian.rb` | メインスクリプト |
| `raindrop_to_obsidian_cron.sh` | cron 用ラッパー（環境変数・rbenv 初期化） |
# raindrop_to_obsidian
