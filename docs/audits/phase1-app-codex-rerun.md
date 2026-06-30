| check | status |
|---|---|
| AskEngine cited refs enforcement | FIXED: extracts `[S#]` via `referencedTags` at `Sources/CallBrainCore/Answer/AskEngine.swift:79` and `:91-99`, keeps only cited valid refs at `:80`, refuses `.noSources` when none remain at `:81-85`. |
| Store init failure surfaced | FIXED: `initError` at `Sources/CallBrainApp/AppEnvironment.swift:15`, primary-store `do/catch` at `:26-40`, unique temp fallback at `:32`, descriptive `fatalError` at `:36`, no `try!`; Home banner renders at `Sources/CallBrainApp/HomeView.swift:31-37`. |
| Remaining CRITICAL/HIGH scan | CLEAR: targeted scan found no remaining CRITICAL/HIGH issues in Phase 1 paths. |

Verification caveat: `swift test --filter AskEngineTests` could not run because this session is read-only and SwiftPM/xcodebuild could not create cache files under `/tmp`.

VERDICT: PASS-WITH-NITS