require "set"
require "./memory_file"
require "./store"
require "./embedder"

module Engram
  # The outcome of one `Sync.run` pass: which memory ids were applied, rolled
  # back, or updated in place, plus the resulting active count.
  struct SyncResult
    getter applied : Array(Int64)
    getter rolled_back : Array(Int64)
    getter updated : Array(Int64)
    getter active_count : Int32

    # Builds a result from the ids touched by this sync and the resulting active count.
    def initialize(@applied : Array(Int64), @rolled_back : Array(Int64), @updated : Array(Int64), @active_count : Int32)
    end

    # One-line human summary, e.g. "engram: +2 applied, -3 rolled back, 1 updated (47 active)".
    def summary : String
      "engram: +#{applied.size} applied, -#{rolled_back.size} rolled back, #{updated.size} updated (#{active_count} active)"
    end
  end

  # Reconciles the memory migration files on disk (`.agents/memories/*.md`)
  # with the per-clone SQLite cache: new files get applied, files that were
  # deleted get rolled back, files whose content changed get re-applied, and
  # `supersedes` demotion links get recomputed from scratch every pass.
  #
  # Sync only ever looks at the working tree and the store — never git
  # history or branch names — so it is git-agnostic (correct mid-rebase, in
  # detached HEAD, after a stash) and idempotent (rerunning it with nothing
  # changed is a no-op). A deleted or corrupted store is fully rebuilt by the
  # next sync, since every file with no matching row is simply applied.
  module Sync
    # Scans *memories_dir* and reconciles it against *store*; *embedder*, if
    # given, computes embeddings for newly-applied or content-changed
    # memories. Raises Engram::DuplicateIdError if two files in the tree
    # declare the same id (before touching the store at all).
    def self.run(memories_dir : String, store : Store, embedder : Embedder? = nil) : SyncResult
      files = scan(memories_dir)
      MemoryFile.check_duplicates(files)

      files_by_id = {} of Int64 => MemoryFile
      files.each { |file| files_by_id[file.id] = file }

      stored_ids = store.all_ids.to_set
      file_ids = files_by_id.keys.to_set

      rolled_back = rollback_missing(store, stored_ids, file_ids)
      applied, updated = apply_and_update(memories_dir, store, files_by_id, stored_ids, embedder)

      recompute_superseded_by(store, files_by_id)
      reembed_on_dimension_change(store, embedder, files_by_id, applied, updated) if embedder

      SyncResult.new(
        applied: applied,
        rolled_back: rolled_back,
        updated: updated,
        active_count: store.counts[:active],
      )
    end

    # Parses every `*.md` file in *memories_dir*; an absent directory scans as empty (nothing to sync yet).
    private def self.scan(memories_dir : String) : Array(MemoryFile)
      return [] of MemoryFile unless Dir.exists?(memories_dir)
      Dir.glob(File.join(memories_dir, "*.md")).sort.map { |path| MemoryFile.parse(path) }
    end

    # Deletes every stored row whose file disappeared from the tree; returns the ids rolled back.
    private def self.rollback_missing(store : Store, stored_ids : Set(Int64), file_ids : Set(Int64)) : Array(Int64)
      ids = (stored_ids - file_ids).to_a.sort
      ids.each { |id| store.delete_memory(id) }
      ids
    end

    # Inserts memories that are new to the store and re-applies ones whose content, slug, or
    # path changed; returns (applied, updated) ids. `file_path` is always stored repo-relative
    # (docs/SPEC.md's schema contract), derived from *memories_dir* rather than the tree-walk's
    # absolute path.
    private def self.apply_and_update(memories_dir : String, store : Store, files_by_id : Hash(Int64, MemoryFile),
                                      stored_ids : Set(Int64), embedder : Embedder?) : {Array(Int64), Array(Int64)}
      applied = [] of Int64
      updated = [] of Int64

      files_by_id.keys.sort.each do |id|
        memory = files_by_id[id]
        relative_path = MemoryFile.repo_relative_path(memories_dir, memory.file_path)

        if stored_ids.includes?(id)
          existing = store.get(id).not_nil!
          next unless content_changed?(memory, existing, relative_path)

          embedding = embedder.try(&.embed(embed_text(memory))) || existing.embedding
          store.update_memory(
            id: memory.id, slug: memory.slug, title: memory.title, topics: memory.topics,
            author: memory.author, body: memory.body, supersedes: memory.supersedes,
            file_path: relative_path, embedding: embedding,
          )
          updated << id
        else
          embedding = embedder.try(&.embed(embed_text(memory)))
          store.insert_memory(
            id: memory.id, slug: memory.slug, title: memory.title, topics: memory.topics,
            author: memory.author, body: memory.body, supersedes: memory.supersedes,
            file_path: relative_path, embedding: embedding,
          )
          applied << id
        end
      end

      {applied, updated}
    end

    # True when *memory*'s content differs from the *existing* stored record, OR when the file
    # was renamed/moved on disk (same id, same content_hash, but a different slug or
    # *relative_path*) — a rename alone must still trigger an in-place update, or the stored
    # slug/file_path go stale until the body next changes.
    private def self.content_changed?(memory : MemoryFile, existing : MemoryRecord, relative_path : String) : Bool
      return true if memory.slug != existing.slug
      return true if relative_path != existing.file_path

      existing_as_file = MemoryFile.new(
        id: existing.id, slug: existing.slug, title: existing.title, topics: existing.topics,
        supersedes: existing.supersedes, author: existing.author, body: existing.body,
        file_path: existing.file_path,
      )
      memory.content_hash != existing_as_file.content_hash
    end

    # The text handed to the embedder for a memory: title plus body.
    private def self.embed_text(memory : MemoryFile) : String
      "#{memory.title}\n\n#{memory.body}"
    end

    # Recomputes every memory's `superseded_by` link from the current tree's
    # `supersedes` declarations. Runs unconditionally each sync (cheap, and
    # simplest way to also un-supersede a memory whose demotion was removed).
    # When more than one active memory supersedes the same id, the newest
    # (highest id) superseder wins.
    private def self.recompute_superseded_by(store : Store, files_by_id : Hash(Int64, MemoryFile)) : Nil
      demoted_by = {} of Int64 => Int64

      files_by_id.each_value do |memory|
        memory.supersedes.each do |old_id|
          next if old_id == memory.id
          next unless files_by_id.has_key?(old_id)

          current = demoted_by[old_id]?
          demoted_by[old_id] = memory.id if current.nil? || memory.id > current
        end
      end

      files_by_id.each_key do |id|
        store.set_superseded_by(id, demoted_by[id]?)
      end
    end

    # If the embedder's output dimension differs from the one last recorded
    # in `engram_meta`, re-embeds every active memory that this pass didn't
    # already (re-)embed, then records the new dimension. A no-op when the
    # embedder never produced a vector this pass (nothing to compare).
    private def self.reembed_on_dimension_change(store : Store, embedder : Embedder, files_by_id : Hash(Int64, MemoryFile),
                                                 applied : Array(Int64), updated : Array(Int64)) : Nil
      new_dimension = embedder.dimension
      return unless new_dimension

      previous_dimension = store.meta("embedding_dimension")
      if previous_dimension && previous_dimension.to_i != new_dimension
        STDERR.puts "engram: warning: embedding dimension changed from #{previous_dimension} to #{new_dimension}; re-embedding all memories"

        already_embedded = (applied + updated).to_set
        files_by_id.each do |id, memory|
          next if already_embedded.includes?(id)

          embedding = embedder.embed(embed_text(memory))
          next unless embedding

          record = store.get(id).not_nil!
          store.update_memory(
            id: id, slug: record.slug, title: record.title, topics: record.topics, author: record.author,
            body: record.body, supersedes: record.supersedes, file_path: record.file_path, embedding: embedding,
          )
        end
      end

      store.set_meta("embedding_dimension", new_dimension.to_s)
    end
  end
end
