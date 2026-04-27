# Multi-Domain + Multi-Token Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support multiple ForwardEmail domains each with its own HMAC key, identified by the incoming `Host` header, while keeping single-domain deploys fully backwards compatible.

**Architecture:** `loadDomainConfigs()` reads `DOMAIN`/`WEBHOOK_KEY` (legacy) plus numbered `DOMAIN_N`/`WEBHOOK_KEY_N` pairs into a `[]DomainConfig` at startup. A `map[string]string` (domain→key) is derived from the slice and passed to `makeWebhookHandler`. Inside the handler, `resolveKey()` strips the port from `r.Host` and looks up the matching key; an unrecognised host returns 403 when any domains are configured. `handleHome` becomes a factory function that receives the config slice and renders one card per domain, each showing `https://{domain}/webhook/email`.

**Tech Stack:** Go 1.21 stdlib only — no new dependencies, no Go version bump.

---

## File Structure

**Modify: `main.go`**
- Add `DomainConfig` struct
- Add `loadDomainConfigs() ([]DomainConfig, string)` — reads env vars; returns slice + standalone legacy key (non-empty only when `WEBHOOK_KEY` is set but `DOMAIN` is not)
- Add `resolveKey(host string, domainMap map[string]string, legacyKey string) (string, bool)` — maps Host to HMAC key, returns allowed bool
- Update `makeWebhookHandler(domainMap map[string]string, legacyKey string, backend Backend)` — replaces single-key logic with `resolveKey`
- Update `main()` — loads configs, builds map, updates handler and handleHome registrations, updates startup logging
- Update `handleHome(configs []DomainConfig, pathURL string) http.HandlerFunc` — factory func rendering one card per domain
- Add `"net"` to imports

**Modify: `test.sh`**
- Add multi-domain test section (second server on port 8082)

---

### Task 1: Add multi-domain tests to test.sh (TDD red phase)

**Files:**
- Modify: `test.sh`

- [ ] **Step 1: Insert multi-domain test block into test.sh**

Add the following block **before** the `=== Cleaning up ===` comment in `test.sh` (before `kill $SERVER_PID`):

```bash
# === Multi-domain tests ===
echo ""
echo "=== Testing multi-domain routing ==="

PORT=8082 \
DOMAIN=legacy.test \
WEBHOOK_KEY=legacy-secret \
DOMAIN_1=alpha.test \
WEBHOOK_KEY_1=alpha-secret \
DOMAIN_2=beta.test \
WEBHOOK_KEY_2=beta-secret \
SENDMAIL_PATH="$(pwd)/mock-sendmail.sh" \
./$BINARY &

MULTI_PID=$!
sleep 1

# Test 1: alpha.test with correct key -> 200
echo ""
echo "--- alpha.test correct key (expect 200) ---"
SIG=$(compute_signature "test_payload.json" "alpha-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: alpha.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 2: beta.test with correct key -> 200
echo ""
echo "--- beta.test correct key (expect 200) ---"
SIG=$(compute_signature "test_payload.json" "beta-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: beta.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 3: alpha.test with wrong key -> 401
echo ""
echo "--- alpha.test wrong key (expect 401) ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: alpha.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: wrong-sig" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 4: unknown host -> 403
echo ""
echo "--- unknown host (expect 403) ---"
SIG=$(compute_signature "test_payload.json" "alpha-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: unknown.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 5: legacy domain still works -> 200
echo ""
echo "--- legacy.test correct key (expect 200) ---"
SIG=$(compute_signature "test_payload.json" "legacy-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: legacy.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

kill $MULTI_PID
wait $MULTI_PID 2>/dev/null || true
```

- [ ] **Step 2: Run tests to observe red state**

```bash
go build -o web2mail . && bash test.sh
```

Expected (before implementation): Test 4 (unknown host) returns `200` instead of `403` — confirming the feature is missing. Tests 1/2/5 may also behave incorrectly (wrong key used for verification).

---

### Task 2: Add DomainConfig, loadDomainConfigs, and resolveKey to main.go

**Files:**
- Modify: `main.go`

- [ ] **Step 1: Add `"net"` to the import block**

Replace the existing import block with:

```go
import (
	"bytes"
	"crypto/tls"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/smtp"
	"net/textproto"
	"os"
	"os/exec"
	"strings"
	"time"
)
```

- [ ] **Step 2: Add DomainConfig struct after the AttachmentContent struct (around line 137)**

```go
// DomainConfig holds a domain hostname and its HMAC key.
// Key may be empty, which disables signature verification for that domain.
type DomainConfig struct {
	Domain string
	Key    string
}
```

- [ ] **Step 3: Add loadDomainConfigs immediately after DomainConfig**

```go
// loadDomainConfigs reads DOMAIN/WEBHOOK_KEY (legacy) and DOMAIN_N/WEBHOOK_KEY_N
// (numbered pairs, stops at first gap) from environment variables.
// Returns the slice of domain configs and a standalone legacyKey — non-empty only
// when WEBHOOK_KEY is set but DOMAIN is not (key-only deploy with no domain name).
func loadDomainConfigs() ([]DomainConfig, string) {
	var configs []DomainConfig

	legacyDomain := os.Getenv("DOMAIN")
	legacyKey := os.Getenv("WEBHOOK_KEY")

	if legacyDomain != "" {
		configs = append(configs, DomainConfig{Domain: legacyDomain, Key: legacyKey})
		legacyKey = "" // domain is in the map; no separate fallback needed
	}

	for i := 1; ; i++ {
		domain := os.Getenv(fmt.Sprintf("DOMAIN_%d", i))
		if domain == "" {
			break
		}
		configs = append(configs, DomainConfig{
			Domain: domain,
			Key:    os.Getenv(fmt.Sprintf("WEBHOOK_KEY_%d", i)),
		})
	}

	return configs, legacyKey
}
```

- [ ] **Step 4: Add resolveKey immediately after loadDomainConfigs**

```go
// resolveKey maps an incoming Host header value to the HMAC key for that domain.
// Returns (key, true) when the host is allowed; ("", false) when it must be rejected.
// Rejection only occurs when at least one domain is configured but the host matches none.
// When no domains are configured at all, returns (legacyKey, true) — legacyKey may be "".
func resolveKey(host string, domainMap map[string]string, legacyKey string) (string, bool) {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if key, ok := domainMap[host]; ok {
		return key, true
	}
	if len(domainMap) > 0 {
		return "", false
	}
	return legacyKey, true
}
```

- [ ] **Step 5: Build to confirm no compile errors**

```bash
go build -o web2mail .
```

Expected: exits 0, binary produced.

- [ ] **Step 6: Commit**

```bash
git add main.go
git commit -m "feat: add DomainConfig, loadDomainConfigs, resolveKey"
```

---

### Task 3: Update makeWebhookHandler to use resolveKey

**Files:**
- Modify: `main.go`

- [ ] **Step 1: Update the function signature**

Change:
```go
func makeWebhookHandler(webhookKey string, backend Backend) http.HandlerFunc {
```
To:
```go
func makeWebhookHandler(domainMap map[string]string, legacyKey string, backend Backend) http.HandlerFunc {
```

- [ ] **Step 2: Replace the signature verification block inside the returned HandlerFunc**

Find this block (after the body is read, before JSON parsing):
```go
		// Verify webhook signature if key is configured
		if webhookKey != "" {
			providedSignature := r.Header.Get("X-Webhook-Signature")
			if providedSignature == "" {
				log.Printf("Webhook authentication failed: missing signature header")
				http.Error(w, "Unauthorized: missing signature", http.StatusUnauthorized)
				return
			}

			// Compute HMAC signature of the request body
			expectedSignatureBytes := computeHMAC(body, webhookKey)

			// Compare signatures using constant-time comparison
			if !verifySignature(providedSignature, expectedSignatureBytes) {
				log.Printf("Webhook authentication failed: invalid signature")
				http.Error(w, "Unauthorized: invalid signature", http.StatusUnauthorized)
				return
			}
		}
```

Replace with:
```go
		// Resolve which HMAC key applies to this request's Host
		webhookKey, allowed := resolveKey(r.Host, domainMap, legacyKey)
		if !allowed {
			log.Printf("Webhook rejected: unknown host %s", r.Host)
			http.Error(w, "Forbidden: unknown host", http.StatusForbidden)
			return
		}

		// Verify webhook signature if a key is configured for this domain
		if webhookKey != "" {
			providedSignature := r.Header.Get("X-Webhook-Signature")
			if providedSignature == "" {
				log.Printf("Webhook authentication failed: missing signature header")
				http.Error(w, "Unauthorized: missing signature", http.StatusUnauthorized)
				return
			}

			expectedSignatureBytes := computeHMAC(body, webhookKey)

			if !verifySignature(providedSignature, expectedSignatureBytes) {
				log.Printf("Webhook authentication failed: invalid signature")
				http.Error(w, "Unauthorized: invalid signature", http.StatusUnauthorized)
				return
			}
		}
```

- [ ] **Step 3: Build to confirm no compile errors**

```bash
go build -o web2mail .
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add main.go
git commit -m "feat: update makeWebhookHandler for Host-based key dispatch"
```

---

### Task 4: Update main() wiring

**Files:**
- Modify: `main.go`

- [ ] **Step 1: Replace the domain/webhookKey variable reads near the top of main()**

Find:
```go
	domain := os.Getenv("DOMAIN")
	pathURL := os.Getenv("PATH_URL")
	webhookKey := os.Getenv("WEBHOOK_KEY")
```

Replace with:
```go
	pathURL := os.Getenv("PATH_URL")
	domainConfigs, legacyKey := loadDomainConfigs()
	domainMap := make(map[string]string, len(domainConfigs))
	for _, dc := range domainConfigs {
		domainMap[dc.Domain] = dc.Key
	}
```

- [ ] **Step 2: Update the startup logging block**

Find:
```go
	log.Printf("Starting ForwardEmail Webhook Handler on port %s", port)
	log.Printf("Domain: %s, Path: %s", domain, pathURL)
	log.Printf("Backend type: %s", backendType)
	if webhookKey != "" {
		log.Printf("Webhook key authentication enabled")
	} else {
		log.Printf("Webhook key authentication disabled (optional)")
	}
```

Replace with:
```go
	log.Printf("Starting ForwardEmail Webhook Handler on port %s", port)
	log.Printf("Path: %s, Backend: %s", pathURL, backendType)
	for _, dc := range domainConfigs {
		log.Printf("Domain: %s (key configured: %v)", dc.Domain, dc.Key != "")
	}
	if legacyKey != "" {
		log.Printf("Legacy key-only mode (WEBHOOK_KEY set, no DOMAIN)")
	}
```

- [ ] **Step 3: Update the makeWebhookHandler call in the route registration block**

Find:
```go
	http.HandleFunc(pathURL+"/webhook/email", makeWebhookHandler(webhookKey, backend))
```

Replace with:
```go
	http.HandleFunc(pathURL+"/webhook/email", makeWebhookHandler(domainMap, legacyKey, backend))
```

- [ ] **Step 4: Build and run tests to confirm multi-domain routing now works**

```bash
go build -o web2mail . && bash test.sh
```

Expected multi-domain results:
- `alpha.test correct key` → `Status: 200`
- `beta.test correct key` → `Status: 200`
- `alpha.test wrong key` → `Status: 401`
- `unknown host` → `Status: 403`
- `legacy.test correct key` → `Status: 200`

- [ ] **Step 5: Commit**

```bash
git add main.go
git commit -m "feat: wire multi-domain config into main() and handler registration"
```

---

### Task 5: Update handleHome to factory function with domain list

**Files:**
- Modify: `main.go`

- [ ] **Step 1: Replace the entire handleHome function with a factory**

Find and remove:
```go
// handleHome serves the home page
func handleHome(w http.ResponseWriter, r *http.Request) {
	domain := os.Getenv("DOMAIN")
	pathURL := os.Getenv("PATH_URL")
    // ... (entire function body through closing brace)
}
```

Replace with:

```go
// handleHome serves the landing page showing all configured domains.
func handleHome(configs []DomainConfig, pathURL string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var domainsHTML strings.Builder
		for _, dc := range configs {
			domainsHTML.WriteString(fmt.Sprintf(`
            <div class="info-card">
                <span class="label">Domain</span>
                <span class="value">%s</span>
                <div class="endpoint-box" style="margin-top:12px;font-size:13px;">
                    https://%s%s/webhook/email
                </div>
            </div>`, dc.Domain, dc.Domain, pathURL))
		}
		if len(configs) == 0 {
			domainsHTML.WriteString(`
            <div class="info-card">
                <span class="label">Domain</span>
                <span class="value">Not configured</span>
            </div>`)
		}

		html := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>forwardingress</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: #4F46E5;
            --primary-light: #818CF8;
            --bg: #F9FAFB;
            --card-bg: rgba(255, 255, 255, 0.8);
            --text-main: #111827;
            --text-secondary: #4B5563;
        }
        body {
            font-family: 'Inter', -apple-system, sans-serif;
            background: linear-gradient(135deg, #667eea 0%%, #764ba2 100%%);
            background-attachment: fixed;
            min-height: 100vh;
            margin: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--text-main);
        }
        .container {
            max-width: 650px;
            width: 90%%;
            margin: 40px auto;
            background: var(--card-bg);
            backdrop-filter: blur(12px);
            border-radius: 24px;
            padding: 48px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25);
            border: 1px solid rgba(255, 255, 255, 0.3);
            text-align: center;
        }
        header {
            margin-bottom: 40px;
        }
        .logo {
            width: 120px;
            height: auto;
            margin-bottom: 24px;
            filter: drop-shadow(0 4px 6px rgba(0, 0, 0, 0.1));
        }
        h1 {
            font-weight: 800;
            font-size: 32px;
            margin: 0;
            background: linear-gradient(to right, #4F46E5, #7C3AED);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            letter-spacing: -0.025em;
        }
        .description {
            color: var(--text-secondary);
            font-size: 16px;
            line-height: 1.6;
            margin-top: 12px;
        }
        .grid {
            display: grid;
            gap: 20px;
            margin: 32px 0;
        }
        .info-card {
            background: rgba(255, 255, 255, 0.5);
            padding: 20px;
            border-radius: 16px;
            border: 1px solid rgba(255, 255, 255, 0.5);
            transition: transform 0.2s;
        }
        .info-card:hover {
            transform: translateY(-2px);
        }
        .label {
            display: block;
            text-transform: uppercase;
            font-size: 11px;
            font-weight: 700;
            color: var(--primary);
            letter-spacing: 0.05em;
            margin-bottom: 4px;
        }
        .value {
            font-weight: 600;
            font-size: 15px;
            word-break: break-all;
        }
        .endpoint-box {
            background: #111827;
            color: #10B981;
            padding: 20px;
            border-radius: 16px;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            position: relative;
            overflow: hidden;
            margin-top: 24px;
        }
        .endpoint-box::before {
            content: "POST";
            position: absolute;
            top: 0;
            right: 0;
            background: #10B981;
            color: #111827;
            padding: 4px 12px;
            font-family: 'Inter', sans-serif;
            font-weight: 800;
            font-size: 10px;
            border-bottom-left-radius: 8px;
        }
        .status-badge {
            display: inline-flex;
            align-items: center;
            background: #D1FAE5;
            color: #065F46;
            padding: 6px 16px;
            border-radius: 9999px;
            font-size: 13px;
            font-weight: 600;
            margin-top: 20px;
        }
        .status-badge::before {
            content: "";
            width: 8px;
            height: 8px;
            background: #10B981;
            border-radius: 50%%;
            margin-right: 8px;
            box-shadow: 0 0 8px #10B981;
        }
        footer {
            margin-top: 40px;
            text-align: center;
            font-size: 13px;
            color: var(--text-secondary);
        }
        ul {
            padding-left: 20px;
            margin: 16px 0;
            color: var(--text-secondary);
            font-size: 14px;
        }
        li {
            margin-bottom: 8px;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <img src="logo.png" alt="forwardingress Logo" class="logo">
            <h1>forwardingress</h1>
            <p class="description">A professional bridge that relays incoming webhooks to your email inbox via SMTP or Sendmail.</p>
        </header>

        <div class="grid" style="text-align: left;">
            %s
            <div class="info-card">
                <span class="label">Base Path Prefix</span>
                <span class="value">%s</span>
            </div>
        </div>

        <div class="label" style="margin-top: 32px;">Available Routes</div>
        <ul>
            <li><code>/health</code> - Service health and diagnostic information</li>
            <li><code>/webhook/email</code> - Core receiver for incoming ForwardEmail POST requests</li>
        </ul>

        <div style="text-align: center;">
            <div class="status-badge">System Operational</div>
        </div>

        <footer>
            Server Time: %s
        </footer>
    </div>
</body>
</html>`, domainsHTML.String(), pathURL, time.Now().Format("Jan 02, 2006 15:04:05 MST"))

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, html)
	}
}
```

- [ ] **Step 2: Update the handleHome route registration in main()**

Find:
```go
	http.HandleFunc(pathURL+"/", handleHome)
```

Replace with:
```go
	http.HandleFunc(pathURL+"/", handleHome(domainConfigs, pathURL))
```

- [ ] **Step 3: Build to confirm no compile errors**

```bash
go build -o web2mail .
```

Expected: exits 0.

- [ ] **Step 4: Run full test suite**

```bash
bash test.sh
```

Expected: all existing tests pass unchanged. Multi-domain tests show:
- `alpha.test correct key` → `Status: 200`
- `beta.test correct key` → `Status: 200`
- `alpha.test wrong key` → `Status: 401`
- `unknown host` → `Status: 403`
- `legacy.test correct key` → `Status: 200`

- [ ] **Step 5: Commit**

```bash
git add main.go
git commit -m "feat: update handleHome to render all configured domains"
```

---

### Task 6: Final verification

- [ ] **Step 1: Clean build and full test run**

```bash
go build -o web2mail . && bash test.sh
```

Expected: binary builds cleanly, all tests produce expected status codes.

- [ ] **Step 2: Update CLAUDE.md to document new env vars**

In `CLAUDE.md`, add the new variables to the Configuration table (after the existing `WEBHOOK_KEY` row):

```markdown
| `DOMAIN_N` | — | Domain hostname for domain N (N = 1, 2, 3…) |
| `WEBHOOK_KEY_N` | — | HMAC secret for domain N; empty disables sig check for that domain |
```

- [ ] **Step 3: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: document DOMAIN_N and WEBHOOK_KEY_N env vars"
```
