require "./spec_helper"
require "../src/engram/mcp_server"

private def db_path(dir : String) : String
  File.join(dir, "engram.db")
end

private def memories_dir(dir : String) : String
  File.join(dir, ".agents", "memories")
end

private def no_op_search : Engram::McpServer::SearchProc
  ->(query : String, topic : String?, limit : Int32, include_superseded : Bool) { [] of Engram::MemoryHit }
end

private def no_op_recent : Engram::McpServer::RecentProc
  ->(topic : String?, limit : Int32) { [] of Engram::MemoryHit }
end

private def no_op_sync : Engram::McpServer::RunSyncProc
  -> { nil }
end

# Builds a server wired to *store*/*dir*, with sensible no-op collaborators
# unless the caller supplies real ones.
private def build_server(
  input : IO,
  output : IO,
  store : Engram::Store,
  dir : String,
  search_memories : Engram::McpServer::SearchProc = no_op_search,
  recent_memories : Engram::McpServer::RecentProc = no_op_recent,
  run_sync : Engram::McpServer::RunSyncProc = no_op_sync,
) : Engram::McpServer
  Engram::McpServer.new(
    input: input,
    output: output,
    store: store,
    memories_dir: memories_dir(dir),
    db_path: db_path(dir),
    search_memories: search_memories,
    recent_memories: recent_memories,
    run_sync: run_sync,
  )
end

# Runs a server wired to *store*/*dir* against newline-joined *requests*
# (each a raw JSON string) and returns the parsed JSON response lines
# actually written.
private def run_requests(store : Engram::Store, dir : String, requests : Array(String),
                         search_memories : Engram::McpServer::SearchProc = no_op_search,
                         recent_memories : Engram::McpServer::RecentProc = no_op_recent,
                         run_sync : Engram::McpServer::RunSyncProc = no_op_sync) : Array(JSON::Any)
  input = IO::Memory.new(requests.join('\n') + "\n")
  output = IO::Memory.new
  server = build_server(input, output, store, dir,
    search_memories: search_memories, recent_memories: recent_memories, run_sync: run_sync)
  server.run
  output.to_s.split('\n').reject(&.empty?).map { |line| JSON.parse(line) }
end

# Builds a JSON-RPC request line with the given *id*/*method*/*params*.
private def request_json(id : Int32, method : String, params : Hash(String, _)? = nil) : String
  hash = {} of String => JSON::Any
  hash["jsonrpc"] = JSON::Any.new("2.0")
  hash["id"] = JSON::Any.new(id)
  hash["method"] = JSON::Any.new(method)
  hash["params"] = JSON.parse(params.to_json) if params
  hash.to_json
end

# Builds a JSON-RPC notification line (no "id" key at all) for *method*/*params*.
private def notification_json(method : String, params : Hash(String, _)? = nil) : String
  hash = {} of String => JSON::Any
  hash["jsonrpc"] = JSON::Any.new("2.0")
  hash["method"] = JSON::Any.new(method)
  hash["params"] = JSON.parse(params.to_json) if params
  hash.to_json
end

describe Engram::McpServer do
  describe "initialize version negotiation" do
    it "echoes back the client's exact version when we support it" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "initialize", {"protocolVersion" => "2025-06-18"}),
        ])
        store.close

        responses[0]["result"]["protocolVersion"].as_s.should eq("2025-06-18")
      end
    end

    it "negotiates the newest supported version <= an older, non-exact client version" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "initialize", {"protocolVersion" => "2025-05-01"}),
        ])
        store.close

        # newest supported <= 2025-05-01 is 2025-03-26 (2025-06-18 is too new)
        responses[0]["result"]["protocolVersion"].as_s.should eq("2025-03-26")
      end
    end

    it "falls back to the oldest supported version for an unknown/older-than-all client version" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "initialize", {"protocolVersion" => "2020-01-01"}),
        ])
        store.close

        responses[0]["result"]["protocolVersion"].as_s.should eq("2024-11-05")
      end
    end

    it "reports serverInfo and tools capabilities" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "initialize", {"protocolVersion" => "2025-06-18"}),
        ])
        store.close

        responses[0]["result"]["serverInfo"]["name"].as_s.should eq("engram")
        responses[0]["result"]["capabilities"]["tools"].as_h.should_not be_nil
      end
    end
  end

  describe "notifications/initialized" do
    it "produces no response line" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          notification_json("notifications/initialized"),
        ])
        store.close

        responses.should be_empty
      end
    end

    it "does not block later requests in the same stream" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          notification_json("notifications/initialized"),
          request_json(1, "ping"),
        ])
        store.close

        responses.size.should eq(1)
        responses[0]["id"].as_i.should eq(1)
      end
    end
  end

  describe "ping" do
    it "responds with an empty result" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [request_json(7, "ping")])
        store.close

        responses[0]["id"].as_i.should eq(7)
        responses[0]["result"].as_h.should eq({} of String => JSON::Any)
      end
    end
  end

  describe "tools/list" do
    it "lists all 5 tools by name" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [request_json(1, "tools/list")])
        store.close

        names = responses[0]["result"]["tools"].as_a.map(&.["name"].as_s)
        names.should eq(["search_memories", "recent_memories", "get_memory", "remember", "memory_status"])
      end
    end
  end

  describe "unknown method" do
    it "replies -32601 when the request has an id" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [request_json(1, "totally/bogus")])
        store.close

        responses[0]["error"]["code"].as_i.should eq(-32601)
        responses[0]["id"].as_i.should eq(1)
      end
    end

    it "produces no response for an unknown method sent as a notification" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [notification_json("totally/bogus")])
        store.close

        responses.should be_empty
      end
    end
  end

  describe "parse error" do
    it "replies -32700 with a null id for invalid JSON" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        input = IO::Memory.new("{not valid json\n")
        output = IO::Memory.new
        server = build_server(input, output, store, dir)
        server.run
        store.close

        line = output.to_s.split('\n').reject(&.empty?).first
        parsed = JSON.parse(line)
        parsed["error"]["code"].as_i.should eq(-32700)
        parsed["id"].raw.should be_nil
      end
    end
  end

  describe "EOF shutdown" do
    it "returns cleanly from #run when input hits EOF, with no trailing garbage output" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        input = IO::Memory.new("")
        output = IO::Memory.new
        server = build_server(input, output, store, dir)
        server.run
        store.close

        output.to_s.should eq("")
      end
    end
  end

  describe "tools/call search_memories" do
    it "returns ranked hits from the injected search collaborator" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        fake_search = ->(query : String, topic : String?, limit : Int32, include_superseded : Bool) {
          [Engram::MemoryHit.new(id: 1_i64, title: "Chose SQLite", topics: ["storage"], snippet: "...sqlite...", score: -1.5)]
        }
        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "search_memories", "arguments" => {"query" => "sqlite"}}),
        ], search_memories: fake_search)
        store.close

        result = responses[0]["result"]
        result["isError"]?.should be_nil
        result["content"][0]["text"].as_s.should contain("Chose SQLite")
        results = result["structuredContent"]["results"].as_a
        results.size.should eq(1)
        results[0]["id"].as_i64.should eq(1_i64)
        results[0]["title"].as_s.should eq("Chose SQLite")
        results[0]["score"].as_f.should eq(-1.5)
      end
    end

    it "returns a tool error (not a protocol error) when 'query' is missing" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "search_memories", "arguments" => {} of String => String}),
        ])
        store.close

        responses[0]["result"]["isError"].as_bool.should be_true
        responses[0]["error"]?.should be_nil
      end
    end
  end

  describe "tools/call recent_memories" do
    it "returns hits from the injected recent collaborator" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        fake_recent = ->(topic : String?, limit : Int32) {
          [Engram::MemoryHit.new(id: 2_i64, title: "Recent one", topics: [] of String, snippet: "body")]
        }
        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "recent_memories", "arguments" => {} of String => String}),
        ], recent_memories: fake_recent)
        store.close

        result = responses[0]["result"]
        results = result["structuredContent"]["results"].as_a
        results.size.should eq(1)
        results[0]["title"].as_s.should eq("Recent one")
      end
    end
  end

  describe "tools/call get_memory" do
    it "returns the full body and metadata for an existing memory" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(
          id: 20260710153000_i64, slug: "chose-sqlite", title: "Chose SQLite",
          topics: ["storage", "architecture"], author: "seth", body: "the full body",
          supersedes: [] of Int64, file_path: ".agents/memories/20260710153000_chose-sqlite.md"
        )

        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "get_memory", "arguments" => {"id" => 20260710153000_i64}}),
        ])
        store.close

        structured = responses[0]["result"]["structuredContent"]
        structured["id"].as_i64.should eq(20260710153000_i64)
        structured["title"].as_s.should eq("Chose SQLite")
        structured["topics"].as_a.map(&.as_s).should eq(["storage", "architecture"])
        structured["body"].as_s.should eq("the full body")
      end
    end

    it "returns a tool error when the id doesn't exist" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "get_memory", "arguments" => {"id" => 999_i64}}),
        ])
        store.close

        responses[0]["result"]["isError"].as_bool.should be_true
      end
    end
  end

  describe "tools/call remember" do
    it "writes a migration file, applies it via run_sync, and reminds the caller to commit" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        sync_calls = [] of Int32
        fake_sync = -> { sync_calls << 1; nil }

        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {
            "name"      => "remember",
            "arguments" => {
              "title"      => "A new decision",
              "body"       => "**Decision:** do the thing.",
              "topics"     => ["testing"],
              "supersedes" => [] of Int64,
            },
          }),
        ], run_sync: fake_sync)
        store.close

        sync_calls.size.should eq(1)

        result = responses[0]["result"]
        result["content"][0]["text"].as_s.should contain("commit")
        file_path = result["structuredContent"]["file_path"].as_s
        file_path.should start_with(".agents/memories/")
        file_path.should_not start_with("/")

        absolute_path = File.join(dir, file_path)
        File.exists?(absolute_path).should be_true

        written = File.read(absolute_path)
        written.should contain("title: A new decision")
        written.should contain("**Decision:** do the thing.")

        id = result["structuredContent"]["id"].as_i64
        File.basename(file_path).should eq("#{id}_a-new-decision.md")
      end
    end

    it "mints distinct ids for repeated remember calls in the same MCP session, even within the same second" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        requests = (1..6).map do |n|
          request_json(n, "tools/call", {
            "name"      => "remember",
            "arguments" => {"title" => "Decision number #{n}", "body" => "body #{n}"},
          })
        end

        responses = run_requests(store, dir, requests)
        store.close

        ids = responses.map { |r| r["result"]["structuredContent"]["id"].as_i64 }
        ids.uniq.size.should eq(6)

        ids.each do |memory_id|
          file_path = responses.find { |r| r["result"]["structuredContent"]["id"].as_i64 == memory_id }
            .not_nil!["result"]["structuredContent"]["file_path"].as_s
          File.exists?(File.join(dir, file_path)).should be_true
        end
      end
    end
  end

  describe "tools/call memory_status" do
    it "reports counts, embedder state, db path, and last sync from the store" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil, body: "a", supersedes: [] of Int64, file_path: "a.md")
        store.insert_memory(id: 2_i64, slug: "b", title: "B", topics: [] of String, author: nil, body: "b", supersedes: [1_i64], file_path: "b.md")
        store.set_superseded_by(1_i64, 2_i64)
        store.set_meta("embedder_enabled", "true")
        store.set_meta("last_sync_at", "2026-07-10T15:30:00Z")

        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "memory_status", "arguments" => {} of String => String}),
        ])
        store.close

        structured = responses[0]["result"]["structuredContent"]
        structured["active"].as_i.should eq(1)
        structured["superseded"].as_i.should eq(1)
        structured["embedder_enabled"].as_bool.should be_true
        structured["db_path"].as_s.should eq(db_path(dir))
        structured["last_sync_at"].as_s.should eq("2026-07-10T15:30:00Z")
      end
    end

    it "reports embedder off and never-synced when meta is unset" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "memory_status", "arguments" => {} of String => String}),
        ])
        store.close

        structured = responses[0]["result"]["structuredContent"]
        structured["embedder_enabled"].as_bool.should be_false
        structured["last_sync_at"].raw.should be_nil
      end
    end
  end

  describe "tools/call with an unknown tool name" do
    it "returns isError instead of a protocol-level error" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        responses = run_requests(store, dir, [
          request_json(1, "tools/call", {"name" => "not_a_real_tool", "arguments" => {} of String => String}),
        ])
        store.close

        responses[0]["error"]?.should be_nil
        responses[0]["result"]["isError"].as_bool.should be_true
      end
    end
  end
end
