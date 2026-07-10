module Engram
  # Installs/uninstalls the three git hooks (`post-checkout`, `post-merge`,
  # `post-rewrite`) that keep the per-clone cache in sync automatically:
  # each just runs `engram sync --quiet`. Every managed block is wrapped in
  # marker comments so `uninstall` can remove exactly what `install` added,
  # regardless of whatever else lives in the hook file.
  module Hooks
    # The three lifecycle hooks that correspond to "the working tree just changed underneath us".
    HOOK_NAMES = ["post-checkout", "post-merge", "post-rewrite"]

    # Opens the engram-managed block in a hook file.
    MARKER_START = "# >>> engram >>>"
    # Closes the engram-managed block in a hook file.
    MARKER_END = "# <<< engram <<<"

    # Installs the engram sync snippet into each of `HOOK_NAMES` under *git_dir*/hooks
    # (creating the hook file with a shebang if it doesn't exist yet; appending, guarded
    # by the marker comments, if it does). Returns the names actually installed — a hook
    # that already carries the marker is left untouched and excluded from the result.
    def self.install(git_dir : String) : Array(String)
      hooks_dir = File.join(git_dir, "hooks")
      Dir.mkdir_p(hooks_dir) unless Dir.exists?(hooks_dir)

      HOOK_NAMES.select { |name| install_into(File.join(hooks_dir, name)) }
    end

    # Removes the engram-managed block from each of `HOOK_NAMES` under *git_dir*/hooks.
    # A hook file left with nothing but a shebang (or nothing at all) after removal is
    # deleted outright. Returns the names actually removed.
    def self.uninstall(git_dir : String) : Array(String)
      hooks_dir = File.join(git_dir, "hooks")

      HOOK_NAMES.select do |name|
        path = File.join(hooks_dir, name)
        File.exists?(path) && uninstall_from(path)
      end
    end

    # Appends (or creates) the marker-guarded snippet at *path*; returns false if it was already present.
    private def self.install_into(path : String) : Bool
      if File.exists?(path)
        content = File.read(path)
        return false if content.includes?(MARKER_START)
        File.write(path, "#{content.chomp}\n\n#{snippet}\n")
      else
        File.write(path, "#!/bin/sh\n\n#{snippet}\n")
        File.chmod(path, 0o755)
      end
      true
    end

    # Strips the marker-guarded block out of *path*; deletes the file if nothing meaningful
    # remains. Returns false if the file carried no engram marker to remove.
    private def self.uninstall_from(path : String) : Bool
      content = File.read(path)
      return false unless content.includes?(MARKER_START)

      lines = content.split('\n')
      start_index = lines.index { |line| line.strip == MARKER_START }
      end_index = lines.index { |line| line.strip == MARKER_END }
      return false unless start_index && end_index

      remaining = (lines[0...start_index] + lines[(end_index + 1)..]).join('\n')
      cleaned = remaining.gsub(/\n{3,}/, "\n\n").strip

      if cleaned.empty? || cleaned == "#!/bin/sh"
        File.delete(path)
      else
        File.write(path, "#{cleaned}\n")
      end
      true
    end

    # The marker-wrapped hook body: just re-syncs the cache, quietly.
    private def self.snippet : String
      "#{MARKER_START}\nengram sync --quiet\n#{MARKER_END}"
    end
  end
end
