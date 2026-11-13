import { isJSONContentType, readBody, validate, LIMITS } from "./validate.js";
import { renderTitle, renderBody } from "./render.js";
import { postIssue } from "./github.js";
import { senderKey, underMinuteLimits, takeDailySlot, takeSenderSlot } from "./limits.js";

const json = (status, body, extra = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...extra },
  });
const error = (status, code) => json(status, { error: code });

// Never logs. Order: method and path, kill switch, KV, content type, body,
// validation, per-minute limits, per-sender daily cap, daily cap, GitHub.
export async function handle(request, env, deps) {
  try {
    return await route(request, env, deps);
  } catch {
    // Never an unhandled throw: Cloudflare would answer with its own 1101 HTML page.
    return error(500, "internal");
  }
}

async function route(request, env, { fetch, now }) {
  if (request.method !== "POST" || new URL(request.url).pathname !== "/feedback") {
    return json(405, { error: "method" }, { Allow: "POST" });
  }
  if (env.RELAY_ENABLED !== "true") return error(503, "off");
  if (!env.FEEDBACK_KV) return error(503, "off");
  if (!isJSONContentType(request.headers.get("Content-Type"))) return error(400, "type");

  const text = await readBody(request, LIMITS.bodyBytes);
  if (text === null) return error(400, "size");
  if (text === "") return error(400, "json");
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return error(400, "json");
  }
  const checked = validate(value);
  if (!checked.ok) return error(400, checked.error);

  const sender = senderKey(request.headers.get("CF-Connecting-IP"));
  if (!(await underMinuteLimits(env, sender))) return error(429, "rate");
  if (!(await takeSenderSlot(env.FEEDBACK_KV, sender, now()))) return error(429, "daily");
  if (!(await takeDailySlot(env.FEEDBACK_KV, now()))) return error(429, "daily");

  const result = await postIssue({
    fetch,
    env,
    nowMs: now(),
    title: renderTitle(checked.feedback),
    body: renderBody(checked.feedback),
  });
  if (result.status === "posted") return json(201, { number: result.number });
  if (result.status === "limited") return error(429, "busy");
  return error(502, "github");
}
