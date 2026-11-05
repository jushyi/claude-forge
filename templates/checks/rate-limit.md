<!-- Rate-limit criteria: request-rate limits, quota enforcement, and abuse-sensitive flows. -->

## Criteria
- RATE-01: every publicly reachable endpoint that does a costly operation (write, search, auth attempt, file upload, expensive computation) enforces a request-rate or concurrency limit keyed to the caller.
- RATE-02: every request body, list or search query, batch operation or file upload the diff introduces has an explicit maximum size, length or item count, enforced before the data is processed.
- RATE-03: a request rejected for exceeding a rate or quota limit returns HTTP 429 with a `Retry-After` value, not a generic error, a different status or a silent drop.
- RATE-04: on an authenticated route, the rate or quota key is the authenticated identity (user, API key or tenant), not the source IP alone.
- RATE-05: rate-limit and quota counters and thresholds are read and incremented in server-side state (in-process store, cache or gateway), never taken from a client-supplied header, cookie or request parameter.
- RATE-06: an endpoint for a sensitive business flow (login, password reset, OTP verification, coupon or voucher redemption, account creation) applies a stricter, flow-specific limit than the service's generic default.
