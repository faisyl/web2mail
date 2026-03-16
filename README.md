# web2mail

A webhook to SMTP/Sendmail bridge specifically for forwardemail.net to deliver emails via an HTTP reverse proxy like nginx or cloudflared.

## Overview

**web2mail** provides a universal webhook endpoint for services like ForwardEmail.net. It receives email data as a JSON payload, reconstructs it into a proper RFC 5322 compliant email (with full MIME support for HTML and attachments), and relays it via your choice of backend: local Postfix (sendmail) or remote SMTP.

## Features

- ✅ **Slick Landing Page** with real-time status and configuration details
- ✅ **Multiple Backends**: Support for local `sendmail` or remote `SMTP`
- ✅ **Full MIME support**: Handles plain text, HTML, and complex attachments
- ✅ **HMAC Security**: Signature verification for secure webhook processing
- ✅ **Self-Contained**: Embedded assets for a zero-dependency frontend

## Installation

### From Binary

Download the latest binary for your platform from the [releases](https://github.com/faisyl/web2mail/releases) page.

### From Source

```bash
go build -o web2mail .
```

## Usage

Set the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | Port to listen on | `8080` |
| `DOMAIN` | Primary domain name | |
| `PATH_URL` | Base path prefix | `/` |
| `WEBHOOK_KEY` | HMAC signature key (optional) | |
| `BACKEND_TYPE` | `sendmail` or `smtp` | `sendmail` |
| `SENDMAIL_PATH` | Path to sendmail binary | `/usr/sbin/sendmail` |
| `SMTP_HOST` | SMTP server host | |
| `SMTP_PORT` | SMTP server port | |
| `SMTP_USER` | SMTP username | |
| `SMTP_PASS` | SMTP password | |
| `SMTP_SKIP_VERIFY` | Skip TLS verification | `false` |

Run the application:

```bash
./web2mail
```

## License

MIT License - see LICENSE file
