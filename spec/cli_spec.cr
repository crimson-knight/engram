require "./spec_helper"
require "process"
require "json"

# Exercises the real, compiled `bin/engram` binary as a subprocess against a
# scripted temp git repo — the CLI's actual user-facing surface, not the
# library internals (those are covered file-by-file in the other specs).
#
# The binary is built once, lazily, the first time any example in this file
# needs it (not at `require` time), so a bare `crystal spec` still works even
# if `bin/` doesn't exist yet.
private BINARY_PATH = File.expand_path("../bin/engram", __DIR__)

private def project_root : String
  File.expand_path("..", __DIR__)
end

# True if *BINARY_PATH* is at least as new as every `.cr` file under `src/` —
# i.e. nothing has changed since it was last built and a rebuild would be a
# no-op. A missing binary is never "up to date".
private def binary_up_to_date? : Bool
  return false unless File.exists?(BINARY_PATH)
  binary_mtime = File.info(BINARY_PATH).modification_time
  Dir.glob(File.join(project_root, "src", "**", "*.cr")).all? do |path|
    File.info(path).modification_time <= binary_mtime
  end
end

private def ensure_binary_built : Nil
  return if binary_up_to_date?
  Dir.mkdir_p(File.dirname(BINARY_PATH))
  status = Process.run("crystal", ["build", "src/engram.cr", "-o", BINARY_PATH], chdir: project_root,
    output: STDOUT, error: STDERR)
  status.success?.should be_true
end

# Runs the compiled binary with *args* inside *dir*, returning {stdout, stderr, exit_code}.
private def run_engram(dir : String, args : Array(String), input : String? = nil) : {String, String, Int32}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  stdin = input ? IO::Memory.new(input) : Process::Redirect::Close
  status = Process.run(BINARY_PATH, args, chdir: dir, input: stdin, output: stdout, error: stderr)
  {stdout.to_s, stderr.to_s, status.exit_code}
end

# Initializes a throwaway git repo at *dir* with a real user identity (some git
# operations — none used here — require it) so specs never touch the real
# project repo or HOME.
private def init_git_repo(dir : String) : Nil
  Process.run("git", ["init", "-q"], chdir: dir)
  Process.run("git", ["config", "user.email", "engram-spec@example.com"], chdir: dir)
  Process.run("git", ["config", "user.name", "Engram Spec"], chdir: dir)
end

describe "engram CLI" do
  it "walks init -> new -> sync -> search hit -> branch-switch rollback -> search miss -> hook install -> doctor" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      init_git_repo(dir)

      # `init` creates the memories dir, a config stub, a .gitignore note, and runs an (empty) first sync.
      stdout_text, err, code = run_engram(dir, ["init"])
      code.should eq(0)
      err.should eq("")
      stdout_text.should contain("+0 applied, -0 rolled back, 0 updated (0 active)")
      Dir.exists?(File.join(dir, ".agents", "memories")).should be_true
      File.exists?(File.join(dir, ".agents", "engram.yml")).should be_true
      File.read(File.join(dir, ".gitignore")).should contain("engram")

      # `new` scaffolds a migration file we can fill in ourselves (no $EDITOR, no tty in a spec).
      stdout_text, err, code = run_engram(dir, ["new", "Chose SQLite over Postgres", "--topics", "storage,architecture"])
      code.should eq(0)
      err.should eq("")
      memory_path = stdout_text.strip
      File.exists?(memory_path).should be_true
      File.basename(memory_path).should match(/\A\d{14}_chose-sqlite-over-postgres\.md\z/)

      content = File.read(memory_path)
      content = content.sub(
        "**Decision:**\n\n**Why:**\n\n**Rejected:**",
        "**Decision:** Use a per-clone SQLite file instead of shared Postgres.\n\n" \
        "**Why:** Zero configuration for every teammate.\n\n**Rejected:** Postgres + pgvector."
      )
      File.write(memory_path, content)

      # `sync` applies the new file.
      stdout_text, err, code = run_engram(dir, ["sync", "--verbose"])
      code.should eq(0)
      err.should eq("")
      stdout_text.should contain("+1 applied, -0 rolled back, 0 updated (1 active)")

      # `search` finds it — both as plain text and as stable JSON.
      stdout_text, err, code = run_engram(dir, ["search", "postgres"])
      code.should eq(0)
      stdout_text.should contain("Chose SQLite over Postgres")

      stdout_text, err, code = run_engram(dir, ["search", "postgres", "--json"])
      code.should eq(0)
      json = JSON.parse(stdout_text)
      json.as_a.size.should eq(1)
      json[0]["title"].as_s.should eq("Chose SQLite over Postgres")

      # `recent` and `show` also see it.
      memory_id = File.basename(memory_path).split('_').first
      stdout_text, err, code = run_engram(dir, ["recent"])
      code.should eq(0)
      stdout_text.should contain("Chose SQLite over Postgres")

      stdout_text, err, code = run_engram(dir, ["show", memory_id])
      code.should eq(0)
      stdout_text.should contain("Rejected:** Postgres + pgvector")

      # Simulate a branch switch away from the memory: the file disappears from the tree.
      File.delete(memory_path)

      stdout_text, err, code = run_engram(dir, ["sync"])
      code.should eq(0)
      stdout_text.should contain("+0 applied, -1 rolled back, 0 updated (0 active)")

      stdout_text, err, code = run_engram(dir, ["search", "postgres"])
      code.should eq(0)
      stdout_text.should contain("No memories found")

      # `hook install` writes the marker-guarded snippet into all three hooks.
      stdout_text, err, code = run_engram(dir, ["hook", "install"])
      code.should eq(0)
      stdout_text.should contain("post-checkout")
      stdout_text.should contain("post-merge")
      stdout_text.should contain("post-rewrite")

      hook_path = File.join(dir, ".git", "hooks", "post-checkout")
      hook_content = File.read(hook_path)
      hook_content.should contain("# >>> engram >>>")
      hook_content.should contain("engram sync --quiet")
      hook_content.should contain("# <<< engram <<<")

      # A second install is idempotent (marker already present).
      stdout_text, err, code = run_engram(dir, ["hook", "install"])
      code.should eq(0)
      stdout_text.should contain("already installed")

      # `doctor` reports everything green: FTS5 present, hooks installed, no
      # embedder configured, DB integrity ok.
      stdout_text, err, code = run_engram(dir, ["doctor"])
      code.should eq(0)
      stdout_text.should contain("[ok] sqlite FTS5 available")
      stdout_text.should contain("[ok]")
      stdout_text.should contain("git hooks installed")
      stdout_text.should_not contain("[fail]")

      # `hook uninstall` removes exactly what it added.
      stdout_text, err, code = run_engram(dir, ["hook", "uninstall"])
      code.should eq(0)
      File.exists?(hook_path).should be_false
    end
  end

  it "installs hooks into the shared common dir from a linked worktree, not its private gitdir" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      main_dir = File.join(dir, "main")
      Dir.mkdir_p(main_dir)
      init_git_repo(main_dir)
      run_engram(main_dir, ["init"])
      Process.run("git", ["add", "-A"], chdir: main_dir)
      Process.run("git", ["commit", "-q", "-m", "init"], chdir: main_dir)

      worktree_dir = File.join(dir, "wt")
      wt_status = Process.run("git", ["worktree", "add", "-q", "-b", "wt-branch", worktree_dir], chdir: main_dir)
      wt_status.success?.should be_true

      # Installing from *inside* the linked worktree must land the hook in the
      # main repo's shared `.git/hooks` — never the worktree's own private
      # `.git/worktrees/<name>/hooks`, which git never consults when deciding
      # whether to run a hook (so a hook installed there is permanently inert).
      stdout_text, err, code = run_engram(worktree_dir, ["hook", "install"])
      code.should eq(0)
      err.should eq("")

      shared_hook = File.join(main_dir, ".git", "hooks", "post-checkout")
      private_hook = File.join(main_dir, ".git", "worktrees", "wt-branch", "hooks", "post-checkout")

      File.exists?(shared_hook).should be_true
      File.read(shared_hook).should contain("# >>> engram >>>")
      (File.info(shared_hook).permissions.value & 0o111).should_not eq(0)
      File.exists?(private_hook).should be_false

      # `doctor`, also run from inside the worktree, must resolve the same
      # shared path and see the hook as installed.
      stdout_text, err, code = run_engram(worktree_dir, ["doctor"])
      code.should eq(0)
      stdout_text.should contain("git hooks installed")
    end
  end

  it "installs hooks into a configured core.hooksPath directory instead of .git/hooks" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      init_git_repo(dir)
      run_engram(dir, ["init"])

      custom_hooks_dir = File.join(dir, "custom-hooks")
      Dir.mkdir_p(custom_hooks_dir)
      Process.run("git", ["config", "core.hooksPath", custom_hooks_dir], chdir: dir)

      stdout_text, err, code = run_engram(dir, ["hook", "install"])
      code.should eq(0)
      err.should eq("")

      configured_hook = File.join(custom_hooks_dir, "post-checkout")
      default_hook = File.join(dir, ".git", "hooks", "post-checkout")

      File.exists?(configured_hook).should be_true
      File.read(configured_hook).should contain("# >>> engram >>>")
      (File.info(configured_hook).permissions.value & 0o111).should_not eq(0)
      File.exists?(default_hook).should be_false

      stdout_text, err, code = run_engram(dir, ["doctor"])
      code.should eq(0)
      stdout_text.should contain("git hooks installed")
    end
  end

  it "makes a pre-existing, non-executable hook file executable when appending the engram block" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      init_git_repo(dir)
      run_engram(dir, ["init"])

      hooks_dir = File.join(dir, ".git", "hooks")
      Dir.mkdir_p(hooks_dir)
      hook_path = File.join(hooks_dir, "post-checkout")
      File.write(hook_path, "#!/bin/sh\necho 'a pre-existing user hook line'\n")
      File.chmod(hook_path, 0o644)
      (File.info(hook_path).permissions.value & 0o111).should eq(0)

      stdout_text, err, code = run_engram(dir, ["hook", "install"])
      code.should eq(0)

      content = File.read(hook_path)
      content.should contain("echo 'a pre-existing user hook line'")
      content.should contain("# >>> engram >>>")
      (File.info(hook_path).permissions.value & 0o111).should_not eq(0)
    end
  end

  it "doctor does not count a marker-carrying hook as installed unless it's also executable" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      init_git_repo(dir)
      run_engram(dir, ["init"])

      hooks_dir = File.join(dir, ".git", "hooks")
      Dir.mkdir_p(hooks_dir)
      marker_body = "#!/bin/sh\n\n# >>> engram >>>\nengram sync --quiet\n# <<< engram <<<\n"
      ["post-checkout", "post-merge", "post-rewrite"].each do |name|
        path = File.join(hooks_dir, name)
        File.write(path, marker_body)
        File.chmod(path, 0o644) # marker present, but deliberately non-executable
      end

      stdout_text, err, code = run_engram(dir, ["doctor"])
      code.should eq(0)
      stdout_text.should_not contain("git hooks installed (")
      stdout_text.should contain("git hooks not installed")
    end
  end

  it "exits 1 with a clear message on a duplicate memory id" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      init_git_repo(dir)
      run_engram(dir, ["init"])

      memories_dir = File.join(dir, ".agents", "memories")
      content = <<-MD
        ---
        id: 20260101000001
        title: First
        topics: []
        supersedes: []
        ---

        body one
        MD
      File.write(File.join(memories_dir, "20260101000001_first.md"), content)
      File.write(File.join(memories_dir, "20260101000001_first-again.md"), content.sub("First", "First again"))

      stdout_text, err, code = run_engram(dir, ["sync"])
      code.should eq(1)
      err.should contain("duplicate memory id 20260101000001")
      err.should contain("20260101000001_first.md")
      err.should contain("20260101000001_first-again.md")
    end
  end

  it "exits 2 when run outside a git repository" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      stdout_text, err, code = run_engram(dir, ["sync"])
      code.should eq(2)
      err.should contain("not inside a git repository")
    end
  end

  it "treats a hyphen-leading query or id as literal text, not an unknown option" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      init_git_repo(dir)
      run_engram(dir, ["init"])

      stdout_text, err, code = run_engram(dir, ["search", "-foo"])
      code.should eq(0)
      err.should eq("")
      stdout_text.should contain("No memories found")

      stdout_text, err, code = run_engram(dir, ["search", "---"])
      code.should eq(0)
      err.should eq("")

      # An explicit `--` still marks the end of options for a query that
      # would otherwise collide with a real flag name.
      stdout_text, err, code = run_engram(dir, ["search", "--", "--json"])
      code.should eq(0)
      err.should eq("")
      stdout_text.should contain("No memories found")

      stdout_text, err, code = run_engram(dir, ["show", "-abc"])
      code.should eq(1)
      err.should contain("'-abc' is not a valid memory id")
    end
  end

  it "exits 1 with a clear message when `show` is given an unknown id" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      init_git_repo(dir)
      run_engram(dir, ["init"])

      stdout_text, err, code = run_engram(dir, ["show", "99999999999999"])
      code.should eq(1)
      err.should contain("no memory with id 99999999999999")
    end
  end

  it "prints the version and top-level help" do
    ensure_binary_built

    SpecHelper.with_tempdir do |dir|
      stdout_text, err, code = run_engram(dir, ["version"])
      code.should eq(0)
      stdout_text.strip.should eq("engram 0.1.0")

      stdout_text, err, code = run_engram(dir, ["--help"])
      code.should eq(0)
      stdout_text.should contain("Usage: engram <command>")
    end
  end
end
