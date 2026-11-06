import { test } from "node:test";
import assert from "node:assert/strict";
import { SECRET_PATTERNS, looksLikeSecret } from "../src/secrets.js";

test("has the six regex patterns (JWTs are a separate linear pass)", () => {
  assert.equal(SECRET_PATTERNS.length, 6);
});

test("GitHub tokens", () => {
  assert.equal(looksLikeSecret("ghp_" + "a1B2".repeat(9)), true);
  assert.equal(looksLikeSecret("ghp_short"), false);
});

test("fine-grained GitHub tokens", () => {
  assert.equal(looksLikeSecret("github_pat_" + "A".repeat(22)), true);
  assert.equal(looksLikeSecret("github_pat_short"), false);
});

test("AWS access key ids", () => {
  assert.equal(looksLikeSecret("key AKIA" + "0123456789ABCDEF"), true);
  assert.equal(looksLikeSecret("AKIA0123"), false);
});

test("private keys", () => {
  assert.equal(looksLikeSecret("-----BEGIN RSA PRIVATE KEY-----"), true);
  assert.equal(looksLikeSecret("-----BEGIN PUBLIC KEY-----"), false);
});

test("Slack tokens", () => {
  assert.equal(looksLikeSecret("xoxb-1234567890-abc"), true);
  assert.equal(looksLikeSecret("xoxb-123"), false);
});

test("sk- keys, but not task- words", () => {
  assert.equal(looksLikeSecret("sk-" + "a".repeat(20)), true);
  assert.equal(looksLikeSecret("task-" + "a".repeat(20)), false);
});

test("JWTs", () => {
  const part = "abcdefgh12";
  assert.equal(looksLikeSecret(`eyJ${part}.${part}.${part}`), true);
  assert.equal(looksLikeSecret(`eyJ${part}.${part}`), false);
});

test("plain text is fine", () => {
  assert.equal(looksLikeSecret("ok"), false);
});

test("JWT boundaries", () => {
  const part = "abcdefgh12";
  assert.equal(looksLikeSecret(`x-eyJ${part}.${part}.${part}`), true);
  assert.equal(looksLikeSecret(`xeyJ${part}.${part}.${part}`), false);
  assert.equal(looksLikeSecret(`_eyJ${part}.${part}.${part}`), false);
  assert.equal(looksLikeSecret(`eyJ${part}.abc.${part}`), false);
});

// A regression here shows up as a test-runner timeout, not a timing assertion.
test("adversarial input stays linear", () => {
  assert.equal(looksLikeSecret("eyJ-".repeat(1000)), false);
  assert.equal(looksLikeSecret("eyJ" + "a".repeat(3990)), false);
  assert.equal(looksLikeSecret("a-".repeat(2000)), false);
  assert.equal(looksLikeSecret("sk-" + "a-".repeat(1998)), true);
  const long = "a".repeat(1300);
  assert.equal(looksLikeSecret(`eyJ${long}.${long}.${long}`), true);
});
