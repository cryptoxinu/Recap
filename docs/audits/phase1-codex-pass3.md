| check | status |
|---|---|
| Atomic ingest persistence | Fixed: `Store.saveMeeting(_:chunks:embeddings:)` writes meeting, chunks, and embeddings inside one `dbQueue.write` transaction at [Store.swift](/Users/z/CallBrain/Sources/CallBrainCore/Store/Store.swift:143). `IngestEngine` builds `EmbeddingInput`s and calls that single save at [IngestEngine.swift](/Users/z/CallBrain/Sources/CallBrainCore/Ingest/IngestEngine.swift:68) and [IngestEngine.swift](/Users/z/CallBrain/Sources/CallBrainCore/Ingest/IngestEngine.swift:75). No separate `saveEmbedding` call in `IngestEngine`. |
| Keyword candidates before LIMIT | Fixed: `SearchEngine.hybrid` passes `candidateChunkIDs` into `store.keywordSearch` at [SearchEngine.swift](/Users/z/CallBrain/Sources/CallBrainCore/Retrieve/SearchEngine.swift:32). `keywordSearch` applies `f.chunk_id IN (...)` in SQL before `ORDER BY score LIMIT ?` at [Store.swift](/Users/z/CallBrain/Sources/CallBrainCore/Store/Store.swift:194). No post-LIMIT candidate filtering found. |
| Remaining CRITICAL/HIGH correctness/concurrency bugs | None found in final scan of `Sources/CallBrainCore/`. |

VERDICT: PASS