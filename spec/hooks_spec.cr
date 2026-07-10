require "./spec_helper"
require "../src/engram/hooks"

# Exercises `Hooks.install`/`Hooks.uninstall`'s marker-guarded behavior
# directly against an effective hooks directory (a plain temp directory here —
# `Hooks` no longer computes `<git_dir>/hooks` itself; it is handed the
# resolved hooks directory `git rev-parse --git-path hooks` would report, so
# `core.hooksPath` and worktree common-dir redirection are honored by the
# caller, not reconstructed here).
#
# Every `install` call below passes an explicit *engram_path* so these specs
# are deterministic and independent of whatever binary happens to be running
# `crystal spec` — `resolve_engram_path`'s `Process.executable_path` default is
# covered separately, below.
FAKE_ENGRAM_PATH = "/opt/fake/bin/engram"

describe Engram::Hooks do
  describe "install into a hook file that already has other content" do
    it "appends the engram block, bakes in the given absolute path, and leaves the pre-existing content untouched" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "post-checkout")
        File.write(hook_path, "#!/bin/sh\necho 'a pre-existing user hook line'\n")

        installed = Engram::Hooks.install(hooks_dir, FAKE_ENGRAM_PATH)
        installed.should contain("post-checkout")

        content = File.read(hook_path)
        content.should contain("echo 'a pre-existing user hook line'")
        content.should contain(Engram::Hooks::MARKER_START)
        content.should contain("#{Engram::Hooks::ENGRAM_BIN_PREFIX}#{FAKE_ENGRAM_PATH}")
        content.should contain("'#{FAKE_ENGRAM_PATH}' sync --quiet")
        content.should contain(Engram::Hooks::MARKER_END)
      end
    end

    it "is a no-op (excluded from the result) on a second install with the same engram path" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        File.write(File.join(hooks_dir, "post-checkout"), "#!/bin/sh\necho 'user line'\n")

        Engram::Hooks.install(hooks_dir, FAKE_ENGRAM_PATH)
        before = File.read(File.join(hooks_dir, "post-checkout"))

        second = Engram::Hooks.install(hooks_dir, FAKE_ENGRAM_PATH)
        after = File.read(File.join(hooks_dir, "post-checkout"))

        second.should_not contain("post-checkout")
        after.should eq(before)
      end
    end

    it "refreshes an existing block in place when the baked-in engram path has changed" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "post-checkout")
        File.write(hook_path, "#!/bin/sh\necho 'a pre-existing user hook line'\n")

        Engram::Hooks.install(hooks_dir, "/old/path/engram")
        second = Engram::Hooks.install(hooks_dir, "/new/path/engram")
        second.should contain("post-checkout")

        content = File.read(hook_path)
        content.should contain("echo 'a pre-existing user hook line'")
        content.should_not contain("/old/path/engram")
        content.should contain("#{Engram::Hooks::ENGRAM_BIN_PREFIX}/new/path/engram")
        content.should contain("'/new/path/engram' sync --quiet")
        # exactly one marker pair — the refresh replaced the block, it didn't append a second one
        content.split(Engram::Hooks::MARKER_START).size.should eq(2)
      end
    end
  end

  describe "uninstall from a hook file that carries both the engram block and other content" do
    it "removes only the engram block and preserves the surrounding user content and the file itself" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "post-checkout")
        File.write(hook_path, "#!/bin/sh\necho 'a pre-existing user hook line'\n")

        Engram::Hooks.install(hooks_dir, FAKE_ENGRAM_PATH)
        removed = Engram::Hooks.uninstall(hooks_dir)
        removed.should contain("post-checkout")

        File.exists?(hook_path).should be_true
        content = File.read(hook_path)
        content.should contain("echo 'a pre-existing user hook line'")
        content.should_not contain(Engram::Hooks::MARKER_START)
        content.should_not contain("sync --quiet")
        content.should_not contain(Engram::Hooks::MARKER_END)
      end
    end

    it "deletes the hook file entirely when nothing but the engram block (and shebang) remains" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        hook_path = File.join(hooks_dir, "post-merge")

        Engram::Hooks.install(hooks_dir, FAKE_ENGRAM_PATH)
        File.exists?(hook_path).should be_true

        removed = Engram::Hooks.uninstall(hooks_dir)
        removed.should contain("post-merge")
        File.exists?(hook_path).should be_false
      end
    end

    it "returns an empty list and changes nothing when no engram hooks are installed" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "post-checkout")
        File.write(hook_path, "#!/bin/sh\necho 'untouched'\n")

        removed = Engram::Hooks.uninstall(hooks_dir)

        removed.should eq([] of String)
        File.read(hook_path).should eq("#!/bin/sh\necho 'untouched'\n")
      end
    end
  end

  describe "resolve_engram_path" do
    it "returns the absolute path of the currently running process (Process.executable_path)" do
      resolved = Engram::Hooks.resolve_engram_path
      resolved.should eq(Process.executable_path || "engram")
    end
  end

  describe "installed_engram_path" do
    it "reads back the exact path install baked in, regardless of shell-quoting" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        path_with_quote = "/opt/weird's path/engram"

        Engram::Hooks.install(hooks_dir, path_with_quote)
        hook_path = File.join(hooks_dir, "post-checkout")

        Engram::Hooks.installed_engram_path(hook_path).should eq(path_with_quote)
      end
    end

    it "returns nil for a hook file with no engram marker" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "post-checkout")
        File.write(hook_path, "#!/bin/sh\necho 'no engram here'\n")

        Engram::Hooks.installed_engram_path(hook_path).should be_nil
      end
    end

    it "returns nil for a path that doesn't exist" do
      Engram::Hooks.installed_engram_path("/no/such/hook").should be_nil
    end
  end
end
