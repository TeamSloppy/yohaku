# Yohaku: additional practice and ordered course

Approved in chat on 2026-10-20. Trunk: main. Each slice is a complete additive feature, draft PR, target <=600 reviewable lines; split modules when larger. Existing dirty main checkout is preserved in place.

| Slice | Result | Depends on | State |
|---|---|---|---|
| 1 | Durable extra practice without SRS writes | - | verified |
| 2 | Explicit AI composition and preview | 1 | verified |
| 3 | Constrained short reading | 2 | verified |
| 4 | Complete first hiragana module | 1 | planned |
| 5 | Full hiragana and placement checks | 4 | planned |
| 6 | Full katakana | 5 | planned |
| 7 | First kanji module | 6 | planned |
| 8 | Individually complete N5 topic packs | 7 | planned |

Safety: additive entry points; each installed module is complete. No temporary flags or cleanup debt. Daily scheduling stays independent. Ready exercises work offline. Generated content uses the selected provider only. Draft PRs may be stacked for review; no automatic merges.

Stage 1: iPhone Simulator build/run and 11 selected unit/UI tests passed, 2026-10-20. Reviewable delta approximately 425 lines; generated Xcode project excluded. Test result: test_sim_2026-10-20T09-29-53-459Z_pid41692_56c59457.xcresult.

Stage 2: 15 selected unit/UI tests passed (2026-10-20); explicit generation, validated vocabulary/particles, cancellation ownership, and source snapshot checks. PR1: https://github.com/TeamSloppy/yohaku/pull/1 (draft).

Stage 3: 6 selected tests passed, including reading preview, preserved source references and durable extra practice. Reading uses validated known expressions and an explicit first-line translation question.
