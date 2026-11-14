# 23. Highest-risk parts

These should drive early spikes and careful review.

| Risk                           | Why it matters                                   | Mitigation                                                           |
| ------------------------------ | ------------------------------------------------ | -------------------------------------------------------------------- |
| Clipboard ownership            | Platform semantics differ substantially          | Native adapters, interoperability tests, explicit persistence policy |
| IME with chosen Sokol revision | Text input APIs may be insufficient              | Early platform spike and native bridge if needed                     |
| Unicode coordinates            | Bytes, scalars, graphemes, and pixels differ     | Typed boundaries and conversion tests                                |
| Full Acme `Edit` compatibility | Easy to implement an incomplete approximation    | Reference corpus and dedicated interpreter milestone                 |
| Async selection pipes          | Late output can destroy newer edits              | Snapshot capture and revision/range validation                       |
| Persistent undo                | History can mismatch changed disk content        | Hash/checkpoint validation and orphan handling                       |
| Live filesystem semantics      | Regular files cannot mimic every device behavior | Canonical IPC plus real mount adapters                               |
| Large-file rendering           | A rope alone does not solve huge-line work       | Bounded shaping and explicit large-file mode                         |
| Process output floods          | Unlimited queues destroy responsiveness          | Backpressure, batching, spill-to-disk                                |
| Windows save/restart semantics | Different executable/file replacement rules      | Native replace APIs and staged launcher                              |
| Agent scope drift              | Easy to accumulate superficial features          | One active milestone and strict acceptance gates                     |
