require "./engram/version"
require "./engram/memory_file"
require "./engram/store"

# engram: branch-scoped memory for coding agents — perfect recall on
# checkout, clean amnesia on switch. See docs/SPEC.md for the full design.
module Engram
end

# STUB: the CLI (subcommand dispatch, `engram sync`/`search`/`mcp`/etc.) is
# built in a later stage. This entry point only exists so `crystal build`
# and `crystal spec` have a working target module to require.
puts "engram #{Engram::VERSION} (CLI not yet implemented — see docs/SPEC.md)"
