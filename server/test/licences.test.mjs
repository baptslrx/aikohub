// Tests du serveur de licences (Node, sans Cloudflare) : KV en mémoire, vraies signatures Ed25519.
import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import worker, { b64url, readToken, makeToken, toolAllowed, newKey, normalizeKey } from "../src/index.js";

class MemoryKV {
  constructor() { this.m = new Map(); }
  async get(k) { return this.m.get(k) ?? null; }
  async put(k, v) { this.m.set(k, v); }
  async delete(k) { this.m.delete(k); }
  async list({ prefix }) { return { keys: [...this.m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }; }
}

const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const env = {
  LICENCES: new MemoryKV(),
  SIGNING_KEY: b64url(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
  PUBLIC_KEY: b64url(await crypto.subtle.exportKey("raw", pair.publicKey)),
  ADMIN_PASSWORD: "secret-admin",
};

async function call(path, body, auth) {
  const req = new Request("https://licences.test" + path, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(auth ? { authorization: "Bearer " + auth } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const r = await worker.fetch(req, env);
  return { status: r.status, body: await r.json() };
}

test("clé lisible, format AIKO-XXXX-XXXX-XXXX", () => {
  const k = newKey();
  assert.match(k, /^AIKO-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
  assert.equal(normalizeKey(" aiko-abcd-efgh-jkmn "), "AIKO-ABCD-EFGH-JKMN");
});

test("profils : chaque licence ne débloque que ses outils", () => {
  assert.ok(toolAllowed("monteur", "aikorush") && toolAllowed("monteur", "aikorelink") && toolAllowed("monteur", "aikoflow"));
  assert.ok(!toolAllowed("monteur", "aikodeploy"));
  assert.ok(toolAllowed("dev", "aikodeploy") && !toolAllowed("dev", "aikorush"));
  assert.ok(toolAllowed("design", "aikopipette") && toolAllowed("design", "aikoshots") && !toolAllowed("design", "aikoserve"));
  assert.ok(toolAllowed("tout", "aikorush") && toolAllowed("tout", "aikodeploy"));
});

let key;
test("administration protégée par mot de passe", async () => {
  assert.equal((await call("/admin/create", { name: "Paul", profile: "monteur" })).status, 401);
  assert.equal((await call("/admin/create", { name: "Paul", profile: "monteur" }, "faux")).status, 401);
  const r = await call("/admin/create", { name: "Paul", profile: "monteur" }, "secret-admin");
  assert.equal(r.status, 200);
  key = r.body.licence.key;
  assert.equal(r.body.licence.maxDevices, 2);
  assert.equal((await call("/admin/create", { name: "X", profile: "pirate" }, "secret-admin")).status, 400);
});

let token;
test("activation sur 2 Mac maximum", async () => {
  const a = await call("/activate", { key: key.toLowerCase(), device: "mac-1", deviceName: "MacBook de Paul" });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  token = a.body.token;
  const again = await call("/activate", { key, device: "mac-1", deviceName: "MacBook de Paul" });
  assert.equal(again.status, 200, "réactiver le même Mac ne compte pas en double");
  assert.equal((await call("/activate", { key, device: "mac-2", deviceName: "iMac" })).status, 200);
  const third = await call("/activate", { key, device: "mac-3", deviceName: "Mac mini" });
  assert.equal(third.status, 409);
  assert.match(third.body.error, /2 appareils/);
  assert.equal((await call("/deactivate", { key, device: "mac-2" })).status, 200);
  assert.equal((await call("/activate", { key, device: "mac-3", deviceName: "Mac mini" })).status, 200, "place libérée");
});

test("jeton signé, lisible hors ligne, infalsifiable", async () => {
  const p = await readToken(env, token);
  assert.equal(p.name, "Paul");
  assert.equal(p.profile, "monteur");
  assert.equal(p.device, "mac-1");
  assert.ok(p.tools.includes("aikorush") && !p.tools.includes("aikodeploy"));
  assert.ok(p.validUntil - p.issued >= 29 * 86400);
  const [body, sig] = token.split(".");
  const forged = b64url(new TextEncoder().encode(JSON.stringify({ ...p, profile: "tout" }))) + "." + sig;
  assert.equal(await readToken(env, forged), null, "changer le profil casse la signature");
  assert.equal(await readToken(env, token, Date.now() + 31 * 86400e3), null, "expiré après 30 jours");
  // Pour le test Swift : vérifier la même signature avec CryptoKit
  writeFileSync(process.env.AIKO_TOKEN_OUT || "/tmp/aiko-token.json", JSON.stringify({ token, publicKey: env.PUBLIC_KEY, forged }));
});

test("renouvellement, révocation, expiration", async () => {
  assert.equal((await call("/refresh", { key, device: "mac-1" })).status, 200);
  assert.equal((await call("/refresh", { key, device: "inconnu" })).status, 403);
  await call("/admin/update", { key, revoked: true }, "secret-admin");
  const r = await call("/refresh", { key, device: "mac-1" });
  assert.equal(r.status, 403);
  assert.match(r.body.error, /désactivée/);
  await call("/admin/update", { key, revoked: false, expires: "2000-01-01T00:00:00Z" }, "secret-admin");
  assert.match((await call("/activate", { key, device: "mac-1" })).body.error, /expiré/);
  await call("/admin/update", { key, expires: null, resetDevices: true }, "secret-admin");
  const list = await call("/admin/list", {}, "secret-admin");
  assert.equal(list.body.licences.length, 1);
  assert.equal(list.body.licences[0].devices.length, 0, "appareils libérés");
});

test("une licence avec date de fin : le jeton ne la dépasse pas", async () => {
  const lic = { key: "AIKO-TEST-TEST-TEST", name: "Essai", profile: "dev", expires: new Date(Date.now() + 3 * 86400e3).toISOString() };
  const p = await readToken(env, await makeToken(env, lic, "mac-x"));
  assert.ok(p.validUntil * 1000 <= Date.parse(lic.expires) + 1000);
});

test("téléchargement refusé sans licence valide ou hors profil", async () => {
  const lic = (await call("/admin/create", { name: "Léa", profile: "dev" }, "secret-admin")).body.licence;
  const t = (await call("/activate", { key: lic.key, device: "mac-lea" })).body.token;
  assert.equal((await call("/download/aikodeploy?t=bidon")).status, 401);
  assert.equal((await call(`/download/aikorush?t=${t}`)).status, 403);
  assert.equal((await call(`/download/aikodeploy?t=${t}`)).status, 404, "autorisé (pas de version publiée dans ce test)");
});

test("clé inconnue : message clair", async () => {
  const r = await call("/activate", { key: "AIKO-XXXX-XXXX-XXXX", device: "d" });
  assert.equal(r.status, 403);
  assert.match(r.body.error, /n'existe pas/);
});
