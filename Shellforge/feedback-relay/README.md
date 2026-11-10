# Shellforge feedback relay

A Cloudflare Worker that takes feedback from the Shellforge app and posts it as a GitHub issue on
`NathanGel/shellforge`, labelled `feedback`, from a GitHub App bot. The app holds no token; the
Worker holds the App's private key as a secret.

    POST /feedback   {"version":"0.8.0","macos":"26.1.0","good":"…","bad":"…","rating":4}

Answers: 201 `{"number":42}`; otherwise `{"error":"<code>"}` with 400 (`json`, `type`, `size`,
`fields`, `empty`, `version`, `secret`), 429 (`rate`, `daily`, `busy`), 502 (`github`), 503 (`off`,
when switched off) or 500 (`internal`). Any other method or path is 405. There is no CORS: only the
app calls it.

**Limits.** 3 posts per minute per sender (`CF-Connecting-IP`, or its /64 for IPv6), 10 per minute
overall, 50 per UTC day, and a kill switch. A body is at most 16 KiB and text 4,000 code points per field, and text
that looks like a secret is refused. The per-minute bindings are approximate; the daily cap is
approximate too, because KV is eventually consistent.

**What it keeps.** No feedback and no IP addresses; only the daily counter (`count:<YYYY-MM-DD>`,
two-day TTL). It never logs, and observability is off in `wrangler.toml`. GitHub's response text is
never passed back to the app.

## Setup (once)

1. Install Node 22 or later (`node -v`).
2. Create a free Cloudflare account and turn on 2FA.
3. Create the GitHub App:
   - permissions: Issues: Read and write, and Metadata: Read (GitHub adds it);
   - private (“Only on this account”), so nobody else can install it;
   - no webhook;
   - install it on `NathanGel/shellforge` only;
   - generate a private key. GitHub downloads a PKCS#1 key, and the Worker accepts only PKCS#8, so convert it:

         openssl pkcs8 -topk8 -nocrypt -in app.pem -out app-pkcs8.pem

   - note the App ID and the installation ID (the number at the end of the installation's URL).
4. Run `gh label create feedback -R NathanGel/shellforge`.
5. Run `npx wrangler@latest login`.
6. Run `npx wrangler kv namespace create FEEDBACK_KV` and put its id in `wrangler.toml`.
7. Put the App ID and installation ID in `wrangler.toml`.
8. Run `npx wrangler@latest deploy`. Wrangler offers to create a `workers.dev` subdomain if there isn't one, and prints the Worker's URL.
9. Run `npx wrangler secret put GITHUB_APP_KEY` and paste the contents of `app-pkcs8.pem`. Then delete both `.pem` files.
10. Set `RELAY_ENABLED` to `"true"` in `wrangler.toml`, deploy again, and test:

        curl -X POST <url>/feedback -H 'Content-Type: application/json' -d '{"version":"0.8.0","macos":"26.1.0","good":"Test"}'

    Check that the issue appears from the bot, labelled `feedback`. A 400 from GitHub here can mean
    the `X-GitHub-Api-Version` value (`src/github.js`) is wrong. If `wrangler deploy` refuses the `[[ratelimits]]` entries, delete them and deploy again: the Worker skips a missing limit, and the daily cap still applies.
11. Put `<worker url>/feedback` into `FeedbackRelay.endpoint` in the app (the bare Worker URL works too: the app adds `/feedback`).

## Operations

- **Switch it off.** Set `RELAY_ENABLED = "false"` in `wrangler.toml` and run `npx wrangler@latest deploy`. Every request then answers 503, and the app tells people feedback is switched off.
- **Suspend the App.** GitHub › Settings › Developer settings › GitHub Apps › the App › Advanced › Suspend. The Worker then gets 4xx from GitHub and answers 502.
- **Delete an issue.** `gh issue delete <number> -R NathanGel/shellforge`. It needs your admin rights; the bot cannot do it.
- **Warning.** Feedback is untrusted text. Any future workflow triggered by `issues: opened` must never put the issue's title or body into a `run:` step (use an environment variable, or don't read them at all).

## Tests

    npm install      # once, only needed for wrangler
    node --test      # no dependencies; Node 22 or later
