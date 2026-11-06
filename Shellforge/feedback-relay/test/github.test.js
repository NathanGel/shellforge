import { test } from "node:test";
import assert from "node:assert/strict";
import { GITHUB, signAppJwt, postIssue } from "../src/github.js";
import { makeTestKey, recordingFetch } from "./helpers.js";

const decode = (s) => Buffer.from(s, "base64url");
const NOW = 1_800_000_000_123;

async function env() {
  const { pem, publicKey } = await makeTestKey();
  return { env: { GITHUB_APP_ID: "123", GITHUB_INSTALLATION_ID: "456", GITHUB_APP_KEY: pem }, publicKey };
}
const ok = [
  { status: 201, json: { token: "t" } },
  { status: 201, json: { number: 42, html_url: "https://evil.example" } },
];
const run = async (responses, extra = {}) => {
  const { env: e } = await env();
  const fetch = recordingFetch(responses);
  const result = await postIssue({ fetch, env: e, nowMs: NOW, title: "T", body: "B", ...extra });
  return { result, fetch };
};

test("jwtIsRS256AndBackdated", async () => {
  const { env: e, publicKey } = await env();
  const jwt = await signAppJwt(e.GITHUB_APP_KEY, "123", NOW);
  assert.ok(!jwt.includes("=") && !jwt.includes("+") && !jwt.includes("/"));
  const [h, p, s] = jwt.split(".");
  assert.equal(JSON.parse(decode(h)).alg, "RS256");
  const payload = JSON.parse(decode(p));
  const iat = Math.floor(NOW / 1000) - 60;
  assert.equal(payload.iat, iat);
  assert.equal(payload.exp, iat + 540);
  assert.equal(payload.iss, "123");
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, decode(s), new TextEncoder().encode(`${h}.${p}`));
  assert.equal(valid, true);
});

test("postIssueMakesExactlyTwoCalls", async () => {
  const { result, fetch } = await run(ok);
  assert.deepEqual(result, { status: "posted", number: 42 });
  assert.equal(fetch.calls.length, 2);
  const [a, b] = fetch.calls;
  assert.equal(a.url, "https://api.github.com/app/installations/456/access_tokens");
  assert.equal(a.init.method, "POST");
  assert.equal(a.init.body, '{"repositories":["shellforge"],"permissions":{"issues":"write"}}');
  assert.equal(b.url, "https://api.github.com/repos/NathanGel/shellforge/issues");
  assert.equal(b.init.method, "POST");
  assert.equal(b.init.headers.Authorization, "Bearer t");
  assert.deepEqual(JSON.parse(b.init.body), { title: "T", body: "B", labels: ["feedback"] });
});

test("everyCallCarriesTheFiveHeaders", async () => {
  const { fetch } = await run(ok);
  for (const c of fetch.calls) {
    const h = c.init.headers;
    assert.match(h.Authorization, /^Bearer .+/);
    assert.equal(h.Accept, "application/vnd.github+json");
    assert.equal(h["X-GitHub-Api-Version"], GITHUB.apiVersion);
    assert.equal(h["User-Agent"], "shellforge-feedback-relay");
    assert.equal(h["Content-Type"], "application/json");
  }
});

test("labelDroppedStillPosts", async () => {
  const { result } = await run([ok[0], { status: 201, json: { number: 7, labels: [] } }]);
  assert.deepEqual(result, { status: "posted", number: 7 });
});

test("githubLimitIsLimited", async () => {
  const limits = [{ status: 429 }, { status: 403, headers: { "retry-after": "30" } }];
  for (const lim of limits) {
    const first = await run([lim]);
    assert.deepEqual(first.result, { status: "limited" });
    assert.equal(first.fetch.calls.length, 1);
    const second = await run([ok[0], lim]);
    assert.deepEqual(second.result, { status: "limited" });
    assert.equal(second.fetch.calls.length, 2);
  }
});

test("otherErrorsFail", async () => {
  for (const status of [403, 404, 410, 422, 500]) {
    assert.deepEqual((await run([{ status }])).result, { status: "failed" }, `token ${status}`);
    assert.deepEqual((await run([ok[0], { status }])).result, { status: "failed" }, `issue ${status}`);
  }
  assert.deepEqual((await run([new Error("boom")])).result, { status: "failed" });
  assert.deepEqual((await run([ok[0], new Error("boom")])).result, { status: "failed" });
});

test("a bad key or malformed success body fails", async () => {
  const { env: e } = await env();
  const bad = await postIssue({ fetch: recordingFetch([]), env: { ...e, GITHUB_APP_KEY: "nope" }, nowMs: NOW, title: "T", body: "B" });
  assert.deepEqual(bad, { status: "failed" });
  assert.deepEqual((await run([{ status: 201, json: {} }])).result, { status: "failed" });
  assert.deepEqual((await run([ok[0], { status: 201, json: {} }])).result, { status: "failed" });
});

test("redirectsAreFailedAndNeverFollowed", async () => {
  for (const index of [0, 1]) {
    const responses = index === 0
      ? [{ status: 301, headers: { location: "https://evil.example/" } }]
      : [{ status: 201, json: { token: "t" } }, { status: 301, headers: { location: "https://evil.example/" } }];
    const { result, fetch } = await run(responses);
    assert.deepEqual(result, { status: "failed" });
    assert.equal(fetch.calls.length, index + 1);
    for (const c of fetch.calls) assert.equal(c.init.redirect, "manual");
  }
});
