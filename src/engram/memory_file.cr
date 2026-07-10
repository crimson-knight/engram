require "digest/sha256"
require "time"

module Engram
  # Raised when a memory migration file cannot be parsed: bad frontmatter,
  # a filename that doesn't match the `<ID>_<slug>.md` convention, or a
  # frontmatter `id` that disagrees with the filename's id.
  class ParseError < Exception
    # Builds a "<path>:<line>: <reason>" message so the failure points straight at the file.
    def initialize(path : String, line : Int32, reason : String)
      super("#{path}:#{line}: #{reason}")
    end
  end

  # Raised when two memory files in the same tree declare the same `id`.
  #
  # This is deliberate: id collisions are decision conflicts and should fail
  # loudly (at merge/sync time) rather than silently last-write-win.
  class DuplicateIdError < Exception
    # Builds a message naming the offending id and both file paths.
    def initialize(id : Int64, path_a : String, path_b : String)
      super("duplicate memory id #{id}: #{path_a} and #{path_b}")
    end
  end

  # A single parsed memory migration file: frontmatter metadata plus markdown body.
  #
  # Files live at `.agents/memories/<ID>_<slug>.md`. The filename is
  # canonical for `id` and `slug`; the frontmatter `id` must match it.
  struct MemoryFile
    # Matches `<14-digit-id>_<slug>.md`; captures the id and slug portions.
    FILENAME_PATTERN = /\A(\d{14})_(.+)\.md\z/

    getter id : Int64
    getter slug : String
    getter title : String
    getter topics : Array(String)
    getter supersedes : Array(Int64)
    getter author : String?
    getter body : String
    getter file_path : String

    # Builds a memory file record from already-parsed fields.
    def initialize(@id : Int64, @slug : String, @title : String, @topics : Array(String),
                   @supersedes : Array(Int64), @author : String?, @body : String, @file_path : String)
    end

    # Reads and parses the memory file at *path* from disk.
    def self.parse(path : String) : MemoryFile
      parse(File.read(path), path)
    end

    # Parses raw migration-file *content*, using *path* for filename validation and error context.
    def self.parse(content : String, path : String) : MemoryFile
      filename = File.basename(path)
      filename_match = FILENAME_PATTERN.match(filename)
      raise ParseError.new(path, 1, "filename %s does not match the <ID>_<slug>.md convention" % filename) unless filename_match
      filename_id = filename_match[1].to_i64
      filename_slug = filename_match[2]

      lines = content.split('\n')
      raise ParseError.new(path, 1, "file is empty, expected frontmatter starting with '---'") if lines.empty?
      raise ParseError.new(path, 1, "expected frontmatter to start with '---' on the first line") unless lines[0].strip == "---"

      fields = {} of String => String
      seen_keys = Set(String).new
      closing_line = nil

      index = 1
      while index < lines.size
        raw_line = lines[index]
        line = raw_line.strip
        line_number = index + 1

        if line == "---"
          closing_line = index
          break
        end

        index += 1
        next if line.empty?

        key_match = /\A([A-Za-z_]+):\s*(.*)\z/.match(raw_line.strip)
        raise ParseError.new(path, line_number, "malformed frontmatter line #{raw_line.inspect}, expected 'key: value'") unless key_match
        key = key_match[1]
        raw_value = key_match[2]

        raise ParseError.new(path, line_number, "duplicate frontmatter key '#{key}'") if seen_keys.includes?(key)
        seen_keys << key

        fields[key] = strip_inline_comment(raw_value, path, line_number)
      end

      raise ParseError.new(path, lines.size, "frontmatter never closed with a second '---'") unless closing_line

      raise ParseError.new(path, 1, "frontmatter is missing required key 'id'") unless fields.has_key?("id")
      raise ParseError.new(path, 1, "frontmatter is missing required key 'title'") unless fields.has_key?("title")

      id_field = fields["id"]
      raise ParseError.new(path, 1, "frontmatter id #{id_field.inspect} is not a plain integer") unless id_field =~ /\A\d+\z/
      frontmatter_id = id_field.to_i64

      if frontmatter_id != filename_id
        raise ParseError.new(path, 1, "frontmatter id #{frontmatter_id} does not match filename id #{filename_id}")
      end

      title = unquote(fields["title"])
      topics = fields.has_key?("topics") ? parse_array(fields["topics"], path, 1) : [] of String
      supersedes = fields.has_key?("supersedes") ? parse_array(fields["supersedes"], path, 1).map(&.to_i64) : [] of Int64
      author = fields.has_key?("author") ? unquote(fields["author"]) : nil

      # Recover the body as a byte-exact substring of the original *content*
      # (not a re-joined line array) so nothing about it is normalized away.
      # The only thing we strip is the format's two structural bytes: the
      # single mandatory blank line between the closing fence and the body
      # (`serialize`/`scaffold` always emit "---\n\n"), and the single
      # terminal newline `serialize` always appends. Anything else --
      # leading indentation on the first body line, extra blank lines,
      # trailing blank lines -- is meaningful content and round-trips as-is.
      header = lines[0..closing_line].join('\n')
      raw_body = content[(header.size + 1)..]? || ""
      raw_body = raw_body[1..] if raw_body.starts_with?('\n')
      raw_body = raw_body[0...-1] if raw_body.ends_with?('\n')
      body = raw_body

      new(
        id: frontmatter_id,
        slug: filename_slug,
        title: title,
        topics: topics,
        supersedes: supersedes,
        author: author,
        body: body,
        file_path: path,
      )
    end

    # Strips a trailing ` # comment` from a scalar frontmatter value, respecting `[...]` arrays and quotes.
    private def self.strip_inline_comment(value : String, path : String, line : Int32) : String
      trimmed = value.strip
      return trimmed if trimmed.empty?

      if trimmed.starts_with?('[')
        close_index = find_array_close_bracket(trimmed)
        raise ParseError.new(path, line, "array value #{trimmed.inspect} is missing a closing ']'") unless close_index
        remainder = trimmed[(close_index + 1)..].strip
        unless remainder.empty? || remainder.starts_with?('#')
          raise ParseError.new(path, line, "unexpected trailing content #{remainder.inspect} after array value")
        end
        return trimmed[0..close_index]
      end

      if trimmed.starts_with?('"') || trimmed.starts_with?('\'')
        close_index = find_matching_quote(trimmed, 0)
        raise ParseError.new(path, line, "quoted value #{trimmed.inspect} is missing its closing quote") unless close_index
        remainder = trimmed[(close_index + 1)..].strip
        unless remainder.empty? || remainder.starts_with?('#')
          raise ParseError.new(path, line, "unexpected trailing content #{remainder.inspect} after quoted value")
        end
        return trimmed[0..close_index]
      end

      hash_index = trimmed.index(" #")
      hash_index ? trimmed[0...hash_index].rstrip : trimmed
    end

    # Finds the index of the closing quote matching the opening `"`/`'` at
    # *value*[*start_index*], honoring `\`-escaped quote characters inside it
    # (so a quoted scalar like `"He said \"go\""` isn't cut short at the
    # first embedded quote). Returns nil if the quote is never closed.
    private def self.find_matching_quote(value : String, start_index : Int32) : Int32?
      quote = value[start_index]
      index = start_index + 1
      while index < value.size
        char = value[index]
        if char == '\\' && index + 1 < value.size
          index += 2
        elsif char == quote
          return index
        else
          index += 1
        end
      end
      nil
    end

    # Finds the index of the `]` closing the array value starting at
    # *value*[0] == '[', skipping over any quoted item's contents (which may
    # itself contain `,` or `]`) so `["a, b]", c]` isn't cut short.
    private def self.find_array_close_bracket(value : String) : Int32?
      index = 1
      while index < value.size
        char = value[index]
        if char == '"' || char == '\''
          closing = find_matching_quote(value, index)
          return nil unless closing
          index = closing + 1
        elsif char == ']'
          return index
        else
          index += 1
        end
      end
      nil
    end

    # Removes a matching pair of surrounding quotes from a scalar value, if
    # present, and undoes the `\\`/`\"` escaping `MemoryFile#serialize` uses
    # for values that needed quoting in the first place.
    private def self.unquote(value : String) : String
      if value.size >= 2 && (value[0] == '"' || value[0] == '\'') && value[-1] == value[0]
        unescape_scalar(value[1..-2])
      else
        value
      end
    end

    # Reverses `escape_scalar`: a `\` followed by any character collapses to
    # that character literally (so `\\` -> `\` and `\"` -> `"`).
    private def self.unescape_scalar(value : String) : String
      String.build do |str|
        index = 0
        while index < value.size
          char = value[index]
          if char == '\\' && index + 1 < value.size
            str << value[index + 1]
            index += 2
          else
            str << char
            index += 1
          end
        end
      end
    end

    # Parses a flat `[a, b, c]` (or `[]`) array value into its trimmed, unquoted items.
    private def self.parse_array(value : String, path : String, line : Int32) : Array(String)
      raise ParseError.new(path, line, "expected array value like [a, b], got #{value.inspect}") unless value.starts_with?('[') && value.ends_with?(']')
      inner = value[1..-2].strip
      return [] of String if inner.empty?
      split_array_items(inner).map { |item| unquote(item.strip) }
    end

    # Splits the interior of an array value on top-level commas, treating a
    # quoted item's contents as opaque so `["a, b", c]` yields two items
    # (`a, b` and `c`), not three.
    private def self.split_array_items(inner : String) : Array(String)
      items = [] of String
      start = 0
      index = 0
      while index < inner.size
        char = inner[index]
        if char == '"' || char == '\''
          closing = find_matching_quote(inner, index)
          index = closing ? closing + 1 : inner.size
        elsif char == ','
          items << inner[start...index]
          start = index + 1
          index += 1
        else
          index += 1
        end
      end
      items << inner[start..]
      items
    end

    # SHA256 hex digest over the meaningful fields (not id/slug/path), used by
    # sync to detect whether a memory's content changed since it was applied.
    # Topics are lowercased in the canonical string to match how `Store`
    # persists them (docs/SPEC.md: "comma-joined, lowercased") — otherwise a
    # memory whose frontmatter uses mixed-case topics would hash differently
    # from the record read back from the store and sync would treat it as
    # perpetually changed.
    def content_hash : String
      canonical = [title, topics.map(&.downcase).join(","), supersedes.join(","), author || "", body].join(' ')
      Digest::SHA256.hexdigest(canonical)
    end

    # The canonical filename for this memory: `<id>_<slug>.md`.
    def filename : String
      "#{id}_#{slug}.md"
    end

    # Renders this memory back into migration-file text (frontmatter + body).
    def serialize : String
      String.build do |str|
        str << "---\n"
        str << "id: " << id << '\n'
        str << "title: " << serialize_scalar(title) << '\n'
        str << "topics: [" << topics.map { |topic| serialize_array_item(topic) }.join(", ") << "]\n"
        str << "supersedes: [" << supersedes.join(", ") << "]\n"
        if author_value = author
          str << "author: " << serialize_scalar(author_value) << '\n'
        end
        str << "---\n\n"
        str << body
        str << '\n'
      end
    end

    # True if *value* would be silently corrupted by the frontmatter scanner
    # unless quoted: a " #" substring reads as an inline comment
    # (`strip_inline_comment`), a leading quote character is mistaken for the
    # start of an already-quoted scalar, a colon could be misread as another
    # key/value delimiter by simpler downstream parsers, and a literal `\`
    # needs escaping before the value can be safely quoted at all.
    private def needs_scalar_quoting?(value : String) : Bool
      value.includes?(" #") || value.starts_with?('"') || value.starts_with?('\'') ||
        value.includes?(':') || value.includes?('\\')
    end

    # Everything `needs_scalar_quoting?` covers, plus the characters that are
    # structural inside a flat `[a, b]` array: a comma would be misread as an
    # item separator and a bracket as the array's boundary.
    private def needs_array_item_quoting?(value : String) : Bool
      needs_scalar_quoting?(value) || value.includes?(',') || value.includes?('[') || value.includes?(']')
    end

    # Backslash-escapes *value* so it can be safely wrapped in double quotes:
    # `\` -> `\\`, `"` -> `\"`. `unescape_scalar` (parse side) reverses this.
    private def escape_scalar(value : String) : String
      String.build do |str|
        value.each_char do |char|
          case char
          when '\\' then str << "\\\\"
          when '"'  then str << "\\\""
          else           str << char
          end
        end
      end
    end

    private def quote_scalar(value : String) : String
      %("#{escape_scalar(value)}")
    end

    # Quotes *value* only if leaving it bare would change its meaning on parse.
    private def serialize_scalar(value : String) : String
      needs_scalar_quoting?(value) ? quote_scalar(value) : value
    end

    # `serialize_scalar`, but for an item inside a `topics`/`supersedes`-style array.
    private def serialize_array_item(value : String) : String
      needs_array_item_quoting?(value) ? quote_scalar(value) : value
    end

    # Builds file content for a brand-new memory (used by `engram new`): a
    # fresh frontmatter block plus a Decision/Why/Rejected body scaffold.
    def self.scaffold(id : Int64, title : String, topics : Array(String) = [] of String,
                      supersedes : Array(Int64) = [] of Int64, author : String? = nil) : String
      body = <<-BODY
        **Decision:**

        **Why:**

        **Rejected:**
        BODY

      new(
        id: id,
        slug: slugify(title),
        title: title,
        topics: topics,
        supersedes: supersedes,
        author: author,
        body: body,
        file_path: "",
      ).serialize
    end

    # Turns a title into a filesystem-safe slug: lowercase, dashes, no repeats.
    def self.slugify(title : String) : String
      slug = title.downcase.gsub(/[^a-z0-9]+/, "-").strip('-')
      slug = slug[0, 60].strip('-') if slug.size > 60
      slug.empty? ? "memory" : slug
    end

    # Raises Engram::DuplicateIdError if any two of *files* share an id.
    def self.check_duplicates(files : Array(MemoryFile)) : Nil
      seen = {} of Int64 => String
      files.each do |file|
        if existing_path = seen[file.id]?
          raise DuplicateIdError.new(file.id, existing_path, file.file_path)
        end
        seen[file.id] = file.file_path
      end
    end

    # The next unused 14-digit migration id for *memories_dir*: the current UTC
    # time, bumped a second at a time until no existing `<id>_*.md` file already
    # claims it, per a one-time directory scan.
    #
    # NOTE: this is a best-effort *peek*, not a claim -- two calls to `next_id`
    # in the same wall-clock second (from two processes, or from `new`/
    # `remember` racing each other) can and will return the same id, because
    # nothing stops either caller's subsequent plain `File.write` from
    # silently truncating whatever the other one just wrote. Anything that's
    # actually about to create the migration file must use `claim_and_write`
    # instead, which makes the id allocation and the file's creation a single
    # atomic step. `next_id` remains only for callers that just want to know
    # what id *would* be used next without writing anything.
    def self.next_id(memories_dir : String) : Int64
      existing = Dir.exists?(memories_dir) ? Dir.glob(File.join(memories_dir, "*.md")).map { |p| File.basename(p) } : [] of String
      time = Time.utc
      loop do
        id = time.to_s("%Y%m%d%H%M%S")
        return id.to_i64 unless existing.any?(&.starts_with?("#{id}_"))
        time = time + 1.second
      end
    end

    # Atomically claims the next unused migration id for a memory whose
    # filename slug is *slug* under *memories_dir*, and publishes the block's
    # result as that file's content in one step. Returns `{id, path}`.
    #
    # This is the race-free replacement for the naive "`next_id` then
    # `File.write`" pattern: that pattern has a TOCTOU gap where two callers
    # (two processes, or two near-simultaneous `remember`/`new` calls) can
    # both land on the same id in the same wall-clock second, and the second
    # `File.write` truncates the first one's file with no error and no
    # duplicate-id detection, because only one file ever ends up on disk.
    #
    # The id -- not the `<id>_<slug>.md` pathname -- is the memory's
    # globally-unique key: two files sharing an id are a duplicate-id conflict
    # even when their slugs (titles) differ, so a candidate id is rejected if
    # ANY `<id>_*.md` already exists, not just one matching this exact slug.
    # We combine two guards to that end:
    #
    # 1. A one-time directory snapshot (like `next_id`): a candidate whose
    #    id-prefix already appears is skipped. This is what makes repeated
    #    claims within the same second -- even with different slugs -- march
    #    forward to distinct ids (the common, single-process case: `engram new`
    #    twice, or an MCP session firing several `remember`s a second apart).
    #
    # 2. For each surviving candidate we write the block's result (the block
    #    receives the candidate id, since the frontmatter embeds it) to a fresh
    #    same-directory temp file, then `File.link` that temp file onto the
    #    final `<id>_<slug>.md` path. `link(2)` is atomic with respect to
    #    existence: if the target already exists -- because a *concurrent*
    #    caller already claimed that exact id/slug pair after our snapshot --
    #    the link fails with `File::AlreadyExistsError` and the existing file is
    #    left completely untouched (the core defect this replaces: a plain
    #    `File.write` would have silently truncated it). On that failure we
    #    discard the temp, bump the id by a second, and retry; on success the
    #    temp is unlinked (it was only ever a staging name) and `{id, path}` is
    #    returned.
    #
    # *memories_dir* must already exist (same precondition as `next_id`;
    # callers already `Dir.mkdir_p` it first). *start_time* defaults to
    # `Time.utc` and exists so specs can freeze the clock to deterministically
    # reproduce two claims racing in the same second.
    def self.claim_and_write(memories_dir : String, slug : String, start_time : Time = Time.utc, & : Int64 -> String) : {Int64, String}
      existing = Dir.exists?(memories_dir) ? Dir.children(memories_dir) : [] of String
      time = start_time
      loop do
        id = time.to_s("%Y%m%d%H%M%S").to_i64
        if existing.any?(&.starts_with?("#{id}_"))
          time += 1.second
          next
        end

        path = File.join(memories_dir, "#{id}_#{slug}.md")
        content = yield id

        tmp = File.tempfile("engram-claim", ".tmp", dir: memories_dir)
        claimed = false
        begin
          tmp.print(content)
          tmp.close
          File.link(tmp.path, path)
          claimed = true
        rescue File::AlreadyExistsError
          time += 1.second
        ensure
          File.delete(tmp.path) if File.exists?(tmp.path)
        end
        return {id, path} if claimed
      end
    end

    # The repo-relative form of *path* (a file living under *memories_dir*):
    # the last two path segments of *memories_dir* (conventionally
    # ".agents/memories") joined with the file's basename. Keeps the `file_path`
    # schema column (docs/SPEC.md: "repo-relative source path") stable no
    # matter how absolute *memories_dir* and *path* happen to be for the caller.
    def self.repo_relative_path(memories_dir : String, path : String) : String
      File.join(File.basename(File.dirname(memories_dir)), File.basename(memories_dir), File.basename(path))
    end
  end
end
