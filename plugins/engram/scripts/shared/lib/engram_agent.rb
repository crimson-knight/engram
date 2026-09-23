# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"
require "set"

# Shared runtime for the Claude Code and Codex adapters.
module EngramAgent
  CONFIG_KEYS = %w[
    ENGRAM_LEDGER ENGRAM_BIN ENGRAM_MISSIONS_FILE ENGRAM_READER_NAME
    ENGRAM_MEMORY_VIEW_DIR ENGRAM_CHECKPOINT_DIR ENGRAM_GATE_BYPASS
    ENGRAM_CONTEXT_MAX_CHARS ENGRAM_READER_MAX_CHARS ENGRAM_TOKEN_CHARS_PER_TOKEN
    ENGRAM_OLLAMA_URL ENGRAM_OLLAMA_MODEL ENGRAM_READER_INDEX
    CLAUDE_CONFIG_DIR CODEX_HOME
  ].freeze
  MISS_STRONG = /lost me|not following|too dense|too technical|over my head|dumb it down|speak to me at my level|explain (?:that|it|this) (?:again|simpler|to me)/i
  MISS_UNDERSTAND = /(?:don't|do not|can't|cannot) understand(?! why)|no idea what (?!you did|you were|you're)/i
  MISS_MEANING = /(?:what do you mean|what does (?:that|this|it|\w+) mean\b)/i
  MUTATION_COMMAND = /
    \b(?:apply_patch|git\s+(?:add|commit|checkout|merge|rebase|reset|cherry-pick))\b
    |\bengram\s+(?:new|remember)\b
    |\b(?:touch|mkdir|cp|mv|rm|install|truncate)\b
    |\bsed\s+-i\b|\bperl\s+-i\b
    |\b(?:cat|tee|echo|printf)\b[^\n;]*(?:>>?|<<)
    |\b(?:write_text|write_bytes)\s*\(
    |\bFile\.write\b
  /ix.freeze

  class << self
    def load_config
      return if @config_loaded
      path = ENV["ENGRAM_AGENT_ENV"]
      unless path
        config_root = ENV["XDG_CONFIG_HOME"] || File.join(home, ".config")
        path = File.join(config_root, "engram", "agent.env")
      end
      path = expand_path(path)
      if File.file?(path)
        File.foreach(path) do |line|
          match = line.match(/\A\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*\z/)
          next unless match && CONFIG_KEYS.include?(match[1]) && !ENV.key?(match[1])
          value = match[2]
          value = value[1...-1] if value.length >= 2 && ((value.start_with?('"') && value.end_with?('"')) || (value.start_with?("'") && value.end_with?("'")))
          ENV[match[1]] = value unless value.start_with?("#")
        end
      end
      @config_loaded = true
    rescue StandardError => e
      warn "engram-agent: could not read agent config: #{e.class}: #{e.message}"
      @config_loaded = true
    end

    def home
      ENV["HOME"] || Dir.home
    end

    def expand_path(path)
      File.expand_path(path.to_s)
    end

    def engram_bin
      load_config
      configured = ENV["ENGRAM_BIN"].to_s
      return "engram" if configured.empty?
      return configured if !configured.start_with?("~") && !configured.include?(File::SEPARATOR)
      expand_path(configured)
    end

    def repo_with_memories(start = Dir.pwd)
      current = File.expand_path(start)
      loop do
        return current if Dir.exist?(File.join(current, ".agents", "memories"))
        parent = File.dirname(current)
        return nil if parent == current
        current = parent
      end
    end

    def ledger_root(start = Dir.pwd)
      load_config
      configured = ENV["ENGRAM_LEDGER"]
      return expand_path(configured) unless configured.to_s.empty?
      repo = repo_with_memories(start)
      return repo if repo
      personal_default = File.join(home, "agent_memory")
      return personal_default if Dir.exist?(File.join(personal_default, ".agents", "memories"))
      nil
    end

    def memories_dir(root = ledger_root)
      root && File.join(root, ".agents", "memories")
    end

    def require_ledger(start = Dir.pwd)
      root = ledger_root(start)
      dir = memories_dir(root)
      raise "no engram ledger found; set ENGRAM_LEDGER or run engram init in this repository" unless root && Dir.exist?(dir)
      [root, dir]
    end

    def frontmatter(text)
      match = text.match(/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m)
      return [{}, text] unless match
      values = {}
      nested = nil
      match[1].each_line do |line|
        if (field = line.match(/\A([A-Za-z][A-Za-z0-9_-]*):\s*(.*?)\s*\z/))
          values[field[1]] = field[2]
          nested = field[1] if field[2].empty?
        elsif nested == "metadata" && (field = line.match(/\A\s+type:\s*(.*?)\s*\z/))
          values["metadata_type"] = field[1]
        end
      end
      [values, match[2].to_s]
    end

    def unquote(value)
      text = value.to_s.strip
      if text.length >= 2 && text.start_with?('"') && text.end_with?('"')
        JSON.parse(text) rescue text[1...-1]
      elsif text.length >= 2 && text.start_with?("'") && text.end_with?("'")
        text[1...-1].gsub("''", "'")
      else
        text
      end
    end

    def topics_from(value)
      text = value.to_s.strip
      text = text[1...-1] if text.start_with?("[") && text.end_with?("]")
      text.split(",").map { |topic| unquote(topic).strip }.reject(&:empty?)
    end

    def memory_entries(root = ledger_root)
      dir = memories_dir(root)
      return [] unless dir && Dir.exist?(dir)
      Dir.glob(File.join(dir, "*.md")).sort.map do |path|
        fm, body = frontmatter(File.read(path))
        basename = File.basename(path)
        id = fm["id"].to_s.empty? ? basename[/\A\d{14}/].to_s : unquote(fm["id"])
        slug = basename.sub(/\A\d{14}_?/, "").sub(/\.md\z/, "")
        topics = topics_from(fm["topics"])
        {
          "id" => id, "slug" => slug,
          "title" => unquote(fm["title"]).empty? ? slug.tr("-", " ") : unquote(fm["title"]),
          "topics" => topics, "type" => topics.first || "reference",
          "body" => body, "path" => path,
        }
      rescue StandardError
        nil
      end.compact.sort_by { |entry| entry["id"] }
    end

    def memory_index(entries = memory_entries, links: false)
      output = +"# Memory Index\n\n"
      output << "Branch-scoped memories available through engram on the current ledger.\n\n"
      return output + "No memory migrations are present in this ledger yet.\n" if entries.empty?
      entries.group_by { |entry| entry["type"] }.sort_by do |_topic, group|
        group.map { |entry| entry["id"].to_i }.max || 0
      end.reverse_each do |topic, group|
        output << "## #{topic}\n"
        group.sort_by { |entry| entry["id"].to_i }.reverse_each do |entry|
          if links
            output << "- [#{entry["title"]}](#{entry["id"]}-#{entry["slug"]}.md)\n"
          else
            output << "- #{entry["title"]} (#{entry["id"]})\n"
          end
        end
        output << "\n"
      end
      output
    end

    def default_memory_view_dir(payload = {})
      load_config
      configured = ENV["ENGRAM_MEMORY_VIEW_DIR"]
      return expand_path(configured) unless configured.to_s.empty?
      project = ENV["CLAUDE_PROJECT_DIR"].to_s
      project = payload["cwd"].to_s if project.empty?
      project = repo_with_memories(project) || project unless project.empty?
      return nil if project.empty? || !project.start_with?("/")
      encoded = "-#{project.sub(%r{\A/}, "").tr("/", "-")}"
      claude_home = ENV["CLAUDE_CONFIG_DIR"].to_s.empty? ? File.join(home, ".claude") : expand_path(ENV["CLAUDE_CONFIG_DIR"])
      File.join(claude_home, "projects", encoded, "memory")
    end

    def yaml_scalar(text)
      JSON.generate(text.to_s.gsub(/[\r\n]+/, " ").strip)
    end

    def ingest_memory_file(path, root)
      raw = File.read(path)
      fm, body = frontmatter(raw)
      return false if fm["generated_from"] || File.basename(path) == "MEMORY.md"
      title = unquote(fm["description"])
      title = unquote(fm["title"]) if title.empty?
      title = unquote(fm["name"]) if title.empty?
      title = File.basename(path).sub(/\.md\z/, "").tr("-", " ") if title.empty?
      title = title.gsub(/[\r\n]+/, " ").strip
      metadata = fm["metadata_type"].to_s
      metadata = unquote(fm["type"]) if metadata.empty?
      metadata = "inbox" if metadata.empty?
      topic = metadata.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A-+|-+\z/, "")
      topics = [topic, "imported"].reject(&:empty?).uniq
      out, err, status = Open3.capture3(engram_bin, "new", title, "--topics", topics.join(","), chdir: root, stdin_data: "")
      raise "engram new failed while importing #{File.basename(path)}: #{err.strip}" unless status.success?
      migration_path = File.expand_path(out.lines.last.to_s.strip, root)
      raise "engram new did not return a migration path" unless File.file?(migration_path)
      id = File.basename(migration_path)[/\A\d{14}/]
      content = +"---\nid: #{id}\ntitle: #{yaml_scalar(title)}\ntopics: [#{topics.join(", ")}]\nsupersedes: []\nauthor: agent-kit\n---\n\n"
      content << body
      File.write(migration_path, content)
      true
    end

    def sync_memory_view(root = ledger_root, view = default_memory_view_dir)
      raise "no ledger directory to sync" unless root && Dir.exist?(memories_dir(root))
      return 0 if view.nil? || view.empty?
      FileUtils.mkdir_p(view)
      ingested = 0
      Dir.glob(File.join(view, "*.md")).sort.each do |path|
        next unless ingest_memory_file(path, root)
        File.delete(path)
        ingested += 1
      end
      _out, err, status = Open3.capture3(engram_bin, "sync", "--quiet", chdir: root)
      raise "engram sync failed: #{err.strip}" unless status.success?
      entries = memory_entries(root)
      Dir.glob(File.join(view, "*.md")).each do |path|
        next if File.basename(path) == "MEMORY.md"
        fm, = frontmatter(File.read(path))
        File.delete(path) if fm["generated_from"]
      end
      entries.each do |entry|
        page = +"---\nname: #{entry["slug"]}\n"
        page << "description: #{yaml_scalar(entry["title"])}\nmetadata:\n  type: #{entry["type"]}\n"
        page << "generated_from: #{entry["id"]}\n---\n\n#{entry["body"]}"
        File.write(File.join(view, "#{entry["id"]}-#{entry["slug"]}.md"), page)
      end
      File.write(File.join(view, "MEMORY.md"), memory_index(entries, links: true))
      ingested
    end

    def reader_name
      load_config
      ENV["ENGRAM_READER_NAME"].to_s.empty? ? "the user" : ENV["ENGRAM_READER_NAME"]
    end

    def reader_reminder
      <<~TEXT
        <reader-reminder>
        A persistent reader model for #{reader_name} is stored in the engram ledger under topic reader. It records vocabulary by domain, depth by topic, preferred reply shapes, and what to do when an explanation misses. Before writing a report, summary, research result, or other user-facing text, load the reader skill and read the card. If the reader says something is unclear, follow its miss protocol and record the useful correction in a new reader memory before ending the session.
        Long reports: use the reader-writer skill or Claude agent. Short briefs: use the reader skill inline. Keep the card out of agent-to-agent notes.
        </reader-reminder>
      TEXT
    end

    def reader_pages(root = ledger_root)
      memory_entries(root).select { |entry| entry["topics"].include?("reader") }.last(20)
    end

    def reader_card(root = ledger_root)
      pages = reader_pages(root)
      return nil if pages.empty?
      text = pages.map do |entry|
        "## #{entry["title"]}\n(ledger id #{entry["id"]})\n\n#{entry["body"].to_s.strip}"
      end.join("\n\n")
      maximum = (ENV["ENGRAM_READER_MAX_CHARS"] || "20000").to_i
      text.length > maximum ? text[0, maximum] + "\n…[clipped: query engram with topic reader for more pages]" : text
    end

    def full_reader_context
      root, = require_ledger
      card = reader_card(root)
      return nil unless card
      <<~TEXT
        <reader-card source="engram topic reader">
        This is the current reader model. Read it before preparing text for the person it describes. On an unclear explanation, follow its protocol and record the correction as a new reader migration.

        #{card}
        </reader-card>
      TEXT
    end

    def missions_context
      load_config
      path = ENV["ENGRAM_MISSIONS_FILE"].to_s
      return "" if path.empty?
      path = expand_path(path)
      return "" unless File.file?(path)
      sections = File.read(path).split(/^##\s+/, -1).drop(1)
      active = sections.select { |section| section.match?(/\*\*Status:\*\*\s*ACTIVE/i) }
      return "" if active.empty?
      output = +"<mission-ledger>\nACTIVE MISSIONS (resolve work against these names and aliases before starting):\n\n"
      active.each do |section|
        lines = section.lines
        output << "## #{lines.first.to_s.strip}\n"
        lines.drop(1).each { |line| output << line if line.match?(/\*\*(?:Status|Aliases|Goal|Plan)\b/) }
        output << "\n"
      end
      output << "If this work matches none, record the matching mission in the configured source.\n</mission-ledger>"
      output
    rescue StandardError => e
      warn "engram-agent: mission injection skipped: #{e.class}: #{e.message}"
      ""
    end

    def detect_codex(payload, transcript_path = nil)
      return true if payload["hook_event_name"] == "Stop" && payload.key?("stop_hook_active") && payload.key?("turn_id")
      path = transcript_path || payload["transcript_path"]
      return true if path.to_s.match?(%r{(?:^|/)sessions/\d{4}/\d{2}/\d{2}/rollout-[^/]+\.jsonl\z})
      if path && File.file?(path)
        first = File.open(path, &:gets).to_s
        first.include?('"type":"session_meta"') || first.include?('"type": "session_meta"')
      else
        false
      end
    end

    def emit_hook_context(payload, event_name, context)
      return if context.to_s.strip.empty?
      if detect_codex(payload)
        puts JSON.generate("hookSpecificOutput" => { "hookEventName" => event_name, "additionalContext" => context })
      else
        puts context
      end
    end

    def safe_session_id(payload)
      id = payload["session_id"].to_s.gsub(/[^A-Za-z0-9_-]/, "")
      id.empty? ? "unknown" : id[0, 120]
    end

    def claude_root
      load_config
      ENV["CLAUDE_CONFIG_DIR"].to_s.empty? ? File.join(home, ".claude") : expand_path(ENV["CLAUDE_CONFIG_DIR"])
    end

    def codex_root
      load_config
      ENV["CODEX_HOME"].to_s.empty? ? File.join(home, ".codex") : expand_path(ENV["CODEX_HOME"])
    end

    def checkpoint_dir(payload)
      load_config
      return expand_path(ENV["ENGRAM_CHECKPOINT_DIR"]) unless ENV["ENGRAM_CHECKPOINT_DIR"].to_s.empty?
      detect_codex(payload) ? File.join(codex_root, "checkpoints") : File.join(claude_root, "checkpoints")
    end

    def checkpoint_file(payload)
      File.join(checkpoint_dir(payload), "#{safe_session_id(payload)}.md")
    end

    def session_start(payload)
      load_config
      codex = detect_codex(payload)
      context = []
      begin
        root, = require_ledger(payload["cwd"].to_s.empty? ? Dir.pwd : payload["cwd"])
        if codex
          _out, err, status = Open3.capture3(engram_bin, "sync", "--quiet", chdir: root)
          warn "engram-agent: engram sync warning: #{err.strip}" unless status.success?
          context << memory_index(memory_entries(root))
        else
          sync_memory_view(root, default_memory_view_dir(payload))
        end
      rescue StandardError => e
        warn "engram-agent: session memory setup skipped: #{e.class}: #{e.message}"
      end
      context << reader_reminder
      mission = missions_context
      context << mission unless mission.empty?
      if payload["source"] == "compact" && (restored = restore_checkpoint(payload))
        context << restored
      end
      context << "Checkpoint file for this session: #{checkpoint_file(payload)}"
      combined = context.join("\n\n")
      maximum = (ENV["ENGRAM_CONTEXT_MAX_CHARS"] || "24000").to_i
      combined = combined[0, maximum] + "\n[engram context clipped]" if combined.length > maximum
      emit_hook_context(payload, "SessionStart", combined)
      0
    end

    def mission_hook
      context = missions_context
      puts context unless context.empty?
      0
    end

    def reader_hook(args)
      load_config
      if args.include?("init")
        return reader_init
      elsif args.include?("--full")
        full = full_reader_context
        puts full if full
      else
        puts reader_reminder
      end
      0
    rescue StandardError => e
      warn "reader-inject-hook: #{e.class}: #{e.message}"
      0
    end

    def reader_init
      root, dir = require_ledger
      FileUtils.mkdir_p(dir)
      out, err, status = Open3.capture3(engram_bin, "new", "Reader card", "--topics", "reader", chdir: root, stdin_data: "")
      raise err.strip unless status.success?
      path = File.expand_path(out.lines.last.to_s.strip, root)
      raise "engram new did not create a migration file" unless File.file?(path)
      template_path = File.expand_path("../templates/reader-card.md", __dir__)
      template_path = File.expand_path("../../templates/reader-card.md", __dir__) unless File.file?(template_path)
      template = File.read(template_path)
      fm, = frontmatter(File.read(path))
      body = +"---\nid: #{unquote(fm["id"])}\ntitle: #{yaml_scalar("Reader card")}\ntopics: [reader]\nsupersedes: []\nauthor: agent-kit\n---\n\n"
      body << template
      File.write(path, body)
      _sync_out, sync_err, sync_status = Open3.capture3(engram_bin, "sync", "--quiet", chdir: root)
      raise sync_err.strip unless sync_status.success?
      puts path
      0
    end

    def section(body, heading_pattern)
      part = body.split(/^\*\*(?=[A-Z])/, -1).find { |item| item.match?(heading_pattern) }
      part ? part.sub(/\A[^\n]*\n/, "") : ""
    end

    def terms_from(text)
      text.gsub(/\([^)]*\)/, "").split(/[,\n]/)
        .map { |term| term.strip.sub(/\A[-*]\s*/, "") }
        .map { |term| (term[/\"([^\"]+)\"/, 1] || term.split(/\s+\(|:/).first.to_s).strip.downcase }
        .reject { |term| term.empty? || term.length > 40 || term.match?(/\A\d/) }
    end

    def lost_entries(text)
      text.scan(/^- ([^:\n]+?)(?: \([^)]*\))?:\s*(.+?)(?=\n- |\z)/m).map do |names, anchor|
        [names.split(/,|\bvs\b|versus/).map { |name| name.strip.downcase }.reject(&:empty?), anchor.gsub(/\s+/, " ").strip]
      end
    end

    def vocabulary_page(root = ledger_root)
      pages = reader_pages(root)
      entry = pages.reverse.find { |item| item["title"].match?(/vocabulary/i) || item["slug"].match?(/vocabulary/i) }
      entry && entry["body"]
    end

    def jargon_gate(args)
      load_config
      json = args.include?("--json")
      draft = STDIN.read
      vocab = vocabulary_page
      unless vocab
        warn "reader-jargon-gate: no reader vocabulary page is available; the gate has no terms to check"
        puts "[]" if json
        return 0
      end
      uses = terms_from(section(vocab, /\AUses/i))
      recognizes = terms_from(section(vocab, /\ARecognizes/i))
      rejected = terms_from(section(vocab, /\ARejected/i)).reject { |term| term.match?(/\bany\b|\bbare\b/) }
      lost = lost_entries(section(vocab, /\ALost/i))
      safe = (uses + recognizes).to_set
      findings = []
      lines = draft.lines
      in_code = false
      lines.each_with_index do |line, index|
        in_code = !in_code if line.strip.start_with?(96.chr * 3)
        next if in_code
        line_number = index + 1
        low = line.downcase
        lost.each do |names, anchor|
          names.each do |term|
            next if safe.include?(term) || !low.match?(/\b#{Regexp.escape(term)}\b/)
            anchor_key = anchor.split(/\s+/).first(3).join(" ").downcase.gsub(/[^a-z ]/, "")
            window = lines[[index - 2, 0].max..[index + 2, lines.length - 1].min].join.downcase
            next if !anchor_key.empty? && window.include?(anchor_key)
            findings << { line: line_number, kind: "LOST", term: term, fix: "use the recorded explanation: #{anchor[0, 140]}" }
          end
        end
        rejected.each do |term|
          if !term.empty? && low.match?(/\b#{Regexp.escape(term)}\b/)
            findings << { line: line_number, kind: "REJECTED", term: term, fix: "remove this term from the draft" }
          end
        end
        line.scan(/(?<![ \w\/.-])((?:[a-z]+_[a-z_]+)|(?:[A-Z][a-z]+(?:[A-Z][a-z]+)+)|(?:[a-z]+\.[a-z]+(?:\.[a-z]+)*)|(?:\b[A-Z]{2,6}\b))(?![ \w\/-])/).flatten.each do |term|
          next if safe.include?(term.downcase)
          next if term.match?(/\.(?:com|org|net|io|dev|md|rb|cr|yml|json|html|css|js)\z/)
          next if %w[PM AM UTC USD MiB GB KB MB OK PR API SEO CRM SSL DNS JSON YAML CSS HTML URL ID iOS].include?(term)
          findings << { line: line_number, kind: "IDENT", term: term, fix: "describe it in ordinary words; keep identifiers in code blocks" }
        end
        line.scan(/(?<![\w.\/-])(\$?\d[\d,]*(?:\.\d+)?%?)(?![\w.\/-])/).flatten.each do |number|
          next if number.match?(/\A(?:19|20)\d\d\z/) || number.length < 2
          number_at = low.index(number.downcase) || 0
          nearby = low[[number_at - 40, 0].max, number.length + 80].to_s
          next if nearby.match?(/\b(per|of|out of|about|from|to|by|at|in|over|under|pages|tokens|characters|turns|sessions|rounds|bullets|lines|seconds|minutes|hours|days|weeks|months|mib|gb|kb|mb|cents|dollars|users|rows|files|commits|percent|score|rating|up|down)\b/)
          findings << { line: line_number, kind: "NUMBER", term: number, fix: "add a label, unit, and direction from the prior value" }
        end
      end
      findings.uniq!
      if json
        puts JSON.pretty_generate(findings)
      elsif findings.empty?
        puts "reader-jargon-gate: clean (#{uses.length} used terms, #{recognizes.length} recognized terms, #{lost.length} recorded explanations)"
      else
        findings.each { |finding| puts "#{finding[:kind].ljust(8)} line #{finding[:line].to_s.rjust(3)}  #{finding[:term]}  ->  #{finding[:fix]}" }
        puts "#{findings.length} finding(s)"
      end
      findings.empty? ? 0 : 1
    rescue StandardError => e
      warn "reader-jargon-gate: #{e.class}: #{e.message}"
      0
    end

    def token_estimate(args)
      load_config
      family_index = args.index("--family")
      warn "reader-token-estimate: model-family counts are not calibrated; using a generic estimate" if family_index
      paths = []
      skip_next = false
      args.each do |argument|
        if skip_next
          skip_next = false
        elsif argument == "--family"
          skip_next = true
        else
          paths << argument
        end
      end
      contents = paths.empty? ? STDIN.read : File.read(paths.first)
      chars_per_token = [(ENV["ENGRAM_TOKEN_CHARS_PER_TOKEN"] || "4").to_f, 0.5].max
      estimate = (contents.length / chars_per_token).round
      if family_index
        puts estimate
      else
        puts "#{contents.length} characters, roughly #{estimate} tokens at #{chars_per_token} characters per token"
        puts "This is a general estimate; tokenizers vary by model and text."
      end
      0
    rescue StandardError => e
      warn "reader-token-estimate: #{e.message}"
      1
    end

    def checkpoint_extract(transcript_path)
      return nil unless transcript_path && File.file?(transcript_path)
      skills = []
      files = []
      recent_users = []
      assistant = ""
      File.foreach(transcript_path) do |line|
        record = JSON.parse(line) rescue nil
        next unless record.is_a?(Hash)
        tool_events(record).each do |event|
          name = event["name"].to_s
          input = event["input"]
          skills << input["skill"] if name == "Skill" && input.is_a?(Hash) && input["skill"]
          files.concat(tool_paths(name, input, tool_command(input)))
        end
        user = user_text(record)
        if !user.strip.empty? && !user.lstrip.start_with?("<")
          recent_users << user
          recent_users.shift while recent_users.length > 12
        end
        if record["type"] == "assistant"
          assistant = content_text(record.dig("message", "content"))
        elsif record["type"] == "response_item" && record.dig("payload", "role") == "assistant"
          assistant = content_text(record.dig("payload", "content"))
        end
      end
      users = recent_users.last(3).map { |text| clip(text, 500) }
      skill_lines = skills.uniq.map { |skill| "- #{skill}" }.join("\n")
      skill_lines = "- (none recorded)" if skill_lines.empty?
      file_lines = files.uniq.last(15).map { |path| "- #{path}" }.join("\n")
      file_lines = "- (none recorded)" if file_lines.empty?
      <<~MARKDOWN
        # AUTO-EXTRACTED STATE (written at pre-compaction, #{Time.now.iso8601})
        Deterministic transcript extraction. A model-written checkpoint is richer when present.

        ## Skills invoked this session
        #{skill_lines}

        ## Files edited (most recent last)
        #{file_lines}

        ## Last user messages (verbatim, clipped)
        #{users.map { |text| "> #{text.gsub("\n", "\n> ")}" }.join("\n\n")}

        ## Last assistant text before compaction
        #{assistant.empty? ? "(none)" : clip(assistant, 800)}
      MARKDOWN
    end

    def clip(value, length)
      text = value.to_s.strip
      text.length > length ? text[0, length] + " …[clipped]" : text
    end

    def checkpoint_precompact(payload)
      directory = checkpoint_dir(payload)
      FileUtils.mkdir_p(directory)
      session = safe_session_id(payload)
      model_path = File.join(directory, "#{session}.md")
      auto_path = File.join(directory, "#{session}.auto.md")
      marker = File.join(directory, "#{session}.block-used")
      auto = checkpoint_extract(payload["transcript_path"])
      File.write(auto_path, auto) if auto
      fresh = File.file?(model_path) && (Time.now - File.mtime(model_path)) < 900
      if payload["trigger"] == "auto" && !fresh && !File.exist?(marker)
        File.write(marker, Time.now.iso8601)
        reason = "Automatic compaction is waiting for a fresh checkpoint. Load the checkpoint skill, reconcile state, and write the checkpoint at #{model_path}. This gate blocks once per compaction cycle."
        if detect_codex(payload)
          puts JSON.generate("continue" => false, "systemMessage" => reason)
        else
          puts JSON.generate("decision" => "block", "reason" => reason)
        end
      end
      0
    end

    def checkpoint_postcompact(payload)
      directory = checkpoint_dir(payload)
      FileUtils.mkdir_p(File.join(directory, "log"))
      session = safe_session_id(payload)
      FileUtils.rm_f(File.join(directory, "#{session}.block-used"))
      summary = payload["compact_summary"].to_s
      summary = "No summary field was supplied by this hook event." if summary.empty?
      log_path = File.join(directory, "log", "#{Time.now.strftime("%Y-%m-%d")}-#{session}.md")
      File.open(log_path, "a") do |file|
        file.puts "\n---\n# PostCompact #{Time.now.iso8601} trigger=#{payload["trigger"]} session=#{session}\n\n"
        file.puts summary
      end
      stale_before = Time.now - 14 * 86_400
      (Dir.glob(File.join(directory, "*.md")) + Dir.glob(File.join(directory, "*.block-used"))).each do |path|
        FileUtils.rm_f(path) if File.file?(path) && File.mtime(path) < stale_before
      end
      0
    end

    def restore_checkpoint(payload)
      directory = checkpoint_dir(payload)
      session = safe_session_id(payload)
      model_path = File.join(directory, "#{session}.md")
      auto_path = File.join(directory, "#{session}.auto.md")
      parts = []
      if File.file?(model_path)
        parts << "## Model-written checkpoint (written #{File.mtime(model_path).iso8601})\n\n#{clip(File.read(model_path), 6000)}"
      end
      parts << clip(File.read(auto_path), 6000) if File.file?(auto_path)
      return nil if parts.empty?
      <<~TEXT
        <post-compaction-checkpoint>
        This checkpoint was injected directly by the SessionStart(compact) hook. Resume at NEXT, re-load listed skills before relying on their procedures, and trust settled RULES.

        #{parts.join("\n\n")}
        </post-compaction-checkpoint>
      TEXT
    end

    def checkpoint_hook(args, payload)
      case args.first
      when "precompact"
        checkpoint_precompact(payload)
      when "postcompact"
        checkpoint_postcompact(payload)
      when "restore"
        restored = restore_checkpoint(payload)
        emit_hook_context(payload, payload["hook_event_name"] || "SessionStart", restored) if restored
        0
      else
        warn "claude-checkpoint-hook: use precompact, postcompact, or restore"
        0
      end
    rescue StandardError => e
      warn "engram-agent-checkpoint: #{e.class}: #{e.message}"
      0
    end

    def read_payload
      parsed = JSON.parse(STDIN.read)
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def main(args)
      load_config
      command = args.shift.to_s
      case command
      when "sync"
        sync_command
      when "session-start"
        session_start(read_payload)
      when "reflect"
        reflect(read_payload)
      when "missions"
        mission_hook
      when "reader"
        reader_hook(args)
      when "jargon"
        jargon_gate(args)
      when "token-estimate"
        token_estimate(args)
      when "checkpoint"
        checkpoint_hook(args, read_payload)
      when "mcp"
        root = ledger_root
        Dir.chdir(root) if root && Dir.exist?(root)
        exec(engram_bin, "mcp")
      when "miss"
        phrase = miss_phrase(STDIN.read)
        puts(phrase ? "MISS #{phrase}" : "CLEAR")
        phrase ? 0 : 1
      else
        warn "usage: engram-agent sync|session-start|reflect|missions|reader|jargon|token-estimate|checkpoint|mcp|miss"
        2
      end
    end
    def content_text(content)
      case content
      when String then content
      when Array
        content.select { |block| block.is_a?(Hash) && %w[text input_text output_text].include?(block["type"]) }
          .map { |block| block["text"].to_s }.join("\n")
      else ""
      end
    end

    def user_text(record)
      return "" if record["isCompactSummary"] == true
      message = record["message"]
      if record["type"] == "user" && message.is_a?(Hash)
        content_text(message["content"])
      elsif record["type"] == "response_item" && record["payload"].is_a?(Hash)
        payload = record["payload"]
        payload["role"] == "user" ? content_text(payload["content"]) : ""
      else
        ""
      end
    end

    def tool_events(record)
      events = []
      events << { "name" => record["tool_name"], "input" => record["tool_input"] || {} } if record["tool_name"]
      if record["type"] == "assistant"
        content = record.dig("message", "content")
        if content.is_a?(Array)
          content.each do |block|
            events << { "name" => block["name"], "input" => block["input"] || {} } if block.is_a?(Hash) && block["type"] == "tool_use"
          end
        end
      end
      if record["type"] == "response_item" && record["payload"].is_a?(Hash)
        payload = record["payload"]
        if %w[function_call custom_tool_call tool_call].include?(payload["type"])
          events << { "name" => payload["name"], "input" => payload["input"] || payload["arguments"] || {} }
        end
      end
      events
    end

    def tool_command(input)
      if input.is_a?(Hash)
        direct = input["command"] || input["cmd"] || input["script"]
        return direct.to_s unless direct.nil?
        return JSON.generate(input)
      end
      value = input.to_s
      parsed = JSON.parse(value) rescue nil
      parsed.is_a?(Hash) ? tool_command(parsed) : value
    end

    def tool_paths(name, input, command)
      paths = []
      if input.is_a?(Hash)
        %w[file_path path target_file filename].each do |key|
          value = input[key]
          paths << value if value.is_a?(String) && !value.empty?
        end
        %w[edits files].each do |key|
          value = input[key]
          paths.concat(value.filter_map { |item| item.is_a?(Hash) ? item["file_path"] || item["path"] : item }) if value.is_a?(Array)
        end
      end
      if name.to_s == "apply_patch" || command.include?("*** Begin Patch")
        command.scan(/^\*\*\*\s+(?:Add File|Update File|Delete File|Move to):\s*(.+?)\s*$/).flatten.each { |path| paths << path }
      end
      if name.to_s.match?(/\A(?:Bash|exec)\z/)
        command.scan(/\b(?:cat|tee|touch|mkdir|cp|mv|rm)\s+(?:-[^\s]+\s+)*["']?([^;\s"'<>]+)["']?/).flatten.each { |path| paths << path }
        command.scan(/(?:^|\s)>\s*["']?([^;\s"'<>]+)["']?/).flatten.each { |path| paths << path }
      end
      paths.compact.map(&:to_s).reject(&:empty?).uniq
    end

    def absolute_tool_path(path, cwd)
      File.expand_path(path, cwd)
    rescue StandardError
      path.to_s
    end

    def memory_file?(path, root)
      return false unless root
      expanded = absolute_tool_path(path, root)
      expanded.start_with?(File.expand_path(memories_dir(root)) + File::SEPARATOR)
    end

    def memory_view_file?(path, view)
      return false unless view
      return false unless absolute_tool_path(path, Dir.pwd).start_with?(File.expand_path(view) + File::SEPARATOR)
      return false unless File.extname(path) == ".md" && File.basename(path) != "MEMORY.md"
      if File.file?(path)
        fm, = frontmatter(File.read(path))
        return false if fm["generated_from"]
      end
      true
    rescue StandardError
      false
    end

    def reader_topics?(text)
      text.to_s.match?(/^topics:\s*\[[^\]]*\breader\b/im) || text.to_s.match?(/^topics:\s*reader\b/im)
    end

    def transcript_start_time(path, codex)
      if codex && path && File.file?(path)
        File.foreach(path).first(4).each do |line|
          record = JSON.parse(line) rescue nil
          next unless record.is_a?(Hash)
          stamp = record["timestamp"] || record.dig("payload", "timestamp")
          return Time.parse(stamp) if stamp.is_a?(String)
        end
      end
      File.birthtime(path)
    rescue StandardError
      File.mtime(path) - 3600
    end

    def scan_transcript(path, payload)
      codex = detect_codex(payload, path)
      start = payload["cwd"].to_s.empty? ? Dir.pwd : payload["cwd"]
      root, = require_ledger(start) rescue [nil, nil]
      view = default_memory_view_dir(payload)
      start_time = path && File.file?(path) ? transcript_start_time(path, codex) : Time.now - 3600
      result = { worked: false, recorded: false, miss: false, reader_recorded: false, files: [], start_time: start_time }
      return result unless path && File.file?(path)
      File.foreach(path) do |line|
        record = JSON.parse(line) rescue nil
        next unless record.is_a?(Hash)
        text = user_text(record)
        result[:miss] ||= miss_phrase(text) if !text.strip.empty? && !text.lstrip.start_with?("<")
        tool_events(record).each do |event|
          name = event["name"].to_s
          input = event["input"]
          command = tool_command(input)
          paths = tool_paths(name, input, command)
          result[:files].concat(paths)
          edit = %w[Write Edit MultiEdit NotebookEdit apply_patch].include?(name)
          mcp_remember = name == "remember" || name.match?(/(?:^|__)remember\z/)
          result[:worked] ||= edit || (name.match?(/\A(?:Bash|exec)\z/) && command.match?(MUTATION_COMMAND)) || mcp_remember
          memory_path = paths.any? { |candidate| memory_file?(candidate, root) || candidate.include?(".agents/memories/") }
          inbox_path = paths.any? { |candidate| memory_view_file?(candidate, view) }
          result[:recorded] ||= memory_path || inbox_path || mcp_remember
          result[:reader_recorded] ||= (memory_path || inbox_path) && reader_topics?(command)
        end
      end
      if root && Dir.exist?(memories_dir(root))
        fresh = Dir.glob(File.join(memories_dir(root), "*.md")).select { |file| File.mtime(file) >= start_time rescue false }
        result[:recorded] ||= fresh.any?
        result[:reader_recorded] ||= fresh.any? do |file|
          fm, = frontmatter(File.read(file))
          topics_from(fm["topics"]).include?("reader")
        rescue StandardError
          false
        end
      end
      if view && Dir.exist?(view)
        fresh_inbox = Dir.glob(File.join(view, "*.md")).reject { |file| File.basename(file) == "MEMORY.md" }
          .select { |file| File.mtime(file) >= start_time rescue false }
          .reject do |file|
            fm, = frontmatter(File.read(file))
            fm["generated_from"]
          rescue StandardError
            true
          end
        result[:recorded] ||= fresh_inbox.any?
      end
      result
    end

    def miss_phrase(text)
      return nil if text.nil? || text.match?(/\A\s*</)
      [MISS_STRONG, MISS_UNDERSTAND, MISS_MEANING].each do |pattern|
        text.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          return match[0] unless quoted?(text, match.begin(0))
        end
      end
      nil
    end

    def quoted?(text, position)
      line_start = (text.rindex("\n", position) || -1) + 1
      before = text[line_start...position].to_s
      return true if before.count('"').odd?
      before.count("“") > before.count("”") || before.count("‘") > before.count("’")
    end

    def reflect(payload)
      load_config
      if ENV["ENGRAM_GATE_BYPASS"] == "1"
        return detect_codex(payload) ? codex_stop_continue : 0
      end
      path = payload["transcript_path"]
      codex = detect_codex(payload, path)
      return codex ? codex_stop_continue : 0 unless path && File.file?(path)
      begin
        root, = require_ledger(payload["cwd"].to_s.empty? ? Dir.pwd : payload["cwd"])
        sync_memory_view(root, default_memory_view_dir(payload)) unless codex
      rescue StandardError => e
        warn "engram-reflect-gate: ledger sync skipped: #{e.class}: #{e.message}"
      end
      result = scan_transcript(path, payload)
      return 0 unless result[:worked] || result[:miss]
      if result[:miss] && !result[:reader_recorded]
        if payload["stop_hook_active"]
          warn "engram-reflect-gate: reader miss is still unrecorded after a continuation; allowing this stop to avoid a loop."
          return codex ? codex_stop_continue : 0
        end
        warn "engram-reflect-gate: the reader said something was unclear (#{result[:miss].inspect}), but no new memory with topic reader was written. Record the term or framing that missed, the explanation that helped (or unresolved), and any level correction in a new migration with topics [reader, <topic>], then run engram sync. Escape hatch: ENGRAM_GATE_BYPASS=1."
        return 2
      end
      return codex_stop_continue if codex && !result[:worked] && !result[:miss]
      return codex ? codex_stop_continue : 0 if result[:recorded]
      if payload["stop_hook_active"]
        warn "engram-reflect-gate: state changed but no ledger write was found after a continuation; allowing this stop to avoid a loop."
        return codex ? codex_stop_continue : 0
      end
      warn "engram-reflect-gate: state changed but no ledger write was found. Before stopping, record one useful decision, result, or lesson as an engram migration under .agents/memories/ and run engram sync. A reader miss also requires a memory with topic reader. Escape hatch: ENGRAM_GATE_BYPASS=1."
      2
    rescue StandardError => e
      warn "engram-reflect-gate: check skipped after an internal error: #{e.class}: #{e.message}"
      0
    end

    def codex_stop_continue
      puts JSON.generate("continue" => true)
      0
    end

  end
end
