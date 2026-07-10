require "./spec_helper"
require "../src/engram/hooks"

# Exercises `Hooks.install`/`Hooks.uninstall`'s marker-guarded behavior
# directly against an effective hooks directory (a plain temp directory here —
# `Hooks` no longer computes `<git_dir>/hooks` itself; it is handed the
# resolved hooks directory `git rev-parse --git-path hooks` would report, so
# `core.hooksPath` and worktree common-dir redirection are honored by the
# caller, not reconstructed here).
describe Engram::Hooks do
  describe "install into a hook file that already has other content" do
    it "appends the engram block and leaves the pre-existing content untouched" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "post-checkout")
        File.write(hook_path, "#!/bin/sh\necho 'a pre-existing user hook line'\n")

        installed = Engram::Hooks.install(hooks_dir)
        installed.should contain("post-checkout")

        content = File.read(hook_path)
        content.should contain("echo 'a pre-existing user hook line'")
        content.should contain(Engram::Hooks::MARKER_START)
        content.should contain("engram sync --quiet")
        content.should contain(Engram::Hooks::MARKER_END)
      end
    end

    it "is a no-op (excluded from the result) on a second install" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        File.write(File.join(hooks_dir, "post-checkout"), "#!/bin/sh\necho 'user line'\n")

        Engram::Hooks.install(hooks_dir)
        before = File.read(File.join(hooks_dir, "post-checkout"))

        second = Engram::Hooks.install(hooks_dir)
        after = File.read(File.join(hooks_dir, "post-checkout"))

        second.should_not contain("post-checkout")
        after.should eq(before)
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

        Engram::Hooks.install(hooks_dir)
        removed = Engram::Hooks.uninstall(hooks_dir)
        removed.should contain("post-checkout")

        File.exists?(hook_path).should be_true
        content = File.read(hook_path)
        content.should contain("echo 'a pre-existing user hook line'")
        content.should_not contain(Engram::Hooks::MARKER_START)
        content.should_not contain("engram sync --quiet")
        content.should_not contain(Engram::Hooks::MARKER_END)
      end
    end

    it "deletes the hook file entirely when nothing but the engram block (and shebang) remains" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        hook_path = File.join(hooks_dir, "post-merge")

        Engram::Hooks.install(hooks_dir)
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
end
