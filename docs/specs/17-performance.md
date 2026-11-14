# 17. Performance and efficiency requirements

Create:

```text
docs/performance-budget.md
```

All numbers below are **initial targets**, not claims.

Choose and document reference hardware before making them release criteria.

## 17.1 Interactive targets

Suggested targets:

- Typical typing core update: p95 below 8 ms.
- No ordinary UI task monopolizes the thread for more than roughly one frame.
- Continuous job output must not make cursor movement visibly lag.
- Scrolling and resizing should remain responsive at the supported refresh rate.
- Background results should be applied in bounded batches.

## 17.2 Benchmark fixtures

Use at least:

| Fixture                        | Purpose                             |
| ------------------------------ | ----------------------------------- |
| 1 MiB source file              | Normal editing                      |
| 100 MiB source/log file        | Large-file indexing and scrolling   |
| 1 GiB log file                 | Backing-store and large-file mode   |
| Single very long line          | Shaping and horizontal scrolling    |
| Mixed-script Unicode           | Font fallback and grapheme movement |
| Invalid UTF-8                  | Lossless handling                   |
| 100k-file project              | Finder scalability                  |
| Heavy process output           | Backpressure                        |
| Large undo tree                | History storage/navigation          |
| Many windows on shared buffers | Layout and snapshot overhead        |

Measure:

- Cold/warm startup.
- Time to first useful viewport.
- Time to editable state.
- Peak and steady-state memory.
- Typing latency.
- Scroll latency.
- Parse latency.
- Clipboard transfer behavior.
- Save time.
- Journal durability cost.

## 17.3 Idle behavior

The editor should not redraw expensively while idle.

If the chosen Sokol application loop does not provide adequate event-driven waiting, investigate a small platform integration change.

“Skip drawing but keep spinning at full speed” is not a good idle implementation.

## 17.4 Allocation policy

Use:

- Frame arenas for transient draw/layout data.
- Worker-local scratch arenas.
- Explicit long-lived allocators.
- Reference-counted immutable snapshots.
- Bounded caches.

Never return worker results that point into a worker’s reset scratch arena.
