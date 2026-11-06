// Shared test helpers: an RSA test key (WebCrypto, PKCS#8 PEM) and a recording fake fetch.

export async function makeTestKey() {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let bin = "";
  for (const b of der) bin += String.fromCharCode(b);
  const lines = btoa(bin).match(/.{1,64}/g).join("\n");
  const pem = `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}

// responses: array of { status, json?, headers? } or Error instances (thrown), consumed in order.
export function recordingFetch(responses) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init });
    const next = responses[calls.length - 1];
    if (next === undefined) throw new Error("unexpected extra fetch call");
    if (next instanceof Error) throw next;
    return new Response(JSON.stringify(next.json ?? {}), { status: next.status, headers: next.headers });
  };
  fn.calls = calls;
  return fn;
}
