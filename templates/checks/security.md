<!-- Security criteria: authorization, secrets, injection, and unsafe deserialization. -->

## Criteria
- SEC-01: a handler that reads or mutates a resource by an ID from the request checks that the caller is authorized for that specific resource (ownership or tenant), not merely authenticated.
- SEC-02: every privileged action (admin-only route, role-gated mutation) checks the caller's role or permission before executing, not only that a valid session exists.
- SEC-03: no secret (API key, password, private key, connection string, signing key) appears as a literal in source or in a committed file; secrets load from the environment or a secret store.
- SEC-04: every user-supplied value placed into a SQL/NoSQL query, shell command or file path goes through a parameterized API or an allow-list, never string concatenation or interpolation.
- SEC-05: every request or datastore value written into an HTML/JS/XML response goes through the templating engine's auto-escaping or an explicit output-encoding call, never raw into markup.
- SEC-06: passwords and other long-term credentials are hashed with a memory-hard algorithm (bcrypt, scrypt, Argon2 or equivalent) before storage and are never logged, stored or transmitted in plaintext or with reversible encryption.
- SEC-07: an outbound network request whose host or URL derives from user input validates the destination against an allow-list before sending.
- SEC-08: no secret, credential or token that the diff introduces or touches is written to a log statement, exception message or crash report. It covers secrets, credentials and tokens only; PII in logs and errors belongs to pii.md.
- SEC-09: data from an untrusted source (request body, queue message, upload) is deserialized with a safe, schema-validated format, never a native object-graph deserializer that can execute code (`pickle`, Java native serialization, PHP `unserialize`).
