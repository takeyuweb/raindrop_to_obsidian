#!/usr/bin/env ruby
# raindrop_to_obsidian.rb
#
# 前日のRaindropブックマークを取得し、LLMで要約して当日のObsidianデイリーノートに追記する
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
require 'uri'
require 'timeout'

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

# 書き込み先は常に当日のデイリーノート
NOTE_DATE = jst_today

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

# ── ページコンテンツ取得 ────────────────────────────────────

MAX_CONTENT_LENGTH = 12_000  # LLMに渡すテキストの最大文字数

def strip_html(html)
  text = html
    .gsub(/<script[^>]*>.*?<\/script>/mi, '')
    .gsub(/<style[^>]*>.*?<\/style>/mi, '')
    .gsub(/<nav[^>]*>.*?<\/nav>/mi, '')
    .gsub(/<footer[^>]*>.*?<\/footer>/mi, '')
    .gsub(/<header[^>]*>.*?<\/header>/mi, '')
    .gsub(/<!--.*?-->/m, '')
    .gsub(/<[^>]+>/, ' ')
    .gsub(/&nbsp;/, ' ')
    .gsub(/&amp;/, '&')
    .gsub(/&lt;/, '<')
    .gsub(/&gt;/, '>')
    .gsub(/&quot;/, '"')
    .gsub(/&#\d+;/, '')
    .gsub(/\s+/, ' ')
    .strip
  text
end

def fetch_page_content(url)
  uri = URI(url)
  return nil unless uri.scheme&.match?(/^https?$/)

  Timeout.timeout(15) do
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https',
                               open_timeout: 10, read_timeout: 10) do |http|
      req = Net::HTTP::Get.new(uri)
      req['User-Agent'] = 'Mozilla/5.0 (compatible; RaindropToObsidian/1.0)'
      req['Accept'] = 'text/html'
      http.request(req)
    end

    # リダイレクト対応（1回まで）
    if response.is_a?(Net::HTTPRedirection) && response['location']
      redirect_uri = URI(response['location'])
      response = Net::HTTP.start(redirect_uri.hostname, redirect_uri.port,
                                 use_ssl: redirect_uri.scheme == 'https',
                                 open_timeout: 10, read_timeout: 10) do |http|
        req = Net::HTTP::Get.new(redirect_uri)
        req['User-Agent'] = 'Mozilla/5.0 (compatible; RaindropToObsidian/1.0)'
        req['Accept'] = 'text/html'
        http.request(req)
      end
    end

    return nil unless response.is_a?(Net::HTTPSuccess)

    content_type = response['content-type'].to_s
    return nil unless content_type.include?('text/html') || content_type.include?('text/plain')

    body = response.body
    # エンコーディング対応
    body.force_encoding('UTF-8') unless body.encoding == Encoding::UTF_8
    body.encode!('UTF-8', invalid: :replace, undef: :replace, replace: '')

    text = strip_html(body)
    text.length > MAX_CONTENT_LENGTH ? text[0...MAX_CONTENT_LENGTH] : text
  end
rescue StandardError => e
  warn "    ⚠️  ページ取得失敗 (#{url}): #{e.message}"
  nil
end

# ── Anthropic API ─────────────────────────────────────────

def anthropic_request(model:, max_tokens:, prompt:)
  uri = URI('https://api.anthropic.com/v1/messages')
  req = Net::HTTP::Post.new(uri)
  req['Content-Type']      = 'application/json'
  req['x-api-key']         = ANTHROPIC_API_KEY
  req['anthropic-version'] = '2023-06-01'
  req.body = JSON.generate(
    model:      model,
    max_tokens: max_tokens,
    messages:   [{ role: 'user', content: prompt }]
  )

  res  = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  data = JSON.parse(res.body)
  data.dig('content', 0, 'text')&.strip
end

def bookmark_context(item, highlights, page_content = nil)
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

  if page_content && !page_content.empty?
    context += <<~TEXT

      --- ページ本文 ---
      #{page_content}
    TEXT
  end

  context
end

def summarize_bookmark(item, highlights, page_content = nil)
  prompt = <<~PROMPT
    以下のウェブページの情報をもとに、日本語で2〜3文の簡潔な要約を作成してください。
    要約には憶測や推論を交えず、記載された事実のみを含めてください。
    要約は「何についてのページか」「なぜ重要か・何が学べるか」を含めてください。

    要約の後に、ポイントとなる内容を1〜3点、箇条書き（「- 」始まり）で添えてください。

    出力形式:
    要約文

    - ポイント1
    - ポイント2
    - ポイント3

    余計な前置きや説明は不要です。

    #{bookmark_context(item, highlights, page_content)}
  PROMPT

  anthropic_request(model: 'claude-haiku-4-5-20251001', max_tokens: 500, prompt: prompt) ||
    '（要約取得失敗）'
end

def review_note(item, highlights, page_content = nil)
  note = item['note'].to_s
  return nil if note.empty?

  prompt = <<~PROMPT
    以下はあるウェブページに対してユーザーが書いたコメント（ノート）です。
    ウェブページの情報も合わせて提供します。

    コメントの内容を分析し、以下に該当する場合のみ日本語で補足してください：
    - 事実誤認や誤った理解がある場合 → 正しい情報を簡潔に説明
    - 疑問文が含まれている場合 → ページの情報やハイライトをもとに回答

    該当しない場合（コメントが正確で疑問もない場合）は、「なし」とだけ出力してください。
    余計な前置きは不要です。補足内容のみ出力してください。

    --- ユーザーのコメント ---
    #{note}

    --- ページ情報 ---
    #{bookmark_context(item, highlights, page_content)}
  PROMPT

  result = anthropic_request(model: 'claude-sonnet-4-6', max_tokens: 500, prompt: prompt)
  return nil if result.nil? || result == 'なし'

  result
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

    # ページコンテンツ取得
    print "  ページ取得中: #{title[0..50]}... "
    page_content = fetch_page_content(url)
    puts page_content ? "✓ (#{page_content.length}文字)" : '– スキップ'

    # LLM要約
    print "  要約中: #{title[0..50]}... "
    summary = summarize_bookmark(item, highlights, page_content)
    puts '✓'

    # ノートの補足（誤認訂正・疑問回答）
    note = item['note'].to_s
    review = nil
    unless note.empty?
      print "  補足確認中: #{title[0..50]}... "
      review = review_note(item, highlights, page_content)
      puts review ? '✓ 補足あり' : '– 補足なし'
    end

    lines << "### [#{title}](#{url})"
    lines << "_#{collection}_ #{tags}".strip
    lines << ''
    lines << summary
    lines << ''

    unless note.empty?
      lines << '**ノート:**'
      lines << note
      lines << ''
      if review
        lines << '**補足:**'
        lines << review
        lines << ''
      end
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
  note_path = daily_note_path(NOTE_DATE)
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
    note_body = build_note_from_template(NOTE_DATE)
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

