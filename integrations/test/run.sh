#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/engram-agent-kit.XXXXXX")
cleanup() {
  if [ "${ENGRAM_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'Temporary test data kept at %s\n' "$temp_root"
  else
    rm -rf -- "$temp_root"
  fi
}
trap cleanup EXIT HUP INT TERM

crystal_bin=${CRYSTAL_BIN:-crystal-alpha}
claude_bin=${CLAUDE_CLI:-claude}
codex_bin=${CODEX_CLI:-codex}
test_home="$temp_root/home"
test_claude_home="$temp_root/claude"
test_codex_home="$temp_root/codex"
engram_bin="$temp_root/bin/engram"
agent="$repo_root/integrations/shared/bin/engram-agent"
mkdir -p "$test_home" "$test_claude_home" "$test_codex_home" "$(dirname -- "$engram_bin")"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  file=$1
  expected=$2
  grep -Fq "$expected" "$file" || fail "$file did not contain: $expected"
}

expect_hook_exit() {
  expected=$1
  output=$2
  shift 2
  set +e
  "$@" > "$output" 2>&1
  actual=$?
  set -e
  [ "$actual" -eq "$expected" ] || {
    cat "$output" >&2
    fail "expected hook exit $expected, got $actual"
  }
}

make_ledger() {
  ledger=$1
  label=$2
  mkdir -p "$ledger"
  git -C "$ledger" init -q
  (cd "$ledger" && "$engram_bin" init >/dev/null && "$engram_bin" new "Fixture memory $label" --topics fixture >/dev/null)
}

write_codex_rollout() {
  output=$1
  ruby -rjson -rtime -e '
    stamp = Time.now.utc.iso8601(6)
    records = [
      { "type" => "session_meta", "timestamp" => stamp, "payload" => { "id" => "synthetic-fixture", "timestamp" => stamp } },
      { "type" => "response_item", "timestamp" => stamp, "payload" => { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "Please update the source file." }] } },
      { "type" => "response_item", "timestamp" => stamp, "payload" => { "type" => "function_call", "name" => "exec", "input" => "apply_patch <<\x27PATCH\x27\\n*** Begin Patch\\n*** Update File: src/sample.cr\\n@@\\n-old\\n+new\\n*** End Patch\\nPATCH" } }
    ]
    records.last["payload"]["input"] = records.last["payload"]["input"].gsub("\\n", "\n")
    File.write(ARGV.fetch(0), records.map(&:to_json).join("\n") + "\n")
  ' "$output"
}

write_codex_miss_rollout() {
  output=$1
  ruby -rjson -rtime -e '
    stamp = Time.now.utc.iso8601(6)
    records = [
      { "type" => "session_meta", "timestamp" => stamp, "payload" => { "id" => "synthetic-miss", "timestamp" => stamp } },
      { "type" => "response_item", "timestamp" => stamp, "payload" => { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "I do not understand that term." }] } }
    ]
    File.write(ARGV.fetch(0), records.map(&:to_json).join("\n") + "\n")
  ' "$output"
}

write_codex_tool_rollout() {
  output=$1
  tool_name=$2
  command_text=$3
  ruby -rjson -rtime -e '
    stamp = Time.now.utc.iso8601(6)
    record = {
      "type" => "tool_call", "tool_name" => ARGV.fetch(1),
      "tool_input" => { "command" => ARGV.fetch(2) }
    }
    records = [
      { "type" => "session_meta", "timestamp" => stamp, "payload" => { "id" => "synthetic-tool", "timestamp" => stamp } },
      { "type" => "response_item", "timestamp" => stamp, "payload" => { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "Please change the source." }] } },
      record
    ]
    File.write(ARGV.fetch(0), records.map(&:to_json).join("\n") + "\n")
  ' "$output" "$tool_name" "$command_text"
}

make_stop_payload() {
  output=$1
  transcript=$2
  harness=$3
  if [ "$harness" = codex ]; then
    ruby -rjson -e '
      puts JSON.generate({
        "transcript_path" => ARGV.fetch(0), "stop_hook_active" => false,
        "hook_event_name" => "Stop", "turn_id" => "synthetic-turn",
        "permission_mode" => "on-request", "last_assistant_message" => "Done.",
        "cwd" => File.dirname(ARGV.fetch(0))
      })
    ' "$transcript" > "$output"
  else
    ruby -rjson -e '
      puts JSON.generate({
        "transcript_path" => ARGV.fetch(0), "stop_hook_active" => false,
        "hook_event_name" => "Stop", "session_id" => "claude-session",
        "permission_mode" => "default", "last_assistant_message" => "Done.",
        "cwd" => File.dirname(ARGV.fetch(0))
      })
    ' "$transcript" > "$output"
  fi
}

"$repo_root/integrations/build.sh" > "$temp_root/build.log"
"$crystal_bin" build "$repo_root/src/engram.cr" -o "$engram_bin"

claude_ledger="$temp_root/ledger-claude-start"
make_ledger "$claude_ledger" "Claude session start"
claude_memory_view="$test_claude_home/projects/fixture/memory"
claude_start_payload="$temp_root/claude-start.json"
printf '{"session_id":"claude-start","cwd":"%s","source":"startup","hook_event_name":"SessionStart"}\n' "$claude_ledger" > "$claude_start_payload"
(cd "$temp_root" && ENGRAM_LEDGER= ENGRAM_BIN="$engram_bin" ENGRAM_MEMORY_VIEW_DIR="$claude_memory_view" HOME="$test_home" \
  ruby "$agent" session-start < "$claude_start_payload" > "$temp_root/claude-start.out")
assert_contains "$temp_root/claude-start.out" '<reader-reminder>'
assert_contains "$claude_memory_view/MEMORY.md" '# Memory Index'
assert_contains "$claude_memory_view/MEMORY.md" 'Fixture memory Claude session start'
printf '%s\n' 'PASS Claude SessionStart writes the auto-memory index and emits the reader reminder.'

codex_ledger="$temp_root/ledger-codex-start"
make_ledger "$codex_ledger" "Codex session start"
codex_start_payload="$temp_root/codex-start.json"
codex_start_transcript="$test_codex_home/sessions/2026/09/23/rollout-session-start.jsonl"
mkdir -p "$(dirname -- "$codex_start_transcript")"
printf '%s\n' '{"type":"session_meta","timestamp":"2026-09-23T00:00:00Z","payload":{"id":"synthetic-start"}}' > "$codex_start_transcript"
printf '{"session_id":"codex-start","cwd":"%s","source":"startup","hook_event_name":"SessionStart","permission_mode":"on-request","transcript_path":"%s"}\n' "$codex_ledger" "$codex_start_transcript" > "$codex_start_payload"
(cd "$temp_root" && ENGRAM_LEDGER= ENGRAM_BIN="$engram_bin" HOME="$test_home" CODEX_HOME="$test_codex_home" \
  ruby "$agent" session-start < "$codex_start_payload" > "$temp_root/codex-start.out")
ruby -rjson -e '
  context = JSON.parse(STDIN.read).dig("hookSpecificOutput", "additionalContext")
  abort "missing Codex memory index" unless context.include?("# Memory Index") && context.include?("Fixture memory Codex session start")
  abort "missing Codex reader reminder" unless context.include?("<reader-reminder>")
' < "$temp_root/codex-start.out"
printf '%s\n' 'PASS Codex SessionStart emits the memory index and reader reminder as additional context.'

reader_ledger="$temp_root/ledger-reader-init"
make_ledger "$reader_ledger" "reader bootstrap"
ENGRAM_LEDGER="$reader_ledger" ENGRAM_BIN="$engram_bin" HOME="$test_home" \
  "$repo_root/integrations/shared/bin/engram-reader-init" > "$temp_root/reader-init.out"
reader_card=$(cat "$temp_root/reader-init.out")
[ -f "$reader_card" ] || fail 'reader init did not return a migration path'
assert_contains "$reader_card" '## Vocabulary'
assert_contains "$reader_card" '## Depth map'
printf '%s\n' 'PASS reader init creates a blank reader migration from the shared template.'

claude_ledger="$temp_root/ledger-claude-reflect"
make_ledger "$claude_ledger" "Claude reflect seed"
claude_transcript="$temp_root/claude-rollout.jsonl"
claude_stop="$temp_root/claude-stop.json"
cat > "$claude_transcript" <<'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"Please edit the source file."}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/sample.cr","old_string":"old","new_string":"new"}}]}}
TRANSCRIPT
make_stop_payload "$claude_stop" "$claude_transcript" claude
claude_memory_view="$test_claude_home/projects/fixture/reflect-memory"
expect_hook_exit 2 "$temp_root/claude-block.out" env ENGRAM_LEDGER="$claude_ledger" ENGRAM_BIN="$engram_bin" ENGRAM_MEMORY_VIEW_DIR="$claude_memory_view" HOME="$test_home" ruby "$agent" reflect < "$claude_stop"
assert_contains "$temp_root/claude-block.out" 'state changed but no ledger write was found'
(cd "$claude_ledger" && "$engram_bin" new 'Recorded Claude change' --topics fixture >/dev/null)
expect_hook_exit 0 "$temp_root/claude-pass.out" env ENGRAM_LEDGER="$claude_ledger" ENGRAM_BIN="$engram_bin" ENGRAM_MEMORY_VIEW_DIR="$claude_memory_view" HOME="$test_home" ruby "$agent" reflect < "$claude_stop"
printf '%s\n' 'PASS Claude Stop blocks an unrecorded edit and passes after a fresh migration.'

codex_ledger="$temp_root/ledger-codex-reflect"
make_ledger "$codex_ledger" "Codex reflect seed"
codex_rollout="$temp_root/rollout-synthetic.jsonl"
write_codex_rollout "$codex_rollout"
codex_stop="$temp_root/codex-stop.json"
make_stop_payload "$codex_stop" "$codex_rollout" codex
expect_hook_exit 2 "$temp_root/codex-block.out" env ENGRAM_LEDGER="$codex_ledger" ENGRAM_BIN="$engram_bin" HOME="$test_home" CODEX_HOME="$test_codex_home" ruby "$agent" reflect < "$codex_stop"
assert_contains "$temp_root/codex-block.out" 'state changed but no ledger write was found'
codex_rollout="$temp_root/rollout-tool-name.jsonl"
write_codex_tool_rollout "$codex_rollout" apply_patch '*** Begin Patch
*** Update File: src/sample.cr
@@
-old
+new
*** End Patch'
codex_stop="$temp_root/codex-tool-name-stop.json"
make_stop_payload "$codex_stop" "$codex_rollout" codex
expect_hook_exit 2 "$temp_root/codex-tool-name-block.out" env ENGRAM_LEDGER="$codex_ledger" ENGRAM_BIN="$engram_bin" HOME="$test_home" CODEX_HOME="$test_codex_home" ruby "$agent" reflect < "$codex_stop"
assert_contains "$temp_root/codex-tool-name-block.out" 'state changed but no ledger write was found'
codex_rollout="$temp_root/rollout-bash-heredoc.jsonl"
write_codex_tool_rollout "$codex_rollout" Bash "cat > src/sample.cr <<'EOF'
new contents
EOF"
codex_stop="$temp_root/codex-bash-stop.json"
make_stop_payload "$codex_stop" "$codex_rollout" codex
expect_hook_exit 2 "$temp_root/codex-bash-block.out" env ENGRAM_LEDGER="$codex_ledger" ENGRAM_BIN="$engram_bin" HOME="$test_home" CODEX_HOME="$test_codex_home" ruby "$agent" reflect < "$codex_stop"
assert_contains "$temp_root/codex-bash-block.out" 'state changed but no ledger write was found'
(cd "$codex_ledger" && "$engram_bin" new 'Recorded Codex change' --topics fixture >/dev/null)
codex_stop="$temp_root/codex-stop.json"
expect_hook_exit 0 "$temp_root/codex-pass.out" env ENGRAM_LEDGER="$codex_ledger" ENGRAM_BIN="$engram_bin" HOME="$test_home" CODEX_HOME="$test_codex_home" ruby "$agent" reflect < "$codex_stop"
assert_contains "$temp_root/codex-pass.out" '{"continue":true}'
printf '%s\n' 'PASS Codex Stop blocks an unrecorded apply_patch and passes after a fresh migration.'

claude_ledger="$temp_root/ledger-claude-miss"
make_ledger "$claude_ledger" "Claude miss seed"
claude_transcript="$temp_root/claude-miss.jsonl"
claude_stop="$temp_root/claude-miss-stop.json"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"I do not understand that term."}}' > "$claude_transcript"
make_stop_payload "$claude_stop" "$claude_transcript" claude
expect_hook_exit 2 "$temp_root/claude-miss-block.out" env ENGRAM_LEDGER="$claude_ledger" ENGRAM_BIN="$engram_bin" ENGRAM_MEMORY_VIEW_DIR="$temp_root/claude-miss-memory" HOME="$test_home" ruby "$agent" reflect < "$claude_stop"
assert_contains "$temp_root/claude-miss-block.out" 'topic reader'
(cd "$claude_ledger" && "$engram_bin" new 'Recorded reader correction' --topics reader >/dev/null)
expect_hook_exit 0 "$temp_root/claude-miss-pass.out" env ENGRAM_LEDGER="$claude_ledger" ENGRAM_BIN="$engram_bin" ENGRAM_MEMORY_VIEW_DIR="$temp_root/claude-miss-memory" HOME="$test_home" ruby "$agent" reflect < "$claude_stop"
printf '%s\n' 'PASS Claude Stop applies the reader-miss rule and passes after a reader migration.'

codex_ledger="$temp_root/ledger-codex-miss"
make_ledger "$codex_ledger" "Codex miss seed"
codex_rollout="$temp_root/rollout-miss.jsonl"
write_codex_miss_rollout "$codex_rollout"
codex_stop="$temp_root/codex-miss-stop.json"
make_stop_payload "$codex_stop" "$codex_rollout" codex
expect_hook_exit 2 "$temp_root/codex-miss-block.out" env ENGRAM_LEDGER="$codex_ledger" ENGRAM_BIN="$engram_bin" HOME="$test_home" CODEX_HOME="$test_codex_home" ruby "$agent" reflect < "$codex_stop"
assert_contains "$temp_root/codex-miss-block.out" 'topic reader'
(cd "$codex_ledger" && "$engram_bin" new 'Recorded reader correction' --topics reader >/dev/null)
expect_hook_exit 0 "$temp_root/codex-miss-pass.out" env ENGRAM_LEDGER="$codex_ledger" ENGRAM_BIN="$engram_bin" HOME="$test_home" CODEX_HOME="$test_codex_home" ruby "$agent" reflect < "$codex_stop"
assert_contains "$temp_root/codex-miss-pass.out" '{"continue":true}'
printf '%s\n' 'PASS Codex Stop applies the reader-miss rule and passes after a reader migration.'

if command -v "$claude_bin" >/dev/null 2>&1 && command -v "$codex_bin" >/dev/null 2>&1; then
  HOME="$test_home" CLAUDE_CONFIG_DIR="$test_claude_home" CODEX_HOME="$test_codex_home" \
    CLAUDE_CLI="$claude_bin" CODEX_CLI="$codex_bin" "$repo_root/integrations/install.sh" --both > "$temp_root/install.log"
  grep -Fq 'engram-agent-kit' "$temp_root/install.log" || fail 'installer did not report marketplace/plugin actions'
  HOME="$test_home" CLAUDE_CONFIG_DIR="$test_claude_home" "$claude_bin" plugin list --json > "$temp_root/claude-plugin-list.json"
  grep -Fq 'engram@engram-agent-kit' "$temp_root/claude-plugin-list.json" || fail 'Claude CLI did not report the installed plugin'
  HOME="$test_home" CODEX_HOME="$test_codex_home" "$codex_bin" plugin list --json > "$temp_root/codex-plugin-list.json"
  grep -Fq 'engram@engram-agent-kit' "$temp_root/codex-plugin-list.json" || fail 'Codex CLI did not report the installed plugin'
  HOME="$test_home" CLAUDE_CONFIG_DIR="$test_claude_home" CODEX_HOME="$test_codex_home" \
    CLAUDE_CLI="$claude_bin" CODEX_CLI="$codex_bin" "$repo_root/integrations/install.sh" --both > "$temp_root/reinstall.log"
  assert_contains "$temp_root/reinstall.log" 'already'
  "$claude_bin" plugin validate --strict "$repo_root/plugins/engram" > "$temp_root/claude-plugin-validate.log"
  "$claude_bin" plugin validate --strict "$repo_root/.claude-plugin/marketplace.json" > "$temp_root/claude-marketplace-validate.log"
  printf '%s\n' 'PASS Claude plugin and marketplace strict validation.'
  printf '%s\n' 'PASS Codex marketplace add and plugin add through the installer; repeat install was idempotent.'
else
  printf '%s\n' 'SKIP native marketplace install checks: Claude CLI or Codex CLI is unavailable.'
fi

printf '%s\n' 'All engram agent kit integration checks passed.'
