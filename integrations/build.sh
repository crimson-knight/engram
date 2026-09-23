#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
plugin_root="$repo_root/plugins/engram"
shared_root="$repo_root/integrations/shared"
runtime_root="$plugin_root/scripts/shared"

mkdir -p "$runtime_root/bin" "$runtime_root/lib" "$runtime_root/templates"
mkdir -p "$plugin_root/skills/reader" "$plugin_root/skills/reader-writer"
mkdir -p "$plugin_root/skills/checkpoint" "$plugin_root/skills/using-engram"
mkdir -p "$plugin_root/agents"

cp "$shared_root/lib/engram_agent.rb" "$runtime_root/lib/engram_agent.rb"
cp "$shared_root/bin/"* "$runtime_root/bin/"
cp "$shared_root/templates/reader-card.md" "$runtime_root/templates/reader-card.md"
chmod +x "$runtime_root/bin/"*

{
  cat <<'SKILL_HEADER'
---
name: reader
description: Shape user-facing writing for the persistent reader model stored in engram.
user-invocable: true
---

SKILL_HEADER
  cat "$shared_root/prompts/reader.md"
} > "$plugin_root/skills/reader/SKILL.md"

{
  cat <<'AGENT_HEADER'
---
name: reader-writer
description: Shape long reports and research results from findings and the engram reader card.
model: inherit
tools: Bash, Read, Write
---

AGENT_HEADER
  cat "$shared_root/prompts/reader-writer.md"
} > "$plugin_root/agents/reader-writer.md"

{
  cat <<'SKILL_HEADER'
---
name: reader-writer
description: Shape long reports and research results from findings and the engram reader card.
---

SKILL_HEADER
  cat "$shared_root/prompts/reader-writer.md"
} > "$plugin_root/skills/reader-writer/SKILL.md"

cp "$shared_root/prompts/checkpoint.md" "$plugin_root/skills/checkpoint/SKILL.md"
cp "$shared_root/prompts/using-engram.md" "$plugin_root/skills/using-engram/SKILL.md"

printf '%s\n' "Built Claude Code and Codex skills from shared prompts."
printf '%s\n' "Copied shared runtime into plugins/engram/scripts/shared/."
