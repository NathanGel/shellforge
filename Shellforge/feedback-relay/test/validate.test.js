import { test } from "node:test";
import assert from "node:assert/strict";
import { LIMITS, isJSONContentType, readBody, validate } from "../src/validate.js";

const base = { version: "0.8.0", macos: "26.1.0" };
const errorOf = (value) => {
  const result = validate(value);
  assert.equal(result.ok, false);
  return result.error;
};

test("limits", () => {
  assert.deepEqual(LIMITS, { bodyBytes: 16384, fieldCodePoints: 4000 });
});

test("content types", () => {
  assert.equal(isJSONContentType("application/json"), true);
  assert.equal(isJSONContentType("application/json; charset=utf-8"), true);
  assert.equal(isJSONContentType("text/plain"), false);
  assert.equal(isJSONContentType("application/json5"), false);
  assert.equal(isJSONContentType(null), false);
});

test("accepts a minimal valid body", () => {
  const result = validate({ ...base, good: "x" });
  assert.deepEqual(result, { ok: true, feedback: { ...base, good: "x" } });
});

test("accepts all fields", () => {
  const result = validate({ ...base, good: "a", bad: "b", rating: 5 });
  assert.equal(result.ok, true);
  assert.equal(result.feedback.rating, 5);
});

test("rejects bad shapes", () => {
  assert.equal(errorOf({ ...base, good: "x", extra: 1 }), "fields");
  assert.equal(errorOf({ ...base, good: null }), "fields");
  for (const rating of [0, 6, 3.5, "4"]) {
    assert.equal(errorOf({ ...base, good: "x", rating }), "fields");
  }
  assert.equal(errorOf({ ...base, good: "a".repeat(4001) }), "fields");
  assert.equal(errorOf({ ...base, bad: "a".repeat(4001) }), "fields");
});

test("rejects empty feedback", () => {
  assert.equal(errorOf({ ...base, good: "  \n", bad: "" }), "empty");
  assert.equal(errorOf({ ...base, rating: 4 }), "empty");
});

test("rejects bad versions", () => {
  assert.equal(errorOf({ version: "unknown", macos: "26.1.0", good: "x" }), "version");
  assert.equal(errorOf({ version: "1.2.3.4.5", macos: "26.1.0", good: "x" }), "version");
  assert.equal(errorOf({ macos: "26.1.0", good: "x" }), "version");
  assert.equal(errorOf({ version: "0.8.0", macos: "x", good: "x" }), "version");
  assert.equal(validate({ version: "0.8.0-beta.1", macos: "26.1", good: "x" }).ok, true);
});

test("rejects non-objects", () => {
  assert.equal(errorOf([]), "json");
  assert.equal(errorOf("hi"), "json");
  assert.equal(errorOf(null), "json");
});

test("rejects secrets", () => {
  assert.equal(errorOf({ ...base, good: "token ghp_" + "a".repeat(36) }), "secret");
  assert.equal(errorOf({ ...base, bad: "token ghp_" + "a".repeat(36) }), "secret");
});

test("invisible-only text counts as blank", () => {
  assert.equal(errorOf({ ...base, good: "\u200b\u0007" }), "empty");
  assert.equal(errorOf({ ...base, good: "\u202e", bad: "\u2060\ufeff " }), "empty");
});

test("secrets are found in the cleaned text", () => {
  const split = "ghp_" + "a".repeat(18) + "\u200e" + "a".repeat(18);
  assert.equal(errorOf({ ...base, good: split }), "secret");
  const zeroWidth = "ghp_" + "a".repeat(18) + "\u200b" + "a".repeat(18);
  assert.equal(errorOf({ ...base, bad: zeroWidth }), "secret");
});

test("rejects strings that are not well-formed", () => {
  assert.equal(errorOf({ ...base, good: "\ud800" }), "fields");
  assert.equal(errorOf({ ...base, good: "ok", bad: "x\udc00" }), "fields");
});

test("counts code points, not UTF-16 units", () => {
  assert.equal(validate({ ...base, good: "😀".repeat(4000) }).ok, true);
  assert.equal(errorOf({ ...base, good: "😀".repeat(4001) }), "fields");
});

test("readBody returns small bodies", async () => {
  const request = new Request("https://x.test/", { method: "POST", body: "0123456789" });
  assert.equal(await readBody(request, 100), "0123456789");
});

test("readBody abandons large streamed bodies without Content-Length", async () => {
  const chunk = new Uint8Array(1000).fill(97);
  let sent = 0;
  const stream = new ReadableStream({
    pull(controller) {
      if (sent >= 20) return controller.close();
      sent += 1;
      controller.enqueue(chunk);
    },
  });
  const request = new Request("https://x.test/", { method: "POST", body: stream, duplex: "half" });
  assert.equal(request.headers.get("content-length"), null);
  assert.equal(await readBody(request, 5000), null);
  assert.ok(sent < 20, "stopped reading early");
});

test("readBody handles a missing body", async () => {
  const request = new Request("https://x.test/", { method: "POST" });
  assert.equal(await readBody(request, 100), "");
});
