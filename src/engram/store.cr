require "db"
require "sqlite3"

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
    @db : DB::Database

    # Opens (creating if needed) the sqlite database at *db_path* and ensures its schema exists.
    def initialize(@db_path : String)
      dir = File.dirname(@db_path)
      Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
      @db = DB.open("sqlite3://#{@db_path}")
      create_schema
    end

    # Closes the underlying database connection.
    def close : Nil
      @db.close
    end

    # Runs *block* inside a single sqlite transaction, for callers (e.g. sync) batching several writes atomically.
    def transaction(&block : DB::Transaction ->)
      @db.transaction(&block)
    end

    # Inserts a new memory row; the FTS index is kept in sync by a trigger. Raises on a duplicate id.
    def insert_memory(id : Int64, slug : String, title : String, topics : Array(String), author : String?,
                      body : String, supersedes : Array(Int64), file_path : String,
                      embedding : Bytes? = nil, applied_at : Time = Time.utc) : Nil
      @db.exec(
        "INSERT INTO memories (id, slug, title, topics, author, body, supersedes, embedding, file_path, applied_at) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        id, slug, title, lowercase_csv(topics), author, body, supersedes.join(","), embedding, file_path, applied_at.to_rfc3339
      )
    end

    # Updates an existing memory row in place; the FTS index is kept in sync by a trigger. Raises Engram::MemoryNotFoundError if *id* is absent.
    def update_memory(id : Int64, slug : String, title : String, topics : Array(String), author : String?,
                      body : String, supersedes : Array(Int64), file_path : String,
                      embedding : Bytes? = nil, applied_at : Time = Time.utc) : Nil
      result = @db.exec(
        "UPDATE memories SET slug = ?, title = ?, topics = ?, author = ?, body = ?, supersedes = ?, " \
        "embedding = ?, file_path = ?, applied_at = ? WHERE id = ?",
        slug, title, lowercase_csv(topics), author, body, supersedes.join(","), embedding, file_path, applied_at.to_rfc3339, id
      )
      raise MemoryNotFoundError.new(id) if result.rows_affected == 0
    end

    # Deletes a memory row if present; the FTS index is kept in sync by a trigger. A no-op if *id* isn't stored.
    def delete_memory(id : Int64) : Nil
      @db.exec("DELETE FROM memories WHERE id = ?", id)
    end

    # Sets (or clears, with nil) which memory id supersedes *id*. Used to recompute demotion links after a sync.
    def set_superseded_by(id : Int64, superseded_by : Int64?) : Nil
      @db.exec("UPDATE memories SET superseded_by = ? WHERE id = ?", superseded_by, id)
    end

    # Returns every memory id currently stored, for sync's set-diff against the working tree.
    def all_ids : Array(Int64)
      ids = [] of Int64
      @db.query_each("SELECT id FROM memories") do |rs|
        ids << rs.read(Int64)
      end
      ids
    end

    # Fetches the full record for *id*, or nil if no such memory is stored.
    def get(id : Int64) : MemoryRecord?
      row = @db.query_one?(
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
      active = @db.scalar("SELECT COUNT(*) FROM memories WHERE superseded_by IS NULL").as(Int64)
      superseded = @db.scalar("SELECT COUNT(*) FROM memories WHERE superseded_by IS NOT NULL").as(Int64)
      {active: active.to_i32, superseded: superseded.to_i32}
    end

    # Reads a value from engram_meta, or nil if the key has never been set.
    def meta(key : String) : String?
      @db.query_one?("SELECT value FROM engram_meta WHERE key = ?", key, as: String)
    end

    # Upserts a key/value pair into engram_meta.
    def set_meta(key : String, value : String) : Nil
      @db.exec(
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
    private def create_schema : Nil
      @db.exec <<-SQL
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

      @db.exec <<-SQL
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
          title, topics, body, content='memories', content_rowid='id'
        )
        SQL

      @db.exec <<-SQL
        CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
          INSERT INTO memories_fts(rowid, title, topics, body) VALUES (new.id, new.title, new.topics, new.body);
        END;
        SQL

      @db.exec <<-SQL
        CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, title, topics, body) VALUES ('delete', old.id, old.title, old.topics, old.body);
        END;
        SQL

      @db.exec <<-SQL
        CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, title, topics, body) VALUES ('delete', old.id, old.title, old.topics, old.body);
          INSERT INTO memories_fts(rowid, title, topics, body) VALUES (new.id, new.title, new.topics, new.body);
        END;
        SQL

      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS engram_meta (key TEXT PRIMARY KEY, value TEXT)
        SQL
    end
  end
end
