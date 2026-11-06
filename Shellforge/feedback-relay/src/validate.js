import { isBlank, visibleText } from "./clean.js";
import { looksLikeSecret } from "./secrets.js";

export const LIMITS = { bodyBytes: 16384, fieldCodePoints: 4000 };

const ALLOWED_KEYS = new Set(["good", "bad", "rating", "version", "macos"]);
const VERSION = /^[0-9]{1,4}(\.[0-9]{1,4}){0,3}(-[0-9A-Za-z.]{1,16})?$/;

export function isJSONContentType(header) {
  if (typeof header !== "string") return false;
  return /^application\/json(\s*;\s*charset=utf-8)?\s*$/i.test(header);
}

// Returns the body text, or null when it is larger than maxBytes. Never
// trusts Content-Length.
export async function readBody(request, maxBytes) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

const fail = (error) => ({ ok: false, error });
const isText = (v) =>
  typeof v === "string" && v.isWellFormed() && [...v].length <= LIMITS.fieldCodePoints;

export function validate(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return fail("json");
  if (Object.keys(value).some((key) => !ALLOWED_KEYS.has(key))) return fail("fields");
  const { good, bad, rating, version, macos } = value;
  for (const text of [good, bad]) {
    if (text !== undefined && !isText(text)) return fail("fields");
  }
  if (rating !== undefined && !(Number.isInteger(rating) && rating >= 1 && rating <= 5)) {
    return fail("fields");
  }
  if (isBlank(good) && isBlank(bad)) return fail("empty");
  for (const v of [version, macos]) {
    if (typeof v !== "string" || !VERSION.test(v)) return fail("version");
  }
  if ([good, bad].some((text) => text !== undefined && looksLikeSecret(visibleText(text)))) {
    return fail("secret");
  }
  const feedback = { version, macos };
  if (good !== undefined) feedback.good = good;
  if (bad !== undefined) feedback.bad = bad;
  if (rating !== undefined) feedback.rating = rating;
  return { ok: true, feedback };
}
