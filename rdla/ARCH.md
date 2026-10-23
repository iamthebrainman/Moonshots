# RDLA architecture: from tape to English prose

Two halves joined by one interface, the **slot-filler table**.

    tape + idioms ──► [A. RDLA core] ──► types, operators, requirement signatures
                                              │
                          question ──► [B. answer planner] ──► answer type + filled slots
                                              │
                                  [C. DADADA SRTN realiser] ──► English prose

## A. RDLA core (deterministic, pure function of the tape)
1. tok / idiom fuse / ctx bundles (built; shard-independent integer sums).
2. Operator detection: chance-corrected coherence(right) - coherence(left); fusion test (pair bundle vs sum of parts).
3. Requirement signatures: per operator, diagn(p) over left/right role positions -> slot demands (direction, filler type).
4. Types: clusters of units that satisfy the same slot demand. Each type gets a stable id = hash of its top-diagnostic members (this id is the new `Cat`).
5. Idiom gloss: `"phrase" means <gloss>` is bundled in the GLOSS role, so the idiom is a unit whose bundle is the gloss's bundle.
6. Genre channels: comedy vs wiki counts kept separate; wiki = baseline.

## B. Answer planner
- Question -> bundle probe (same float/activate/interact path) -> answer type from the operator found in the question
  (what-is -> DEFINE, why/because -> CAUSE, X vs Y -> COMPARE, is X a Y -> YESNO, how -> PROCEDURE, "phrase" -> IDIOM).
- Slot filling: for each slot in the chosen template, rank members of the slot's type by cosine against the question/answer bundle. Top-k with an avoid-list, argmax (no randomness).

## C. Realiser = the DADADA engine, generalised
Changes to the uploaded engine, nothing else:
| DADADA now | RDLA version |
|---|---|
| `Cat` = 4 hard-coded enum values | `Cat` = induced type id (u32); `Cat.fixed` kept for the seed grammar |
| one `templates` array | `templates[AnswerType]` : a set per answer type |
| slot candidates = seed + corpus counts | slot candidates = type members ranked by bundle similarity to the query |
| `Part = lit \| cat` | `Part = lit \| cat \| sub(NonTerminal)` -> recursion (clause inside clause) |
| learned template/connector/glue counts | unchanged: plain counting, argmax, avoid-lists |
| text model file | unchanged format + `TYPE` section |

Recursion: a `sub` part expands another nonterminal (e.g. EVIDENCE -> "because " CLAUSE | CLAUSE " and " EVIDENCE), depth-capped.
Operators surface in prose as literal chunks: an operator's learned requirement (e.g. "have to" wants a verb phrase on its right) selects which literal may join which slot types, so the grammar never joins mismatched types.

Determinism: same tape + same question + same model file -> identical text. Template/connector choice is argmax over counts; slot choice is argmax over similarity with ties broken by unit hash.

## Build order
M1 substrate (done) -> M2 operator metric + fusion + parallel shards -> M3 signatures/types/genre -> M4 teaching queue for idioms -> M5 planner + typed SRTN (port of dadada to Zig 0.15 API) -> M6 400 MB run.

## Update: lens over a mapped tape (current design)

The persisted file is the TAPE plus a positions index (`lens.zig`, `rdla index`), not extracted facts.
A question picks an answer type (wh-word x modal); the answer type picks a LENS (a slot requirement:
operator word-sequences after the subject, clause-initial subject, noun-phrase end cues); `find`
walks the subject's occurrences through the index and reads the tape. Every match is a real place in the
tape and is cited as evidence. Senses stay apart because they are different occurrences. Templates
(`gen.zig`) are used only if every slot they need was found. The context-bundle accumulator
(`ctx.zig`, `store.zig`) remains as the "float" side for operator discovery; answers do not use it.

Slot-requirement rules currently hand-entered in `lens.zig`/`gen.zig`: the copula operator list, the
because/by/in/should operator lists, noun-phrase end cues (-ly, -ed, function words), lead-sentence
priority (title line, paragraph start). Function words are the units present in every 1/64th stretch
of the tape. Deriving the operator lists and cues from the tape is the next step.
