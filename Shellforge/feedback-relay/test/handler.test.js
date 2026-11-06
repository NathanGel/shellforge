import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../src/handler.js";
import { makeTestKey, recordingFetch } from "./helpers.js";

const NOW = Date.UTC(2026, 10, 6, 12);
const GOOD = { version: "0.8.0", macos: "26.1.0", good: "Nice" };
const ok = [
  { status: 201, json: { token: "t" } },
  { status: 201, json: { number: 42 } },
];

function fakeKV({ value, throwOnPut = false } = {}) {
  const kv = {
    puts: [],
    get: async () => value ?? null,
    put: async (k, v, o) => {
      if (throwOnPut) throw new Error("kv down");
      kv.puts.push([k, v, o]);
    },
  };
  return kv;
}
const limiter = (success = true) => {
  const l = { keys: [], limit: async ({ key }) => (l.keys.push(key), { success }) };
  return l;
};

async function setup(over = {}) {
  const { pem } = await makeTestKey();
  const env = {
    RELAY_ENABLED: "true",
    GITHUB_APP_ID: "1",
    GITHUB_INSTALLATION_ID: "2",
    GITHUB_APP_KEY: pem,
    FEEDBACK_KV: fakeKV(),
    PER_SENDER: limiter(),
    GLOBAL: limiter(),
    ...over,
  };
  return env;
}
const post = (body, headers = {}, path = "/feedback") =>
  new Request(`https://relay.example${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
const run = async (request, env, responses = ok) => {
  const fetch = recordingFetch(responses);
  const res = await handle(request, env, { fetch, now: () => NOW });
  return { res, fetch, json: await res.json() };
};
const noSideEffects = (env, fetch) => {
  assert.equal(fetch.calls.length, 0);
  assert.equal(env.PER_SENDER.keys.length, 0);
  assert.equal(env.GLOBAL.keys.length, 0);
  assert.equal(env.FEEDBACK_KV.puts.length, 0);
};

test("onlyPostFeedback", async () => {
  const env = await setup();
  for (const req of [
    new Request("https://r.example/feedback"),
    new Request("https://r.example/feedback", { method: "OPTIONS" }),
    post(GOOD, {}, "/other"),
  ]) {
    const { res } = await run(req, env);
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "POST");
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.ok(![...res.headers.keys()].some((k) => k.startsWith("access-control-")));
  }
});

test("killSwitch", async () => {
  for (const v of ["false", "TRUE", undefined]) {
    const env = await setup({ RELAY_ENABLED: v });
    const { res, fetch } = await run(post(GOOD), env);
    assert.equal(res.status, 503);
    noSideEffects(env, fetch);
  }
});

test("kvMissingFailsClosed", async () => {
  const env = await setup({ FEEDBACK_KV: undefined });
  const { res } = await run(post(GOOD), env);
  assert.equal(res.status, 503);
});

test("invalidCostsNothing", async () => {
  let env = await setup();
  let r = await run(post(GOOD, { "Content-Type": "text/plain" }), env);
  assert.equal(r.res.status, 400);
  assert.deepEqual(r.json, { error: "type" });
  noSideEffects(env, r.fetch);

  env = await setup();
  r = await run(post({ ...GOOD, good: "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789" }), env);
  assert.equal(r.res.status, 400);
  assert.deepEqual(r.json, { error: "secret" });
  noSideEffects(env, r.fetch);
});

test("noBodyAndBadJSONAre400Json", async () => {
  const env = await setup();
  const empty = new Request("https://r.example/feedback", { method: "POST", headers: { "Content-Type": "application/json" } });
  assert.deepEqual((await run(empty, env)).json, { error: "json" });
  assert.deepEqual((await run(post("{nope"), env)).json, { error: "json" });
});

test("streamedOversizeBody", async () => {
  const env = await setup();
  const chunk = new Uint8Array(1000).fill(97);
  let n = 0;
  const stream = new ReadableStream({
    pull(c) {
      if (n++ < 20) c.enqueue(chunk);
      else c.close();
    },
  });
  const req = new Request("https://r.example/feedback", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: stream,
    duplex: "half",
  });
  const { res, json, fetch } = await run(req, env);
  assert.equal(res.status, 400);
  assert.deepEqual(json, { error: "size" });
  noSideEffects(env, fetch);
});

test("perSenderKeyIgnoresForwardedFor", async () => {
  const env = await setup();
  await run(post(GOOD, { "CF-Connecting-IP": "203.0.113.9", "X-Forwarded-For": "1.2.3.4" }), env);
  assert.deepEqual(env.PER_SENDER.keys, ["203.0.113.9"]);
  assert.deepEqual(env.GLOBAL.keys, ["global"]);
});

test("minuteLimits", async () => {
  for (const which of ["PER_SENDER", "GLOBAL"]) {
    const env = await setup({ [which]: limiter(false) });
    const { res, json, fetch } = await run(post(GOOD), env);
    assert.equal(res.status, 429);
    assert.deepEqual(json, { error: "rate" });
    assert.equal(fetch.calls.length, 0);
    assert.equal(env.FEEDBACK_KV.puts.length, 0);
  }
  for (const which of ["PER_SENDER", "GLOBAL"]) {
    const env = await setup({ [which]: undefined });
    const { res } = await run(post(GOOD), env);
    assert.equal(res.status, 201);
  }
});

test("dailyCap", async () => {
  let env = await setup({ FEEDBACK_KV: fakeKV({ value: "50" }) });
  let r = await run(post(GOOD), env);
  assert.equal(r.res.status, 429);
  assert.deepEqual(r.json, { error: "daily" });
  assert.equal(r.fetch.calls.length, 0);

  env = await setup({ FEEDBACK_KV: fakeKV({ value: "49" }) });
  r = await run(post(GOOD), env);
  assert.equal(r.res.status, 201);
  assert.deepEqual(env.FEEDBACK_KV.puts, [["count:2026-11-06", "50", { expirationTtl: 172800 }]]);
});

test("kvWriteFailureStillPosts", async () => {
  const env = await setup({ FEEDBACK_KV: fakeKV({ throwOnPut: true }) });
  assert.equal((await run(post(GOOD), env)).res.status, 201);
});

test("success", async () => {
  const env = await setup();
  const { res, json } = await run(post(GOOD), env);
  assert.equal(res.status, 201);
  assert.equal(res.headers.get("content-type"), "application/json");
  assert.deepEqual(json, { number: 42 });
});

test("githubLimited", async () => {
  const env = await setup();
  const { res, json } = await run(post(GOOD), env, [{ status: 429 }]);
  assert.equal(res.status, 429);
  assert.deepEqual(json, { error: "busy" });
});

test("githubFailed", async () => {
  const env = await setup();
  const { res, json } = await run(post(GOOD), env, [{ status: 500, json: { message: "SECRET GITHUB TEXT" } }]);
  assert.equal(res.status, 502);
  assert.deepEqual(json, { error: "github" });
  assert.ok(!JSON.stringify(json).includes("SECRET"));
});

test("anUnexpectedThrowIs500Internal", async () => {
  const env = await setup();
  const stream = new ReadableStream({
    pull(c) {
      c.error(new Error("connection reset"));
    },
  });
  const req = new Request("https://r.example/feedback", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: stream,
    duplex: "half",
  });
  const { res, json, fetch } = await run(req, env);
  assert.equal(res.status, 500);
  assert.equal(res.headers.get("content-type"), "application/json");
  assert.deepEqual(json, { error: "internal" });
  assert.equal(fetch.calls.length, 0);
});
