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

      body_lines = lines[(closing_line + 1)..]
      body = body_lines.join('\n').strip

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
        close_index = trimmed.index(']')
        raise ParseError.new(path, line, "array value #{trimmed.inspect} is missing a closing ']'") unless close_index
        remainder = trimmed[(close_index + 1)..].strip
        unless remainder.empty? || remainder.starts_with?('#')
          raise ParseError.new(path, line, "unexpected trailing content #{remainder.inspect} after array value")
        end
        return trimmed[0..close_index]
      end

      if trimmed.starts_with?('"') || trimmed.starts_with?('\'')
        quote = trimmed[0]
        close_index = trimmed.index(quote, 1)
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

    # Removes a matching pair of surrounding quotes from a scalar value, if present.
    private def self.unquote(value : String) : String
      if value.size >= 2 && (value[0] == '"' || value[0] == '\'') && value[-1] == value[0]
        value[1..-2]
      else
        value
      end
    end

    # Parses a flat `[a, b, c]` (or `[]`) array value into its trimmed, unquoted items.
    private def self.parse_array(value : String, path : String, line : Int32) : Array(String)
      raise ParseError.new(path, line, "expected array value like [a, b], got #{value.inspect}") unless value.starts_with?('[') && value.ends_with?(']')
      inner = value[1..-2].strip
      return [] of String if inner.empty?
      inner.split(',').map { |item| unquote(item.strip) }
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
        str << "title: " << title << '\n'
        str << "topics: [" << topics.join(", ") << "]\n"
        str << "supersedes: [" << supersedes.join(", ") << "]\n"
        if author_value = author
          str << "author: " << author_value << '\n'
        end
        str << "---\n\n"
        str << body
        str << '\n'
      end
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
    # claims it. Shared by `engram new` (`Cli.next_migration_id`) and the MCP
    # `remember` tool so that firing several `remember` calls within the same
    # wall-clock second can never mint the same id twice.
    def self.next_id(memories_dir : String) : Int64
      existing = Dir.exists?(memories_dir) ? Dir.glob(File.join(memories_dir, "*.md")).map { |p| File.basename(p) } : [] of String
      time = Time.utc
      loop do
        id = time.to_s("%Y%m%d%H%M%S")
        return id.to_i64 unless existing.any?(&.starts_with?("#{id}_"))
        time = time + 1.second
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
