export const DAILY_CAP = 50;
export const SENDER_DAILY_CAP = 3;
const DAILY_TTL_SECONDS = 172800;

// The per-sender key: the address itself for IPv4, the /64 prefix for IPv6.
export function senderKey(ip) {
  if (typeof ip !== "string" || ip === "") return "unknown";
  const value = ip.trim().toLowerCase();
  if (!value.includes(":")) return value;
  if (value.includes(".")) return value.slice(value.lastIndexOf(":") + 1); // ::ffff:1.2.3.4
  const [head, tail] = value.split("::");
  const front = head === "" ? [] : head.split(":");
  const back = tail === undefined || tail === "" ? [] : tail.split(":");
  const groups = tail === undefined ? front : [...front, ...Array(Math.max(0, 8 - front.length - back.length)).fill("0"), ...back];
  return groups
    .slice(0, 4)
    .map((g) => (/^[0-9a-f]{1,4}$/.test(g) ? parseInt(g, 16).toString(16) : g))
    .join(":");
}

export function dayKey(nowMs) {
  return `count:${new Date(nowMs).toISOString().slice(0, 10)}`;
}

// A missing binding skips that limit; so does one that throws.
export async function underMinuteLimits(env, key) {
  for (const [binding, bindingKey] of [[env.PER_SENDER, key], [env.GLOBAL, "global"]]) {
    if (!binding) continue;
    try {
      if (!(await binding.limit({ key: bindingKey })).success) return false;
    } catch {
      // Skip a broken limiter rather than fail the request.
    }
  }
  return true;
}

// Approximate: KV is eventually consistent. A failed write still counts the post;
// a failed read fails closed.
export async function takeDailySlot(kv, nowMs) {
  const key = dayKey(nowMs);
  let count;
  try {
    count = Number.parseInt((await kv.get(key)) ?? "0", 10);
  } catch {
    return false;
  }
  if (!Number.isInteger(count)) count = 0;
  if (count >= DAILY_CAP) return false;
  try {
    await kv.put(key, String(count + 1), { expirationTtl: DAILY_TTL_SECONDS });
  } catch {
    // Still post.
  }
  return true;
}

export function senderDayKey(nowMs, key) {
  return `sender:${new Date(nowMs).toISOString().slice(0, 10)}:${key}`;
}

// One sender cannot use up the global day. Checked before the global slot; same
// approximation as takeDailySlot: a failed read fails closed, a failed write still posts.
export async function takeSenderSlot(kv, key, nowMs) {
  const kvKey = senderDayKey(nowMs, key);
  let count;
  try {
    count = Number.parseInt((await kv.get(kvKey)) ?? "0", 10);
  } catch {
    return false;
  }
  if (!Number.isInteger(count)) count = 0;
  if (count >= SENDER_DAILY_CAP) return false;
  try {
    await kv.put(kvKey, String(count + 1), { expirationTtl: DAILY_TTL_SECONDS });
  } catch {
    // Still post.
  }
  return true;
}
