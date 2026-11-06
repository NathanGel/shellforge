export const GITHUB = {
  api: "https://api.github.com",
  owner: "NathanGel",
  repo: "shellforge",
  apiVersion: "2026-03-10",
  userAgent: "shellforge-feedback-relay",
};

const b64url = (bytes) => {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
};
const encodePart = (obj) => b64url(new TextEncoder().encode(JSON.stringify(obj)));

export async function signAppJwt(pem, appId, nowMs) {
  const b64 = pem.replace(/-----(BEGIN|END)[^-]*-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const iat = Math.floor(nowMs / 1000) - 60;
  const signingInput = `${encodePart({ alg: "RS256", typ: "JWT" })}.${encodePart({ iat, exp: iat + 540, iss: appId })}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

const headers = (bearer) => ({
  Authorization: `Bearer ${bearer}`,
  Accept: "application/vnd.github+json",
  "X-GitHub-Api-Version": GITHUB.apiVersion,
  "User-Agent": GITHUB.userAgent,
  "Content-Type": "application/json",
});

// Never returns or logs GitHub's response text.
export async function postIssue({ fetch, env, nowMs, title, body }) {
  try {
    const jwt = await signAppJwt(env.GITHUB_APP_KEY, env.GITHUB_APP_ID, nowMs);
    const tokenRes = await fetch(`${GITHUB.api}/app/installations/${env.GITHUB_INSTALLATION_ID}/access_tokens`, {
      method: "POST",
      redirect: "manual",
      headers: headers(jwt),
      body: JSON.stringify({ repositories: [GITHUB.repo], permissions: { issues: "write" } }),
    });
    const tokenFailure = failureOf(tokenRes);
    if (tokenFailure) return tokenFailure;
    const token = (await tokenRes.json())?.token;
    if (typeof token !== "string" || !token) return { status: "failed" };

    const issueRes = await fetch(`${GITHUB.api}/repos/${GITHUB.owner}/${GITHUB.repo}/issues`, {
      method: "POST",
      redirect: "manual",
      headers: headers(token),
      body: JSON.stringify({ title, body, labels: ["feedback"] }),
    });
    const issueFailure = failureOf(issueRes);
    if (issueFailure) return issueFailure;
    const number = (await issueRes.json())?.number;
    if (!Number.isInteger(number)) return { status: "failed" };
    return { status: "posted", number };
  } catch {
    return { status: "failed" };
  }
}

function failureOf(res) {
  if (res.status === 429 || (res.status === 403 && res.headers.get("retry-after") !== null)) {
    return { status: "limited" };
  }
  return res.status === 201 ? null : { status: "failed" };
}
