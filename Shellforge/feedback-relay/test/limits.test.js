import { test } from "node:test";
import assert from "node:assert/strict";
import { senderKey, dayKey, takeDailySlot, underMinuteLimits, DAILY_CAP } from "../src/limits.js";

test("senderKey", () => {
  assert.equal(senderKey("203.0.113.9"), "203.0.113.9");
  assert.equal(senderKey("2001:db8:1:2:3:4:5:6"), "2001:db8:1:2");
  assert.equal(senderKey("2001:DB8::1"), "2001:db8:0:0");
  assert.equal(senderKey(null), "unknown");
});

test("dayKeyIsUTC", () => {
  assert.equal(dayKey(Date.UTC(2026, 10, 6, 23, 59)), "count:2026-11-06");
});

test("takeDailySlot", async () => {
  const puts = [];
  const kv = { get: async () => "49", put: async (...a) => puts.push(a) };
  assert.equal(DAILY_CAP, 50);
  assert.equal(await takeDailySlot(kv, Date.UTC(2026, 10, 6)), true);
  assert.deepEqual(puts, [["count:2026-11-06", "50", { expirationTtl: 172800 }]]);
  const full = { get: async () => "50", put: async () => assert.fail("no put") };
  assert.equal(await takeDailySlot(full, Date.UTC(2026, 10, 6)), false);
});

test("underMinuteLimitsSkipsMissingBindings", async () => {
  assert.equal(await underMinuteLimits({}, "k"), true);
});
