require "./spec_helper"
require "../src/engram/hooks"

# Exercises `Hooks.install`/`Hooks.uninstall`'s marker-guarded behavior
# directly against a temp "git dir" (just a plain directory — `Hooks` never
# shells out to git, it only touches `<git_dir>/hooks/*`).
describe Engram::Hooks do
  describe "install into a hook file that already has other content" do
    it "appends the engram block and leaves the pre-existing content untouched" do
      SpecHelper.with_tempdir do |dir|
        hooks_dir = File.join(dir, "hooks")
        Dir.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "post-checkout")
        File.write(hook_path, "#!/bin/sh\necho 'a pre-existing user hook line'\n")

        installed = Engram::Hooks.install(dir)
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

        Engram::Hooks.install(dir)
        before = File.read(File.join(hooks_dir, "post-checkout"))

        second = Engram::Hooks.install(dir)
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

        Engram::Hooks.install(dir)
        removed = Engram::Hooks.uninstall(dir)
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
        hook_path = File.join(dir, "hooks", "post-merge")

        Engram::Hooks.install(dir)
        File.exists?(hook_path).should be_true

        removed = Engram::Hooks.uninstall(dir)
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

        removed = Engram::Hooks.uninstall(dir)

        removed.should eq([] of String)
        File.read(hook_path).should eq("#!/bin/sh\necho 'untouched'\n")
      end
    end
  end
end
