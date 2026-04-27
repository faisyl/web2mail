# Multi-Domain + Multi-Token Support Design

**Date:** 2026-04-27  
**Status:** Awaiting implementation

## Overview

Add support for multiple domains, each with its own HMAC verification key. The server is deployed at (or behind) each domain's hostname, so the incoming `Host` header identifies which domain — and therefore which key — applies to a given webhook request.

## Configuration

Existing single-domain env vars continue to work unchanged (backwards compatible):

| Variable | Purpose |
|---|---|
| `DOMAIN` | Legacy single domain |
| `WEBHOOK_KEY` | Legacy HMAC key for that domain |

New numbered pairs for additional domains (N = 1, 2, 3, …):

| Variable | Example | Purpose |
|---|---|---|
| `DOMAIN_N` | `DOMAIN_1=foo.com` | Domain hostname |
| `WEBHOOK_KEY_N` | `WEBHOOK_KEY_1=abc123` | HMAC key for domain N |

Loading rules:
- Scanning stops at the first gap (missing `DOMAIN_N` terminates the scan; `DOMAIN_{N+1}` is not checked)
- A domain configured with an empty key has signature verification disabled for that domain only — consistent with existing single-domain behaviour

## Data Structure

A `DomainConfig` slice is built once at startup:

```go
type DomainConfig struct {
    Domain string
    Key    string // empty = no sig verification
}
```

And a `map[string]string` (domain → key) is derived from it for O(1) handler lookup.

## Routing

The webhook endpoint path is unchanged: `POST /webhook/email`

Inside the handler:

1. Read `r.Host`, strip any port suffix (`:PORT`)
2. Look up the sanitised host in the domain→key map
3. If found: use that key for HMAC verification (or skip if key is empty)
4. If not found but a legacy `WEBHOOK_KEY` exists: use it as fallback (supports single-domain deploys with no numbered vars)
5. If not found and no legacy fallback: respond `403 Forbidden`

`makeWebhookHandler` signature changes from `(webhookKey string, backend Backend)` to `(domains map[string]string, legacyKey string, backend Backend)`.

## Landing Page

`handleHome` receives `[]DomainConfig` instead of reading `os.Getenv("DOMAIN")` directly.

Each configured domain renders one card showing its webhook endpoint:

```
https://{domain}/webhook/email
```

No domain slug appended to the path — the hostname already identifies the domain.

## Error Handling

| Scenario | Response |
|---|---|
| Host not in map, no legacy key | `403 Forbidden` |
| Host found, key non-empty, sig missing | `401 Unauthorized` (existing behaviour) |
| Host found, key non-empty, sig invalid | `401 Unauthorized` (existing behaviour) |
| Host found, key empty | Skip verification, proceed (existing behaviour) |

## What Does Not Change

- Go version stays at 1.21 (no path parameter syntax needed)
- Zero external dependencies
- `hmac_helpers.go` unchanged
- Both backend types (`SendmailBackend`, `SMTPBackend`) unchanged
- All other routes (`/health`, `/logo.png`, `/`) unchanged
