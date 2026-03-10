# Raindrop.io API 調査報告書

**作成日**: 2026/03/09
**ステータス**: Draft

## 概要

### 調査の背景

raindrop_to_obsidian プロジェクトでは、Raindrop.io API を利用して日次のブックマークを取得し、Obsidian のデイリーノートに追記している。開発中に検索パラメータの形式で問題が発生し（MongoDB風の構造化クエリが動作しなかった）、API仕様の正確な理解が必要となった。今後のスクリプト保守・改善に備え、調査結果を記録する。

### 調査の目的

本プロジェクトで使用する Raindrop.io API のエンドポイント・認証方式・検索構文・データ構造・制限事項を整理し、参照ドキュメントとして残す。

### 調査範囲

- 本プロジェクトで使用中のエンドポイントと関連仕様
- 検索構文（特に日付フィルタリング）
- レートリミット・API制限事項
- ハイライトの取得方法

技術選定や代替APIとの比較は対象外とする。

## 調査内容

### 調査対象

- Raindrop.io REST API v1
- 公式ドキュメント (developer.raindrop.io)
- 検索構文ヘルプ (help.raindrop.io)

### 調査方法

- 公式APIドキュメントの精読
- 検索演算子ヘルプページの確認
- 実際のスクリプト実行による動作検証

## 調査結果

### 認証方式

Raindrop.io API は OAuth 2.0 を採用している。

| 項目 | 内容 |
|---|---|
| ヘッダー形式 | `Authorization: Bearer {access_token}` |
| トークン有効期限 | 約2週間（1,209,599秒） |
| テストトークン | app.raindrop.io の開発者設定から取得可能。**有効期限なし** |
| リフレッシュ | `POST https://raindrop.io/oauth/access_token` に `grant_type=refresh_token` で更新 |

本プロジェクトではテストトークン（有効期限なし）を使用している。

### 使用中のエンドポイント

#### GET /rest/v1/raindrops/{collectionId}（複数ブックマーク取得）

本スクリプトの `fetch_bookmarks` メソッドで使用。

| パラメータ | 型 | 説明 |
|---|---|---|
| `collectionId` (パス) | number | コレクションID。`0` で全ブックマーク（Trash除く） |
| `search` | string | テキスト形式の検索クエリ |
| `perpage` | number | 1ページあたりの件数（最大50） |
| `page` | number | ページ番号（0始まり） |
| `sort` | string | ソート順。デフォルトは `-created`（作成日降順） |
| `nested` | boolean | サブコレクションのブックマークも含めるか |

**注意:** `search` パラメータはテキスト形式の検索演算子を受け付ける。MongoDB風の構造化クエリ（`$gte`, `$lt` など）は動作しない。

#### GET /rest/v1/raindrop/{id}（単一ブックマーク取得）

本スクリプトの `fetch_highlights` メソッドで、個別ブックマークのハイライトを取得するために使用。

| パラメータ | 型 | 説明 |
|---|---|---|
| `id` (パス) | number | raindropのID |

レスポンスの `item.highlights` 配列からハイライトを取得できる。

### 検索構文

`search` パラメータは Raindrop アプリ内の検索バーと同じテキスト演算子を使用する。

#### 日付関連（本プロジェクトで使用）

| 構文 | 説明 | 例 |
|---|---|---|
| `created:YYYY-MM-DD` | 作成日指定 | `created:2026-03-08` |
| `created:YYYY-MM` | 作成月指定 | `created:2026-03` |
| `created:YYYY` | 作成年指定 | `created:2026` |
| `created:>YYYY-MM-DD` | 指定日以降 | `created:>2026-01-01` |
| `created:<YYYY-MM-DD` | 指定日以前 | `created:<2026-06-01` |
| `lastUpdate:YYYY-MM-DD` | 更新日指定 | `lastUpdate:2026-03-01` |

#### その他の演算子（参考）

| 構文 | 説明 |
|---|---|
| `word` | 単語検索 |
| `"phrase"` | フレーズ完全一致 |
| `-word` | 除外 |
| `#tag` | タグ検索 |
| `match:OR` | OR検索（デフォルトはAND） |
| `title:word` | タイトル検索 |
| `excerpt:word` | 説明文検索 |
| `note:word` | ノート検索 |
| `link:word` | URL検索 |
| `type:value` | タイプ指定（link, article, image, video, document, audio） |
| `notag:true` | タグなしのもの |

### レスポンスのデータ構造（raindropオブジェクト）

本プロジェクトで使用しているフィールドを中心に記載する。

#### 使用中のフィールド

| フィールド | 型 | スクリプトでの用途 |
|---|---|---|
| `_id` | number | ハイライト取得のためのID |
| `title` | string | ブックマークのタイトル表示 |
| `link` | string | URL表示 |
| `excerpt` | string | LLM要約のコンテキスト |
| `note` | string | ユーザーメモの表示・LLM要約のコンテキスト |
| `tags` | array of string | タグ表示 |
| `collection` | object | `collection.title` でコレクション名を表示 |

#### その他のフィールド（参考）

| フィールド | 型 | 説明 |
|---|---|---|
| `cover` | string | カバー画像URL |
| `type` | string | コンテンツタイプ |
| `important` | boolean | お気に入りフラグ |
| `created` | string | 作成日時（ISO 8601） |
| `lastUpdate` | string | 更新日時（ISO 8601） |
| `domain` | string | ドメイン名 |
| `media` | array | 関連メディア |

### ハイライト

raindropオブジェクトの `highlights` 配列に含まれる。

| フィールド | 型 | 説明 |
|---|---|---|
| `_id` | string | 一意識別子 |
| `text` | string | ハイライトされたテキスト |
| `note` | string | ハイライトへの注釈 |
| `color` | string | 色（yellow, blue, green など） |
| `created` | string | 作成日時 |

本スクリプトでは `text` フィールドのみを使用している。

#### 取得方法

1. **単一raindropから取得（本プロジェクトで使用）:** `GET /rest/v1/raindrop/{id}` のレスポンスに含まれる
2. **全ハイライト取得:** `GET /rest/v1/highlights`（perpage最大50、デフォルト25）
3. **コレクション内ハイライト取得:** `GET /rest/v1/highlights/{collectionId}`

### レートリミット

| 項目 | 内容 |
|---|---|
| 制限 | 認証ユーザーあたり **1分間に最大120リクエスト** |
| 超過時のレスポンス | HTTP 429 Too Many Requests |

レスポンスヘッダーで残りリクエスト数を確認できる。

| ヘッダー | 説明 |
|---|---|
| `X-RateLimit-Limit` | 1分間の最大リクエスト数 |
| `RateLimit-Remaining` | 残りリクエスト数 |
| `X-RateLimit-Reset` | リセット時刻（UTC epoch秒） |

## 分析・考察

### 主要な発見

1. **検索パラメータはテキスト形式のみ:** `search` パラメータは Raindrop アプリの検索バーと同じテキスト演算子を使う。MongoDB風の構造化クエリは受け付けない。当初のスクリプトが `$gte`/`$lt` を使用していたため空の結果が返っていた。

2. **ハイライト取得のAPI呼び出し効率:** 現在のスクリプトはブックマークごとに個別APIリクエスト（`GET /raindrop/{id}`）でハイライトを取得している。ブックマーク数が多い場合、`GET /highlights` エンドポイントを使えばリクエスト数を削減できる可能性がある。

3. **テストトークンに有効期限がない:** 本プロジェクトで使用しているテストトークンには有効期限がないため、cron実行でのトークン更新は不要。

### リスクと制約

- **レートリミット:** 1分120リクエストの制限がある。ブックマークN件に対し、一覧取得で `ceil(N/50)` 回 + ハイライト取得でN回のリクエストが発生する。1日あたりのブックマーク数が100件を超える場合はレートリミットに注意が必要。
- **ページネーション上限:** 1ページ最大50件。本スクリプトではループでページングしており対応済み。
- **検索の日付精度:** `created:YYYY-MM-DD` は日単位のフィルタリング。タイムゾーンの扱いはRaindrop側に依存しており、JSTとのずれが生じる可能性がある（現時点では問題は観測されていない）。

## 結論・推奨事項

### 結論

Raindrop.io API は本プロジェクトの要件を十分に満たしている。検索パラメータの形式（テキスト演算子）を正しく使用することで、日付指定でのブックマーク取得が安定して動作する。テストトークンの有効期限がないため、cron運用での認証切れの懸念もない。

### 推奨事項

1. **ハイライト取得の効率化を検討**
   - 理由: 現在はブックマークごとに個別APIリクエストを行っているため、件数が多い日はリクエスト数が増加する
   - 方法: `GET /rest/v1/highlights` エンドポイントで一括取得し、raindropRef で紐づける
   - 優先度: 低（現状の利用規模では問題なし）

2. **ハイライトの注釈（note）の活用を検討**
   - 理由: ハイライトオブジェクトには `note` フィールドがあるが、現在は `text` のみ使用している
   - 優先度: 低

## 参考資料

- [Raindrop.io API Documentation](https://developer.raindrop.io)
- [Multiple raindrops endpoint](https://developer.raindrop.io/v1/raindrops/multiple)
- [Single raindrop endpoint](https://developer.raindrop.io/v1/raindrops/single)
- [Highlights endpoint](https://developer.raindrop.io/v1/highlights)
- [Using Search (operators)](https://help.raindrop.io/using-search#operators)
