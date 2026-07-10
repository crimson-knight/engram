require "json"
require "time"
require "./store"
require "./memory_file"

module Engram
  # One ranked or recent memory, as returned across the search/recent seam.
  #
  # `search.cr` is built in a parallel stage; rather than depend on its
  # concrete type, `McpServer` is constructed with plain Procs (see
  # `McpServer::SearchProc` / `McpServer::RecentProc`) that must return
  # `Array(MemoryHit)`. This struct IS the seam contract.
  record MemoryHit,
    id : Int64,
    title : String,
    topics : Array(String),
    snippet : String,
    score : Float64? = nil

  # Hand-rolled newline-delimited JSON-RPC 2.0 MCP server, driven over
  # injected IO so it can be exercised through `IO::Memory` pairs in specs
  # and wired to real stdio in production.
  #
  # Reads one JSON-RPC message per line from `input`; writes at most one
  # JSON-RPC response line per request to `output` (notifications get no
  # reply at all); EOF on `input` ends `#run` (there is no shutdown method).
  #
  # ## Seam: search and sync collaborators
  #
  # `search.cr` and `sync.cr` are built in a parallel stage. Rather than
  # reference their concrete types directly, this server takes three narrow
  # Procs plus the already-built `Store`:
  #
  #   * `search_memories : SearchProc` — `(query, topic, limit, include_superseded) -> Array(MemoryHit)`
  #   * `recent_memories : RecentProc` — `(topic, limit) -> Array(MemoryHit)`
  #   * `run_sync : RunSyncProc` — `() -> Nil`, a full re-sync (used by `remember`
  #     after writing a new migration file, so apply/rollback/supersedes-recompute
  #     stay the sole responsibility of `sync.cr`)
  #
  # `memory_status` reports embedder state and last-sync time by reading
  # `engram_meta` keys `"embedder_enabled"` and `"last_sync_at"` off the
  # `Store` — the assumption is that `sync.cr` writes those keys on every run.
  # This isn't spelled out in docs/SPEC.md and is called out again in this
  # builder's final report as the concrete contract the integrator must honor.
  class McpServer
    # Protocol versions this server understands, newest first.
    PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    # Static `tools/list` payload for the 5 tools this server exposes.
    TOOLS = JSON.parse(<<-JSON).as_a
      [
        {
          "name": "search_memories",
          "description": "Full-text + recency ranked search over active (non-superseded) memories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "query": {"type": "string", "description": "Search text, matched via FTS5 bm25 + recency."},
              "topic": {"type": "string", "description": "Restrict to memories tagged with this topic."},
              "limit": {"type": "integer", "description": "Max results to return (default 10)."},
              "include_superseded": {"type": "boolean", "description": "Include superseded memories (default false)."}
            },
            "required": ["query"]
          }
        },
        {
          "name": "recent_memories",
          "description": "Newest active memories, most recent first.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "topic": {"type": "string", "description": "Restrict to memories tagged with this topic."},
              "limit": {"type": "integer", "description": "Max results to return (default 10)."}
            },
            "required": []
          }
        },
        {
          "name": "get_memory",
          "description": "Full body and metadata for one memory by id.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "id": {"type": "integer", "description": "The memory's 14-digit migration id."}
            },
            "required": ["id"]
          }
        },
        {
          "name": "remember",
          "description": "Writes a new memory migration file under .agents/memories and applies it to the local cache. The agent MUST commit the resulting file afterwards or the memory is lost.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "title": {"type": "string"},
              "body": {"type": "string", "description": "Markdown body, conventionally Decision/Why/Rejected sections."},
              "topics": {"type": "array", "items": {"type": "string"}},
              "supersedes": {"type": "array", "items": {"type": "integer"}, "description": "IDs of older memories this one replaces."}
            },
            "required": ["title", "body"]
          }
        },
        {
          "name": "memory_status",
          "description": "Active/superseded memory counts, embedder state, DB path, and last sync time.",
          "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
          }
        }
      ]
      JSON

    # `(query, topic, limit, include_superseded) -> ranked Array(MemoryHit)`.
    alias SearchProc = Proc(String, String?, Int32, Bool, Array(MemoryHit))
    # `(topic, limit) -> newest-first Array(MemoryHit)`.
    alias RecentProc = Proc(String?, Int32, Array(MemoryHit))
    # Re-runs a full `engram sync` (apply/rollback/update) against the working tree.
    alias RunSyncProc = Proc(Nil)

    # Raised internally when an incoming line isn't a well-formed JSON-RPC request; always maps to -32700.
    class RequestFormatError < Exception
    end

    # An incoming line, parsed just enough to dispatch: the id (nil for notifications), whether an id was present at all, the method name, and raw params.
    record ParsedRequest, id : JSON::Any?, has_id : Bool, method : String, params : JSON::Any?

    # The protocol version this session negotiated in `initialize` (defaults to our newest before that happens).
    getter negotiated_version : String

    # Wires an MCP server against injected stdio and its collaborators; see the seam note on the class.
    def initialize(
      @input : IO,
      @output : IO,
      @store : Store,
      @memories_dir : String,
      @db_path : String,
      @search_memories : SearchProc,
      @recent_memories : RecentProc,
      @run_sync : RunSyncProc,
    )
      @negotiated_version = PROTOCOL_VERSIONS.first
      if fd = @output.as?(IO::FileDescriptor)
        fd.sync = true
      end
      if fd = @input.as?(IO::FileDescriptor)
        fd.sync = true
      end
    end

    # Reads and dispatches one JSON-RPC message per line until `input` hits EOF.
    def run : Nil
      loop do
        line = @input.gets
        break unless line
        trimmed = line.strip
        next if trimmed.empty?
        handle_line(trimmed)
      end
    end

    # Parses one line and dispatches it, writing a response unless it was a notification.
    private def handle_line(line : String) : Nil
      begin
        request = parse_request(line)
      rescue ex : Exception
        write_error(nil, -32700, "Parse error: #{ex.message}")
        return
      end

      begin
        case request.method
        when "initialize"
          handle_initialize(request.id, request.params)
        when "notifications/initialized"
          nil # notifications never get a reply
        when "ping"
          write_result(request.id, {} of String => JSON::Any)
        when "tools/list"
          write_result(request.id, {"tools" => TOOLS})
        when "tools/call"
          handle_tools_call(request.id, request.params)
        else
          write_error(request.id, -32601, "Method not found: #{request.method}") if request.has_id
        end
      rescue ex : Exception
        write_error(request.id, -32603, "Internal error: #{ex.message}") if request.has_id
      end
    end

    # Parses *line* into a `ParsedRequest`; raises `RequestFormatError` for anything that isn't a JSON object with a string `method`.
    private def parse_request(line : String) : ParsedRequest
      any = JSON.parse(line)
      obj = any.as_h? || raise RequestFormatError.new("expected a JSON object")
      has_id = obj.has_key?("id")
      id = has_id ? obj["id"] : nil
      method = obj["method"]?.try(&.as_s?) || raise RequestFormatError.new("missing or invalid 'method'")
      ParsedRequest.new(id: id, has_id: has_id, method: method, params: obj["params"]?)
    end

    # Negotiates the protocol version and replies with server info and capabilities.
    private def handle_initialize(id : JSON::Any?, params : JSON::Any?) : Nil
      requested = params.try(&.as_h?).try(&.["protocolVersion"]?).try(&.as_s?)
      @negotiated_version = negotiate_version(requested)

      result = {
        "protocolVersion" => @negotiated_version,
        "capabilities"    => {"tools" => {} of String => JSON::Any},
        "serverInfo"      => {"name" => "engram", "version" => Engram::VERSION},
      }
      write_result(id, result)
    end

    # Picks the version to speak: the client's exact version if we support it,
    # else the newest version we support that's <= the client's request,
    # else our oldest supported version as a last resort.
    private def negotiate_version(requested : String?) : String
      return PROTOCOL_VERSIONS.first unless requested
      PROTOCOL_VERSIONS.find { |v| v <= requested } || PROTOCOL_VERSIONS.last
    end

    # Dispatches a `tools/call` request to one of the 5 known tools.
    private def handle_tools_call(id : JSON::Any?, params : JSON::Any?) : Nil
      obj = params.try(&.as_h?) || {} of String => JSON::Any
      name = obj["name"]?.try(&.as_s?)
      arguments = obj["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      unless name
        write_tool_error(id, "tools/call requires a string 'name'")
        return
      end

      begin
        case name
        when "search_memories" then call_search_memories(id, arguments)
        when "recent_memories" then call_recent_memories(id, arguments)
        when "get_memory"      then call_get_memory(id, arguments)
        when "remember"        then call_remember(id, arguments)
        when "memory_status"   then call_memory_status(id, arguments)
        else
          write_tool_error(id, "unknown tool: #{name}")
        end
      rescue ex : ArgumentError
        write_tool_error(id, ex.message || "invalid arguments for tool '#{name}'")
      end
    end

    # `search_memories`: ranked results from the injected search collaborator.
    private def call_search_memories(id : JSON::Any?, args : Hash(String, JSON::Any)) : Nil
      query = args["query"]?.try(&.as_s?) || raise ArgumentError.new("search_memories requires a string 'query'")
      topic = args["topic"]?.try(&.as_s?)
      limit = args["limit"]?.try(&.as_i?) || 10
      include_superseded = args["include_superseded"]?.try(&.as_bool?) || false

      hits = @search_memories.call(query, topic, limit, include_superseded)
      text = hits.empty? ? "No memories matched #{query.inspect}." : "Found #{hits.size} memories matching #{query.inspect}:\n#{hit_lines(hits)}"
      write_tool_result(id, text, {"results" => hit_payloads(hits)})
    end

    # `recent_memories`: newest-first results from the injected recent collaborator.
    private def call_recent_memories(id : JSON::Any?, args : Hash(String, JSON::Any)) : Nil
      topic = args["topic"]?.try(&.as_s?)
      limit = args["limit"]?.try(&.as_i?) || 10

      hits = @recent_memories.call(topic, limit)
      text = hits.empty? ? "No memories found." : "#{hits.size} most recent memories:\n#{hit_lines(hits)}"
      write_tool_result(id, text, {"results" => hit_payloads(hits)})
    end

    # `get_memory`: full body and metadata for one id, read straight from the Store.
    private def call_get_memory(id : JSON::Any?, args : Hash(String, JSON::Any)) : Nil
      memory_id = args["id"]?.try(&.as_i64?) || raise ArgumentError.new("get_memory requires an integer 'id'")
      record = @store.get(memory_id) || raise ArgumentError.new("no memory with id #{memory_id}")

      text = "##{record.id} #{record.title}\n\n#{record.body}"
      structured = {
        "id" => record.id, "title" => record.title, "topics" => record.topics, "author" => record.author,
        "body" => record.body, "supersedes" => record.supersedes, "superseded_by" => record.superseded_by,
        "file_path" => record.file_path, "applied_at" => record.applied_at,
      }
      write_tool_result(id, text, structured)
    end

    # `remember`: scaffolds and writes a new migration file, applies it via `run_sync`, and reminds the caller to commit it.
    private def call_remember(id : JSON::Any?, args : Hash(String, JSON::Any)) : Nil
      title = args["title"]?.try(&.as_s?) || raise ArgumentError.new("remember requires a string 'title'")
      body = args["body"]?.try(&.as_s?) || raise ArgumentError.new("remember requires a string 'body'")
      topics = string_array(args["topics"]?, "topics")
      supersedes = int64_array(args["supersedes"]?, "supersedes")

      Dir.mkdir_p(@memories_dir) unless Dir.exists?(@memories_dir)
      memory_id = MemoryFile.next_id(@memories_dir)
      memory = MemoryFile.new(
        id: memory_id, slug: MemoryFile.slugify(title), title: title, topics: topics,
        supersedes: supersedes, author: nil, body: body, file_path: ""
      )
      path = File.join(@memories_dir, memory.filename)
      File.write(path, memory.serialize)
      @run_sync.call

      relative_path = MemoryFile.repo_relative_path(@memories_dir, path)
      text = <<-TEXT
        Remembered as ##{memory_id} (#{relative_path}).
        IMPORTANT: this migration file is on disk but not yet committed. Run
        `git add #{path}` and commit it now, or this memory disappears the
        next time the working tree is reset and never reaches any other clone.
        TEXT
      write_tool_result(id, text, {"id" => memory_id, "file_path" => relative_path})
    end

    # `memory_status`: counts plus embedder/last-sync state read from `engram_meta`.
    private def call_memory_status(id : JSON::Any?, args : Hash(String, JSON::Any)) : Nil
      counts = @store.counts
      embedder_on = @store.meta("embedder_enabled") == "true"
      last_sync = @store.meta("last_sync_at")

      text = "#{counts[:active]} active, #{counts[:superseded]} superseded memories. " \
             "Embedder #{embedder_on ? "on" : "off"}. DB at #{@db_path}. " \
             "#{last_sync ? "Last sync #{last_sync}." : "Never synced."}"
      structured = {
        "active" => counts[:active], "superseded" => counts[:superseded],
        "embedder_enabled" => embedder_on, "db_path" => @db_path, "last_sync_at" => last_sync,
      }
      write_tool_result(id, text, structured)
    end

    # Renders hits as "- #id title" lines for a tool's human-readable summary.
    private def hit_lines(hits : Array(MemoryHit)) : String
      hits.map { |h| "- ##{h.id} #{h.title}" }.join('\n')
    end

    # Renders hits as the structuredContent payload shared by search/recent.
    private def hit_payloads(hits : Array(MemoryHit))
      hits.map { |h| {"id" => h.id, "title" => h.title, "topics" => h.topics, "snippet" => h.snippet, "score" => h.score} }
    end

    # Reads *value* as an array of strings for *field*, defaulting to `[]` when absent; raises ArgumentError on the wrong shape.
    private def string_array(value : JSON::Any?, field : String) : Array(String)
      return [] of String unless value
      arr = value.as_a? || raise ArgumentError.new("'#{field}' must be an array")
      arr.map { |item| item.as_s? || raise ArgumentError.new("'#{field}' must contain only strings") }
    end

    # Reads *value* as an array of integers for *field*, defaulting to `[]` when absent; raises ArgumentError on the wrong shape.
    private def int64_array(value : JSON::Any?, field : String) : Array(Int64)
      return [] of Int64 unless value
      arr = value.as_a? || raise ArgumentError.new("'#{field}' must be an array")
      arr.map { |item| item.as_i64? || raise ArgumentError.new("'#{field}' must contain only integers") }
    end

    # Writes a successful tool result: human text plus the structured payload.
    private def write_tool_result(id : JSON::Any?, text : String, structured) : Nil
      write_result(id, {
        "content"           => [{"type" => "text", "text" => text}],
        "structuredContent" => structured,
      })
    end

    # Writes a tool-level failure (bad args, unknown tool, missing memory) as a normal JSON-RPC success whose result carries `isError: true`, so the calling agent sees the message.
    private def write_tool_error(id : JSON::Any?, message : String) : Nil
      write_result(id, {
        "content" => [{"type" => "text", "text" => message}],
        "isError" => true,
      })
    end

    # Writes a JSON-RPC success response for *id*.
    private def write_result(id : JSON::Any?, result) : Nil
      send({"jsonrpc" => "2.0", "id" => id, "result" => result})
    end

    # Writes a JSON-RPC protocol-level error response for *id* (or `null` for parse errors, which have no id).
    private def write_error(id : JSON::Any?, code : Int32, message : String) : Nil
      send({"jsonrpc" => "2.0", "id" => id, "error" => {"code" => code, "message" => message}})
    end

    # Serializes *payload* to one JSON line and flushes it to `output`.
    private def send(payload) : Nil
      @output.puts(payload.to_json)
      @output.flush
    end
  end
end
