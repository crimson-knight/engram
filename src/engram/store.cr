require "db"
require "sqlite3"
require "uri"

module Engram
  # Raised when `update_memory` is called for an id that isn't in the store.
  class MemoryNotFoundError < Exception
    # Builds a message naming the missing id.
    def initialize(id : Int64)
      super("no memory with id #{id} in the store")
    end
  end

  # A single memory row read back from the store, with csv columns already split.
  struct MemoryRecord
    getter id : Int64
    getter slug : String
    getter title : String
    getter topics : Array(String)
    getter author : String?
    getter body : String
    getter supersedes : Array(Int64)
    getter superseded_by : Int64?
    getter embedding : Bytes?
    getter file_path : String
    getter applied_at : String

    # Builds a memory record from already-decoded fields.
    def initialize(@id : Int64, @slug : String, @title : String, @topics : Array(String), @author : String?,
                   @body : String, @supersedes : Array(Int64), @superseded_by : Int64?, @embedding : Bytes?,
                   @file_path : String, @applied_at : String)
    end
  end

  # Owns the per-clone SQLite cache (normally `.git/engram.db`): schema
  # creation and every read/write needed to keep it in sync with the memory
  # migration files on disk. The database is a disposable cache — deleting it
  # and running `sync` again fully rebuilds it from the working tree.
  class Store
    # Busy-wait window handed to sqlite's own retry loop (via `PRAGMA busy_timeout`) before
    # a lock contention gives up and raises "database is locked" — long enough to ride out
    # another local process's (a post-checkout hook, a running `engram mcp` server) brief
    # write, short enough that a truly stuck lock still fails within one interactive command.
    BUSY_TIMEOUT_MS = 5000

    @db : DB::Database
    # Set for the duration of a `#transaction` block so every CRUD method below routes its
    # queries through the transaction's own connection instead of `@db` — `@db.exec` and
    # friends each check out *a* pooled connection, which (with more than one connection in
    # play) need not be the one the transaction actually began on, silently defeating the
    # transaction's atomicity. See `#executor`.
    @conn : DB::Connection? = nil

    # Opens (creating if needed) the sqlite database at *db_path*, ensures its schema exists,
    # and self-heals a corrupted cache file: since `.git/engram.db` is a disposable cache of
    # the migration files in `.agents/memories/`, a corrupted or truncated file is deleted and
    # replaced with a fresh empty database here, and the next `sync` fully repopulates it. A
    # permission or lock failure opening the file is a different, non-disposable problem and
    # always propagates — only a genuine corruption signature triggers a rebuild. The actual
    # open-and-repair logic lives in `self.open_and_repair` (a class method working on locals,
    # not ivars) so this assignment stays a single, unconditional statement: Crystal's
    # definite-assignment check for instance variables treats anything assigned inside a
    # begin/rescue as potentially skipped unless it's *also* assigned in the rescue branch,
    # which would otherwise force `@db`/`@db_path` through every retry path here too.
    def initialize(db_path : String)
      @db_path = db_path
      dir = File.dirname(@db_path)
      Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
      @db = self.class.open_and_repair(@db_path)
    end

    # Opens *path*, ensures its schema exists, and repairs a corrupted (but readable) cache
    # file by deleting and recreating it — retried exactly once, so a second failure is a
    # real, non-corruption error and propagates. A permission or lock failure opening the
    # file surfaces as `DB::ConnectionRefused` (not `SQLite3::Exception`) and always
    # propagates untouched, never mistaken for disposable-cache corruption.
    def self.open_and_repair(path : String) : DB::Database
      db = DB.open(connection_uri(path))
      db = rebuild_database(path, db) if corrupted_connection?(db)
      create_schema(db)
      db
    rescue ex : SQLite3::Exception
      # Belt-and-suspenders: corruption that `PRAGMA integrity_check` didn't catch (it only
      # walks existing structures) but that the schema statements themselves surface. `db` is
      # always already assigned here in practice — this driver only ever raises a bare
      # `SQLite3::Exception` (never wrapped in `DB::ConnectionRefused`) from statements that
      # run after `DB.open` already succeeded — `.not_nil!` documents that, not works around it.
      raise ex unless corruption_error?(ex)
      db = rebuild_database(path, db.not_nil!)
      create_schema(db)
      db
    end

    # Builds the `sqlite3://` connection URI the underlying driver expects for *path*,
    # percent-encoding the filename so a real repo pathname containing `+`, `?`, `#`, `%`, or
    # a space is treated as literal filename bytes rather than decoded into a space (`+`),
    # parsed as the start of query params (`?`) or a URI fragment (`#`) — a naive
    # `"sqlite3://#{path}"` interpolation hands the driver a different, mis-decoded path, or
    # makes `DB.open` raise outright. Also sets a `busy_timeout` pragma so a concurrent
    # sync/`engram mcp` connection retries instead of hard-failing with "database is locked".
    # Public so every other opener of this same sqlite file (`Search`, the CLI's DB integrity
    # check) can build the identical, safe URI instead of re-interpolating the path themselves.
    def self.connection_uri(path : String, busy_timeout_ms : Int32 = BUSY_TIMEOUT_MS) : URI
      URI.new(
        scheme: "sqlite3", host: "",
        path: URI.encode_www_form(path, space_to_plus: false),
        query: "busy_timeout=#{busy_timeout_ms}",
      )
    end

    # Closes the underlying database connection.
    def close : Nil
      @db.close
    end

    # Runs *block* inside a single sqlite transaction on one connection, so callers (e.g.
    # `Sync`) can batch several CRUD calls on this `Store` atomically: either all of them land
    # or (on an exception, which re-raises after rollback) none do. Do not call `embed()` or
    # any other network I/O inside *block* — it would hold sqlite's write lock across the
    # network for as long as the request takes.
    def transaction(&block : ->) : Nil
      @db.transaction do |tx|
        @conn = tx.connection
        begin
          yield
        ensure
          @conn = nil
        end
      end
    end

    # True if `PRAGMA integrity_check` reports (or raises) corruption on the just-opened
    # *db*. A permission or lock failure reading it is a different problem and propagates
    # as-is rather than being mistaken for a disposable corrupt cache.
    private def self.corrupted_connection?(db : DB::Database) : Bool
      db.scalar("PRAGMA integrity_check").to_s != "ok"
    rescue ex : SQLite3::Exception
      raise ex unless corruption_error?(ex)
      true
    end

    # True for the sqlite error strings a corrupted or truncated file surfaces (e.g. "file is
    # not a database", "database disk image is malformed"). Deliberately does NOT match
    # lock/busy errors ("database is locked") or anything else — those must always propagate,
    # never be treated as a green light to delete a perfectly fine database out from under a
    # concurrent writer.
    def self.corruption_error?(ex : SQLite3::Exception) : Bool
      message = ex.message
      !!message && (message.includes?("not a database") || message.includes?("malformed"))
    end

    # Closes the (corrupt) *db*, deletes the cache file at *path* and any stale
    # rollback-journal sidecar, and returns a freshly-opened, empty database at the same
    # path. Safe: the cache is disposable, and `Sync.run` fully repopulates it from
    # `.agents/memories/` next pass.
    private def self.rebuild_database(path : String, db : DB::Database) : DB::Database
      db.close
      {path, "#{path}-journal", "#{path}-wal", "#{path}-shm"}.each do |sidecar|
        File.delete(sidecar) if File.exists?(sidecar)
      end
      DB.open(connection_uri(path))
    end

    # The connection CRUD methods below query through: the active transaction's connection
    # while one is running (see `#transaction`), otherwise the database's own pool.
    private def executor : DB::Database | DB::Connection
      @conn || @db
    end

    # Inserts a new memory row; the FTS index is kept in sync by a trigger. Raises on a duplicate id.
    def insert_memory(id : Int64, slug : String, title : String, topics : Array(String), author : String?,
                      body : String, supersedes : Array(Int64), file_path : String,
                      embedding : Bytes? = nil, applied_at : Time = Time.utc) : Nil
      executor.exec(
        "INSERT INTO memories (id, slug, title, topics, author, body, supersedes, embedding, file_path, applied_at) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        id, slug, title, lowercase_csv(topics), author, body, supersedes.join(","), embedding, file_path, applied_at.to_rfc3339
      )
    end

    # Updates an existing memory row in place; the FTS index is kept in sync by a trigger. Raises Engram::MemoryNotFoundError if *id* is absent.
    def update_memory(id : Int64, slug : String, title : String, topics : Array(String), author : String?,
                      body : String, supersedes : Array(Int64), file_path : String,
                      embedding : Bytes? = nil, applied_at : Time = Time.utc) : Nil
      result = executor.exec(
        "UPDATE memories SET slug = ?, title = ?, topics = ?, author = ?, body = ?, supersedes = ?, " \
        "embedding = ?, file_path = ?, applied_at = ? WHERE id = ?",
        slug, title, lowercase_csv(topics), author, body, supersedes.join(","), embedding, file_path, applied_at.to_rfc3339, id
      )
      raise MemoryNotFoundError.new(id) if result.rows_affected == 0
    end

    # Deletes a memory row if present; the FTS index is kept in sync by a trigger. A no-op if *id* isn't stored.
    def delete_memory(id : Int64) : Nil
      executor.exec("DELETE FROM memories WHERE id = ?", id)
    end

    # Sets (or clears, with nil) which memory id supersedes *id*. Used to recompute demotion links after a sync.
    def set_superseded_by(id : Int64, superseded_by : Int64?) : Nil
      executor.exec("UPDATE memories SET superseded_by = ? WHERE id = ?", superseded_by, id)
    end

    # Returns every memory id currently stored, for sync's set-diff against the working tree.
    def all_ids : Array(Int64)
      ids = [] of Int64
      executor.query_each("SELECT id FROM memories") do |rs|
        ids << rs.read(Int64)
      end
      ids
    end

    # Fetches the full record for *id*, or nil if no such memory is stored.
    def get(id : Int64) : MemoryRecord?
      row = executor.query_one?(
        "SELECT id, slug, title, topics, author, body, supersedes, superseded_by, embedding, file_path, applied_at " \
        "FROM memories WHERE id = ?",
        id,
        as: {Int64, String, String, String, String?, String, String, Int64?, Bytes?, String, String}
      )
      return nil unless row
      row_id, slug, title, topics, author, body, supersedes, superseded_by, embedding, file_path, applied_at = row
      MemoryRecord.new(
        id: row_id,
        slug: slug,
        title: title,
        topics: split_csv(topics),
        author: author,
        body: body,
        supersedes: split_csv(supersedes).map(&.to_i64),
        superseded_by: superseded_by,
        embedding: embedding,
        file_path: file_path,
        applied_at: applied_at,
      )
    end

    # Returns the number of active (not superseded) and superseded memories.
    def counts : NamedTuple(active: Int32, superseded: Int32)
      active = executor.scalar("SELECT COUNT(*) FROM memories WHERE superseded_by IS NULL").as(Int64)
      superseded = executor.scalar("SELECT COUNT(*) FROM memories WHERE superseded_by IS NOT NULL").as(Int64)
      {active: active.to_i32, superseded: superseded.to_i32}
    end

    # Reads a value from engram_meta, or nil if the key has never been set.
    def meta(key : String) : String?
      executor.query_one?("SELECT value FROM engram_meta WHERE key = ?", key, as: String)
    end

    # Upserts a key/value pair into engram_meta.
    def set_meta(key : String, value : String) : Nil
      executor.exec(
        "INSERT INTO engram_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        key, value
      )
    end

    # Splits a comma-joined column back into its parts, treating an empty string as no parts.
    private def split_csv(value : String) : Array(String)
      value.empty? ? [] of String : value.split(',')
    end

    # Lowercases and comma-joins *topics* for storage, honoring the schema's documented
    # `topics TEXT ... -- comma-joined, lowercased` invariant (docs/SPEC.md).
    private def lowercase_csv(topics : Array(String)) : String
      topics.map(&.downcase).join(",")
    end

    # Creates the memories table, the FTS5 index and its sync triggers, and the meta table, if they don't already exist.
    private def self.create_schema(db : DB::Database) : Nil
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS memories (
          id INTEGER PRIMARY KEY,
          slug TEXT NOT NULL,
          title TEXT NOT NULL,
          topics TEXT NOT NULL DEFAULT '',
          author TEXT,
          body TEXT NOT NULL,
          supersedes TEXT NOT NULL DEFAULT '',
          superseded_by INTEGER,
          embedding BLOB,
          file_path TEXT NOT NULL,
          applied_at TEXT NOT NULL
        )
        SQL

      db.exec <<-SQL
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
          title, topics, body, content='memories', content_rowid='id'
        )
        SQL

      db.exec <<-SQL
        CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
          INSERT INTO memories_fts(rowid, title, topics, body) VALUES (new.id, new.title, new.topics, new.body);
        END;
        SQL

      db.exec <<-SQL
        CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, title, topics, body) VALUES ('delete', old.id, old.title, old.topics, old.body);
        END;
        SQL

      db.exec <<-SQL
        CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, title, topics, body) VALUES ('delete', old.id, old.title, old.topics, old.body);
          INSERT INTO memories_fts(rowid, title, topics, body) VALUES (new.id, new.title, new.topics, new.body);
        END;
        SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS engram_meta (key TEXT PRIMARY KEY, value TEXT)
        SQL
    end
  end
end
