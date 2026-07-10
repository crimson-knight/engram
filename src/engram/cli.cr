require "option_parser"
require "process"
require "socket"
require "uri"
require "json"
require "./version"
require "./memory_file"
require "./store"
require "./sync"
require "./embedder"
require "./search"
require "./mcp_server"
require "./hooks"

module Engram
  # Raised for problems in the environment engram runs in — no `.git` found,
  # sqlite built without FTS5, an unwritable cache directory. These map to
  # exit code 2 (see docs/SPEC.md's exit-code table); everything else that's
  # a user/data mistake (bad frontmatter, duplicate ids, bad config) is 1.
  class EnvironmentError < Exception
  end

  # The `engram` executable: subcommand dispatch, option parsing, and all
  # user-facing output. Every other file under `src/engram/` is a library;
  # this is the only place that touches STDIN/STDOUT/STDERR/ARGV/exit codes.
  class Cli
    MEMORIES_SUBDIR = File.join(".agents", "memories")
    CONFIG_FILE     = File.join(".agents", "engram.yml")

    # Runs engram with *argv* and returns the process exit code (0/1/2 per docs/SPEC.md).
    def self.run(argv : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR) : Int32
      new(stdout, stderr).run(argv)
    end

    # Builds a CLI instance writing normal output to *stdout* and errors/warnings to *stderr*.
    def initialize(@stdout : IO, @stderr : IO)
    end

    # Dispatches *argv*'s first element as a subcommand and returns the resulting exit code.
    def run(argv : Array(String)) : Int32
      command = argv.first?
      rest = argv.size > 1 ? argv[1..] : [] of String

      return print_usage if command.nil? || command == "-h" || command == "--help"

      begin
        case command
        when "init"                 then cmd_init(rest)
        when "new"                  then cmd_new(rest)
        when "sync"                 then cmd_sync(rest)
        when "search"               then cmd_search(rest)
        when "recent"               then cmd_recent(rest)
        when "show"                 then cmd_show(rest)
        when "mcp"                  then cmd_mcp(rest)
        when "hook"                 then cmd_hook(rest)
        when "doctor"               then cmd_doctor(rest)
        when "version", "--version" then cmd_version
        else
          @stderr.puts "engram: unknown command '#{command}' (see `engram --help`)"
          1
        end
      rescue ex : EnvironmentError
        @stderr.puts "engram: #{ex.message}"
        2
      rescue ex : OptionParser::Exception
        @stderr.puts "engram: #{ex.message}"
        1
      rescue ex : DuplicateIdError | ParseError | EmbedderConfigError | MemoryNotFoundError | ArgumentError
        @stderr.puts "engram: #{ex.message}"
        1
      rescue ex : Exception
        @stderr.puts "engram: #{ex.message}"
        2
      end
    end

    # Prints top-level usage and returns exit code 0.
    private def print_usage : Int32
      @stdout.puts <<-USAGE
        engram #{Engram::VERSION} — branch-scoped memory for coding agents

        Usage: engram <command> [options]

        Commands:
          init                           Create .agents/memories/, a config stub, and run the first sync
          new "<title>" [options]        Scaffold a new memory migration file
          sync [--verbose] [--quiet]     Reconcile the DB cache against .agents/memories/
          search <query> [options]       FTS5 bm25 + recency (+ optional embeddings) ranked search
          recent [options]               Newest-first active memories
          show <id> [--json]             Full body and metadata for one memory
          mcp                            Run the stdio MCP server
          hook install|uninstall         Manage the post-checkout/post-merge/post-rewrite git hooks
          doctor                         Check FTS5, hook state, embedder reachability, DB integrity
          version                        Print the engram version

        Run `engram <command> --help` for command-specific options.
        USAGE
      0
    end

    # `engram init`: creates .agents/memories/, a commented-out config stub, a
    # .gitignore note, and runs the first sync.
    private def cmd_init(args : Array(String)) : Int32
      help_requested = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: engram init"
        p.on("-h", "--help", "Show this help") { @stdout.puts p; help_requested = true }
      end
      parser.parse(args)
      return 0 if help_requested

      repo_root = self.class.find_repo_root(Dir.current)
      memories_dir = self.class.memories_dir_for(repo_root)
      created_memories_dir = !Dir.exists?(memories_dir)
      Dir.mkdir_p(memories_dir)

      config_path = File.join(repo_root, CONFIG_FILE)
      wrote_config_stub = self.class.ensure_config_stub(config_path)
      noted_gitignore = self.class.ensure_gitignore_note(repo_root)

      db_path = self.class.db_path_for(repo_root)
      embedder = self.class.load_embedder(repo_root)
      store = Store.new(db_path)
      result = begin
        r = Sync.run(memories_dir, store, embedder)
        self.class.record_sync_meta(store, embedder)
        r
      ensure
        store.close
      end

      @stdout.puts "engram: created #{memories_dir}" if created_memories_dir
      @stdout.puts "engram: wrote config stub #{config_path}" if wrote_config_stub
      @stdout.puts "engram: noted the .git/engram.db cache in #{File.join(repo_root, ".gitignore")}" if noted_gitignore
      @stdout.puts result.summary
      0
    end

    # `engram new "<title>" [--topics a,b] [--supersedes id,...]`: scaffolds a migration file.
    private def cmd_new(args : Array(String)) : Int32
      topics = [] of String
      supersedes = [] of Int64
      help_requested = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: engram new \"<title>\" [--topics a,b] [--supersedes id,...]"
        p.on("--topics LIST", "Comma-separated topics") { |v| topics = self.class.split_csv(v) }
        p.on("--supersedes LIST", "Comma-separated ids this memory replaces") { |v| supersedes = self.class.split_csv(v).map(&.to_i64) }
        p.on("-h", "--help", "Show this help") { @stdout.puts p; help_requested = true }
      end
      parser.parse(args)
      return 0 if help_requested

      title = args.join(" ").strip
      if title.empty?
        @stderr.puts "engram: new requires a title"
        return 1
      end

      repo_root = self.class.find_repo_root(Dir.current)
      memories_dir = self.class.memories_dir_for(repo_root)
      Dir.mkdir_p(memories_dir) unless Dir.exists?(memories_dir)

      slug = MemoryFile.slugify(title)
      # Claim the id and publish the file in one atomic step (see
      # `MemoryFile.claim_and_write`): two `engram new`/`remember` calls racing
      # in the same wall-clock second get distinct ids instead of silently
      # truncating each other's file.
      _, path = MemoryFile.claim_and_write(memories_dir, slug) do |candidate_id|
        MemoryFile.scaffold(candidate_id, title, topics, supersedes, ENV["USER"]?)
      end
      @stdout.puts path

      if STDIN.tty? && STDOUT.tty? && (editor = ENV["EDITOR"]?)
        Process.run(editor, [path],
          input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      end
      0
    end

    # `engram sync [--verbose] [--quiet]`: reconciles the DB cache against the working tree.
    private def cmd_sync(args : Array(String)) : Int32
      verbose = false
      quiet = false
      help_requested = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: engram sync [options]"
        p.on("--verbose", "Print each applied/rolled-back/updated id") { verbose = true }
        p.on("--quiet", "Suppress the summary line (used by git hooks)") { quiet = true }
        p.on("-h", "--help", "Show this help") { @stdout.puts p; help_requested = true }
      end
      parser.parse(args)
      return 0 if help_requested

      repo_root = self.class.find_repo_root(Dir.current)
      memories_dir = self.class.memories_dir_for(repo_root)
      db_path = self.class.db_path_for(repo_root)
      embedder = self.class.load_embedder(repo_root)

      store = Store.new(db_path)
      result = begin
        r = Sync.run(memories_dir, store, embedder)
        self.class.record_sync_meta(store, embedder)
        r
      ensure
        store.close
      end

      unless quiet
        @stdout.puts result.summary
        if verbose
          @stdout.puts "  applied: #{result.applied.join(", ")}" unless result.applied.empty?
          @stdout.puts "  rolled back: #{result.rolled_back.join(", ")}" unless result.rolled_back.empty?
          @stdout.puts "  updated: #{result.updated.join(", ")}" unless result.updated.empty?
        end
      end
      0
    end

    # `engram search <query> [--topic t] [--limit n] [--all] [--json]`.
    private def cmd_search(args : Array(String)) : Int32
      topic = nil.as(String?)
      limit = 10
      all = false
      json = false
      help_requested = false
      parser = OptionParser.new do |p|
        p.banner = <<-BANNER
          Usage: engram search <query> [options]

          Ranks matches by FTS5 bm25 blended with a recency boost:
            score = bm25(memories_fts) - 1.0 * (id - oldest) / (newest - oldest)
          When an embedder is configured, cosine similarity over stored
          embeddings is blended in via Reciprocal Rank Fusion (k=60).

          A query word that begins with '-' is still read as query text, not
          an unknown option. Use `--` to mark, explicitly, where options end
          and the (rest of the) query begins.
          BANNER
        p.on("--topic TOPIC", "Restrict to this topic") { |t| topic = t }
        p.on("--limit N", "Max results (default 10)") { |n| limit = n.to_i }
        p.on("--all", "Include superseded memories") { all = true }
        p.on("--json", "Machine-readable JSON output") { json = true }
        p.on("-h", "--help", "Show this help") { @stdout.puts p; help_requested = true }
      end
      option_args, positional_args = self.class.split_positional_args(args, ["--topic", "--limit"], ["--all", "--json", "-h", "--help"])
      parser.parse(option_args)
      return 0 if help_requested

      query = positional_args.join(" ")
      if query.empty?
        @stderr.puts "engram: search requires a query"
        return 1
      end

      repo_root = self.class.find_repo_root(Dir.current)
      db_path = self.class.db_path_for(repo_root)
      self.class.ensure_schema(db_path)
      embedder_proc = self.class.search_embedder_proc(repo_root)
      search = Search.new(db_path, embedder: embedder_proc)
      results = begin
        search.search(query, topic: topic, limit: limit, include_superseded: all)
      ensure
        search.close
      end

      print_results(results, json)
      0
    end

    # `engram recent [--topic t] [--limit n] [--json]`: newest-first active memories.
    private def cmd_recent(args : Array(String)) : Int32
      topic = nil.as(String?)
      limit = 10
      json = false
      help_requested = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: engram recent [options]"
        p.on("--topic TOPIC", "Restrict to this topic") { |t| topic = t }
        p.on("--limit N", "Max results (default 10)") { |n| limit = n.to_i }
        p.on("--json", "Machine-readable JSON output") { json = true }
        p.on("-h", "--help", "Show this help") { @stdout.puts p; help_requested = true }
      end
      parser.parse(args)
      return 0 if help_requested

      repo_root = self.class.find_repo_root(Dir.current)
      db_path = self.class.db_path_for(repo_root)
      self.class.ensure_schema(db_path)
      search = Search.new(db_path)
      results = begin
        search.recent(topic: topic, limit: limit)
      ensure
        search.close
      end

      print_results(results, json)
      0
    end

    # `engram show <id> [--json]`: full body and metadata for one memory.
    private def cmd_show(args : Array(String)) : Int32
      json = false
      help_requested = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: engram show <id> [--json]"
        p.on("--json", "Machine-readable JSON output") { json = true }
        p.on("-h", "--help", "Show this help") { @stdout.puts p; help_requested = true }
      end
      option_args, positional_args = self.class.split_positional_args(args, [] of String, ["--json", "-h", "--help"])
      parser.parse(option_args)
      return 0 if help_requested

      id_arg = positional_args.first?
      unless id_arg
        @stderr.puts "engram: show requires a memory id"
        return 1
      end
      id = id_arg.to_i64?
      unless id
        @stderr.puts "engram: '#{id_arg}' is not a valid memory id"
        return 1
      end

      repo_root = self.class.find_repo_root(Dir.current)
      db_path = self.class.db_path_for(repo_root)
      store = Store.new(db_path)
      record = begin
        store.get(id)
      ensure
        store.close
      end

      unless record
        @stderr.puts "engram: no memory with id #{id}"
        return 1
      end

      if json
        payload = {
          id: record.id, slug: record.slug, title: record.title, topics: record.topics,
          author: record.author, body: record.body, supersedes: record.supersedes,
          superseded_by: record.superseded_by, file_path: record.file_path, applied_at: record.applied_at,
        }
        @stdout.puts payload.to_json
      else
        @stdout.puts "##{record.id} #{record.title}"
        @stdout.puts "topics: #{record.topics.join(", ")}" unless record.topics.empty?
        @stdout.puts "author: #{record.author}" if record.author
        @stdout.puts "superseded by: ##{record.superseded_by}" if record.superseded_by
        @stdout.puts ""
        @stdout.puts record.body
      end
      0
    end

    # `engram mcp`: runs the stdio MCP server wired to the real Store/Search/Sync.
    private def cmd_mcp(args : Array(String)) : Int32
      repo_root = self.class.find_repo_root(Dir.current)
      memories_dir = self.class.memories_dir_for(repo_root)
      db_path = self.class.db_path_for(repo_root)
      embedder = self.class.load_embedder(repo_root)

      store = Store.new(db_path)
      search_embedder = self.class.search_embedder_proc(repo_root)
      search = Search.new(db_path, embedder: search_embedder)

      begin
        # Fresh recall the moment the server starts, mirroring the hooks'
        # auto-sync-on-checkout behavior for an agent that just connected.
        Sync.run(memories_dir, store, embedder)
        self.class.record_sync_meta(store, embedder)

        search_memories = ->(query : String, topic : String?, limit : Int32, include_superseded : Bool) do
          search.search(query, topic: topic, limit: limit, include_superseded: include_superseded).map do |r|
            MemoryHit.new(id: r.id, title: r.title, topics: r.topics, snippet: r.snippet, score: r.score)
          end
        end

        recent_memories = ->(topic : String?, limit : Int32) do
          search.recent(topic: topic, limit: limit).map do |r|
            MemoryHit.new(id: r.id, title: r.title, topics: r.topics, snippet: r.snippet, score: r.score)
          end
        end

        run_sync = -> do
          Sync.run(memories_dir, store, embedder)
          self.class.record_sync_meta(store, embedder)
          nil
        end

        server = McpServer.new(
          input: STDIN, output: STDOUT, store: store, memories_dir: memories_dir, db_path: db_path,
          search_memories: search_memories, recent_memories: recent_memories, run_sync: run_sync,
        )
        server.run
      ensure
        search.close
        store.close
      end
      0
    end

    # `engram hook install|uninstall`.
    private def cmd_hook(args : Array(String)) : Int32
      sub = args.first?
      unless sub && (sub == "install" || sub == "uninstall")
        @stderr.puts "engram: usage: engram hook install|uninstall"
        return 1
      end

      repo_root = self.class.find_repo_root(Dir.current)
      hooks_dir = self.class.hooks_dir_for(repo_root)

      if sub == "install"
        engram_path = Hooks.resolve_engram_path
        installed = Hooks.install(hooks_dir, engram_path)
        if installed.empty?
          @stdout.puts "engram: hooks already installed"
        else
          @stdout.puts "engram: installed hooks: #{installed.join(", ")} (binary: #{engram_path})"
        end
      else
        removed = Hooks.uninstall(hooks_dir)
        if removed.empty?
          @stdout.puts "engram: no engram hooks were installed"
        else
          @stdout.puts "engram: removed engram hooks: #{removed.join(", ")}"
        end
      end
      0
    end

    # `engram doctor`: checks FTS5, memories dir, hook state, embedder reachability, DB integrity.
    private def cmd_doctor(args : Array(String)) : Int32
      help_requested = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: engram doctor"
        p.on("-h", "--help", "Show this help") { @stdout.puts p; help_requested = true }
      end
      parser.parse(args)
      return 0 if help_requested

      repo_root = self.class.find_repo_root(Dir.current)
      db_path = self.class.db_path_for(repo_root)
      memories_dir = self.class.memories_dir_for(repo_root)

      ok = true
      environment_problem = false

      if self.class.fts5_available?
        @stdout.puts "[ok] sqlite FTS5 available"
      else
        @stdout.puts "[fail] sqlite FTS5 is not available in this sqlite build"
        ok = false
        environment_problem = true
      end

      if Dir.exists?(memories_dir)
        @stdout.puts "[ok] #{memories_dir} exists"
      else
        @stdout.puts "[warn] #{memories_dir} does not exist yet (run `engram init`)"
      end

      hooks_dir = begin
        self.class.hooks_dir_for(repo_root)
      rescue ex : EnvironmentError
        @stdout.puts "[fail] #{ex.message}"
        ok = false
        environment_problem = true
        nil
      end

      if hooks_dir
        hooks_installed = self.class.hooks_installed(hooks_dir)
        if hooks_installed.size == Hooks::HOOK_NAMES.size
          stale = self.class.hooks_with_missing_binary(hooks_dir, hooks_installed)
          if stale.empty?
            @stdout.puts "[ok] git hooks installed (#{hooks_installed.join(", ")})"
          else
            @stdout.puts "[warn] git hooks installed but the baked-in engram binary no longer exists for: " \
                         "#{stale.join(", ")} (it was moved, rebuilt, or uninstalled since `engram hook install` " \
                         "ran; re-run `engram hook install` from the binary you want hooks to use)"
          end
        elsif hooks_installed.empty?
          @stdout.puts "[warn] git hooks not installed (run `engram hook install`)"
        else
          @stdout.puts "[warn] git hooks partially installed (#{hooks_installed.join(", ")}; run `engram hook install`)"
        end
      end

      config_path = File.join(repo_root, CONFIG_FILE)
      config_failed = false
      embedder_config = begin
        EmbedderConfig.load(config_path)
      rescue ex : EmbedderConfigError
        @stdout.puts "[fail] #{ex.message}"
        ok = false
        config_failed = true
        nil
      end

      if config_failed
        # Already reported as a [fail] line above; nothing more to print.
      elsif embedder_config.nil?
        @stdout.puts "[ok] no embedder configured (FTS5-only search)"
      elsif self.class.embedder_reachable?(embedder_config)
        @stdout.puts "[ok] embedder reachable at #{embedder_config.url}"
      else
        @stdout.puts "[warn] embedder configured at #{embedder_config.url} but unreachable"
      end

      if self.class.db_integrity_ok?(db_path)
        @stdout.puts "[ok] database integrity check passed"
      else
        @stdout.puts "[fail] database integrity check failed at #{db_path}"
        ok = false
        environment_problem = true
      end

      return 2 if environment_problem
      return 1 unless ok
      0
    end

    # `engram version`.
    private def cmd_version : Int32
      @stdout.puts "engram #{Engram::VERSION}"
      0
    end

    # Renders search/recent results either as JSON (stable machine shape) or as plain lines.
    private def print_results(results : Array(SearchResult), json : Bool) : Nil
      if json
        @stdout.puts results.to_json
      elsif results.empty?
        @stdout.puts "No memories found."
      else
        results.each do |r|
          @stdout.puts "##{r.id}  #{r.title}  [#{r.topics.join(", ")}]  score=#{r.score.round(4)}"
          @stdout.puts "    #{r.snippet}"
        end
      end
    end

    # Walks up from *start* looking for a `.git` entry (directory or worktree
    # pointer file); the directory containing it is the repo root. Raises
    # Engram::EnvironmentError if none is found — engram's per-clone cache
    # lives under `.git/`, so it has nowhere to go outside a git repo.
    def self.find_repo_root(start : String) : String
      dir = File.expand_path(start)
      loop do
        return dir if File.exists?(File.join(dir, ".git"))
        parent = File.dirname(dir)
        raise EnvironmentError.new("not inside a git repository (no .git found above #{start})") if parent == dir
        dir = parent
      end
    end

    # `.agents/memories` under *repo_root*.
    def self.memories_dir_for(repo_root : String) : String
      File.join(repo_root, MEMORIES_SUBDIR)
    end

    # The real git directory for *repo_root*'s `.git` entry: itself if a
    # directory, or the target of a worktree/submodule `gitdir:` pointer file.
    # In a linked worktree this is the *private* per-worktree gitdir (e.g.
    # `.git/worktrees/<name>`) — exactly right for `db_path_for`'s per-clone
    # cache, which is deliberately worktree-private, but wrong for anything
    # that needs git's actual hooks directory. Use `hooks_dir_for` for that.
    def self.git_dir_for(repo_root : String) : String
      entry = File.join(repo_root, ".git")
      return entry if Dir.exists?(entry)

      contents = File.read(entry).strip
      match = /\Agitdir:\s*(.+)\z/.match(contents)
      raise EnvironmentError.new("malformed .git file at #{entry}") unless match
      pointer = match[1]
      pointer.starts_with?('/') ? pointer : File.expand_path(pointer, repo_root)
    end

    # The per-clone SQLite cache path: `<git dir>/engram.db`.
    def self.db_path_for(repo_root : String) : String
      File.join(git_dir_for(repo_root), "engram.db")
    end

    # Resolves *repo_root*'s effective hooks directory the same way git itself
    # resolves it when deciding whether to run a hook: by shelling out to
    # `git rev-parse --path-format=absolute --git-path hooks`. This — not
    # `git_dir_for` plus a manually-joined "hooks" — honors `core.hooksPath`
    # (which can point anywhere, under any name) and, in a linked worktree,
    # resolves to the *shared* common-dir hooks rather than the worktree's own
    # private gitdir. A hook installed anywhere else is silently never run by
    # git, so every path that installs or checks hooks must go through this.
    def self.hooks_dir_for(repo_root : String) : String
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run("git", ["-C", repo_root, "rev-parse", "--path-format=absolute", "--git-path", "hooks"],
        output: stdout, error: stderr)
      unless status.success?
        raise EnvironmentError.new("could not resolve git's hooks directory: #{stderr.to_s.strip}")
      end
      stdout.to_s.strip
    end

    # Guarantees the sqlite schema exists at *db_path* before a read-only command (`search`,
    # `recent`) opens its own `Search` connection — `Search` never creates tables itself, only
    # `Store` does. On a fresh repo where `init`/`sync` never ran, this keeps first-run
    # `search`/`recent` a clean "No memories found." (exit 0) instead of leaking sqlite's raw
    # "no such table: memories" as an uncaught exception (exit 2).
    def self.ensure_schema(db_path : String) : Nil
      Store.new(db_path).close
    end

    # Loads `.agents/engram.yml`'s embedder config (if any) and wraps it in a real HTTP-backed Embedder.
    def self.load_embedder(repo_root : String) : Embedder?
      config = EmbedderConfig.load(File.join(repo_root, CONFIG_FILE))
      config ? Embedder.new(config) : nil
    end

    # A one-shot query-embedding proc for `Search`, or nil when no embedder is configured.
    # Reuses `Embedder`'s own HTTP transport; `Search` already swallows any exception it raises.
    def self.search_embedder_proc(repo_root : String) : Search::Embedder?
      config = EmbedderConfig.load(File.join(repo_root, CONFIG_FILE))
      return nil unless config
      ->(text : String) { Embedder.http_transport(config, text) }
    end

    # Records embedder-on/off and last-sync-time in `engram_meta` after a sync, so
    # `memory_status` (MCP) and `doctor` can report real state instead of guessing.
    def self.record_sync_meta(store : Store, embedder : Embedder?) : Nil
      store.set_meta("embedder_enabled", embedder ? "true" : "false")
      store.set_meta("last_sync_at", Time.utc.to_rfc3339)
    end

    # Splits a `--topics a,b` / `--supersedes 1,2` style comma list into trimmed, non-empty parts.
    def self.split_csv(value : String) : Array(String)
      value.split(',').map(&.strip).reject(&.empty?)
    end

    # Splits *args* into (option tokens, positional tokens) for commands whose positional text
    # (a search query, a show id) must be taken literally even when it begins with '-' — a bare
    # OptionParser would otherwise reject it as an unknown flag. *valued_flags* consume the
    # following token as their value; *boolean_flags* stand alone; anything else is positional,
    # including tokens that merely look like flags. A literal `--` ends flag scanning early:
    # every token after it is positional even if it exactly matches a flag name.
    def self.split_positional_args(args : Array(String), valued_flags : Array(String), boolean_flags : Array(String)) : {Array(String), Array(String)}
      options = [] of String
      positional = [] of String
      literal = false
      index = 0
      while index < args.size
        arg = args[index]
        if literal
          positional << arg
        elsif arg == "--"
          literal = true
        elsif valued_flags.includes?(arg)
          options << arg
          index += 1
          options << args[index] if index < args.size
        elsif boolean_flags.includes?(arg)
          options << arg
        else
          positional << arg
        end
        index += 1
      end
      {options, positional}
    end

    # Writes a fully-commented-out `.agents/engram.yml` stub if the file doesn't already exist; returns whether it was written.
    def self.ensure_config_stub(path : String) : Bool
      return false if File.exists?(path)
      stub = <<-YAML
        # engram embedder config (optional — omit this file, or this section, to
        # stay FTS5-only with zero setup). Uncomment and point at any
        # OpenAI-compatible /v1/embeddings endpoint (Ollama works, so does
        # OpenAI) to enable semantic search, blended in via Reciprocal Rank
        # Fusion alongside the default bm25+recency ranking.
        #
        # embedder:
        #   url: http://localhost:11434/v1/embeddings
        #   model: nomic-embed-text
        #   api_key_env: OPENAI_API_KEY
        YAML
      File.write(path, stub)
      true
    end

    # Appends an idempotent, marker-guarded note to *repo_root*/.gitignore explaining that
    # `.git/engram.db` never needs an entry (git never tracks `.git/` itself). Returns whether it was written.
    def self.ensure_gitignore_note(repo_root : String) : Bool
      path = File.join(repo_root, ".gitignore")
      existing = File.exists?(path) ? File.read(path) : ""
      return false if existing.includes?(Hooks::MARKER_START)

      note = String.build do |s|
        s << existing
        s << "\n" unless existing.empty? || existing.ends_with?("\n")
        s << "\n" unless existing.empty?
        s << Hooks::MARKER_START << '\n'
        s << "# engram's per-clone cache lives at .git/engram.db, inside .git/ which\n"
        s << "# git never tracks — nothing else needs to be ignored for engram.\n"
        s << Hooks::MARKER_END << '\n'
      end
      File.write(path, note)
      true
    end

    # True if this sqlite build supports FTS5 (creates a throwaway in-memory virtual table to check).
    def self.fts5_available? : Bool
      db = DB.open("sqlite3::memory:")
      db.exec("CREATE VIRTUAL TABLE probe USING fts5(x)")
      true
    rescue
      false
    ensure
      db.try(&.close)
    end

    # Which of the three managed hooks currently exist, are executable, and carry the
    # engram marker under the effective *hooks_dir* (from `hooks_dir_for` — never a
    # manually-joined `<git_dir>/hooks`). All three must hold: git silently skips a
    # non-executable hook, so a marker-only match would have `doctor` call a dead
    # hook file "installed" when it will never actually run.
    def self.hooks_installed(hooks_dir : String) : Array(String)
      Hooks::HOOK_NAMES.select do |name|
        path = File.join(hooks_dir, name)
        File.exists?(path) && executable?(path) && File.read(path).includes?(Hooks::MARKER_START)
      end
    end

    # Of *installed_names* (already confirmed present/executable/marker-carrying by
    # `hooks_installed`), which ones bake in an absolute engram path that no longer
    # exists on disk — a hook that looks "installed" but would actually fail to run
    # engram at all. Only checks paths `resolve_engram_path` would actually produce
    # (absolute, starting with "/"); the rare bare-command fallback (when the OS
    # can't report `Process.executable_path`) can't be verified this way and is left
    # alone rather than flagged as false-stale.
    def self.hooks_with_missing_binary(hooks_dir : String, installed_names : Array(String)) : Array(String)
      installed_names.select do |name|
        engram_path = Hooks.installed_engram_path(File.join(hooks_dir, name))
        engram_path && engram_path.starts_with?('/') && !File.exists?(engram_path)
      end
    end

    # True if *path* has any executable bit set (owner, group, or other).
    def self.executable?(path : String) : Bool
      (File.info(path).permissions.value & 0o111) != 0
    end

    # Best-effort TCP reachability check for *config*'s endpoint host:port (no request body sent).
    def self.embedder_reachable?(config : EmbedderConfig) : Bool
      uri = URI.parse(config.url)
      host = uri.host
      return false unless host
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      socket = TCPSocket.new(host, port, connect_timeout: 2.seconds)
      socket.close
      true
    rescue
      false
    end

    # `PRAGMA integrity_check` against *db_path*; true (nothing to check yet) if the file doesn't exist.
    def self.db_integrity_ok?(db_path : String) : Bool
      return true unless File.exists?(db_path)
      db = DB.open(Store.connection_uri(db_path))
      db.scalar("PRAGMA integrity_check").to_s == "ok"
    rescue
      false
    ensure
      db.try(&.close)
    end
  end
end
