# Automatic phrase practice

User request: compose phrases/sentences from studied words and kana, save them for repetition, ask multiple-choice meaning questions. User selected automatic addition to Today. Existing all-task-changes-to-main publication authorization retained. Worktree: existing yohaku-study-persistence/Workspace; branch codex/composed-phrase-practice, baseline9b57a0f.

Single vertical increment, target600reviewable lines/cap1000. Additive optional card metadata, existing card FIFO/CAS writer, existing lesson grade journal. No second state writer or schema replacement. A complete generation→saved-card→Today→quiz path ships together; pure kana progress is a small local preference, not a separate new course. No toggles or abstraction migration. Prefer keep ≤600; report actual size before publication. No implementation outside this feature, no provider fallback, no background scheduling guarantee while app closed.

## Goal
Automatically prepare up to3 new composed exercises per local day when Today opens, using known word cards and practiced kana; include up to2 in a new lesson. Quiz answers grade the phrase independently and durably.

## Boundary
Existing manual cards/quiz, material provenance/import journal, frozen active lesson and once-only grade protocol preserved. Automatic generation only before a new lesson, supported writable vault, two known words, selected available provider and no concurrent agent run. Two successful reviews with last rating remembered qualify a word; generated phrases never recursively become ingredients. No fabricated note/source quotes. Existing frozen snapshot keeps generated question/options.

## Done when
- Known kana persists locally from completed tracing glyphs; UI-test preferences isolated. Current vocabulary validated inside card FIFO before saving generated cards.
- Model returns ordered known word IDs, translation and3 distinct alternatives; client constructs Japanese from the exact supplied words. Kana-only rendering uses known reading characters. Invalid/unknown/duplicate output rejected.
- Per-vault/day quota and duplicate protection survive reopen; concurrent or stale vault/source/model work cannot add cards. Generation failure leaves existing lesson usable, with retry.
- Generated phrase stores ingredient snapshots, fixed options and original prompt/answer. Its own SRS changes; ingredient SRS does not. Legacy cards decode without metadata; content edits safely disable outdated phrase options.
- Today prepares automatically on open/foreground/day change, exposes progress/error/retry, and never changes active/completed lessons. Start cannot race preparation. Ordinary planner order remains identical without phrases.
- Daily lesson shows Japanese +4 choices, answer feedback and explanation, then commits exactly one remembered/forgot grade on Next through existing durable cursor APIs. Existing library Quiz reuses fixed choices.

## Implementation Steps
1. Add bounded composition DTO/parser and AgentSession generation using selected model; optional persisted phrase card metadata and local kana/day profile.
2. Add guarded card-FIFO save, day quota/dedup and known-input revalidation; automatic Workspace coordinator with context/config/cancellation guards and generation status.
3. Wire kana completion, Today automatic preparation/status, bounded planner phrase allocation and frozen phrase quiz UI. Preserve manual paths.
4. Meaningful parser/persistence/quota/cancellation/grade tests; Simulator generation fixture→Today quiz→restart; existing Today/manual quiz regressions; Catalyst compile. No live provider calls in checks.

## Verifications
Use XcodeBuildMCP CLI/default Xcode, task derived /tmp/yohaku-study-persistence-derived; serialize Simulator/build operations. Unit scopes include phrase tests plus card/lesson persistence/planner/practice. UI fixture skips real inference but runs the same validation/persistence and quiz. Record passed/failed/unrun, exact paths and limits. No physical iCloud or handwritten recognition quality claim.

Status: implementation and planned local verification complete in the isolated worktree. No other writers or subagents.

## Implementation notes
- Optional phrasePractice card metadata stores immutable ingredient snapshots, original prompt/answer, generation date and shuffled-once choices. The client assembles the Japanese prompt from known word IDs and allowed particles; overlong or invalid output never becomes a card.
- Word eligibility requires at least two successful reviews and the latest rating remembered. Reading-only prompts require all reading characters to be practiced kana; whitespace readings cannot produce blank questions. Generated cards cannot become ingredients.
- Today prepares before a new lesson and offers cancel/retry. Current vault, day, model, material membership and original words are rechecked before the card FIFO commit. Existing lessons remain frozen, and phrase grading uses their existing journal.
- Local inference requests one phrase using up to four whole vocabulary records (1200 UTF-8 bytes); remote generation requests up to three using up to24 records (12000 bytes). Output uses the existing provider token limits. No provider fallback.
- Known kana and per-vault daily receipts are local UserDefaults preferences. Generated cards and their SRS use the existing vault writer. No closed-app scheduled execution or cross-device kana-profile sync is claimed.

## Verification record
- Initial compile found a missing writer argument in the test setup; fixed. First focused unit run:49 distinct tests passed.
- Expanded iPhone run:51 distinct unit tests passed, including stale vault/day/model/cancel, empty-output retry, quota, frozen lesson and exactly-once grading. New phrase UI and existing Today resume UI passed.
- UI testing found plain-style row hit areas excluding their blank center. Added explicit full-row content shapes to phrase choices and the library sidebar entry. The old Quiz regression is being rerun after the library fix.
- Final iPad13 run:11 distinct tests passed (nine phrase unit tests, with four stale-generation argument cases; phrase UI and ordinary Quiz UI). Final iPhone compact run:both phrase UI and ordinary Quiz UI passed. The sidebar hit-area regression is resolved on both layouts.
- Catalyst compilation passed via XcodeBuildMCP, generic Mac Catalyst destination, CODE_SIGNING_ALLOWED=NO. Fresh Yohaku.debug.dylib produced at12:44:43 local time. Existing MarkdownEditor deprecation and AgentSession await warnings remain; no runtime-on-Mac claim.
- Review size:571 added+removed Swift source/test lines against baseline; below the600-line target. Excluded documentation and generated XcodeGen project file (8 lines). One complete vertical increment, no PR needed for the explicitly requested direct main publication.
- Simulator composition fixtures run the production parser, persistence, planner and quiz but replace live inference. Live provider accuracy, physical-device inference and physical iCloud sync were not tested.
- Logs: /tmp/yohaku-phrase-unit2.log, /tmp/yohaku-phrase-final.log, /tmp/yohaku-phrase-ipad.log, /tmp/yohaku-phrase-compact.log, /tmp/yohaku-phrase-catalyst.log. Screenshots copied to the task visualization folder under phrase-practice/.

