# engram agent kit

The agent kit adds lifecycle hooks, writing guidance, and an MCP connection to
engram. The runtime is shared Ruby code under `integrations/shared`; the Claude
Code and Codex packages provide thin hook and manifest adapters. The plugin
directory is `plugins/engram` for both marketplaces.

The kit expects the engram CLI on `PATH` or at `ENGRAM_BIN`. For a project
ledger, run `engram init` in its Git repository. The runtime locates the nearest
repository containing `.agents/memories`; if it cannot find one, it uses
`~/agent_memory` when that ledger exists. Set `ENGRAM_LEDGER` to choose a
different ledger. The `integrations/shared/config/agent.env.example` file lists
the shared options. Copy it to `~/.config/engram/agent.env` and uncomment the
values you need, or set them in the harness environment.

## Install

Install the plugin through the native CLI commands:

```sh
integrations/install.sh --claude
integrations/install.sh --codex
integrations/install.sh --both
```

The installer builds the packaged skills and runtime, registers the local
marketplace, and installs `engram`. It checks for an existing marketplace and
plugin before making changes. Before a CLI update, it copies the affected
settings file and plugin directory to a timestamped `.agent-kit-backup.*` path.
The installed hooks still require the harness to trust or accept them. Review
the hook commands in `plugins/engram/hooks/hooks.json` and
`plugins/engram/.codex-plugin/plugin.json` before enabling them.

Codex CLI's repo marketplace is `.agents/plugins/marketplace.json`; the
manifest points to `./plugins/engram`. Claude Code uses
`.claude-plugin/marketplace.json`. The Codex CLI marketplace commands and this
marketplace layout follow the current [Codex plugin packaging
guide](https://developers.openai.com/plugins/build/plugins#install-a-local-plugin-manually).

The plugin's MCP entry runs `engram mcp` through a small shell adapter. It
loads `~/.config/engram/agent.env`, changes to `ENGRAM_LEDGER` when set, and
then starts the CLI. Claude Code also has the repository's existing root
`.mcp.json` setup; the packaged plugin keeps the same `engram` server name.
Codex CLI can install the plugin and its declared MCP stanza. The isolated
check verifies plugin installation, but does not open a live Codex MCP
connection.

## Reader model

The reader model is a persistent, evidence-based model of the person the agent
reports to. It tracks vocabulary by subject area, depth for each topic, useful
reply shapes, recurring explanation misses, and the response protocol that
helps resolve a miss. It records stated preferences and observed corrections;
it should not become a personality profile or a collection of guesses.

Start an empty reader card in a repository with:

```sh
ENGRAM_LEDGER=/path/to/repository \
  ENGRAM_BIN=engram integrations/shared/bin/engram-reader-init
```

The helper creates a new migration with topic `reader`, copies the placeholder
structure from `integrations/shared/templates/reader-card.md`, and runs
`engram sync`. Fill the sections with information the reader has stated or
demonstrated. The template contains no person's preferences or vocabulary.

The `reader` skill is shared by both packages. The `reader-writer` instructions
come from one shared prompt too: Claude Code exposes them as both a `reader-writer`
agent and a skill; Codex exposes them as a skill. The full card can be loaded
with the `reader-inject-hook --full` helper or through the engram MCP tools.
`reader-jargon-gate` checks drafts against the ledger's reader vocabulary.
`reader-token-estimate` gives a generic character-based estimate. The optional
`reader-embed-index` uses a local Ollama embedding endpoint when configured.

## Hooks

| Hook or helper | What it does | Claude Code | Codex CLI |
|---|---|---|---|
| SessionStart | Syncs the ledger; adds a short reader reminder and optional active missions. On compact resume it restores the checkpoint. | Writes a `MEMORY.md` index and page files to Claude's project auto-memory directory, then emits the reminder. | Emits a `MEMORY.md`-style index and reminder in `hookSpecificOutput.additionalContext` on startup, resume, clear, and compact. |
| Stop reflection gate | Scans the transcript. If it finds a state-changing action without a new ledger entry, it blocks once and asks for a useful migration. An unclear-reader message also requires a new memory with topic `reader`. | Reads transcript lines with user messages and `Write`, `Edit`, or `MultiEdit` tool calls. | Reads rollout JSONL `response_item` calls, including `apply_patch` and `exec` command input, and uses Codex Stop fields such as `transcript_path`, `stop_hook_active`, `hook_event_name`, and `turn_id`. A repeated block is allowed through to prevent a loop. |
| PreCompact | Extracts a deterministic fallback checkpoint from the transcript. Automatic compaction waits once for a fresh checkpoint when the last checkpoint is missing or stale. | Uses Claude's PreCompact event and decision output. | Uses Codex's PreCompact event and JSON `continue: false` output to pause compaction. |
| PostCompact | Archives the compact summary and prunes checkpoints older than 14 days. | Uses Claude's PostCompact event. | Uses Codex's PostCompact event. |
| Reader reminder | Prints a short reminder at session start; `--full` prints the reader card. | SessionStart reminder plus a command helper. | SessionStart `additionalContext` reminder plus a command helper. |
| Mission injection | Prints active missions from the optional `ENGRAM_MISSIONS_FILE`. | SessionStart when configured; otherwise no-op. | SessionStart `additionalContext` when configured; otherwise no-op. |
| Reader-miss detector | Scans user messages for unclear-reader signals for the reflection gate. | Reads Claude transcript user messages. | Reads Codex rollout user messages from recognized JSONL records. |
| Reader jargon gate | Checks a draft against the reader vocabulary in the ledger. | Shared helper used by the reader instructions. | Shared helper used by the reader skill. |
| Reader token estimate | Gives a generic character-based token estimate. | Shared command helper. | Shared command helper. |
| Reader embedding index | Optionally indexes reader text through a configured local Ollama endpoint. | Shared optional helper; disabled unless configured. | Shared optional helper; disabled unless configured. |
| Auto-memory sync | Copies ledger pages and generates the `MEMORY.md` index. | Writes to Claude's project auto-memory directory. | Not available; SessionStart emits the index as context instead. |
| Checkpoint skill | Explains how to save and restore session checkpoints. | Skill plus PreCompact, PostCompact, and compact-resume hooks. | Skill plus PreCompact, PostCompact, and compact-resume hooks. |

The Codex Stop hook writes a plain-text continuation reason to `stderr` and
exits 2 when it needs another pass. A successful Stop invocation emits
`{"continue":true}`. This matches Codex's Stop hook contract. Its SessionStart
hook returns the index through `additionalContext`. See the [Codex hooks
guide](https://learn.chatgpt.com/docs/hooks#sessionstart) for the SessionStart
context shape, the [Stop hook contract](https://learn.chatgpt.com/docs/hooks#stop),
and the documented limitation that `transcript_path` format is not a stable
hook interface.

## Claude Code and Codex support

| Capability | Claude Code | Codex CLI | Exact difference |
|---|---|---|---|
| Plugin install | Claude marketplace and plugin manifests | Codex marketplace plus `.codex-plugin/plugin.json` | Each harness has a separate marketplace and plugin manifest; both load the same plugin files. |
| Persistent memory index | Claude project auto-memory directory | SessionStart additional context | Codex does not provide Claude-style auto-memory storage; the index is re-emitted on SessionStart. |
| Reader-writer subagent | Native `agents/reader-writer.md` plus skill | Skill only | Codex plugins do not consume Claude agent-definition files, so the skill cannot guarantee an isolated subagent run. |
| Transcript scan | Claude JSONL message and tool-use records | Codex rollout `response_item` records and tool inputs | Codex documents the transcript path as convenience data with an unstable format. The scanner recognizes the current `exec`/`apply_patch` forms and shell writes; new tool encodings may need an adapter update. |
| Stop blocking | Hook exit 2 with a reason | Hook exit 2 with a reason; successful calls return JSON | The shared check is the same; the output adapter follows each runtime's contract. |
| Compaction | PreCompact and PostCompact | PreCompact and PostCompact | The events exist on both runtimes, but Codex hook JSON rules differ from Claude's hook decision output. |
| MCP server | Plugin `.mcp.json` and the existing repo `.mcp.json` pattern | Plugin MCP stanza or fallback `config.toml` | A live MCP handshake is not covered by `integrations/test/run.sh`. |

Codex plugin hooks are bundled with the installed plugin, but Codex requires
the current hook definition to be reviewed and trusted before it runs. The
plugin can therefore be installed successfully while its lifecycle hooks are
still inactive. See the [Codex plugin hook guidance](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks).

## Codex fallback files

For a Codex setup that does not use plugins, copy
`integrations/codex/fallback/.codex/hooks.json` into the project as
`.codex/hooks.json`. Set `ENGRAM_AGENT_KIT_ROOT` to this checkout in the shell
that launches Codex, or replace it in the hook commands with the checkout's
absolute path. Merge `integrations/codex/fallback/AGENTS.md` into the project's
`AGENTS.md` and merge `integrations/codex/fallback/config.toml` into the
user's Codex `config.toml`. The snippets do not edit existing files.

The fallback `config.toml` adds the MCP server under `[mcp_servers.engram]`.
Use the shared `agent.env` file to set `ENGRAM_LEDGER` and `ENGRAM_BIN` in the
environment inherited by Codex. Hook commands read the same values.

## Configuration reference

| Variable | Default or use |
|---|---|
| `ENGRAM_LEDGER` | Nearest Git repository containing `.agents/memories`, then `~/agent_memory`. |
| `ENGRAM_BIN` | `engram` resolved from `PATH`. |
| `ENGRAM_MISSIONS_FILE` | Unset; mission injection becomes a no-op. |
| `ENGRAM_READER_NAME` | Unset; reminder says “the user.” |
| `ENGRAM_MEMORY_VIEW_DIR` | Claude only; derived from `CLAUDE_PROJECT_DIR` or SessionStart `cwd` when unset. |
| `ENGRAM_CHECKPOINT_DIR` | Harness-specific checkpoint folder below Claude config or `CODEX_HOME`. |
| `ENGRAM_AGENT_ENV` | Optional config file path; default is `$XDG_CONFIG_HOME/engram/agent.env` or `~/.config/engram/agent.env`. |
| `ENGRAM_GATE_BYPASS` | Unset; set to `1` only to bypass Stop reflection checks. |

## Verification

Run `integrations/test/run.sh` to build engram into a temporary directory, make
fresh temporary Git ledgers, exercise Claude and Codex SessionStart and Stop
payloads, install both plugins with temporary `CLAUDE_CONFIG_DIR` and
`CODEX_HOME`, and validate the Claude plugin manifests. Codex rollout data in
the test is synthetic; no real conversation transcript is committed. Run
`crystal spec` separately for the engine specs.

The Codex test confirms the current CLI can add this local marketplace and
plugin. It does not execute a full model turn, exercise real hook delivery, or
verify MCP server startup. The Codex docs explicitly warn that transcript
format can change, so the Codex reflection adapter should be rechecked when
Codex changes its rollout records.
