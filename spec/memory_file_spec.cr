require "./spec_helper"

private VALID_CONTENT = <<-MD
  ---
  id: 20260710153000
  title: Chose SQLite over Postgres for the memory cache
  topics: [storage, architecture]
  supersedes: []            # optional: list of older memory IDs this replaces
  author: seth              # optional, freeform
  ---

  **Decision:** Use a per-clone SQLite file at .git/engram.db instead of a shared Postgres database.

  **Why:** Zero configuration for every teammate; the DB is a disposable cache of the
  migration files, so nothing is lost when it's deleted.

  **Rejected:** Postgres + pgvector — the per-developer setup cost (install, extension,
  embedding model) was the main thing killing adoption.
  MD

describe Engram::MemoryFile do
  describe ".parse" do
    it "parses a well-formed migration file" do
      path = "/tmp/fake/20260710153000_chose-sqlite-over-postgres.md"
      memory = Engram::MemoryFile.parse(VALID_CONTENT, path)

      memory.id.should eq(20260710153000_i64)
      memory.slug.should eq("chose-sqlite-over-postgres")
      memory.title.should eq("Chose SQLite over Postgres for the memory cache")
      memory.topics.should eq(["storage", "architecture"])
      memory.supersedes.should eq([] of Int64)
      memory.author.should eq("seth")
      memory.body.should contain("**Decision:**")
      memory.body.should contain("**Rejected:**")
      memory.file_path.should eq(path)
    end

    it "reads a file straight off disk" do
      SpecHelper.with_tempdir do |dir|
        path = SpecHelper.write_file(dir, "20260710153000_chose-sqlite-over-postgres.md", VALID_CONTENT)
        memory = Engram::MemoryFile.parse(path)
        memory.title.should eq("Chose SQLite over Postgres for the memory cache")
      end
    end

    it "defaults topics, supersedes, and author when absent" do
      content = <<-MD
        ---
        id: 20260710153000
        title: Minimal memory
        ---

        Just a body.
        MD
      memory = Engram::MemoryFile.parse(content, "20260710153000_minimal-memory.md")

      memory.topics.should eq([] of String)
      memory.supersedes.should eq([] of Int64)
      memory.author.should be_nil
    end

    it "parses a populated supersedes array of ids" do
      content = <<-MD
        ---
        id: 20260710153000
        title: Supersedes something
        supersedes: [20260101000000, 20260102000000]
        ---

        Body text.
        MD
      memory = Engram::MemoryFile.parse(content, "20260710153000_supersedes-something.md")
      memory.supersedes.should eq([20260101000000_i64, 20260102000000_i64])
    end

    it "raises Engram::ParseError when the filename doesn't match <ID>_<slug>.md" do
      expect_raises(Engram::ParseError, /does not match/) do
        Engram::MemoryFile.parse(VALID_CONTENT, "not-a-valid-filename.md")
      end
    end

    it "raises Engram::ParseError when the frontmatter id doesn't match the filename id" do
      content = <<-MD
        ---
        id: 19990101000000
        title: Mismatched id
        ---

        Body.
        MD
      expect_raises(Engram::ParseError, /does not match filename id/) do
        Engram::MemoryFile.parse(content, "20260710153000_mismatched-id.md")
      end
    end

    it "raises Engram::ParseError when the file doesn't start with a frontmatter fence" do
      content = "no frontmatter here\n"
      expect_raises(Engram::ParseError, /expected frontmatter/) do
        Engram::MemoryFile.parse(content, "20260710153000_no-fence.md")
      end
    end

    it "raises Engram::ParseError when the frontmatter is never closed" do
      content = <<-MD
        ---
        id: 20260710153000
        title: Unclosed
        MD
      expect_raises(Engram::ParseError, /never closed/) do
        Engram::MemoryFile.parse(content, "20260710153000_unclosed.md")
      end
    end

    it "raises Engram::ParseError on a malformed frontmatter line" do
      content = <<-MD
        ---
        id: 20260710153000
        this is not key value
        title: Bad line
        ---

        Body.
        MD
      expect_raises(Engram::ParseError, /malformed frontmatter line/) do
        Engram::MemoryFile.parse(content, "20260710153000_bad-line.md")
      end
    end

    it "raises Engram::ParseError when a required key is missing" do
      content = <<-MD
        ---
        id: 20260710153000
        ---

        Body.
        MD
      expect_raises(Engram::ParseError, /missing required key 'title'/) do
        Engram::MemoryFile.parse(content, "20260710153000_missing-title.md")
      end
    end

    it "raises Engram::ParseError when id is not a plain integer" do
      content = <<-MD
        ---
        id: not-a-number
        title: Bad id
        ---

        Body.
        MD
      expect_raises(Engram::ParseError, /not a plain integer/) do
        Engram::MemoryFile.parse(content, "20260710153000_bad-id.md")
      end
    end

    it "raises Engram::ParseError on a duplicated frontmatter key" do
      content = <<-MD
        ---
        id: 20260710153000
        title: First title
        title: Second title
        ---

        Body.
        MD
      expect_raises(Engram::ParseError, /duplicate frontmatter key/) do
        Engram::MemoryFile.parse(content, "20260710153000_dup-key.md")
      end
    end

    it "raises Engram::ParseError on a malformed array value" do
      content = <<-MD
        ---
        id: 20260710153000
        title: Bad array
        topics: storage, architecture
        ---

        Body.
        MD
      expect_raises(Engram::ParseError, /expected array value/) do
        Engram::MemoryFile.parse(content, "20260710153000_bad-array.md")
      end
    end
  end

  describe "#content_hash" do
    it "is stable across re-parses of the same content" do
      a = Engram::MemoryFile.parse(VALID_CONTENT, "20260710153000_chose-sqlite-over-postgres.md")
      b = Engram::MemoryFile.parse(VALID_CONTENT, "20260710153000_chose-sqlite-over-postgres.md")
      a.content_hash.should eq(b.content_hash)
    end

    it "changes when the body changes" do
      other_content = VALID_CONTENT.sub("Use a per-clone SQLite file", "Use a shared Postgres database")
      a = Engram::MemoryFile.parse(VALID_CONTENT, "20260710153000_chose-sqlite-over-postgres.md")
      b = Engram::MemoryFile.parse(other_content, "20260710153000_chose-sqlite-over-postgres.md")
      a.content_hash.should_not eq(b.content_hash)
    end
  end

  describe "#serialize and .scaffold" do
    it "round-trips a scaffolded memory through serialize and parse" do
      id = 20260710153000_i64
      scaffolded = Engram::MemoryFile.scaffold(id, "A brand new decision", topics: ["testing"], author: "seth")
      slug = Engram::MemoryFile.slugify("A brand new decision")
      filename = "#{id}_#{slug}.md"

      reparsed = Engram::MemoryFile.parse(scaffolded, filename)
      reparsed.id.should eq(id)
      reparsed.slug.should eq(slug)
      reparsed.title.should eq("A brand new decision")
      reparsed.topics.should eq(["testing"])
      reparsed.author.should eq("seth")
    end

    it "round-trips an existing memory through serialize" do
      memory = Engram::MemoryFile.parse(VALID_CONTENT, "20260710153000_chose-sqlite-over-postgres.md")
      reparsed = Engram::MemoryFile.parse(memory.serialize, memory.filename)

      reparsed.id.should eq(memory.id)
      reparsed.title.should eq(memory.title)
      reparsed.topics.should eq(memory.topics)
      reparsed.supersedes.should eq(memory.supersedes)
      reparsed.author.should eq(memory.author)
      reparsed.content_hash.should eq(memory.content_hash)
    end

    it "omits the author line when there is no author" do
      memory = Engram::MemoryFile.parse(<<-MD, "20260710153000_no-author.md")
        ---
        id: 20260710153000
        title: No author here
        ---

        Body.
        MD
      memory.serialize.should_not contain("author:")
    end

    it "round-trips a title containing ' #' without truncating it at the hash" do
      memory = Engram::MemoryFile.new(
        id: 20260710153000_i64, slug: "reason-2", title: "Reason #2 for choosing X",
        topics: [] of String, supersedes: [] of Int64, author: nil, body: "Body.", file_path: "",
      )
      reparsed = Engram::MemoryFile.parse(memory.serialize, memory.filename)
      reparsed.title.should eq("Reason #2 for choosing X")
    end

    it "round-trips a title that starts with an embedded quote character" do
      memory = Engram::MemoryFile.new(
        id: 20260710153000_i64, slug: "quoted-title", title: %q("Special" release notes),
        topics: [] of String, supersedes: [] of Int64, author: nil, body: "Body.", file_path: "",
      )
      reparsed = Engram::MemoryFile.parse(memory.serialize, memory.filename)
      reparsed.title.should eq(%q("Special" release notes))
    end

    it "round-trips a topic containing a comma as a single item, not two" do
      memory = Engram::MemoryFile.new(
        id: 20260710153000_i64, slug: "comma-topic", title: "Comma in topic",
        topics: ["a, b", "c"], supersedes: [] of Int64, author: nil, body: "Body.", file_path: "",
      )
      reparsed = Engram::MemoryFile.parse(memory.serialize, memory.filename)
      reparsed.topics.should eq(["a, b", "c"])
    end

    it "preserves leading indentation on a body that starts with an indented code block" do
      body = "    def foo\n      bar\n    end"
      memory = Engram::MemoryFile.new(
        id: 20260710153000_i64, slug: "indented-body", title: "Indented body",
        topics: [] of String, supersedes: [] of Int64, author: nil, body: body, file_path: "",
      )
      reparsed = Engram::MemoryFile.parse(memory.serialize, memory.filename)
      reparsed.body.should eq(body)
    end

    it "preserves blank lines surrounding the body beyond the single mandatory separator" do
      body = "\nFirst line has a blank line above it.\n\nAnd a trailing blank line below.\n"
      memory = Engram::MemoryFile.new(
        id: 20260710153000_i64, slug: "blank-lines", title: "Blank lines",
        topics: [] of String, supersedes: [] of Int64, author: nil, body: body, file_path: "",
      )
      reparsed = Engram::MemoryFile.parse(memory.serialize, memory.filename)
      reparsed.body.should eq(body)
    end
  end

  describe ".claim_and_write" do
    it "never silently overwrites: two claims racing on an identical title in the same frozen second get different ids" do
      SpecHelper.with_tempdir do |dir|
        frozen = Time.utc(2026, 7, 10, 15, 30, 0)
        title = "Same Title Race"
        slug = Engram::MemoryFile.slugify(title)

        id_a, path_a = Engram::MemoryFile.claim_and_write(dir, slug, frozen) { |id| Engram::MemoryFile.scaffold(id, title) }
        id_b, path_b = Engram::MemoryFile.claim_and_write(dir, slug, frozen) { |id| Engram::MemoryFile.scaffold(id, title) }

        # No silent last-writer-wins clobber: the second claim got a bumped
        # id (not the same one), a distinct path, and both files persist with
        # their own correct, uncorrupted content.
        id_a.should_not eq(id_b)
        id_b.should eq(id_a + 1)
        path_a.should_not eq(path_b)

        File.exists?(path_a).should be_true
        File.exists?(path_b).should be_true
        Engram::MemoryFile.parse(File.read(path_a), path_a).id.should eq(id_a)
        Engram::MemoryFile.parse(File.read(path_b), path_b).id.should eq(id_b)

        # No stray staging temp files left behind in the memories dir.
        Dir.glob(File.join(dir, "*")).map { |p| File.basename(p) }.sort.should eq(
          ["#{id_a}_#{slug}.md", "#{id_b}_#{slug}.md"].sort
        )
      end
    end

    it "claims the id the block actually receives, not a stale one computed beforehand" do
      SpecHelper.with_tempdir do |dir|
        slug = "check-id"
        id, path = Engram::MemoryFile.claim_and_write(dir, slug) { |claimed_id| "id was #{claimed_id}" }
        File.read(path).should eq("id was #{id}")
      end
    end
  end

  describe ".slugify" do
    it "lowercases and dasherizes a title" do
      Engram::MemoryFile.slugify("Chose SQLite over Postgres!").should eq("chose-sqlite-over-postgres")
    end

    it "falls back to 'memory' when nothing alphanumeric remains" do
      Engram::MemoryFile.slugify("!!!").should eq("memory")
    end
  end

  describe ".check_duplicates" do
    it "raises Engram::DuplicateIdError when two files share an id" do
      a = Engram::MemoryFile.parse(VALID_CONTENT, "20260710153000_a.md")
      b = Engram::MemoryFile.parse(VALID_CONTENT.sub("Chose SQLite", "Chose Something Else"), "20260710153000_b.md")

      expect_raises(Engram::DuplicateIdError, /duplicate memory id 20260710153000/) do
        Engram::MemoryFile.check_duplicates([a, b])
      end
    end

    it "does not raise when all ids are unique" do
      a = Engram::MemoryFile.parse(VALID_CONTENT, "20260710153000_a.md")
      other_content = VALID_CONTENT.sub("id: 20260710153000", "id: 20260710153001")
      b = Engram::MemoryFile.parse(other_content, "20260710153001_b.md")

      Engram::MemoryFile.check_duplicates([a, b])
    end
  end
end
