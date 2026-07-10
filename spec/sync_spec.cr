require "./spec_helper"
require "../src/engram/sync"
require "../src/engram/embedder"

# MemoryFile requires 14-digit ids (`<ID>_<slug>.md`); these read as
# plain, obviously-ordered fixture ids rather than real timestamps.
private ID_A = 20260101000001_i64
private ID_B = 20260101000002_i64
private ID_C = 20260101000003_i64

private def memories_dir(repo : String) : String
  File.join(repo, ".agents", "memories")
end

private def db_path(repo : String) : String
  File.join(repo, ".git", "engram.db")
end

# A temp dir with `.agents/memories/` created and `git init`'d, so specs
# exercise sync against a real (if throwaway) git repo without ever touching
# the actual project repo or HOME. Sync itself never shells out to git.
private def with_temp_repo(&)
  SpecHelper.with_tempdir do |dir|
    Dir.mkdir_p(memories_dir(dir))
    Process.run("git", ["init", "-q"], chdir: dir)
    yield dir
  end
end

private def write_memory(repo : String, id : Int64, title : String, body : String = "some body text",
                         topics : Array(String) = [] of String, supersedes : Array(Int64) = [] of Int64,
                         author : String? = nil) : String
  slug = Engram::MemoryFile.slugify(title)
  content = Engram::MemoryFile.new(
    id: id, slug: slug, title: title, topics: topics, supersedes: supersedes,
    author: author, body: body, file_path: "",
  ).serialize
  SpecHelper.write_file(memories_dir(repo), "#{id}_#{slug}.md", content)
end

private def fake_embedder(&transport : Engram::EmbedderConfig, String -> Array(Float32)) : Engram::Embedder
  config = Engram::EmbedderConfig.new(url: "http://fake.local/v1/embeddings", model: "fake-model")
  Engram::Embedder.new(config, &transport)
end

private def unpack(bytes : Bytes) : Array(Float32)
  Slice(Float32).new(bytes.to_unsafe.as(Float32*), bytes.size // 4).to_a
end

describe Engram::Sync do
  describe ".run" do
    it "applies a brand-new memory file into an empty store" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "First decision")
        store = Engram::Store.new(db_path(dir))
        result = Engram::Sync.run(memories_dir(dir), store)
        record = store.get(ID_A)
        store.close

        result.applied.should eq([ID_A])
        result.rolled_back.should eq([] of Int64)
        result.updated.should eq([] of Int64)
        result.active_count.should eq(1)
        result.summary.should eq("engram: +1 applied, -0 rolled back, 0 updated (1 active)")
        record.should_not be_nil
      end
    end

    it "applies multiple new files in one pass" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "First decision")
        write_memory(dir, ID_B, "Second decision")
        store = Engram::Store.new(db_path(dir))
        result = Engram::Sync.run(memories_dir(dir), store)
        store.close

        result.applied.should eq([ID_A, ID_B])
        result.active_count.should eq(2)
      end
    end

    it "rolls back a memory whose file was deleted" do
      with_temp_repo do |dir|
        path = write_memory(dir, ID_A, "Temporary decision")
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)

        File.delete(path)
        result = Engram::Sync.run(memories_dir(dir), store)
        ids = store.all_ids
        store.close

        result.rolled_back.should eq([ID_A])
        result.applied.should eq([] of Int64)
        result.active_count.should eq(0)
        ids.should eq([] of Int64)
      end
    end

    it "re-applies a memory whose content changed, in place" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Evolving decision", body: "original body")
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)

        write_memory(dir, ID_A, "Evolving decision", body: "updated body")
        result = Engram::Sync.run(memories_dir(dir), store)
        record = store.get(ID_A).not_nil!
        store.close

        result.updated.should eq([ID_A])
        result.applied.should eq([] of Int64)
        result.rolled_back.should eq([] of Int64)
        record.body.should eq("updated body")
      end
    end

    it "is idempotent: re-running with nothing changed applies/rolls back/updates nothing" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Stable decision")
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)
        result = Engram::Sync.run(memories_dir(dir), store)
        store.close

        result.applied.should eq([] of Int64)
        result.rolled_back.should eq([] of Int64)
        result.updated.should eq([] of Int64)
        result.active_count.should eq(1)
      end
    end

    it "is git-agnostic: works fine with no commits at all in the tree" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Works without any commits")
        store = Engram::Store.new(db_path(dir))
        result = Engram::Sync.run(memories_dir(dir), store)
        store.close

        result.applied.should eq([ID_A])
      end
    end

    it "rebuilds a deleted database from the working tree on the next sync" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Persisted decision")
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)
        store.close

        File.delete(db_path(dir))

        rebuilt_store = Engram::Store.new(db_path(dir))
        result = Engram::Sync.run(memories_dir(dir), rebuilt_store)
        ids = rebuilt_store.all_ids
        rebuilt_store.close

        result.applied.should eq([ID_A])
        ids.should eq([ID_A])
      end
    end

    it "raises Engram::DuplicateIdError naming both paths when two files share an id" do
      with_temp_repo do |dir|
        path_a = write_memory(dir, ID_A, "First title")
        path_b = write_memory(dir, ID_A, "A totally different title")
        store = Engram::Store.new(db_path(dir))

        error = expect_raises(Engram::DuplicateIdError, /duplicate memory id #{ID_A}\b/) do
          Engram::Sync.run(memories_dir(dir), store)
        end
        store.close

        message = error.message.not_nil!
        message.should contain(File.basename(path_a))
        message.should contain(File.basename(path_b))
      end
    end

    it "does not mutate the store at all when duplicate ids are found" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "First title")
        write_memory(dir, ID_A, "A totally different title")
        write_memory(dir, ID_B, "Unrelated fine memory")
        store = Engram::Store.new(db_path(dir))

        expect_raises(Engram::DuplicateIdError) do
          Engram::Sync.run(memories_dir(dir), store)
        end
        ids = store.all_ids
        store.close

        ids.should eq([] of Int64)
      end
    end

    it "demotes an older memory when a newer one supersedes it" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Old decision")
        write_memory(dir, ID_B, "New decision", supersedes: [ID_A])
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)

        old_record = store.get(ID_A).not_nil!
        new_record = store.get(ID_B).not_nil!
        counts = store.counts
        store.close

        old_record.superseded_by.should eq(ID_B)
        new_record.superseded_by.should be_nil
        counts.should eq({active: 1, superseded: 1})
      end
    end

    it "un-supersedes a memory once the newer file drops it from supersedes" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Old decision")
        write_memory(dir, ID_B, "New decision", supersedes: [ID_A])
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)

        write_memory(dir, ID_B, "New decision", supersedes: [] of Int64, body: "revised, no longer supersedes")
        Engram::Sync.run(memories_dir(dir), store)
        old_record = store.get(ID_A).not_nil!
        counts = store.counts
        store.close

        old_record.superseded_by.should be_nil
        counts.should eq({active: 2, superseded: 0})
      end
    end

    it "stores a repo-relative file_path, not the tree-walk's absolute path" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Some decision")
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)
        record = store.get(ID_A).not_nil!
        store.close

        record.file_path.should eq(".agents/memories/#{ID_A}_some-decision.md")
        record.file_path.should_not start_with("/")
      end
    end

    it "re-applies (refreshing slug and file_path) when a memory file is renamed with unchanged content" do
      with_temp_repo do |dir|
        old_path = write_memory(dir, ID_A, "Original Title")
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)

        new_path = File.join(memories_dir(dir), "#{ID_A}_renamed-title.md")
        File.rename(old_path, new_path)

        result = Engram::Sync.run(memories_dir(dir), store)
        record = store.get(ID_A).not_nil!
        store.close

        result.updated.should eq([ID_A])
        result.applied.should eq([] of Int64)
        record.slug.should eq("renamed-title")
        record.file_path.should eq(".agents/memories/#{ID_A}_renamed-title.md")
      end
    end

    it "picks the newest (highest id) superseder when two memories both claim to supersede the same id" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Old decision")
        write_memory(dir, ID_B, "A rival newer decision", supersedes: [ID_A])
        write_memory(dir, ID_C, "The actual newest decision", supersedes: [ID_A])
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)

        old_record = store.get(ID_A).not_nil!
        store.close

        old_record.superseded_by.should eq(ID_C)
      end
    end
  end

  describe "embedder integration" do
    it "leaves embeddings nil with no embedder configured (off by default)" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "No embeddings here")
        store = Engram::Store.new(db_path(dir))
        Engram::Sync.run(memories_dir(dir), store)
        record = store.get(ID_A).not_nil!
        store.close

        record.embedding.should be_nil
      end
    end

    it "stores a packed embedding for each newly-applied memory when a fake embedder is given" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Embed me")
        store = Engram::Store.new(db_path(dir))
        embedder = fake_embedder { |_, _| [1.0_f32, 2.0_f32, 3.0_f32] }

        Engram::Sync.run(memories_dir(dir), store, embedder)
        record = store.get(ID_A).not_nil!
        store.close

        unpack(record.embedding.not_nil!).should eq([1.0_f32, 2.0_f32, 3.0_f32])
      end
    end

    it "re-embeds only changed memories on a normal sync, leaving untouched ones alone" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "Stays the same")
        write_memory(dir, ID_B, "Will change", body: "v1")
        store = Engram::Store.new(db_path(dir))
        calls = [] of String
        embedder = fake_embedder { |_, text| calls << text; [9.0_f32] }
        Engram::Sync.run(memories_dir(dir), store, embedder)

        calls.clear
        write_memory(dir, ID_B, "Will change", body: "v2")
        Engram::Sync.run(memories_dir(dir), store, embedder)
        store.close

        calls.size.should eq(1)
      end
    end

    it "warns once and continues without embeddings when the transport fails" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "First")
        write_memory(dir, ID_B, "Second")
        store = Engram::Store.new(db_path(dir))
        call_count = 0
        embedder = fake_embedder { |_, _| call_count += 1; raise "boom" }

        result = Engram::Sync.run(memories_dir(dir), store, embedder)
        first = store.get(ID_A).not_nil!
        second = store.get(ID_B).not_nil!
        store.close

        result.applied.should eq([ID_A, ID_B])
        first.embedding.should be_nil
        second.embedding.should be_nil
        call_count.should eq(1)
      end
    end

    it "re-embeds every active memory when the embedder's dimension changes, and records the new dimension" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "First memory")
        write_memory(dir, ID_B, "Second memory")
        store = Engram::Store.new(db_path(dir))

        small_embedder = fake_embedder { |_, _| [1.0_f32, 2.0_f32] }
        Engram::Sync.run(memories_dir(dir), store, small_embedder)

        # Only memory B's file changes; memory A would normally be left
        # alone, but the dimension change must force it to be re-embedded too.
        write_memory(dir, ID_B, "Second memory", body: "updated body")
        big_embedder = fake_embedder { |_, _| [1.0_f32, 2.0_f32, 3.0_f32, 4.0_f32] }
        Engram::Sync.run(memories_dir(dir), store, big_embedder)

        first = store.get(ID_A).not_nil!
        second = store.get(ID_B).not_nil!
        dimension_meta = store.meta("embedding_dimension")
        store.close

        unpack(first.embedding.not_nil!).size.should eq(4)
        unpack(second.embedding.not_nil!).size.should eq(4)
        dimension_meta.should eq("4")
      end
    end

    it "records the dimension after the very first sync with an embedder" do
      with_temp_repo do |dir|
        write_memory(dir, ID_A, "First memory")
        store = Engram::Store.new(db_path(dir))
        embedder = fake_embedder { |_, _| [1.0_f32, 2.0_f32, 3.0_f32] }

        Engram::Sync.run(memories_dir(dir), store, embedder)
        dimension_meta = store.meta("embedding_dimension")
        store.close

        dimension_meta.should eq("3")
      end
    end
  end
end
