# tiktok-signature

## Purpose
HTTP microservice that generates valid TikTok API signatures (X-Bogus and X-Gnarly) by running a persistent headless Chromium session with TikTok's own SDK injected locally. Exposes a `/signature` endpoint that returns a signed URL and browser fingerprint metadata for external callers to use, and a `/fetch` endpoint that performs the full request inside the browser as a fallback. If this service goes down, any downstream crawler or client that needs to make authenticated TikTok web API requests will receive signature validation failures.

## Where it sits in Socialgist
Acquisition/crawl support layer. This service has no upstream dependencies within Socialgist — it connects directly to TikTok externally. Downstream consumers are TikTok crawlers (e.g. crawler-comment, crawler-video in the `tiktok` namespace) that call `/signature` to obtain a signed URL before making their own API requests.

## Key concepts and domain vocabulary
- **X-Bogus** — TikTok's primary request signature, encoded in the query string. Computed by TikTok's own SDK (`webmssdk`) against the full query string and User-Agent. Invalid if either changes after signing.
- **X-Gnarly** — Secondary signature, computed by `xgnarly.mjs` using a custom ChaCha20 variant. Travels alongside X-Bogus.
- **msToken** — Session token extracted from browser cookies. Included in the signed query string.
- **`/signature` vs `/fetch`** — `/signature` returns a signed URL for the caller to request externally (recommended, ~80ms). `/fetch` makes the request from inside the browser (slower, but bypasses bot detection entirely). Use `/fetch` only as a fallback.
- **Browser fingerprint** — The signed URL is bound to the User-Agent, platform, screen dimensions, and browser language used at signing time. External requests must reproduce these exactly or TikTok rejects the signature.
- **Session refresh** — The browser session auto-restarts after 500 signatures or 30 minutes, whichever comes first. On a proactive refresh, msTokens are exported to the token pool before teardown.
- **msToken pass-through** — Callers may supply their own `msToken` in the `/signature` request body. The signer uses it instead of the browser session token. Falls back to the browser cookie token if none is provided. This allows crawlers to draw from a shared token pool rather than relying solely on the signer's session.
- **`/health` vs `/ready`** — `/health` is the liveness probe: returns 503 only when the browser has failed to restart repeatedly (`consecutiveInitFailures >= 2`) or init has been stuck for over 2 minutes. `/ready` is the readiness probe: returns 503 any time `isInitializing` is true or `isReady` is false, signalling k8s to pull the pod from rotation immediately.

## Architecture
Requests flow through a sequential queue (one browser page, no concurrent access) into one of two signing paths:

1. **Fast path** (`_signDirectly`) — Calls `window.__sdkN.u[995].v()` inside the browser page to generate X-Bogus, then `encodeXGnarly()` for X-Gnarly. No page navigation. ~80ms.
2. **Intercept path** (`_signViaPageIntercept`) — Navigates to a TikTok page and captures a signed request emitted by the page bundle. Used when `navigateTo` is passed in the request body.

**Availability design (prod):** 2 replicas run in parallel. During a browser session refresh (~30s), the pod's `/ready` endpoint returns 503 and k8s pulls it from rotation — the other pod handles all traffic. This makes session refreshes nearly invisible to callers. The readiness probe uses `failureThreshold: 1` intentionally: a single pod can sustain full load, so the cost of a false positive (brief single-pod operation) is lower than the cost of routing requests to a pod mid-restart.

Key files:
- `server.mjs` — HTTP server, browser lifecycle, queue, both signing paths, all endpoints
- `xgnarly.mjs` — ChaCha20-based X-Gnarly encoder (reverse-engineered from TikTok SDK)
- `javascript/webmssdk_5.1.3.js` — TikTok's SDK, injected into the browser before page load
- `deploy/dev/deployment.yml` / `deploy/prod/deployment.yml` — K8s manifests (Service, Deployment, Ingress)
- `.drone.yml` — CI/CD pipeline for Harbor publish and k8s deploy

## Running it locally
```bash
npm install
cp .env.example .env   # edit as needed
npm start
```

The server initializes a browser session on startup and navigates to a TikTok page before accepting requests. Allow ~30 seconds before the first signature request.

Environment variables (names only):
- `PORT` — listening port (default: 8080)
- `PROXY_ENABLED` — set to `true` to route browser traffic through a proxy
- `PROXY_HOST` — proxy host:port (no scheme)
- `PROXY_USER` — proxy username
- `PROXY_PASS` — proxy password
- `PUPPETEER_EXECUTABLE_PATH` — override Chrome binary path (set automatically in Docker)
- `MAX_GENERATIONS_BEFORE_REFRESH` — browser restart threshold by signature count (default: 500)
- `MAX_SESSION_AGE_MS` — browser restart threshold by elapsed time in ms (default: 1800000)
- `ELASTIC_URL` — Elasticsearch base URL for stats reporting; stats are disabled if unset
- `ELASTIC_INDEX` — base index name; a date suffix is appended daily (e.g. `tiktok-signature-metrics-20261013`) (default: tiktok-signature-metrics)
- `STATS_INTERVAL_MS` — how often to flush stats to Elasticsearch in ms (default: 60000)

To test a signed URL externally:
```bash
curl -s --compressed \
  -H "User-Agent: <user_agent from response>" \
  -H "Referer: https://www.tiktok.com/" \
  -H "Accept: application/json, text/plain, */*" \
  -H "Accept-Language: en-US,en;q=0.9" \
  "<signed_url from response>"
```
Cookies are not required. The User-Agent must exactly match `navigator.user_agent` from the `/signature` response.

## Conventions and constraints
- ESM throughout (`type: "module"`), Node 20+ required
- Prettier enforced — run `npx prettier --check .` before pushing
- All endpoints are unauthenticated by design; do not expose this service publicly
- The browser runs a single persistent page — never add concurrent page access
- `window.__sdkN.u[995].v()` is the SDK signing function; index 995 is SDK-version-specific and may need updating if the SDK is upgraded
- `runAsUser: 1000` is required in the k8s securityContext — UID 100 has no home directory in node:20-slim and Chrome will crash at launch
- Do not set `--no-zygote` or `--single-process` Chrome flags; they cause instability without benefit in this setup
- The liveness probe (`/health`) only returns 503 on persistent init failure — not during a normal browser restart. This prevents k8s from killing a pod that is mid-refresh and would recover on its own.
- The readiness probe (`/ready`) returns 503 any time the browser is not ready, including during planned session refreshes. `failureThreshold: 1` is intentional — see Architecture above.
- msToken pool export (`exportMsTokensToPool`) runs only on proactive session refresh, not on error-triggered restarts. On error, the page state is unknown and `page.evaluate()` may fail.

## Data handling
This repo does not handle customer data, PII, or licensed source content.
No special retention or compliance constraints apply.

## Testing and CI
CI runs on every push via Drone:
- `npm test` — Jest suite (validates file structure and SDK presence)
- Prettier format check on `.mjs`, `.js`, `.md`, `.yml`
- `npm audit --audit-level=critical --omit=dev`

No behavioral or integration tests exist for the signing logic. Manual verification via `/health` and a test `/signature` + curl is required after any change to `server.mjs` or `xgnarly.mjs`.

Dev deploys on push to `dev` branch → `tiktok` namespace → `tiktok-sig.k8s-dev.sgdctroy.net`
Prod deploys on push to `master` branch → `sg-tiktok-prod` namespace → `tiktok-sig.k8s-prod.sgdctroy.net`

## Ownership
TikTok data acquisition team, Socialgist. For escalation contact the primary maintainer via the standard on-call path.
