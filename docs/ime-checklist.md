# Input method manual test log (tech.md §11.5 B)

One row per run. Mark each result ✓ / ✗; attach a snippet of `/usr/bin/log stream --predicate 'subsystem == "local.sparkling"' --level debug` for every ✗.

| Date | Input method and version | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-17 | In-process simulation (IdeaUITests, not a real input method) | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | — | ✓ | — | — | Only proves nothing is committed while there is marked text; real input methods still need a manual test |
