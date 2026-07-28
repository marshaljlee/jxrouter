## Fix Plan: JXRouter 10-Minute Hang on First Request

### Root Cause
Three compounding issues in the proxy pipeline cause indefinite hangs:

1. **Body accumulation has NO timeout** (ProxyServer.swift:619-636) — `connection.receive` blocks forever on Content-Length mismatch
2. **Stream Task silently dies** (ProviderRouter.swift:208) — No `catch` clause → `continuation.finish()` never called → output stream hangs forever  
3. **[DONE] doesn't finish the stream** (ProviderRouter.swift:227) — `break` exits inner while-loop only, outer for-await continues for 30 extra seconds

### Changes (ordered by priority)

| # | File | What | Why |
|---|------|------|-----|
| **1** | `ProxyServer.swift:619-636` | Add 30s timeout to `connection.receive` in body accumulation. | **Eliminates indefinite body-read hang — the #1 cause** |
| **2** | `ProxyServer.swift:614-684` | Wrap the outer Task with a 90s total request timeout + cancellation. | **Ensures every request terminates even if everything else fails** |
| **3** | `ProviderRouter.swift:221-228` | After `[DONE]`, break the outer for-await loop (label+break) so stream finishes immediately. | **Prevents 30s extra wait per provider after all events are sent** |
| **4** | `ProviderRouter.swift:208-268` | Add `catch` clause to streaming Task. On error, yield `message_stop` and `continuation.finish()`. | **Prevents permanent hang when the Task encounters an error** |
| **5** | `CurlClient.swift:68-83` | Replace blocking `fileHandle.read(upToCount:)` with a non-blocking read loop that respects a 30s total deadline. | **Prevents 30s blocking read that ignores the declared 10s header timeout** |
| **6** | `ProviderRouter.swift:74-91` | Add 1s backoff between fallback providers + 120s overall chain cap. | **Prevents rapid-fail cascade, bounds total fallback time** |
| **7** | `CurlClient.swift:116-132` | Add `onTermination` handler to kill curl process on consumer disconnect. | **Prevents orphan curl process leaks** |
| **8** | `DirectDNSResolver.swift:69-92` | Add 10s timeout to `getaddrinfo` via dispatch queue. | **Caps DNS resolution delays from system resolver** |

### Implementation order
1. Fixes **#1 and #2** first (critical — directly prevent the 10-minute hang)
2. Fix **#3 and #4** (high — prevent stream-related hangs and latency)
3. Fix **#5** (high — makes CurlClient timeout actually work)
4. Fix **#6 and #7** (medium — reliability)
5. Fix **#8** (low — edge case)