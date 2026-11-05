# Project

## What
- Automated development framework for Claude Code, unofficial and not affiliated with Anthropic.
- Loop: gather → discuss → plan → execute → verify (includes a manual test with the operator) → ship.

## North star
- A developer with Claude Code installs forge without losing their own setup and ships features through its loop.

## Priorities
- Least work possible: fewest plans, least ceremony, least code.
- Claude token budget first.
- Speed.
- Deterministic barebones orchestrator; templates rendered by script, not written freehand.
- Parallel by default, within limits derived from the machine.

## Out of scope
- RAG and memory.
- Nightly pipelines.
- Gates that enforce process instead of product correctness.
