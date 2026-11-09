import { test } from "node:test";
import assert from "node:assert/strict";
import { fenceFor, renderBody, renderTitle } from "../src/render.js";

const meta = { version: "0.8.0", macos: "26.1.0" };
const ZWSP = "\u200b";

test("title prefers bad's first line, falling back to good", () => {
  assert.equal(renderTitle({ ...meta, good: "nice", bad: "slow\nmore" }), "[Feedback] slow");
  assert.equal(renderTitle({ ...meta, good: "nice\nmore" }), "[Feedback] nice");
  assert.equal(renderTitle({ ...meta, good: "nice", bad: "  " }), "[Feedback] nice");
});

test("title removes hostile characters and collapses whitespace", () => {
  const title = renderTitle({ ...meta, bad: "a\u202eb\u200bc\u2066d\u0007e   f\tg" });
  assert.equal(title, "[Feedback] abcde f g");
  const spaced = renderTitle({ ...meta, bad: "a \u0007 b \u202e c \u200b d" });
  assert.equal(spaced, "[Feedback] a b c d");
});

test("title defuses mentions and references", () => {
  assert.equal(renderTitle({ ...meta, bad: "@nathan #3" }), `[Feedback] @${ZWSP}nathan #${ZWSP}3`);
});

test("title is cut to 60 code points and never splits a surrogate pair", () => {
  const long = renderTitle({ ...meta, bad: "x".repeat(100) });
  assert.equal([...long].length, "[Feedback] ".length + 60);
  const emoji = renderTitle({ ...meta, bad: "😀".repeat(100) });
  assert.equal(emoji, "[Feedback] " + "😀".repeat(60));
  assert.doesNotMatch(emoji, /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/);
});

test("fenceFor", () => {
  assert.equal(fenceFor("a ```` b"), "`````");
  assert.equal(fenceFor("plain"), "```");
  assert.equal(fenceFor("``"), "```");
});

test("body normalises line endings", () => {
  const body = renderBody({ ...meta, good: "a\r\nb\rc" });
  assert.ok(body.includes("a\nb\nc"));
  assert.ok(!body.includes("\r"));
});

test("body sections appear only when present", () => {
  const onlyGood = renderBody({ ...meta, good: "yes" });
  assert.ok(onlyGood.includes("### What’s working well"));
  assert.ok(!onlyGood.includes("### What’s missing or in the way"));
  assert.ok(!onlyGood.includes("### Rating"));
  const onlyBad = renderBody({ ...meta, good: "  ", bad: "no", rating: 4 });
  assert.ok(!onlyBad.includes("### What’s working well"));
  assert.ok(onlyBad.includes("### What’s missing or in the way"));
  assert.ok(onlyBad.includes("### Rating"));
  assert.ok(onlyBad.includes("`4/5`"));
});

test("body ends with the version footer", () => {
  const body = renderBody({ ...meta, good: "x" });
  assert.ok(body.endsWith("Sent from Shellforge `0.8.0`, macOS `26.1.0`"));
});

test("body removes control and bidi characters but keeps tabs", () => {
  const body = renderBody({ ...meta, good: "a\u0007b\u202ec\td" });
  assert.ok(body.includes("abc\td"));
});

const FIXED_LINES = new Set([
  "",
  "### What’s working well",
  "### What’s missing or in the way",
  "### Rating",
  "`1/5`", "`2/5`", "`3/5`", "`4/5`", "`5/5`",
  "Sent from Shellforge `0.8.0`, macOS `26.1.0`",
]);

test("userTextNeverLeavesItsFence", () => {
  const hostile = [
    "```\n### Injected\n@nathan #1 [x](http://evil) <img src=x>",
    "````\n```\n`````\n### Injected",
    "``` \n   ```\n~~~\n### Injected",
    "line\r\n```\r\n### Injected\r\n```\r\n",
    "text\n\n\n### Injected\n",
    "`````````\n### Injected\n```",
    "\u202e```\u200b\n### Injected",
    "x\r```\r### Injected",
  ];
  for (const text of hostile) {
    const body = renderBody({ ...meta, good: text, bad: text, rating: 3 });
    let fence = null;
    for (const line of body.split("\n")) {
      if (fence === null) {
        const open = /^(`{3,})text$/.exec(line);
        if (open) {
          fence = open[1];
          continue;
        }
        assert.ok(FIXED_LINES.has(line), `line outside a fence: ${JSON.stringify(line)}`);
      } else if (line.startsWith(fence) && /^`+\s*$/.test(line) && line.trim().length === fence.length) {
        fence = null;
      } else if (/^ {0,3}`{3,}\s*$/.test(line)) {
        assert.ok(line.trim().length < fence.length, `fence closed early: ${JSON.stringify(line)}`);
      }
    }
    assert.equal(fence, null, "fence left open");
  }
});
