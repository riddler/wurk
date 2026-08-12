---
name: wurk:research
description: Document the codebase as it exists today - fan out read-only sub-agents, synthesize their findings, and write a dated research document with frontmatter and permalinks. Reads .claude/wurk.json; honors .claude/wurk/research.md.
model: opus
argument-hint: ["research question or bead ID"]
---

# Research codebase

Conduct comprehensive research across the codebase to answer a question, by
spawning parallel read-only sub-agents and synthesizing their findings into a
document.

## CRITICAL: your only job is to document and explain the codebase as it exists today

- DO NOT suggest improvements or changes unless the user explicitly asks
- DO NOT perform root cause analysis unless the user explicitly asks
- DO NOT propose future enhancements unless the user explicitly asks
- DO NOT critique the implementation or identify problems
- DO NOT recommend refactoring, optimization, or architectural changes
- ONLY describe what exists, where it exists, how it works, and how the
  components interact
- You are creating a technical map of the existing system

## Project extension

If `.claude/wurk/research.md` exists, **read it before step 1**. Typical
content: the project's own vocabulary for its pipeline or layers, sibling or
reference checkouts worth pointing an agent at, and areas that reliably need
their own sub-agent.

Also read `.claude/wurk/codebase.md` if it exists. It is not this skill's
extension - it is addressed to the `wurk-codebase-*` agents, and this skill's
only job with it is to forward it (step 3).

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Initial setup

1. **If a bead ID was given** (`/wurk:research <id>`), skip the default
   message and go to the bead workflow below.

2. **If no parameters were given**, respond with:

   ```
   I'm ready to research the codebase. Please provide:

   - A research question or area of interest, OR
   - A bead ID to research

   I'll analyze it thoroughly by exploring the relevant components and
   connections.
   ```

   Then wait.

## Bead research workflow

1. **Fetch the bead**: `bd show <id>`. Extract the title, description, type,
   priority, labels, and any dependencies or linked issues worth researching
   too. If it does not exist, say so and ask for a different id or a
   question.

2. **Frame the research question** from the description, and research the
   current implementation, the components and files involved, the relevant
   existing patterns, and the integration points. Apply the standard workflow
   below; the filename in step 5 will carry the bead id.

3. **After the research completes**, record it on the bead and summarize:

   ```bash
   bd note <id> "Research doc: <path>"
   ```

   ```
   Research complete for <id>

   Research document: <path>

   [brief summary of key findings]

   You can now use `/wurk:plan <path>` to create an implementation plan.
   ```

## Steps to follow after receiving the query

1. **Read any directly mentioned files first**, FULLY. Use the Read tool with
   no limit/offset. Read them yourself in the main context **before** spawning
   any sub-agent, so the decomposition starts from real content.

2. **Analyze and decompose the question.** Break it into composable research
   areas. Think about the underlying patterns, connections, and architectural
   implications the user might be after. Identify the specific components and
   concepts to investigate, and which layers of the project are involved (the
   extension file names them where the project has a vocabulary for it).
   Track the sub-tasks.

3. **Spawn parallel sub-agents**, each with one narrow question and a request
   for `file:line` references back. Pick by what the question needs:

   - **wurk-codebase-locator** - WHERE files and components live
   - **wurk-codebase-analyzer** - HOW a specific component works
   - **wurk-codebase-pattern-finder** - existing patterns to model after
   - **wurk-docs-locator** - which project documents exist on the topic
     (research, plans, ADRs, design notes)
   - **wurk-docs-analyzer** - the key insights from the most relevant of them
   - **Explore** - a read-only breadth-first sweep when the question is "what
     touches X" and no specialized agent fits
   - **wurk-web-search-researcher** - external documentation and specs, only
     when the user asks for it. Instruct it to return links, and include them
     in the final report.
   - **general-purpose** - only when the question needs more than reading:
     running a snippet, checking behavior in a REPL, or reading a sibling
     checkout outside this repo. Say so explicitly in the prompt.

   **Pass the project's document roots** to `wurk-docs-locator` and
   `wurk-docs-analyzer` in their prompts: the manifest's `artifacts.research`
   and `artifacts.plans`, plus the ADR directory if the project has one. The
   agents can find these themselves, but a skill that forgets costs every
   invocation an extra manifest read.

   **Pass the project's orientation** to every `wurk-codebase-*` agent you
   spawn: paste the content of `.claude/wurk/codebase.md`, verbatim, under
   the heading `## Project orientation, from .claude/wurk/codebase.md`.
   Forward it as it stands - summarizing or excerpting it is a judgment call
   you would be making invisibly, on every invocation. If the file does not
   exist, say nothing about it; the agents orient from the repo, which is
   the normal case.

   The research agents are documentarians, not critics: they describe what
   exists and do not suggest improvements or identify issues. Accepted ADRs
   are settled decisions - cite the number, do not re-argue it.

   Use them intelligently: start with locators to find what exists, then run
   analyzers on the most promising findings, and run several in parallel when
   they are looking for different things. Each agent knows its job; do not
   write detailed prompts about HOW to search.

4. **Wait for ALL sub-agents to complete, then synthesize.** Compile every
   result. Prioritize live codebase findings as the primary source of truth
   and document findings as supplementary historical context. Connect
   findings across components, include specific paths and line numbers,
   highlight patterns and architectural decisions with their ADR numbers, and
   answer the question with concrete evidence.

5. **Gather metadata and write the document.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/doc_meta.rb metadata
   ruby ~/.claude/skills/wurk:kit/scripts/doc_meta.rb filename \
     --dir <artifacts.research> --description "<kebab-topic>" [--issue <id>]
   ```

   `metadata` gives `data.date`, `data.git_commit`, and `data.branch`;
   `filename` gives `data.path`, built from the manifest's
   `artifacts.filename` grammar. `doc_meta.rb` is the single definition site
   this skill shares with `/wurk:plan`, so the two cannot drift.

   Render the frontmatter:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/doc_meta.rb frontmatter \
     --topic "<the question>" [--beads-issue <id>] \
     --tags "research,codebase,<component>" [--status complete]
   ```

   `data.frontmatter` is the ready-to-paste `---`-delimited block. The
   repository name in it comes from `artifacts.repository`, or from the git
   remote when the manifest does not set it. **Never write the document with
   placeholder values** in place of any of these - if a value is not
   available yet, get it from `doc_meta.rb` rather than filling in a
   stand-in.

   **You MUST propose the complete document and write it to disk before
   presenting your summary:**

   1. Compose the full content - the frontmatter block above, then body
      content you write yourself
   2. Present the proposed path and a brief description
   3. Ask permission to write it
   4. On approval, write it with the Write tool
   5. Confirm it was written

   Body structure (`doc_meta.rb` emits frontmatter and a filename only, never
   a section skeleton - this shape is yours to write):

   ```markdown
   # Research: [Question/Topic]

   **Date**: [date with timezone]
   **Git Commit**: [commit hash]
   **Branch**: [branch name]
   **Bead**: [id, if applicable]

   ## Research Question

   [the original query]

   ## Summary

   [high-level documentation of what was found, answering the question by
   describing what exists]

   ## Detailed Findings

   ### [Component/Area 1]

   - What exists (`path/to/file.ext:123`)
   - How it connects to other components
   - Implementation details, without evaluation

   ## Code References

   - `path/to/file.ext:45` - what is there
   - `path/to/other.ext:12-40` - what that block does

   ## Architecture Documentation

   [patterns, conventions, and design implementations found in the codebase;
   cite ADR numbers where applicable]

   ## Historical Context

   [relevant insights from the project's documents, with references]

   ## Related Research

   [links to other research documents]

   ## Open Questions

   [areas needing further investigation]
   ```

6. **Add permalinks (if applicable).** Check whether the commit is one
   anybody else can resolve - on the default branch, or pushed:

   ```bash
   git branch --show-current && git status
   ```

   That judgment call stays here; the rewrite itself is mechanical:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/permalinks.rb <path>
   ```

   It turns every backtick-quoted `` `file:line` `` (or `` `file:line-line` ``)
   reference already in the document into a link in the forge's blob-URL
   format, idempotently - a second run touches nothing already rewritten.
   `data.count` is how many changed; `data.substitutions` lists them. A forge
   whose URL format the kit does not implement blocks rather than guessing a
   URL that 404s inside a document nobody re-reads.

7. **Present findings**: a concise summary with the key file references, and
   an offer to answer follow-ups.

8. **Handle follow-up questions.** Spawn new sub-agents as needed, then
   append the findings to the same document under a new follow-up section:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/doc_meta.rb follow-up <path> \
     --note "Added follow-up research for [brief description]"
   ```

   This bumps `last_updated`, sets `last_updated_note`, and appends a
   `## Follow-up Research <timestamp>` heading - nothing else. Write the
   findings under that heading yourself.

## Important notes

- Always use parallel sub-agents to maximize efficiency and minimize context
  usage
- Always run fresh codebase research - never rely solely on existing
  documents
- The project's document directories provide historical context that
  supplements live findings
- Focus on concrete paths and line numbers
- Research documents should be self-contained
- Each sub-agent prompt should be specific and scoped to read-only work
- Document cross-component connections and how systems interact
- Include temporal context
- Keep the main session focused on synthesis, not deep file reading
- Explore the whole document tree the manifest points at (research, plans,
  ADRs, design notes), not just the research directory
- **CRITICAL**: you and all sub-agents are documentarians, not evaluators
- **REMEMBER**: document what IS, not what SHOULD BE
- **Critical ordering**: read mentioned files first (step 1); wait for all
  sub-agents before synthesizing (step 4); gather metadata before writing
  (step 5); never write with placeholder values
- **Frontmatter consistency**: always include it, keep the fields consistent
  across documents, update it when adding follow-up research, and use
  snake_case for multi-word field names
