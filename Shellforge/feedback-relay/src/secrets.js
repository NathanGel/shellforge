// A courtesy to honest senders, not a security control. Every check is
// linear-time. The JWT check is a hand-written pass, because the equivalent
// regex is quadratic on input like "eyJ-eyJ-eyJ-...".
export const SECRET_PATTERNS = [
  /\b(ghp|gho|ghu|ghs)_[A-Za-z0-9]{30,}/,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /\bxox[abp]-[A-Za-z0-9-]{10,}/,
  /(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}/,
];

// Same matches as /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/.
export function looksLikeJWT(text) {
  for (const [run] of text.matchAll(/[A-Za-z0-9_.-]+/g)) {
    const segments = run.split(".");
    for (let i = 0; i + 2 < segments.length; i += 1) {
      if (!hasJWTStart(segments[i])) continue;
      if (segments[i + 1].length >= 8 && segments[i + 2].length >= 8) return true;
    }
  }
  return false;
}

// "eyJ" at a word boundary (segment start or after "-") with at least 8 more
// characters before the segment ends.
function hasJWTStart(segment) {
  let from = 0;
  for (;;) {
    const at = segment.indexOf("eyJ", from);
    if (at < 0 || segment.length - at < 11) return false;
    if (at === 0 || segment[at - 1] === "-") return true;
    from = at + 1;
  }
}

export function looksLikeSecret(text) {
  return looksLikeJWT(text) || SECRET_PATTERNS.some((pattern) => pattern.test(text));
}
