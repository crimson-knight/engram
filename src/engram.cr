require "./engram/version"
require "./engram/memory_file"
require "./engram/store"
require "./engram/sync"
require "./engram/embedder"
require "./engram/search"
require "./engram/mcp_server"
require "./engram/hooks"
require "./engram/cli"

# engram: branch-scoped memory for coding agents — perfect recall on
# checkout, clean amnesia on switch. See docs/SPEC.md for the full design.
module Engram
end

# This file is the executable entry point only — `spec_helper.cr` requires
# the library files directly (not this one), so nothing but a real `crystal
# build`/`crystal run` of `src/engram.cr` ever reaches this line.
exit(Engram::Cli.run(ARGV))
