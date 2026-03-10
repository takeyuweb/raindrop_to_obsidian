#!/usr/bin/env ruby
# raindrop_to_obsidian.rb
#
# 前日のRaindropブックマークを取得し、LLMで要約してObsidianのデイリーノートに追記する
#
# 必要な環境変数:
#   RAINDROP_TOKEN    - Raindrop.io API トークン
#   ANTHROPIC_API_KEY - Anthropic API キー
#   OBSIDIAN_VAULT    - Obsidian Vault のパス（例: ~/Documents/MyVault）
#
# デイリーノートのパス構造: Daily/YYYY/YYYY-MM-DD.md
# テンプレートパス:         Templates/Daily.md
#
# テンプレート内の以下のプレースホルダーを自動置換:
#   {{date}}             → YYYY-MM-DD
#   {{title}}            → YYYY-MM-DD
#   {{date:YYYY-MM-DD}}  → YYYY-MM-DD（Templater形式）

require 'net/http'
require 'json'
require 'date'
require 'fileutils'

# ── 設定 ────────────────────────────────────────────────
RAINDROP_TOKEN    = ENV.fetch('RAINDROP_TOKEN')
ANTHROPIC_API_KEY = ENV.fetch('ANTHROPIC_API_KEY')
VAULT_PATH        = File.expand_path(ENV.fetch('OBSIDIAN_VAULT'))
TEMPLATE_PATH     = File.join(VAULT_PATH, 'Templates', 'Daily.md')

JST_OFFSET = '+09:00'

# JST の「今日」を基準に前日を計算する
jst_now    = Time.now.getlocal(JST_OFFSET)
jst_today  = Date.new(jst_now.year, jst_now.month, jst_now.day)

TARGET_DATE = if ARGV[0]
                Date.parse(ARGV[0])
              else
                jst_today - 1
              end

# ── Raindrop API ─────────────────────────────────────────

def raindrop_get(path, params = {})
  uri = URI("https://api.raindrop.io/rest/v1#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{RAINDROP_TOKEN}"
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  JSON.parse(res.body)
end

def fetch_bookmarks(date)
  search = "created:#{date.strftime('%Y-%m-%d')}"

  items = []
  page  = 0

  loop do
    data = raindrop_get('/raindrops/0', search: search, perpage: 50, page: page)
    batch = data['items'] || []
    items.concat(batch)
    break if batch.size < 50
    page += 1
  end

  items
end

def fetch_highlights(raindrop_id)
  data = raindrop_get("/raindrop/#{raindrop_id}")
  data.dig('item', 'highlights') || []
end

# ── Anthropic API ─────────────────────────────────────────

def summarize_bookmark(item, highlights)
  title      = item['title'].to_s
  url        = item['link'].to_s
  excerpt    = item['excerpt'].to_s
  tags       = (item['tags'] || []).join(', ')
  collection = item.dig('collection', 'title').to_s
  hl_texts   = highlights.map { |h| h['text'] }.compact.join("\n")

  note       = item['note'].to_s

  context = <<~TEXT
    タイトル: #{title}
    URL: #{url}
    コレクション: #{collection}
    タグ: #{tags}
    抜粋: #{excerpt}
    ノート: #{note.empty? ? '（なし）' : note}
    ハイライト:
    #{hl_texts.empty? ? '（なし）' : hl_texts}
  TEXT

  prompt = <<~PROMPT
    以下のウェブページの情報をもとに、日本語で2〜3文の簡潔な要約を作成してください。
    要約は「何についてのページか」「なぜ重要か・何が学べるか」を含めてください。
    余計な前置きや説明は不要です。要約文のみ出力してください。

    #{context}
  PROMPT

  uri = URI('https://api.anthropic.com/v1/messages')
  req = Net::HTTP::Post.new(uri)
  req['Content-Type']      = 'application/json'
  req['x-api-key']         = ANTHROPIC_API_KEY
  req['anthropic-version'] = '2023-06-01'
  req.body = JSON.generate(
    model:      'claude-haiku-4-5-20251001',
    max_tokens: 300,
    messages:   [{ role: 'user', content: prompt }]
  )

  res  = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  data = JSON.parse(res.body)
  data.dig('content', 0, 'text')&.strip || '（要約取得失敗）'
end

# ── Markdown 生成 ─────────────────────────────────────────

def build_section(bookmarks)
  lines = []
  lines << "## 📚 Raindrop (#{TARGET_DATE.strftime('%Y-%m-%d')})"
  lines << ''

  bookmarks.each do |item|
    title      = item['title'] || item['link']
    url        = item['link']
    collection = item.dig('collection', 'title') || '未分類'
    tags       = (item['tags'] || []).map { |t| "##{t}" }.join(' ')

    # ハイライト取得
    highlights = fetch_highlights(item['_id'])

    # LLM要約
    print "  要約中: #{title[0..50]}... "
    summary = summarize_bookmark(item, highlights)
    puts '✓'

    lines << "### [#{title}](#{url})"
    lines << "_#{collection}_ #{tags}".strip
    lines << ''
    lines << summary
    lines << ''

    note = item['note'].to_s
    unless note.empty?
      lines << '**ノート:**'
      lines << note
      lines << ''
    end

    if highlights.any?
      lines << '**ハイライト:**'
      highlights.each { |h| lines << "> #{h['text']}" }
      lines << ''
    end

    lines << '---'
    lines << ''
  end

  lines.join("\n")
end

# ── テンプレート処理 ──────────────────────────────────────

def build_note_from_template(date)
  date_str = date.strftime('%Y-%m-%d')

  unless File.exist?(TEMPLATE_PATH)
    warn "⚠️  テンプレートが見つかりません: #{TEMPLATE_PATH}"
    warn "    フォールバック: シンプルなヘッダーで作成します"
    return "# #{date_str}\n"
  end

  content = File.read(TEMPLATE_PATH)

  # 一般的なプレースホルダーを置換
  content
    .gsub('{{date}}', date_str)
    .gsub('{{title}}', date_str)
    .gsub(/\{\{date:[-YMD]+\}\}/, date_str)           # {{date:YYYY-MM-DD}} 形式
    .gsub(/<%\s*tp\.date\.now\([^)]*\)\s*%>/, date_str) # Templater形式
end

# ── デイリーノート書き込み ──────────────────────────────────

def daily_note_path(date)
  year = date.strftime('%Y')
  file = "#{date.strftime('%Y-%m-%d')}.md"
  File.join(VAULT_PATH, 'Daily', year, file)
end

def write_daily_note(content)
  note_path = daily_note_path(TARGET_DATE)
  FileUtils.mkdir_p(File.dirname(note_path))

  if File.exist?(note_path)
    # 既存ノートに追記（重複チェック付き）
    existing = File.read(note_path)
    if existing.include?("## 📚 Raindrop (#{TARGET_DATE.strftime('%Y-%m-%d')})")
      puts "⚠️  すでに書き込み済みです: #{note_path}"
      return
    end
    File.open(note_path, 'a') { |f| f.puts "\n#{content}" }
    puts "✅ 追記しました: #{note_path}"
  else
    # テンプレートから新規作成
    note_body = build_note_from_template(TARGET_DATE)
    File.write(note_path, note_body + "\n" + content)
    puts "✅ テンプレートから新規作成しました: #{note_path}"
  end
end

# ── メイン ───────────────────────────────────────────────

puts "📅 対象日: #{TARGET_DATE}"
puts "🔍 ブックマーク取得中..."

bookmarks = fetch_bookmarks(TARGET_DATE)

if bookmarks.empty?
  puts "📭 #{TARGET_DATE} のブックマークはありません"
  exit 0
end

puts "📖 #{bookmarks.size}件取得 → 要約を生成中..."

section = build_section(bookmarks)
write_daily_note(section)

