require "db"
require "sqlite3"
require "json"

module Engram
  # A single ranked result from `Search#search` or `Search#recent`.
  #
  # `score` is only meaningful within one call, and its ordering convention
  # depends on how the call was answered: plain bm25+recency results carry a
  # score that sorts ascending (lower is better — the FTS5 bm25 convention,
  # nudged by the recency boost), while results blended with embeddings via
  # Reciprocal Rank Fusion carry an RRF score that sorts descending (higher is
  # better). `Search` always returns results already in the right order for
  # whichever path produced them — `score` is exposed for transparency and
  # `--json` output, not for the caller to re-sort by.
  struct SearchResult
    include JSON::Serializable

    getter id : Int64
    getter title : String
    getter topics : Array(String)
    getter snippet : String
    getter score : Float64

    # Builds a search result from already-computed fields.
    def initialize(@id : Int64, @title : String, @topics : Array(String), @snippet : String, @score : Float64)
    end
  end

  # Ranks the memories materialized in a Store's SQLite cache: FTS5 bm25 full-text
  # search blended with a recency boost, optionally fused with brute-force cosine
  # similarity over embeddings (Reciprocal Rank Fusion) when both an embedder and
  # stored embeddings are available.
  #
  # `Store` deliberately exposes only CRUD (no raw FTS5/bm25 query surface), so
  # `Search` opens its own independent connection to the same sqlite file — the
  # pattern `spec/store_spec.cr` already establishes with its `raw_match` helper.
  # Point `Search.new` at the same `db_path` used to build the `Store`.
  class Search
    @db : DB::Database

    # Reciprocal Rank Fusion smoothing constant (spec-mandated).
    RRF_K = 60

    # Recency boost weight: recency_boost = w * (id - oldest) / (newest - oldest) (spec-mandated, w = 1.0).
    RECENCY_WEIGHT = 1.0

    # Characters kept in a snippet before truncation.
    SNIPPET_LENGTH = 160

    # A query-text-to-embedding callable (e.g. backed by `Engram::Embedder`); optional, never required.
    alias Embedder = Proc(String, Array(Float32))

    # A memory row loaded for ranking, restricted to this call's topic/superseded filters.
    private struct Candidate
      getter id : Int64
      getter title : String
      getter topics : Array(String)
      getter body : String
      getter embedding : Bytes?

      # Builds a candidate from already-decoded columns.
      def initialize(@id : Int64, @title : String, @topics : Array(String), @body : String, @embedding : Bytes?)
      end
    end

    # Opens a connection to the sqlite database at *db_path* (already created and
    # populated via `Store` + `sync`). *embedder*, if given, turns query text into
    # a query embedding for cosine/RRF blending; omit it to search FTS5-only.
    def initialize(@db_path : String, @embedder : Embedder? = nil)
      @db = DB.open("sqlite3://#{@db_path}")
    end

    # Closes the underlying database connection.
    def close : Nil
      @db.close
    end

    # Full-text search over memories: bm25-ranked and recency-boosted, and RRF-fused
    # with cosine similarity over embeddings when the store has them and an embedder
    # was supplied. A blank *query* degrades to newest-first (like `recent`). Superseded
    # memories are excluded unless *include_superseded* is true.
    def search(query : String, topic : String? = nil, limit : Int32 = 10, include_superseded : Bool = false) : Array(SearchResult)
      candidates = load_candidates(topic, include_superseded)
      return [] of SearchResult if candidates.empty?

      by_id = {} of Int64 => Candidate
      candidates.each { |c| by_id[c.id] = c }
      oldest, newest = recency_bounds(candidates)

      tokens = sanitize_tokens(query)
      return recency_only_results(candidates, oldest, newest, limit) if tokens.empty?

      fts_scores = fts_scores_for(tokens, by_id, oldest, newest)
      cosine_scores = embeddable?(candidates) ? cosine_scores_for(query, candidates) : nil

      if cosine_scores
        rrf = rrf_merge(fts_scores, cosine_scores)
        ids = rrf.keys.sort_by { |id| {-rrf[id], -id} }
        ids.first(limit).map { |id| build_result(by_id[id], rrf[id]) }
      else
        ids = fts_scores.keys.sort_by { |id| {fts_scores[id], -id} }
        ids.first(limit).map { |id| build_result(by_id[id], fts_scores[id]) }
      end
    end

    # Newest-first memories, optionally filtered by *topic*. Superseded memories are
    # excluded unless *include_superseded* is true. `score` on each result is its recency boost.
    def recent(topic : String? = nil, limit : Int32 = 10, include_superseded : Bool = false) : Array(SearchResult)
      candidates = load_candidates(topic, include_superseded)
      return [] of SearchResult if candidates.empty?

      oldest, newest = recency_bounds(candidates)
      recency_only_results(candidates, oldest, newest, limit)
    end

    # Builds the newest-first, recency-scored list shared by a blank-query `search` and by `recent`.
    private def recency_only_results(candidates : Array(Candidate), oldest : Int64, newest : Int64, limit : Int32) : Array(SearchResult)
      candidates.sort_by { |c| -c.id }.first(limit).map { |c| build_result(c, recency_boost(c.id, oldest, newest)) }
    end

    # Loads memories from the store passing the superseded/topic filters — this call's ranking population.
    private def load_candidates(topic : String?, include_superseded : Bool) : Array(Candidate)
      sql = String.build do |s|
        s << "SELECT id, title, topics, body, embedding FROM memories"
        s << " WHERE superseded_by IS NULL" unless include_superseded
      end

      rows = [] of Candidate
      @db.query_each(sql) do |rs|
        id = rs.read(Int64)
        title = rs.read(String)
        topics_csv = rs.read(String)
        body = rs.read(String)
        embedding = rs.read(Bytes?)
        topics = topics_csv.empty? ? [] of String : topics_csv.split(',')
        rows << Candidate.new(id: id, title: title, topics: topics, body: body, embedding: embedding)
      end

      return rows unless topic
      wanted = topic.downcase
      rows.select { |c| c.topics.any? { |t| t.downcase == wanted } }
    end

    # The (oldest, newest) id bounds this call's recency boost normalizes against — the
    # spec's "active ids": this call's own topic/superseded-filtered candidate population.
    private def recency_bounds(candidates : Array(Candidate)) : Tuple(Int64, Int64)
      ids = candidates.map(&.id)
      {ids.min, ids.max}
    end

    # `w * (id - oldest) / (newest - oldest)`, guarded against a zero-width range (a single id, or all tied).
    private def recency_boost(id : Int64, oldest : Int64, newest : Int64) : Float64
      return 0.0 if newest == oldest
      RECENCY_WEIGHT * (id - oldest).to_f64 / (newest - oldest).to_f64
    end

    # Extracts lowercase word tokens from free-text *query*, dropping FTS5 syntax characters
    # (quotes, hyphens, colons, ...) that would otherwise make arbitrary user input an invalid
    # MATCH pattern. An empty token list means "blank query" to the caller.
    private def sanitize_tokens(query : String) : Array(String)
      query.downcase.scan(/[a-z0-9_]+/).map(&.[0])
    end

    # Runs the FTS5 MATCH query for *tokens* (ANDed, the FTS5 default) and returns
    # `id => bm25_rank - recency_boost` for candidates present in *by_id* — the id
    # world is intersected with this call's topic/superseded filters here.
    private def fts_scores_for(tokens : Array(String), by_id : Hash(Int64, Candidate), oldest : Int64, newest : Int64) : Hash(Int64, Float64)
      match = tokens.join(" ")
      scores = {} of Int64 => Float64
      @db.query_each("SELECT rowid, bm25(memories_fts) FROM memories_fts WHERE memories_fts MATCH ?", match) do |rs|
        id = rs.read(Int64)
        bm25 = rs.read(Float64)
        next unless by_id.has_key?(id)
        scores[id] = bm25 - recency_boost(id, oldest, newest)
      end
      scores
    end

    # True if an embedder is configured and at least one candidate carries a stored embedding.
    private def embeddable?(candidates : Array(Candidate)) : Bool
      !@embedder.nil? && candidates.any? { |c| c.embedding }
    end

    # Embeds *query* and returns `id => cosine_similarity` for every candidate carrying an
    # embedding of matching dimension. Returns nil (no cosine ranking) if the embedder is
    # unset, raises, or none of the stored embeddings line up with the query vector's size.
    private def cosine_scores_for(query : String, candidates : Array(Candidate)) : Hash(Int64, Float64)?
      embedder = @embedder
      return nil unless embedder

      query_vector = begin
        embedder.call(query)
      rescue
        nil
      end
      return nil unless query_vector

      scores = {} of Int64 => Float64
      candidates.each do |c|
        next unless bytes = c.embedding
        vector = unpack_embedding(bytes)
        next unless vector.size == query_vector.size
        scores[c.id] = cosine_similarity(query_vector, vector)
      end
      scores.empty? ? nil : scores
    end

    # Unpacks a packed-Float32 BLOB column back into an Array(Float32) (the verified reinterpret pattern).
    private def unpack_embedding(bytes : Bytes) : Array(Float32)
      Slice(Float32).new(bytes.to_unsafe.as(Float32*), bytes.size // 4).to_a
    end

    # Cosine similarity between two equal-length vectors; 0.0 if either is the zero vector.
    private def cosine_similarity(a : Array(Float32), b : Array(Float32)) : Float64
      dot = 0.0
      norm_a = 0.0
      norm_b = 0.0
      a.each_with_index do |value, i|
        dot += value.to_f64 * b[i].to_f64
        norm_a += value.to_f64 ** 2
        norm_b += b[i].to_f64 ** 2
      end
      return 0.0 if norm_a == 0.0 || norm_b == 0.0
      dot / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
    end

    # Reciprocal Rank Fusion (k=60) of the bm25+recency ranking and the cosine ranking: each
    # id's score sums `1 / (k + rank)` across whichever of the two rankings it appears in — an
    # id absent from a ranking contributes 0 for it, which is exactly how a memory with no FTS
    # match at all can still surface (and rank) purely on cosine similarity.
    private def rrf_merge(fts_scores : Hash(Int64, Float64), cosine_scores : Hash(Int64, Float64)) : Hash(Int64, Float64)
      fts_rank = {} of Int64 => Int32
      fts_scores.keys.sort_by { |id| fts_scores[id] }.each_with_index { |id, i| fts_rank[id] = i + 1 }

      cosine_rank = {} of Int64 => Int32
      cosine_scores.keys.sort_by { |id| -cosine_scores[id] }.each_with_index { |id, i| cosine_rank[id] = i + 1 }

      merged = {} of Int64 => Float64
      (fts_rank.keys + cosine_rank.keys).uniq.each do |id|
        score = 0.0
        score += 1.0 / (RRF_K + fts_rank[id]) if fts_rank.has_key?(id)
        score += 1.0 / (RRF_K + cosine_rank[id]) if cosine_rank.has_key?(id)
        merged[id] = score
      end
      merged
    end

    # Builds the public SearchResult for *candidate* at the given final *score*.
    private def build_result(candidate : Candidate, score : Float64) : SearchResult
      SearchResult.new(
        id: candidate.id,
        title: candidate.title,
        topics: candidate.topics,
        snippet: snippet_for(candidate.body),
        score: score,
      )
    end

    # A single-line, whitespace-collapsed preview of *body*, truncated to SNIPPET_LENGTH with an ellipsis.
    private def snippet_for(body : String) : String
      flat = body.gsub(/\s+/, " ").strip
      return flat if flat.size <= SNIPPET_LENGTH
      flat[0, SNIPPET_LENGTH].rstrip + "..."
    end
  end
end
