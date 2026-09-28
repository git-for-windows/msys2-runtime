# Cygwin patch review briefings

A briefing is a decision aid for an expert returning to the code. It
complements human judgment; it is not a diff summary, research report,
approval notice or sendable email. Use [review contracts][contracts] for the
source-review method and source-pinned PTY/PseudoConsole contracts.

## Briefing format

Write one self-contained document per patch/revision or explicitly stated
dependent series. No prior briefing or conversation should be necessary.
For batches, use stable numbered filenames such as `NN-topic-vN.md`. Aim for
350-500 visible words, a three-minute read; simple changes can be shorter.
Around 550 words, trim peripheral detail, never blockers or necessary causal
steps. Keep raw traces, exhaustive line maps and manifests outside the
briefing; link useful evidence notes.

Use a reader-friendly title naming the problem or outcome and revision,
rather than copying a long mail subject. Immediately below, put the bold
linked date and review position shown in the skeleton. Link the exact
revision message permalink, not a search URL. Label the timezone when
sender-local and UTC archive dates differ. Use `request changes`,
`no blocker identified in this change`, or `blocked`/`inconclusive` with the
missing evidence.

Keep the order: background, intended change, problems or boundedness, review
decision. Adapt headings naturally; omit empty sections. Background covers
only necessary actors, user-visible semantics, buffer/state ownership,
request versus acknowledgement and locks. Explain identifiers on first use;
assume expertise, not implementation familiarity. Skip POSIX primers.
Describe the original observable failure, correction and relevant
earlier-version differences: fixed, remaining or newly exposed concerns,
plus earlier known-good bounded behavior.

Give each material problem one coherent paragraph opening with a bold,
concrete consequence. Include reachable preconditions, actors and data
lifecycle, named state/functions/locks, feasible ordering, why alternate
paths cannot repair it, observable failure and before/after contrast.
Distinguish a pre-existing bad edge from a newly enabled cycle, attributing
only the new behavior to this revision. Without blockers, explain the
change's bounds and what it does not establish.

Prefer principles and named functions over naked line numbers. Citations
support, not replace, explanation. Line references identify the exact file,
revision or patched snapshot, and enclosing function; hunk labels can
mislead. Pin external host/API claims to exact source versions or
authoritative documentation.

The decision specifies required changes or the limited scope meriting
favorable review, preserving the intended correction. Do not present
untested alternatives as proven fixes, request unrelated cleanup or expand
the patch into a runtime audit.

End with an honest evidence-limit paragraph distinguishing source trace,
runtime observation and hypothesis: exactly what was exercised and not,
including no reproduction where appropriate. Claim independent
corroboration only if it happened. Existing `Reviewed-by` trailers do not
prove current concerns are resolved; a briefing authorizes neither replies
nor approval trailers.

Normally finish with two or three useful context links; the patch is
already linked. Local provenance links are optional. Omit greetings,
sign-offs, tables of findings, nested lists, long code dumps and opaque
agent transcripts.

## Evidence workflow

1. Retrieve the exact submission's complete raw patch and thread, plus
   relevant earlier revisions and review replies; revisions may be separate
   threads. Check adjacent UTC dates when sender dates differ. If searching
   fails, use archive indexes, a known Message-ID or another public mirror.
   Search failures or missing entries do not prove a patch never existed;
   snippets and changelogs are insufficient.

2. Pin the exact base and complete final patched state. Record Message-ID,
   source URL, base commit, applied patches/dependencies and pre/postimage
   identities; check advertised Git blob hashes when present. Prefer raw
   mail to HTML-rendered patches. Investigate mismatches, incomplete diffs
   or ambiguous bases; preserve evidence and state limitations. Request
   missing source when needed. Never silently repair or guess content, or
   claim to have checked the author's final tree without verification.
   Protect the worktree and unrelated changes; a private index plus
   selected snapshots may suffice for read-only investigation.

3. Use the contracts to read surrounding code and callers, including
   caller-held locks. Trace ownership, lifetime, alternate entries,
   initialization, replacement and close. Establish lock identity across
   actors at the kernel-object level and inspect actual acquisition
   results. Establish the smallest feasible before/after witness; arbitrary
   flag combinations or opposite name-only lock orders are not findings.
   Use `git log -L` when origins or preserved contracts matter. Recheck PTY
   contracts before applying them to console code or another revision.

4. Compare earlier objections explicitly against this exact revision and
   inspect new surfaces affected by the fix. Classify findings as fixed,
   remaining, new or pre-existing. Keep related but unapplied patches
   separate.

5. Choose the smallest validation exercising the claim. Runtime evidence
   needs the actual upstream patch/series, matching built and loaded binary,
   exact reproducer and relevant runtime/terminal configuration, with a
   baseline comparison where needed. Reuse only verified artifacts; an old
   DLL or build directory is not proof this patch was tested. Avoid broad
   rebuilds or new test infrastructure merely for appearances. Rigorous
   source review can still inform the briefing; it must not masquerade as
   runtime reproduction or confirmation of a fix. Preserve commands,
   outcomes, source locations, versions and logs outside the briefing.

6. Before writing, distill an evidence ledger: claim, patch version,
   preconditions, before/after path, source citation or reproduction result,
   confidence/limits and disposition. It need not be tracked. Give any
   drafter verified facts and uncertainty; drafting alone is not
   independent review.

7. Read as a returning reviewer: are the problem, change, causal failures
   and decision understandable without source spelunking? Check word count,
   links/local evidence paths, exact revision/date, unsupported claims,
   mixed revisions and missing caveats. Save the requested artifact in the
   user's chosen location or session artifacts and deliver its path. Do not
   publish private drafts or raw mail unless requested.

## Copyable skeleton

Replace brace-delimited placeholders; omit the zone if unnecessary. Rename
Problems to Why the change is bounded when no blocker is identified.

```markdown
# {Problem or outcome}, v{N}

**[Patch: {DATE} ({ZONE})]({MESSAGE_URL}) | Review position: {POSITION}.**

## Background

{Actors, semantics, ownership and synchronization needed for this patch.}

## What v{N} fixes

{Original observable failure, correction and relevant earlier-version
differences, including preserved behavior.}

## Problems

**{Concrete consequence}.** {Reachable before/after causal path, named
state/functions/locks, failed recovery paths and observable result.}

## Review decision

{Required change, or the exact limited scope meriting favorable review.}

{Evidence limit: source trace / runtime observation / hypothesis; exactly
what was and was not exercised, including absence of reproduction.}

**Further context:** [Earlier review]({REVIEW_URL}) |
[Maintainer reply]({REPLY_URL})
```

[contracts]: CYGWIN-REVIEW-CONTRACTS.md
