   A deferred check is
   owed when it cannot be observed before ship: its pass needs the merge
   to main, a deploy, a port or golive, a release, or production traffic
   or time after release. Its own step, or its folded part of a
   requirement step, is tagged `[owed]`, and verify never runs, walks or
   fixes an owed check and never makes it a gap; an `[owed]` step is
   neither agent-owned nor operator-owned. A requirement step with an owed
   check folded into it has its other parts judged as today, and only
   they decide its pass.
