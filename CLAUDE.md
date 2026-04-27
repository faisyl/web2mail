# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**web2mail** is a webhook-to-email bridge server. It receives email data as JSON payloads from [ForwardEmail.net](https://forwardemail.net) webhooks and delivers them via either local Sendmail or remote SMTP. It also serves a landing page displaying its configuration.

## Commands

Uses [Task](https://taskfile.dev) as the task runner:

```sh
task build            # go build -v -o web2mail .
task test             # runs test.sh integration tests against a running server
task clean            # removes binary and dist/
task release-check    # verify .goreleaser.yaml
task release-snapshot # build snapshot release packages (deb, rpm, apk, archlinux)
```

No unit tests — testing is done via `test.sh`, a shell script that starts the server and fires curl requests.

## Architecture

The entire application logic lives in two files:

- **`main.go`** — HTTP server, webhook handler, email construction, landing page, backend routing
- **`hmac_helpers.go`** — HMAC-SHA256 signature verification

**Zero external Go dependencies** — only standard library.

### Backend Interface

Email delivery is pluggable via a `Backend` interface with two implementations:

- **`SendmailBackend`** — pipes RFC 5322 email to a local sendmail binary via stdin
- **`SMTPBackend`** — connects to a remote SMTP server with optional STARTTLS and auth

### Request Flow

```
POST /webhook/email
  → HMAC-SHA256 signature verification (constant-time)
  → JSON decode → WebhookPayload struct
  → Build RFC 5322 email:
      text only            → Content-Type: text/plain
      text + html          → multipart/alternative
      with attachments     → multipart/mixed (wrapping multipart/alternative)
  → Route to configured backend (Sendmail or SMTP)
```

Attachments arrive as `{type: "Buffer", data: [int...]}` and are base64-encoded with 76-char line wrapping per RFC 5322.

### Configuration (Environment Variables)

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `DOMAIN` | — | Legacy single domain (hostname the server is reachable at) |
| `PATH_URL` | `/` | Base path prefix for all routes |
| `WEBHOOK_KEY` | — | HMAC secret for `DOMAIN`; if unset, signature check is skipped |
| `DOMAIN_N` | — | Domain N hostname (N = 1, 2, 3…); scanning stops at first gap |
| `WEBHOOK_KEY_N` | — | HMAC secret for `DOMAIN_N`; empty disables sig check for that domain |
| `BACKEND_TYPE` | `sendmail` | `sendmail` or `smtp` |
| `SENDMAIL_PATH` | `/usr/sbin/sendmail` | Path to sendmail binary |
| `SMTP_HOST` | — | SMTP server hostname |
| `SMTP_PORT` | — | SMTP server port |
| `SMTP_USER` | — | SMTP auth username |
| `SMTP_PASS` | — | SMTP auth password |
| `SMTP_SKIP_VERIFY` | `false` | Skip TLS certificate verification |

### HTTP Routes

- `GET /` (or `/{PATH_URL}/`) — landing page (dynamically generated HTML, shows live config)
- `GET /health` — JSON health check
- `POST /webhook/email` — webhook receiver
- `GET /logo.png` — embedded asset (86400s cache TTL)

The logo PNG is embedded in the binary via `//go:embed assets/logo.png`.

## Release

GoReleaser (`.goreleaser.yaml`) builds for Linux amd64/arm64/armv7 and packages as deb, rpm, apk, and archlinux packages. Run `task release-snapshot` for a local test build without publishing.
