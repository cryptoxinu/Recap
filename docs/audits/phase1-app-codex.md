| severity | file:area | issue | fix |
|---|---|---|---|
| HIGH | `Sources/CallBrainCore/Answer/AskEngine.swift:76-79` | Citation enforcement does not fully hold: if the LLM returns uncited text or only bogus tags like `[S99]`, `used.isEmpty ? refs : used` marks it answered and attaches all offered refs. | Extract `[S#]` tags, reject/repair answers with no valid tags or unknown tags, and require valid citations before `.answered`. |
| HIGH | `Sources/CallBrainApp/AppEnvironment.swift:23-24` | Primary store init errors are silently swallowed and replaced with a temp SQLite store; existing meetings can appear empty, and fallback has `try!` crash risk. | Surface store init failure in UI/app startup; remove temp fallback or make it explicit and non-destructive. |

VERDICT: FAIL