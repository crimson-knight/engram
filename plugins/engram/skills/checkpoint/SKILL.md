---
name: checkpoint
description: Save the current task state before compaction or a work break, then resume from its next action.
user-invocable: true
---

# Checkpoint

Write the orientation work into the checkpoint file so a new context can
resume at the next concrete action.

## Steps

1. Reconcile task state with any task tracker or status file used by the work.
2. If the repository has a fast test suite and code changed, run it and record
   the result. Name any failing checks and their cause.
3. Use the checkpoint file path printed by the engram SessionStart hook. If the
   path is not in context, invoke the checkpoint helper path command or use
   the current session id from the hook payload when available. Keep the file
   under 150 lines and 6,000 characters.
4. Print one line confirming the path and line count.

## Format

    # CHECKPOINT v1 — <ISO-8601 timestamp>

    ## MISSION
    <The user's ask, as close to verbatim as needed>

    ## STATE
    - ✅ <completed item> — <file or command evidence>
    - 🔄 <in-flight item> — <exact stopping point>
    - ⬜ <not-started item>

    ## NEXT
    <One concrete action with a file path, command, and expected result>

    ## SKILLS
    - <skill name> — <one-line rule; reload before using its procedure>

    ## RULES
    - <settled constraint>

    ## TRAPS
    - <fact that would otherwise be rediscovered>

NEXT must be executable without another lookup. State claims need evidence.
Never include secrets, keys, or tokens. The pre-compaction hook also writes a
deterministically extracted fallback from the transcript.
