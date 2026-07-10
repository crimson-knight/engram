require "./spec_helper"
require "db"
require "sqlite3"

private def db_path(dir : String) : String
  File.join(dir, "engram.db")
end

# Opens a second, independent connection to the same sqlite file, for
# assertions the Store API itself doesn't expose (raw FTS5 MATCH queries,
# sqlite_master introspection).
private def raw_match(dir : String, term : String) : Array(Int64)
  ids = [] of Int64
  DB.open("sqlite3://#{db_path(dir)}") do |db|
    db.query_each("SELECT rowid FROM memories_fts WHERE memories_fts MATCH ? ORDER BY rowid", term) do |rs|
      ids << rs.read(Int64)
    end
  end
  ids
end

private def sqlite_master_names(dir : String) : Array(String)
  names = [] of String
  DB.open("sqlite3://#{db_path(dir)}") do |db|
    db.query_each("SELECT name FROM sqlite_master") do |rs|
      names << rs.read(String)
    end
  end
  names
end

describe Engram::Store do
  it "creates the memories table, the FTS5 index, its triggers, and engram_meta" do
    SpecHelper.with_tempdir do |dir|
      store = Engram::Store.new(db_path(dir))
      names = sqlite_master_names(dir)
      store.close

      names.should contain("memories")
      names.should contain("memories_fts")
      names.should contain("engram_meta")
      names.should contain("memories_ai")
      names.should contain("memories_ad")
      names.should contain("memories_au")
    end
  end

  it "is safe to open twice against the same path (IF NOT EXISTS schema)" do
    SpecHelper.with_tempdir do |dir|
      store_a = Engram::Store.new(db_path(dir))
      store_a.insert_memory(
        id: 1_i64, slug: "one", title: "One", topics: [] of String, author: nil,
        body: "first", supersedes: [] of Int64, file_path: "a.md"
      )
      store_a.close

      store_b = Engram::Store.new(db_path(dir))
      store_b.all_ids.should eq([1_i64])
      store_b.close
    end
  end

  describe "insert/update/delete kept in sync with FTS" do
    it "makes an inserted memory findable via FTS5 MATCH" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(
          id: 20260710153000_i64, slug: "zephyr-decision", title: "Unique Zephyr Title",
          topics: ["storage"], author: "seth", body: "some body text mentions the zephyr keyword",
          supersedes: [] of Int64, file_path: ".agents/memories/20260710153000_zephyr-decision.md"
        )
        store.close

        raw_match(dir, "zephyr").should eq([20260710153000_i64])
      end
    end

    it "updates the FTS index when a memory is updated in place" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(
          id: 1_i64, slug: "a", title: "Zephyr Title", topics: [] of String, author: nil,
          body: "zephyr body", supersedes: [] of Int64, file_path: "a.md"
        )
        store.update_memory(
          id: 1_i64, slug: "a", title: "Gamma Title", topics: [] of String, author: nil,
          body: "gamma body", supersedes: [] of Int64, file_path: "a.md"
        )
        store.close

        raw_match(dir, "zephyr").should eq([] of Int64)
        raw_match(dir, "gamma").should eq([1_i64])
      end
    end

    it "raises Engram::MemoryNotFoundError when updating an id that isn't stored" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        expect_raises(Engram::MemoryNotFoundError, /999/) do
          store.update_memory(
            id: 999_i64, slug: "missing", title: "Missing", topics: [] of String, author: nil,
            body: "body", supersedes: [] of Int64, file_path: "missing.md"
          )
        end
        store.close
      end
    end

    it "removes a memory from FTS and the store when deleted" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(
          id: 1_i64, slug: "a", title: "Zephyr Title", topics: [] of String, author: nil,
          body: "zephyr body", supersedes: [] of Int64, file_path: "a.md"
        )
        store.delete_memory(1_i64)
        ids = store.all_ids
        record = store.get(1_i64)
        store.close

        ids.should eq([] of Int64)
        record.should be_nil
        raw_match(dir, "zephyr").should eq([] of Int64)
      end
    end

    it "deleting an id that isn't stored is a no-op" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.delete_memory(12345_i64)
        store.all_ids.should eq([] of Int64)
        store.close
      end
    end
  end

  describe "#get" do
    it "round-trips every column, splitting csv topics and supersedes back into arrays" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(
          id: 20260710153000_i64, slug: "chose-sqlite", title: "Chose SQLite",
          topics: ["storage", "architecture"], author: "seth", body: "the body",
          supersedes: [20260101000000_i64], file_path: ".agents/memories/20260710153000_chose-sqlite.md"
        )
        record = store.get(20260710153000_i64).not_nil!
        store.close

        record.id.should eq(20260710153000_i64)
        record.slug.should eq("chose-sqlite")
        record.title.should eq("Chose SQLite")
        record.topics.should eq(["storage", "architecture"])
        record.author.should eq("seth")
        record.body.should eq("the body")
        record.supersedes.should eq([20260101000000_i64])
        record.superseded_by.should be_nil
        record.embedding.should be_nil
        record.file_path.should eq(".agents/memories/20260710153000_chose-sqlite.md")
      end
    end
  end

  describe "embedding BLOB round-trip" do
    it "packs and unpacks a Float32 vector through the embedding column" do
      SpecHelper.with_tempdir do |dir|
        vector = Float32.slice(0.25_f32, -1.5_f32, 3.0_f32, 42.125_f32)
        packed = Bytes.new(vector.to_unsafe.as(UInt8*), vector.size * 4)

        store = Engram::Store.new(db_path(dir))
        store.insert_memory(
          id: 1_i64, slug: "a", title: "With embedding", topics: [] of String, author: nil,
          body: "body", supersedes: [] of Int64, file_path: "a.md", embedding: packed
        )
        record = store.get(1_i64).not_nil!
        store.close

        bytes = record.embedding.not_nil!
        floats = Slice(Float32).new(bytes.to_unsafe.as(Float32*), bytes.size // 4)
        floats.to_a.should eq(vector.to_a)
      end
    end
  end

  describe "#counts" do
    it "counts active and superseded memories separately" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil, body: "a", supersedes: [] of Int64, file_path: "a.md")
        store.insert_memory(id: 2_i64, slug: "b", title: "B", topics: [] of String, author: nil, body: "b", supersedes: [1_i64], file_path: "b.md")
        store.set_superseded_by(1_i64, 2_i64)

        counts = store.counts
        store.close

        counts[:active].should eq(1)
        counts[:superseded].should eq(1)
      end
    end
  end

  describe "meta get/set" do
    it "returns nil for a key that was never set" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        value = store.meta("missing")
        store.close
        value.should be_nil
      end
    end

    it "round-trips a value and upserts on a second set" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.set_meta("embedding_dimension", "768")
        store.meta("embedding_dimension").should eq("768")

        store.set_meta("embedding_dimension", "1024")
        value = store.meta("embedding_dimension")
        store.close

        value.should eq("1024")
      end
    end
  end

  describe "connection URI escaping" do
    it "opens the exact intended file when the path contains characters the sqlite3 URI driver would otherwise mis-decode" do
      SpecHelper.with_tempdir do |dir|
        weird_dir = File.join(dir, "has +space%percent?question#hash")
        Dir.mkdir_p(weird_dir)
        path = File.join(weird_dir, "engram.db")

        store = Engram::Store.new(path)
        store.insert_memory(
          id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil,
          body: "body", supersedes: [] of Int64, file_path: "a.md"
        )
        store.close

        # The file was created at the exact path asked for, not some mis-decoded
        # neighbor (a bare `"sqlite3://#{path}"` interpolation turns `+` into a
        # space, and lets `?`/`#` start URI query/fragment parsing instead of
        # naming the file).
        File.exists?(path).should be_true
        Dir.children(dir).should eq([File.basename(weird_dir)])

        reopened = Engram::Store.new(path)
        ids = reopened.all_ids
        reopened.close

        ids.should eq([1_i64])
      end
    end
  end

  describe "corrupted cache recovery" do
    it "self-heals a database file containing random garbage bytes instead of raising" do
      SpecHelper.with_tempdir do |dir|
        path = db_path(dir)
        File.write(path, Random::Secure.random_bytes(4096))

        store = Engram::Store.new(path)
        ids_before_write = store.all_ids
        store.insert_memory(
          id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil,
          body: "body", supersedes: [] of Int64, file_path: "a.md"
        )
        record = store.get(1_i64)
        store.close

        ids_before_write.should eq([] of Int64)
        record.should_not be_nil
      end
    end

    it "self-heals a truncated database file (valid header, missing pages) instead of raising" do
      SpecHelper.with_tempdir do |dir|
        path = db_path(dir)
        seed = Engram::Store.new(path)
        seed.insert_memory(
          id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil,
          body: "a" * 500, supersedes: [] of Int64, file_path: "a.md"
        )
        seed.close

        full = File.open(path, "rb") { |f| bytes = Bytes.new(f.size); f.read_fully(bytes); bytes }
        File.write(path, full[0, 50])

        store = Engram::Store.new(path)
        ids = store.all_ids
        store.close

        ids.should eq([] of Int64)
      end
    end
  end

  describe ".corruption_error?" do
    it "is true for a real error raised against a garbage-byte file" do
      SpecHelper.with_tempdir do |dir|
        path = db_path(dir)
        File.write(path, Random::Secure.random_bytes(2048))

        db = DB.open(Engram::Store.connection_uri(path))
        ex = expect_raises(SQLite3::Exception) { db.exec("CREATE TABLE IF NOT EXISTS t (id INTEGER)") }
        db.close

        Engram::Store.corruption_error?(ex).should be_true
      end
    end

    it "is false for a real lock/busy error, so a merely-contended database is never mistaken for corrupt" do
      SpecHelper.with_tempdir do |dir|
        path = db_path(dir)
        holder = Engram::Store.new(path)

        caught = nil.as(SQLite3::Exception?)
        holder.transaction do
          holder.insert_memory(
            id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil,
            body: "a", supersedes: [] of Int64, file_path: "a.md"
          )

          contender = DB.open(Engram::Store.connection_uri(path, busy_timeout_ms: 100))
          begin
            contender.exec(
              "INSERT INTO memories (id, slug, title, topics, author, body, supersedes, embedding, file_path, applied_at) " \
              "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
              2_i64, "b", "B", "", nil, "b", "", nil, "b.md", Time.utc.to_rfc3339
            )
          rescue e : SQLite3::Exception
            caught = e
          end
          # The failed statement can leave this throwaway connection unable to close
          # cleanly (closing it re-attempts the still-locked statement); irrelevant to
          # what this spec is proving, so swallow it rather than let it mask `caught`.
          contender.close rescue nil
        end
        holder.close

        ex = caught.not_nil!
        ex.message.to_s.should match(/locked/)
        Engram::Store.corruption_error?(ex).should be_false

        # And the database itself was left alone by the contention: reopening still
        # sees exactly the row `holder` committed, nothing rebuilt or lost.
        reopened = Engram::Store.new(path)
        ids = reopened.all_ids
        reopened.close

        ids.should eq([1_i64])
      end
    end
  end

  describe "#transaction" do
    it "commits every write made inside the block together" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.transaction do
          store.insert_memory(id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil, body: "a", supersedes: [] of Int64, file_path: "a.md")
          store.insert_memory(id: 2_i64, slug: "b", title: "B", topics: [] of String, author: nil, body: "b", supersedes: [] of Int64, file_path: "b.md")
        end
        ids = store.all_ids
        store.close

        ids.sort.should eq([1_i64, 2_i64])
      end
    end

    it "rolls back every write made inside the block if it raises, leaving no partially-applied state" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.insert_memory(id: 1_i64, slug: "already-there", title: "Already there", topics: [] of String, author: nil, body: "x", supersedes: [] of Int64, file_path: "a.md")

        expect_raises(Exception, "boom") do
          store.transaction do
            store.insert_memory(id: 2_i64, slug: "b", title: "B", topics: [] of String, author: nil, body: "b", supersedes: [] of Int64, file_path: "b.md")
            store.delete_memory(1_i64)
            raise "boom"
          end
        end

        ids = store.all_ids
        store.close

        ids.should eq([1_i64])
      end
    end

    it "sets a busy_timeout pragma so a contended write retries for a bounded window instead of failing instantly" do
      SpecHelper.with_tempdir do |dir|
        path = db_path(dir)
        store = Engram::Store.new(path)

        elapsed = Time.measure do
          store.transaction do
            store.insert_memory(id: 1_i64, slug: "a", title: "A", topics: [] of String, author: nil, body: "a", supersedes: [] of Int64, file_path: "a.md")

            contender = DB.open(Engram::Store.connection_uri(path, busy_timeout_ms: 150))
            expect_raises(SQLite3::Exception, /locked/) do
              contender.exec(
                "INSERT INTO memories (id, slug, title, topics, author, body, supersedes, embedding, file_path, applied_at) " \
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                2_i64, "b", "B", "", nil, "b", "", nil, "b.md", Time.utc.to_rfc3339
              )
            end
            # See the note in the ".corruption_error?" spec above: closing this
            # throwaway connection can itself re-hit the lock; not what's under test.
            contender.close rescue nil
          end
        end
        store.close

        elapsed.should be >= 100.milliseconds
      end
    end
  end
end
