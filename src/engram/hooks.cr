module Engram
  # Installs/uninstalls the three git hooks (`post-checkout`, `post-merge`,
  # `post-rewrite`) that keep the per-clone cache in sync automatically. Each
  # hook body invokes the **absolute path of the engram binary that ran
  # `hook install`** (resolved via `Process.executable_path`), not a bare
  # `engram` — git runs hooks under a minimal, noninteractive `PATH` that most
  # shells' interactive `PATH` never touches, so a bare command silently
  # no-ops (hook exits nonzero, cache goes stale, `git checkout` never fails
  # loudly) unless engram happens to be installed to a directory already on
  # that noninteractive PATH. Baking in the absolute path makes the hook work
  # regardless of PATH. Every managed block is wrapped in marker comments so
  # `uninstall` can remove exactly what `install` added, regardless of
  # whatever else lives in the hook file; a comment line inside the block also
  # records the baked-in path in a form `doctor` (and a repeat `install`) can
  # read back out without re-parsing shell quoting.
  #
  # Callers must pass the *effective* hooks directory — the one git itself
  # will actually run hooks from, resolved via `git rev-parse --git-path
  # hooks` (see `Cli.hooks_dir_for`). That's not always `<repo>/.git/hooks`:
  # `core.hooksPath` can point anywhere, and in a linked worktree the hooks
  # git runs live in the shared common dir, not the worktree's own private
  # gitdir. This module never reconstructs that path itself — it only
  # reads/writes files directly under whatever directory it's given.
  module Hooks
    # The three lifecycle hooks that correspond to "the working tree just changed underneath us".
    HOOK_NAMES = ["post-checkout", "post-merge", "post-rewrite"]

    # Opens the engram-managed block in a hook file.
    MARKER_START = "# >>> engram >>>"
    # Closes the engram-managed block in a hook file.
    MARKER_END = "# <<< engram <<<"

    # The comment line, inside the marker block, that records the baked-in absolute
    # engram path in a directly-greppable form — no shell-quote parsing required to
    # read it back (used by `installed_engram_path` and, transitively, `doctor`).
    ENGRAM_BIN_PREFIX = "# engram-bin: "

    # Installs the engram sync snippet into each of `HOOK_NAMES` under the effective
    # *hooks_dir* (creating the hook file with a shebang if it doesn't exist yet;
    # appending, guarded by the marker comments, if it does). *engram_path* defaults
    # to the currently-running binary's own absolute path — that's what gets baked
    # into the hook body, so pass an explicit value only in tests or other unusual
    # callers. Returns the names actually installed or refreshed: a hook whose
    # existing block already bakes in *engram_path* is left untouched and excluded
    # from the result; a hook whose block bakes in some *other* path (the binary was
    # rebuilt or moved since the last install) has its block rewritten in place, so
    # re-running `hook install` after moving the binary actually repairs a hook
    # `doctor` flagged as stale, rather than being a permanent no-op.
    def self.install(hooks_dir : String, engram_path : String = self.resolve_engram_path) : Array(String)
      Dir.mkdir_p(hooks_dir) unless Dir.exists?(hooks_dir)

      HOOK_NAMES.select { |name| install_into(File.join(hooks_dir, name), engram_path) }
    end

    # Removes the engram-managed block from each of `HOOK_NAMES` under the effective
    # *hooks_dir*. A hook file left with nothing but a shebang (or nothing at all)
    # after removal is deleted outright. Returns the names actually removed.
    def self.uninstall(hooks_dir : String) : Array(String)
      HOOK_NAMES.select do |name|
        path = File.join(hooks_dir, name)
        File.exists?(path) && uninstall_from(path)
      end
    end

    # The absolute path of the engram binary currently running this process. Falls
    # back to the bare command name only if the OS can't report it (rare, exotic
    # platforms) — that fallback reproduces the pre-hardening PATH-dependent
    # behavior rather than baking in something worse than a bare command.
    def self.resolve_engram_path : String
      Process.executable_path || "engram"
    end

    # The absolute engram path baked into *path*'s marker block by `install`, or nil
    # if *path* doesn't exist, carries no engram block, or (a hook installed before
    # this hardening landed) has a block with no `# engram-bin:` line. `doctor` uses
    # this to confirm an "installed" hook would actually resolve engram at run time
    # rather than silently no-op under git's minimal noninteractive PATH.
    def self.installed_engram_path(path : String) : String?
      return nil unless File.exists?(path)
      installed_engram_path_from_content(File.read(path))
    end

    # Appends (or creates, or in-place refreshes) the marker-guarded snippet at
    # *path* for *engram_path*; returns false if nothing changed.
    private def self.install_into(path : String, engram_path : String) : Bool
      if File.exists?(path)
        content = File.read(path)
        return replace_block(path, content, engram_path) if content.includes?(MARKER_START)
        File.write(path, "#{content.chomp}\n\n#{snippet(engram_path)}\n")
      else
        File.write(path, "#!/bin/sh\n\n#{snippet(engram_path)}\n")
      end
      ensure_executable(path)
      true
    end

    # *path* already carries an engram marker block: rewrites it in place if the
    # path baked into it differs from *engram_path*, leaving everything outside the
    # block untouched. Returns false (a no-op) when the existing block already
    # matches *engram_path*.
    private def self.replace_block(path : String, content : String, engram_path : String) : Bool
      return false if installed_engram_path_from_content(content) == engram_path

      lines = content.split('\n')
      start_index = lines.index { |line| line.strip == MARKER_START }
      end_index = lines.index { |line| line.strip == MARKER_END }
      return false unless start_index && end_index

      rebuilt = (lines[0...start_index] + snippet(engram_path).split('\n') + lines[(end_index + 1)..]).join('\n')
      File.write(path, "#{rebuilt.chomp}\n")
      ensure_executable(path)
      true
    end

    # Adds the owner/group/other execute bits to *path* without disturbing whatever
    # read/write bits it already has.
    private def self.ensure_executable(path : String) : Nil
      current = File.info(path).permissions.value
      File.chmod(path, current | 0o111)
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

    # The marker-wrapped hook body: a human-readable `# engram-bin:` record of the
    # baked-in path (so `doctor`/a repeat `install` never has to reverse-parse the
    # shell-quoted command line), then the actual sync invocation, single-quoted so
    # a path containing spaces or shell metacharacters still runs correctly.
    private def self.snippet(engram_path : String) : String
      "#{MARKER_START}\n#{ENGRAM_BIN_PREFIX}#{engram_path}\n#{shell_quote(engram_path)} sync --quiet\n#{MARKER_END}"
    end

    # Extracts the `# engram-bin:` record from an already-read hook *content*, or nil if absent.
    private def self.installed_engram_path_from_content(content : String) : String?
      line = content.split('\n').find { |l| l.starts_with?(ENGRAM_BIN_PREFIX) }
      line.try(&.[ENGRAM_BIN_PREFIX.size..])
    end

    # Single-quotes *path* for safe embedding in a POSIX `sh` command line, escaping
    # any embedded single quote as `'\''` (close quote, escaped literal quote,
    # reopen quote) — defends against paths containing spaces or shell
    # metacharacters, which are common enough on macOS (e.g. under "Application
    # Support" or a synced-drive username with an apostrophe).
    private def self.shell_quote(path : String) : String
      "'" + path.gsub("'", "'\\''") + "'"
    end
  end
end
