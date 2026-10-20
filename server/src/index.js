// Serveur de licences AikoHub (Cloudflare Workers + KV).
// Clés créées par l'administrateur, licences par profil, 2 appareils max, jetons signés (Ed25519) valables 30 jours.

export const PROFILES = ["design", "monteur", "dev", "tout"];

// Outils et profils qui y donnent accès (« tous » = inclus dans chaque profil).
export const TOOLS = {
  aikoroue: { app: "AikoRoue", profiles: ["design", "monteur", "dev"] },
  aikopipette: { app: "AikoPipette", profiles: ["design", "dev"] },
  aikorush: { app: "AikoRush", profiles: ["monteur"] },
  aikoserve: { app: "AikoServe", profiles: ["dev"] },
  aikoshield: { app: "AikoShield", profiles: ["design", "monteur", "dev"] },
  aikomemo: { app: "AikoMemo", profiles: ["design", "monteur", "dev"] },
  aikoflow: { app: "AikoFlow", profiles: ["design", "monteur", "dev"] },
  aikodeck: { app: "AikoDeck", profiles: ["design", "monteur"] },
  aikorelink: { app: "AikoRelink", profiles: ["monteur"] },
  aikodeploy: { app: "AikoDeploy", profiles: ["dev"] },
  aikoshots: { app: "AikoShots", profiles: ["design", "dev"] },
};

const TOKEN_DAYS = 30;
const enc = new TextEncoder();

// ---------- outils ----------

export function b64url(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64url(str) {
  const s = str.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((str.length + 3) % 4);
  const bin = atob(s);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

const err = (message, status = 400) => json({ ok: false, error: message }, status);

export function newKey() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // sans O/0 ni I/1
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  const chars = [...bytes].map((b) => alphabet[b % alphabet.length]);
  return "AIKO-" + [0, 4, 8].map((i) => chars.slice(i, i + 4).join("")).join("-");
}

export const normalizeKey = (k) => String(k || "").trim().toUpperCase().replace(/\s+/g, "");

function timingSafeEqual(a, b) {
  const x = enc.encode(String(a)), y = enc.encode(String(b));
  if (x.length !== y.length) return false;
  let r = 0;
  for (let i = 0; i < x.length; i++) r |= x[i] ^ y[i];
  return r === 0;
}

async function signingKey(env) {
  if (!env.__key) {
    env.__key = await crypto.subtle.importKey("pkcs8", unb64url(env.SIGNING_KEY), { name: "Ed25519" }, false, ["sign"]);
  }
  return env.__key;
}

async function publicKey(env) {
  return crypto.subtle.importKey("raw", unb64url(env.PUBLIC_KEY), { name: "Ed25519" }, false, ["verify"]);
}

export function toolAllowed(profile, tool) {
  const t = TOOLS[tool];
  return !!t && (profile === "tout" || t.profiles.includes(profile));
}

// ---------- jetons ----------

export async function makeToken(env, lic, device, now = Date.now()) {
  let validUntil = now + TOKEN_DAYS * 86400e3;
  if (lic.expires) validUntil = Math.min(validUntil, Date.parse(lic.expires));
  const payload = {
    key: lic.key, name: lic.name, profile: lic.profile, device,
    issued: Math.floor(now / 1000), validUntil: Math.floor(validUntil / 1000),
    tools: Object.keys(TOOLS).filter((t) => toolAllowed(lic.profile, t)),
  };
  const body = enc.encode(JSON.stringify(payload));
  const sig = await crypto.subtle.sign({ name: "Ed25519" }, await signingKey(env), body);
  return b64url(body) + "." + b64url(sig);
}

export async function readToken(env, token, now = Date.now()) {
  const [p, s] = String(token || "").split(".");
  if (!p || !s) return null;
  const body = unb64url(p);
  const ok = await crypto.subtle.verify({ name: "Ed25519" }, await publicKey(env), unb64url(s), body);
  if (!ok) return null;
  const payload = JSON.parse(new TextDecoder().decode(body));
  if (payload.validUntil * 1000 < now) return null;
  return payload;
}

// ---------- licences (KV) ----------

const kvKey = (k) => "lic:" + normalizeKey(k);

async function getLicence(env, key) {
  const raw = await env.LICENCES.get(kvKey(key));
  return raw ? JSON.parse(raw) : null;
}

async function putLicence(env, lic) {
  await env.LICENCES.put(kvKey(lic.key), JSON.stringify(lic));
}

function licenceProblem(lic, now = Date.now()) {
  if (!lic) return "Cette clé n'existe pas. Vérifie-la (elle commence par AIKO-).";
  if (lic.revoked) return "Cette clé a été désactivée.";
  if (lic.expires && Date.parse(lic.expires) < now) return "Cette clé a expiré.";
  return null;
}

// ---------- routes publiques ----------

async function activate(env, body) {
  const lic = await getLicence(env, body.key);
  const problem = licenceProblem(lic);
  if (problem) return err(problem, 403);
  const device = String(body.device || "").slice(0, 128);
  if (!device) return err("Appareil inconnu");
  const now = new Date().toISOString();
  const known = lic.devices.find((d) => d.id === device);
  if (known) {
    known.lastSeen = now;
    known.name = String(body.deviceName || known.name).slice(0, 80);
  } else {
    if (lic.devices.length >= (lic.maxDevices || 2)) {
      return err(`Cette clé est déjà utilisée sur ${lic.devices.length} appareils (${lic.devices.map((d) => d.name).join(", ")}). ` +
        "Désactive-la sur un autre Mac dans AikoHub, ou demande à ce qu'on libère un appareil.", 409);
    }
    lic.devices.push({ id: device, name: String(body.deviceName || "Mac").slice(0, 80), activated: now, lastSeen: now });
  }
  await putLicence(env, lic);
  return json({ ok: true, token: await makeToken(env, lic, device), name: lic.name, profile: lic.profile });
}

async function refresh(env, body) {
  const lic = await getLicence(env, body.key);
  const problem = licenceProblem(lic);
  if (problem) return err(problem, 403);
  const d = lic.devices.find((x) => x.id === body.device);
  if (!d) return err("Ce Mac n'est plus activé pour cette clé.", 403);
  d.lastSeen = new Date().toISOString();
  await putLicence(env, lic);
  return json({ ok: true, token: await makeToken(env, lic, d.id), name: lic.name, profile: lic.profile });
}

async function deactivate(env, body) {
  const lic = await getLicence(env, body.key);
  if (!lic) return err("Clé inconnue", 404);
  lic.devices = lic.devices.filter((d) => d.id !== body.device);
  await putLicence(env, lic);
  return json({ ok: true });
}

// Dernières versions des outils (pour afficher les mises à jour)
async function catalog(env) {
  const out = {};
  await Promise.all(Object.entries(TOOLS).map(async ([repo, t]) => {
    const rel = await latestRelease(env, repo);
    out[repo] = { app: t.app, profiles: t.profiles, version: rel?.tag_name || null };
  }));
  return json({ ok: true, tools: out });
}

async function latestRelease(env, repo) {
  if (!env.GITHUB_TOKEN) return null;
  const cache = typeof caches !== "undefined" ? caches.default : null;
  const cacheKey = new Request(`https://cache.aikohub/${repo}/latest`);
  if (cache) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit.json();
  }
  const r = await fetch(`https://api.github.com/repos/${env.GITHUB_OWNER || "baptslrx"}/${repo}/releases/latest`, {
    headers: { authorization: `Bearer ${env.GITHUB_TOKEN}`, "user-agent": "aikohub", accept: "application/vnd.github+json" },
  });
  if (!r.ok) return null;
  const rel = await r.json();
  if (cache) {
    await cache.put(cacheKey, new Response(JSON.stringify(rel), { headers: { "cache-control": "max-age=600" } }));
  }
  return rel;
}

// Téléchargement d'un outil : seulement avec un jeton valide qui donne accès à cet outil
async function download(env, url) {
  const tool = url.pathname.split("/")[2];
  const payload = await readToken(env, url.searchParams.get("t"));
  if (!payload) return err("Licence invalide ou expirée : ouvre AikoHub pour la renouveler.", 401);
  const lic = await getLicence(env, payload.key);
  if (licenceProblem(lic)) return err(licenceProblem(lic), 403);
  if (!toolAllowed(lic.profile, tool)) return err("Cet outil n'est pas dans ta licence.", 403);
  const rel = await latestRelease(env, tool);
  const asset = rel?.assets?.find((a) => /-Mac\.zip$/i.test(a.name));
  if (!asset) return err("Aucune version Mac disponible pour cet outil.", 404);
  const r = await fetch(asset.url, {
    headers: { authorization: `Bearer ${env.GITHUB_TOKEN}`, "user-agent": "aikohub", accept: "application/octet-stream" },
  });
  if (!r.ok) return err("Téléchargement impossible pour le moment.", 502);
  return new Response(r.body, {
    headers: {
      "content-type": "application/zip",
      "content-disposition": `attachment; filename="${asset.name}"`,
      "x-aiko-version": rel.tag_name || "",
      ...(r.headers.get("content-length") ? { "content-length": r.headers.get("content-length") } : {}),
    },
  });
}

// ---------- administration ----------

async function admin(env, path, body) {
  switch (path) {
    case "/admin/create": {
      const profile = String(body.profile || "").toLowerCase();
      if (!PROFILES.includes(profile)) return err("Profil inconnu (design, monteur, dev ou tout)");
      const name = String(body.name || "").trim().slice(0, 80);
      if (!name) return err("Indique le nom de la personne");
      let key;
      do key = newKey(); while (await env.LICENCES.get(kvKey(key)));
      const lic = {
        key, name, profile, maxDevices: Math.min(10, Math.max(1, Number(body.maxDevices) || 2)), devices: [],
        revoked: false, expires: body.expires || null, note: String(body.note || "").slice(0, 200),
        created: new Date().toISOString(),
      };
      await putLicence(env, lic);
      return json({ ok: true, licence: lic });
    }
    case "/admin/list": {
      const out = [];
      let cursor;
      do {
        const page = await env.LICENCES.list({ prefix: "lic:", cursor });
        for (const k of page.keys) {
          const raw = await env.LICENCES.get(k.name);
          if (raw) out.push(JSON.parse(raw));
        }
        cursor = page.list_complete ? undefined : page.cursor;
      } while (cursor);
      out.sort((a, b) => (b.created || "").localeCompare(a.created || ""));
      return json({ ok: true, licences: out });
    }
    case "/admin/update": {
      const lic = await getLicence(env, body.key);
      if (!lic) return err("Clé inconnue", 404);
      if ("revoked" in body) lic.revoked = !!body.revoked;
      if ("expires" in body) lic.expires = body.expires || null;
      if ("maxDevices" in body) lic.maxDevices = Math.min(10, Math.max(1, Number(body.maxDevices) || 2));
      if ("profile" in body && PROFILES.includes(body.profile)) lic.profile = body.profile;
      if ("name" in body && body.name) lic.name = String(body.name).slice(0, 80);
      if (body.resetDevices) lic.devices = [];
      if (body.removeDevice) lic.devices = lic.devices.filter((d) => d.id !== body.removeDevice);
      await putLicence(env, lic);
      return json({ ok: true, licence: lic });
    }
    case "/admin/delete": {
      await env.LICENCES.delete(kvKey(body.key));
      return json({ ok: true });
    }
    default:
      return err("Action inconnue", 404);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/") return json({ ok: true, service: "AikoHub licences" });
      if (request.method === "GET" && url.pathname === "/catalog") return catalog(env);
      if (request.method === "GET" && url.pathname.startsWith("/download/")) return download(env, url);
      if (request.method !== "POST") return err("Méthode non prise en charge", 405);
      const body = await request.json().catch(() => ({}));
      if (url.pathname.startsWith("/admin/")) {
        const auth = request.headers.get("authorization") || "";
        if (!env.ADMIN_PASSWORD || !timingSafeEqual(auth, "Bearer " + env.ADMIN_PASSWORD)) {
          return err("Mot de passe administrateur incorrect", 401);
        }
        return admin(env, url.pathname, body);
      }
      if (url.pathname === "/activate") return activate(env, body);
      if (url.pathname === "/refresh") return refresh(env, body);
      if (url.pathname === "/deactivate") return deactivate(env, body);
      return err("Introuvable", 404);
    } catch (e) {
      return err("Erreur du serveur : " + (e && e.message ? e.message : e), 500);
    }
  },
};
