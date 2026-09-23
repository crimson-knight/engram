The session-start hook adds a short reminder. Load the full reader card before
writing anything the user will read. Use the engram MCP tools to call
recent_memories with topic reader, then get_memory for each active card page.
If MCP is not available, run the packaged reader-inject-hook helper with
--full from the engram agent kit.

The reader model is a persistent description of the person the agent reports
to. It can contain vocabulary keyed by domain, the reader's level for different
topics, preferred reply shapes, and the protocol for resolving a miss. Treat
the reader's stated corrections as stronger than guesses. Do not store
judgments about the reader.

## Before sending text the reader will see

1. Review the full request and answer each thread in the order it was raised.
2. Identify the topic or domain for each concept. Set the depth for each topic
   from the matching depth-map entry. Use its bridge-from guidance for topics
   where the reader is new.
3. Check vocabulary by domain. A term can be familiar in one topic and unclear
   in another.
4. Shape a brief as one bottom-line sentence, up to four bullets, and one link
   or question. Use other formats only when the card names one.
5. Make every requested user action self-contained: what to do, why it matters,
   where it goes, what access is missing, and how completion will be confirmed.
6. Label numbers with their source, unit, and direction of change. Define a
   new name in ordinary words the first time.
7. Check the draft against the card. Remove rejected terms, replace lost terms
   with the recorded explanation, explain identifiers outside code, label bare
   numbers, and shorten dense paragraphs.
8. If the packaged jargon gate is available, run it on the draft and fix each
   blocking finding. If not, apply the same checks directly from the card.

## When the reader says something is unclear

Do not repeat the whole explanation with fewer words. Restate the ask in the
reader's terms, ask which word or number missed, identify where a number came
from, and explain the mechanism with a familiar example. Use a picture when a
flow, comparison, or log is easier to see than to read. Confirm or correct the
reader's paraphrase explicitly.

Before the session ends, add a new engram migration with topic reader. Record
the term or framing that missed, the useful explanation or that the issue is
unresolved, and any correction to the depth map. Supersede an older page when
the new memory changes it, and carry the complete updated page forward.

## Confidence

A direct correction applies immediately. Treat an inferred term as established
only after the reader uses it without prompting in more than one session in
the same domain. Raise the depth for a topic only when the reader demonstrates
that level there.
