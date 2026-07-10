require "spec"
require "file_utils"
require "../src/engram/version"
require "../src/engram/memory_file"
require "../src/engram/store"

module SpecHelper
  # Creates a fresh temp directory for a spec example and yields its path; always cleans up after.
  def self.with_tempdir(&)
    path = File.tempname("engram-spec")
    Dir.mkdir_p(path)
    begin
      yield path
    ensure
      FileUtils.rm_rf(path)
    end
  end

  # Writes *content* to *dir*/*filename* and returns the full path.
  def self.write_file(dir : String, filename : String, content : String) : String
    path = File.join(dir, filename)
    File.write(path, content)
    path
  end
end
