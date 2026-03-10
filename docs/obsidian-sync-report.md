# Obsidian Sync / obsidian-headless 調査報告書

**作成日**: 2026/03/09
**ステータス**: Draft

## 概要

### 調査の背景

raindrop_to_obsidian プロジェクトでは、スクリプトが生成したデイリーノートを他デバイスに同期するために Obsidian Sync を利用している。GUI なしの Linux サーバーで同期を行うため、ヘッドレスクライアント `ob`（obsidian-headless）を systemd ユーザーサービスとして運用している。セットアップ時に Node.js バージョン不一致や WorkingDirectory の設定誤りで問題が発生したため、調査結果と運用知見を記録する。

### 調査の目的

- `ob` CLI の仕様・コマンド・要件を整理する
- systemd での運用に必要な設定と注意点を記録する
- 補足として Obsidian Sync サービス全般の情報を整理する

### 調査範囲

- `ob` CLI（obsidian-headless）のコマンド・オプション・要件（メイン）
- systemd ユーザーサービスでの運用知見
- Obsidian Sync の概要・料金・制限事項（補足）

## 調査内容

### 調査対象

- obsidian-headless v0.0.6（オープンベータ、2026年2月リリース）
- Obsidian Sync サービス

### 調査方法

- 公式ドキュメント・ヘルプの調査
- `ob` CLI のヘルプ出力確認
- npm パッケージ情報の確認
- 本プロジェクトでの実運用経験

## 調査結果

### ob CLI（obsidian-headless）

#### 概要

Obsidian Sync のヘッドレスクライアント。デスクトップアプリなしでコマンドラインから Vault を同期できる。CI/CD パイプライン、自動化ワークフロー、サーバーバックアップなどが主なユースケース。

**現在オープンベータ段階。**

#### インストール

```bash
npm install -g obsidian-headless
```

Obsidian Sync のアクティブなサブスクリプションが必要。

#### Node.js バージョン要件

**Node.js 22 以上が必須。** obsidian-headless は WebSocket をグローバルオブジェクトとして使用しており、Node.js 22 以降で WebSocket がネイティブ対応されている。Node.js 18 などの古いバージョンでは `ReferenceError: WebSocket is not defined` で起動に失敗する。

#### コマンド一覧

| コマンド | 説明 |
|---|---|
| `ob login` | アカウント認証（`--email`, `--password`, `--mfa` オプション） |
| `ob logout` | 認証情報のクリア |
| `ob sync-list-remote` | リモート Vault 一覧表示 |
| `ob sync-list-local` | ローカル設定済み Vault 一覧表示 |
| `ob sync-create-remote` | リモート Vault 新規作成 |
| `ob sync-setup` | ローカルとリモート Vault のリンク設定 |
| `ob sync-config` | 同期設定の変更 |
| `ob sync` | 1回限りの同期実行 |
| `ob sync --continuous` | 継続的同期モード（ファイル変更を監視） |
| `ob sync-status` | 現在の同期状態表示 |
| `ob sync-unlink` | Vault 切断と認証情報削除 |

#### ob sync のオプション

| オプション | 説明 |
|---|---|
| `--path <local-path>` | Vault のローカルパス。**省略時はカレントディレクトリを使用** |
| `--continuous` | 継続的同期モードで実行 |

#### ob sync-config のオプション

| オプション | 説明 |
|---|---|
| `--mode` | `bidirectional`（デフォルト）, `pull-only`, `mirror-remote` |
| `--conflict-strategy` | `merge` など |
| `--file-types` | 同期する添付ファイルの種類（image, audio, video, pdf, unsupported） |
| `--configs` | 設定カテゴリの同期指定 |
| `--excluded-folders` | 除外フォルダ |

#### ob sync-setup のオプション

| オプション | 説明 |
|---|---|
| `--vault <id-or-name>` | リモート Vault の ID または名前（必須） |
| `--path` | ローカルパス |
| `--password` | E2EE Vault のパスワード |
| `--device-name` | デバイス名 |
| `--config-dir` | 設定ディレクトリ（デフォルト: `.obsidian`） |

### systemd ユーザーサービスでの運用

#### 現在の設定

```ini
[Unit]
Description=Obsidian Headless Sync
After=network-online.target

[Service]
Type=simple
Environment="PATH=/home/yuichi/.nvm/versions/node/v24.13.0/bin:/usr/bin:/bin"
WorkingDirectory=%h/Documents/My Vault
ExecStart=/home/yuichi/.nvm/versions/node/v24.13.0/bin/ob sync --continuous
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

配置先: `~/.config/systemd/user/obsidian-sync.service`

#### 設定上の重要ポイント

1. **WorkingDirectory は Vault のパスにすること:** `ob sync` は `--path` を省略するとカレントディレクトリを Vault として扱う。`WorkingDirectory` の設定がそのまま同期対象の Vault パスになるため、正しい Vault パスを指定する必要がある。

2. **ExecStart には `ob` のフルパスを指定すること:** systemd ユーザーサービスはシェルプロファイル（`.bashrc` など）を読み込まないため、nvm でインストールした `ob` はパスが通らない。フルパスで指定する必要がある。

3. **Environment で PATH を設定すること:** `ob` 自体をフルパスで指定しても、`ob` の shebang（`#!/usr/bin/env node`）が node を探す際にシステムの古い Node.js（例: `/usr/bin/node` = v18）が使われてしまう。`Environment="PATH=..."` で nvm 版の Node.js が優先されるよう設定する。

#### 本プロジェクトで発生した問題と解決

| 問題 | 原因 | 解決策 |
|---|---|---|
| `status=203/EXEC` で起動失敗 | `ob` のパスが解決できなかった | ExecStart にフルパスを指定 |
| `WorkingDirectory` が存在しないパス | 初期設定で `%h/vaults/my-vault` になっていた | `%h/Documents/My Vault` に修正 |
| `ReferenceError: WebSocket is not defined` | shebang 経由でシステムの Node.js v18 が使われていた | `Environment="PATH=..."` で nvm 版 Node.js v24 を優先 |

#### 運用コマンド

```bash
# サービスの状態確認
systemctl --user status obsidian-sync

# 再起動
systemctl --user restart obsidian-sync

# ログ確認
journalctl --user -u obsidian-sync -n 30 --no-pager

# 設定変更後のリロード
systemctl --user daemon-reload
```

### 既知の制限事項・注意点

| 項目 | 内容 |
|---|---|
| オープンベータ | サービスはまだベータ段階。使用開始前にデータのバックアップが推奨される |
| デスクトップアプリとの併用禁止 | 同一デバイスで Obsidian デスクトップの Sync と Headless Sync を同時に使用するとデータ競合が発生する |
| Linux での birthtime 非対応 | ファイル作成日時（birthtime）の保存は Windows と macOS のみ。Linux では同期自体は正常だが birthtime は保持されない |
| stale .sync.lock 問題 | 強制終了後にロックファイルが残り、以降の同期がブロックされることがある（GitHub Issue #4、オープン） |
| Docker イメージ未提供 | 公式 Docker イメージは未提供（GitHub Issue #2、オープン） |
| JSON 出力モード未対応 | 自動化連携向けの JSON 出力はまだない（GitHub Issue #6、オープン） |

### Obsidian Sync 全般（補足）

#### サービス概要

Obsidian の公式クラウド同期サービス。複数デバイス間でノートをエンドツーエンド暗号化（AES-256）で同期する。オフラインファースト設計で、オフライン時の編集は再接続時に自動同期される。

#### 料金プラン

| | Standard | Plus |
|---|---|---|
| 年払い | $4/月 | $8/月 |
| 月払い | $5/月 | $10/月 |
| Vault 数 | 1 | 10 |
| ストレージ | 1 GB | 10 GB（最大 100 GB に拡張可） |
| 最大ファイルサイズ | 5 MB | 200 MB |
| バージョン履歴 | 1ヶ月 | 12ヶ月 |

#### 同期可能なコンテンツ

- Markdown ファイル
- 添付ファイル（画像、音声、動画、PDF）— 種類ごとにオン/オフ可能
- Vault 設定（選択的に同期可能）

## 分析・考察

### 主要な発見

1. **Node.js バージョンが運用上の最大の注意点:** obsidian-headless は Node.js 22 以上を前提としている。systemd 環境ではシェルプロファイルが読み込まれないため、nvm を使用している場合は PATH の明示的な設定が必須。ExecStart のフルパス指定だけでは不十分で、shebang 経由の node 解決まで考慮する必要がある。

2. **WorkingDirectory = Vault パス:** `ob sync` はカレントディレクトリを Vault として扱うため、systemd の `WorkingDirectory` ディレクティブが実質的に Vault の指定となる。パスにスペースを含む場合でも systemd は正しく処理する。

3. **オープンベータであること:** v0.0.6 の段階であり、stale lock 問題など未解決のイシューがある。`Restart=on-failure` で回復できる障害には対応しているが、ロックファイルが残った場合は手動対応が必要になる可能性がある。

### リスクと制約

- **ベータ段階のリスク:** 破壊的変更や予期しない動作の可能性がある。バックアップを維持することが重要。
- **nvm のバージョン変更時:** nvm で Node.js のバージョンを変更した場合、systemd の ExecStart と Environment のパスも更新する必要がある。
- **stale lock:** 強制終了後に `.sync.lock` が残る問題は未解決。発生した場合はロックファイルを手動削除する必要がある。

## 結論・推奨事項

### 結論

obsidian-headless は本プロジェクトの要件（GUI なし環境での Vault 同期）を満たしている。systemd ユーザーサービスとして運用する場合、Node.js バージョンと PATH の設定が最も重要な構成ポイントとなる。オープンベータではあるが、現在の利用では安定して動作している。

### 推奨事項

1. **nvm のバージョン更新時に systemd 設定も更新する**
   - 理由: ExecStart と Environment のパスが特定の Node.js バージョンにハードコードされている
   - 方法: `nvm install` 後に service ファイルのパスを更新し `daemon-reload` を実行

2. **stale lock 問題への対処手順を把握しておく**
   - 理由: GitHub Issue #4 として報告されているがまだ未解決
   - 方法: 同期が停止した場合は `.sync.lock` の存在を確認し、手動削除後にサービスを再起動

3. **ベータ版の更新を定期的に確認する**
   - 理由: 既知の問題の修正や破壊的変更が入る可能性がある
   - 方法: `npm update -g obsidian-headless` で更新

## 参考資料

- [Obsidian Sync](https://obsidian.md/sync)
- [Obsidian Sync ヘルプ](https://help.obsidian.md/obsidian-sync/obsidian-sync)
- [Obsidian Headless ヘルプ](https://help.obsidian.md/headless)
- [obsidian-headless npm パッケージ](https://www.npmjs.com/package/obsidian-headless)
- [obsidian-headless GitHub リポジトリ](https://github.com/obsidianmd/obsidian-headless)
