<!-- PII criteria: judged against the spec's pii_fields, covering logging, storage, retention, deletion and third-party sharing. -->

## Criteria
- PII-01: no `pii_fields` value is passed to a log, print or console statement.
- PII-02: no `pii_fields` value appears in an exception message, error response body or stack trace that the diff surfaces to a log, a client or a crash/telemetry service.
- PII-03: every new column, document field, cache entry or file that stores a `pii_fields` value writes it through field-, column- or storage-level encryption, not plaintext.
- PII-04: every backup, export, log archive or temp or cache copy of a `pii_fields` value that the diff creates carries the same encryption as the primary store.
- PII-05: every `pii_fields` value the diff stores has a retention period, TTL or scheduled purge.
- PII-06: every delete or erasure path the diff adds for a record holding a `pii_fields` value removes the value from every store the diff writes it to (primary table, cache, search index, queue or event payload), not only a soft-delete flag.
- PII-07: every `pii_fields` value the diff sends to a third-party processor or a downstream queue or topic is covered by a deletion or retention hook tied to the primary record's retention or deletion path.
