     Before the round only, run the `AskUserQuestion` Rules bullet's
     notify and push steps with the questions' headers: load
     `PushNotification` when not yet loaded, run
     `forge notify "<session title>" "<headers>"` and send
     `PushNotification` under 200 characters, a failing notify or push
     ignored. Then ask: each `unmet` and `operator` line is one question,
     its `header` the line's ID (`step <k>` for a step covering no
     requirement) and its question the line itself, at most four questions
     per `AskUserQuestion` call and further calls for the rest; never one
     question per walkthrough step, which the numbered text above covers
     once.
   - Each `unmet` line's question has exactly the options `Accept` and
     `Restart phase <N>`. `Accept` sets, for each requirement the line
     names, `done` to `true` and `accepted` to the operator's words
     (`Accept` when nothing more was typed) in `F/requirements.json` with
     `jq`, and a phase `unmet` entry stays as recorded. `Restart phase <N>`
     records the gap `{"phase": "N", "gap": "<the line's reason>"}`, for a
     phase entry `{"phase": "N", "gap": "unmet <task>: <reason>"}`. Read a
     typed answer's intent: one accepting the line is `Accept` with its
     text as `accepted`; one asking for a change is `Restart phase <N>`
     with its text as the phase's decision: append `Decision: <text>` to
     `spec` of `<P>/spec.json` and of that phase's
     entry in `F/split.json` with `jq`, so step 7's commit carries it and
     the retried phase plans with it once step 9's `forge next` starts it.
   - Each `operator` line's question has exactly the options `Passed` and
     `Gap`, the gap typed in Other. `Passed` records the line `[operator]`
     in `manual_test`. `Gap`, or an answer typed in Other reporting a
     failure, records a gap tagged with the phase of `F/split.json` whose
     `requirements` hold the ID, else as step 7 tags an unclear gap, its
     text the operator's words with the evidence you can reach (logs,
     database rows, HTTP responses, screenshots saved as Browser pass step
     3 does), kept under `E/s<k>/`;
     an answer saying the step worked while the evidence contradicts it is
     a gap naming both. An answer meaning skip records the line
     `[skipped]` in `manual_test`, not a gap. A gap of the round goes to no
     fixer: `forge next` retries its phase.
   - An answer on any question meaning `Spec is wrong` ends the round with
     `result` `gaps`; step 9's `Spec is wrong` path runs after step 7
     records.
   - After the round `operator_ran` is true when an `operator` line was
     asked, and `result` is `pass` only when every `unmet` line took
     `Accept`, every `operator` line took `Passed` or skip, no step left a
     gap and no answer meant `Spec is wrong`; nothing else records `pass`,
     not your own judgment.
