import { cleanText, isBlank, visibleText } from "./clean.js";

const TITLE_PREFIX = "[Feedback] ";
const TITLE_MAX = 60;
const ZWSP = "\u200b";

function safeFirstLine(text) {
  const line = visibleText(text).split("\n").find((l) => l.trim() !== "") ?? "";
  return line.replace(/\s+/gu, " ").trim().replace(/([@#])/g, `$1${ZWSP}`);
}

export function renderTitle(feedback) {
  const source = isBlank(feedback.bad) ? feedback.good : feedback.bad;
  const line = safeFirstLine(source ?? "");
  return TITLE_PREFIX + [...line].slice(0, TITLE_MAX).join("");
}

// The backtick run one longer than the longest run in the text, at least 3.
export function fenceFor(text) {
  const longest = Math.max(0, ...(text.match(/`+/g) ?? []).map((run) => run.length));
  return "`".repeat(Math.max(3, longest + 1));
}

function fenced(text) {
  const cleaned = cleanText(text);
  const fence = fenceFor(cleaned);
  return `${fence}text\n${cleaned}\n${fence}`;
}

export function renderBody(feedback) {
  const parts = [];
  if (!isBlank(feedback.good)) parts.push("### What’s working well", fenced(feedback.good));
  if (!isBlank(feedback.bad)) parts.push("### What’s missing or in the way", fenced(feedback.bad));
  if (feedback.rating !== undefined) parts.push("### Rating", `\`${feedback.rating}/5\``);
  parts.push(`Sent from Shellforge \`${feedback.version}\`, macOS \`${feedback.macos}\``);
  return parts.join("\n\n");
}
