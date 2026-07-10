require "./spec_helper"
require "../src/engram/search"

private def db_path(dir : String) : String
  File.join(dir, "engram.db")
end

# Packs a Float32 vector into the BLOB layout Store#insert_memory expects (the verified reinterpret pattern).
private def pack(vector : Array(Float32)) : Bytes
  slice = Slice(Float32).new(vector.size) { |i| vector[i] }
  Bytes.new(slice.to_unsafe.as(UInt8*), slice.size * 4)
end

private def insert(store : Engram::Store, id : Int64, title : String, body : String,
                   topics : Array(String) = [] of String, supersedes : Array(Int64) = [] of Int64,
                   embedding : Bytes? = nil) : Nil
  store.insert_memory(
    id: id, slug: "slug-#{id}", title: title, topics: topics, author: nil,
    body: body, supersedes: supersedes, file_path: ".agents/memories/#{id}_slug.md", embedding: embedding
  )
end

describe Engram::Search do
  describe "bm25 + recency ordering" do
    it "breaks an exact bm25 tie by recency, ranking the newer memory first" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        # Same title/body shape and same query-term frequency for both -> identical bm25.
        insert(store, 20260101000000_i64, "Old Zephyr Note", "the zephyr module was chosen for this")
        insert(store, 20260401000000_i64, "New Zephyr Note", "the zephyr module was chosen for this")
        store.close

        search = Engram::Search.new(db_path(dir))
        results = search.search("zephyr")
        search.close

        results.map(&.id).should eq([20260401000000_i64, 20260101000000_i64])
        # score is bm25 - recency_boost; the newer row's extra recency_boost subtraction
        # must make its score strictly lower (better) than the tied-bm25 older row's.
        (results[0].score < results[1].score).should be_true
      end
    end

    it "lets a strong keyword match beat a weak one even though it is older" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        # A large corpus of "noise" documents that never mention "gamma" gives the term a
        # meaningful IDF, so bm25 actually discriminates between a 40x repeat and a single,
        # diluted mention -- with only these two documents bm25's dynamic range is too tiny
        # (near-universal terms carry ~zero IDF) for this scenario to be observable at all.
        strong_body = (["gamma"] * 40).join(" ")
        weak_body = "gamma " + (["filler"] * 60).join(" ")
        insert(store, 20260101000000_i64, "Old Strong Gamma Match", strong_body)
        insert(store, 20260401000000_i64, "New Weak Gamma Match", weak_body)
        30.times do |i|
          insert(store, 20260102000000_i64 + i, "Noise #{i}", "this document has nothing to do with the query term at all filler filler filler")
        end
        store.close

        search = Engram::Search.new(db_path(dir))
        results = search.search("gamma", limit: 2)
        search.close

        results.map(&.id).should eq([20260101000000_i64, 20260401000000_i64])
      end
    end

    it "excludes memories that do not match the query at all, with no embedder configured" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 1_i64, "Unrelated", "nothing to do with the query")
        store.close

        search = Engram::Search.new(db_path(dir))
        results = search.search("zzzznomatchtoken")
        search.close

        results.should eq([] of Engram::SearchResult)
      end
    end
  end

  describe "RRF merge with a fake embedder" do
    it "surfaces a keyword-poor, semantically-close memory that pure FTS would miss entirely" do
      SpecHelper.with_tempdir do |dir|
        keyword_vector = pack([1.0_f32, 0.0_f32, 0.0_f32])
        semantic_vector = [0.0_f32, 1.0_f32, 0.0_f32]

        store = Engram::Store.new(db_path(dir))
        # Older, matches the keyword strongly, no embedding stored for it.
        insert(store, 20260105000000_i64, "Chose Redis For Caching", "widget widget widget widget")
        # Newer, zero keyword overlap, but its embedding is exactly the query embedding below.
        insert(store, 20260110000000_i64, "Switched To A Faster Cache Backend",
          "we moved caching to a different backend for latency reasons",
          embedding: pack(semantic_vector))
        store.close

        # Baseline: FTS-only search never surfaces the semantically-close memory.
        fts_only = Engram::Search.new(db_path(dir))
        baseline = fts_only.search("widget")
        fts_only.close
        baseline.map(&.id).should eq([20260105000000_i64])

        # With an embedder whose query embedding matches the semantically-close memory
        # exactly (cosine 1.0), RRF pulls it into the results and, on the resulting exact
        # RRF tie (both are sole-top-of-one-list), the newer memory wins by id.
        embedder = Engram::Search::Embedder.new { |_query| semantic_vector }
        fused = Engram::Search.new(db_path(dir), embedder: embedder)
        results = fused.search("widget")
        fused.close

        results.map(&.id).should eq([20260110000000_i64, 20260105000000_i64])
      end
    end

    it "falls back to FTS-only ordering when the embedder raises" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 1_i64, "Has Embedding", "keyword here", embedding: pack([1.0_f32, 0.0_f32]))
        store.close

        broken_embedder = Engram::Search::Embedder.new { |_query| raise "embedder endpoint unreachable" }
        search = Engram::Search.new(db_path(dir), embedder: broken_embedder)
        results = search.search("keyword")
        search.close

        results.map(&.id).should eq([1_i64])
      end
    end

    it "does not blend embeddings when no candidate has a stored embedding" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 1_i64, "No Embedding Here", "keyword here")
        store.close

        embedder = Engram::Search::Embedder.new { |_query| [1.0_f32, 0.0_f32] }
        search = Engram::Search.new(db_path(dir), embedder: embedder)
        results = search.search("keyword")
        search.close

        results.map(&.id).should eq([1_i64])
      end
    end
  end

  describe "topic filter" do
    it "restricts results to memories tagged with the given topic (case-insensitive)" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 1_i64, "Storage Choice", "keyword storage decision", topics: ["Storage"])
        insert(store, 2_i64, "Networking Choice", "keyword networking decision", topics: ["networking"])
        store.close

        search = Engram::Search.new(db_path(dir))
        by_topic = search.search("keyword", topic: "storage")
        recent_by_topic = search.recent(topic: "STORAGE")
        search.close

        by_topic.map(&.id).should eq([1_i64])
        recent_by_topic.map(&.id).should eq([1_i64])
      end
    end

    it "returns an empty list for a topic no memory has" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 1_i64, "Storage Choice", "keyword storage decision", topics: ["storage"])
        store.close

        search = Engram::Search.new(db_path(dir))
        results = search.search("keyword", topic: "nonexistent")
        search.close

        results.should eq([] of Engram::SearchResult)
      end
    end
  end

  describe "superseded exclusion" do
    it "excludes a superseded memory from search and recent by default, includes it with include_superseded" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 1_i64, "Old Decision", "keyword old decision")
        insert(store, 2_i64, "New Decision", "keyword new decision", supersedes: [1_i64])
        store.set_superseded_by(1_i64, 2_i64)
        store.close

        search = Engram::Search.new(db_path(dir))
        default_search = search.search("keyword")
        all_search = search.search("keyword", include_superseded: true)
        default_recent = search.recent
        all_recent = search.recent(include_superseded: true)
        search.close

        default_search.map(&.id).should eq([2_i64])
        all_search.map(&.id).sort!.should eq([1_i64, 2_i64])
        default_recent.map(&.id).should eq([2_i64])
        all_recent.map(&.id).sort!.should eq([1_i64, 2_i64])
      end
    end
  end

  describe "empty-query and no-match edge cases" do
    it "treats a blank query as newest-first, matching #recent" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 20260101000000_i64, "First", "alpha body")
        insert(store, 20260201000000_i64, "Second", "beta body")
        insert(store, 20260301000000_i64, "Third", "gamma body")
        store.close

        search = Engram::Search.new(db_path(dir))
        blank = search.search("")
        whitespace = search.search("   ")
        recent = search.recent
        search.close

        expected = [20260301000000_i64, 20260201000000_i64, 20260101000000_i64]
        blank.map(&.id).should eq(expected)
        whitespace.map(&.id).should eq(expected)
        recent.map(&.id).should eq(expected)
      end
    end

    it "returns an empty array (not an error) when the store has no memories at all" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        store.close

        search = Engram::Search.new(db_path(dir))
        search.search("anything").should eq([] of Engram::SearchResult)
        search.recent.should eq([] of Engram::SearchResult)
        search.close
      end
    end
  end

  describe "#recent" do
    it "orders newest first and respects limit" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 20260101000000_i64, "First", "alpha body")
        insert(store, 20260201000000_i64, "Second", "beta body")
        insert(store, 20260301000000_i64, "Third", "gamma body")
        store.close

        search = Engram::Search.new(db_path(dir))
        results = search.recent(limit: 2)
        search.close

        results.map(&.id).should eq([20260301000000_i64, 20260201000000_i64])
      end
    end
  end

  describe "SearchResult#to_json" do
    it "serializes id, title, topics, snippet, and score" do
      SpecHelper.with_tempdir do |dir|
        store = Engram::Store.new(db_path(dir))
        insert(store, 1_i64, "JSON Shape", "keyword " + ("padding " * 40), topics: ["storage"])
        store.close

        search = Engram::Search.new(db_path(dir))
        result = search.search("keyword").first
        search.close

        json = result.to_json
        parsed = JSON.parse(json)
        parsed["id"].as_i64.should eq(1_i64)
        parsed["title"].as_s.should eq("JSON Shape")
        parsed["topics"].as_a.map(&.as_s).should eq(["storage"])
        parsed["snippet"].as_s.should end_with("...")
        # Truncated at SNIPPET_LENGTH then rstripped before the ellipsis is appended, so the
        # exact length depends on whether a trailing space fell right at the cut point.
        parsed["snippet"].as_s.size.should be <= 163
        parsed["score"].as_f?.should_not be_nil
      end
    end
  end
end
