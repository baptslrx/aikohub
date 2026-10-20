// Crée une paire de clés Ed25519 : la privée signe les licences (secret du serveur), la publique va dans l'appli.
const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const b64url = (b) => Buffer.from(b).toString("base64url");
const priv = b64url(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const pub = b64url(await crypto.subtle.exportKey("raw", pair.publicKey));
console.log(JSON.stringify({ privateKey: priv, publicKey: pub }));
