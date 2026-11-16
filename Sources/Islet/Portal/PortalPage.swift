/// The phone's side of Portal: one self-contained page (no scripts or fonts from the
/// internet) that the iPhone opens from the QR code and keeps on its Home Screen. Its
/// token stays in the page's own URL, because a Home Screen web app on iOS doesn't share
/// Safari's storage.
enum PortalPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Portal">
<meta name="theme-color" content="#000000">
<link rel="apple-touch-icon" href="/icon.png">
<title>Islet Portal</title>
<style>
  :root { --a: #7c5cff; --b: #22d3ee; --c: #ff4fd8; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; height: 100%; background: #000; color: #fff; overflow: hidden;
    font: 16px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  body { display: flex; flex-direction: column; align-items: center;
    padding: calc(env(safe-area-inset-top) + 18px) 20px calc(env(safe-area-inset-bottom) + 18px); }
  #sky { position: fixed; inset: 0; z-index: 0; }
  main { position: relative; z-index: 1; width: 100%; max-width: 440px; flex: 1; display: flex;
    flex-direction: column; align-items: center; }
  header { width: 100%; display: flex; justify-content: space-between; align-items: center; }
  header h1 { font-size: 17px; font-weight: 600; margin: 0; letter-spacing: .2px; }
  header span { font-size: 13px; color: rgba(255,255,255,.55); }
  .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: #34d399;
    box-shadow: 0 0 10px #34d399; margin-right: 6px; vertical-align: 1px; }
  .dot.off { background: #f87171; box-shadow: 0 0 10px #f87171; }

  /* The portal */
  #portal { position: relative; width: min(78vw, 330px); aspect-ratio: 1; margin: 6vh 0 3vh; border-radius: 50%;
    cursor: pointer; touch-action: manipulation; }
  #portal .ring { position: absolute; inset: 0; border-radius: 50%; filter: blur(.5px); }
  #portal .r1 { background: conic-gradient(from 0deg, var(--a), var(--b), var(--c), var(--a));
    -webkit-mask: radial-gradient(circle, transparent 57%, #000 58%, #000 66%, transparent 67%);
            mask: radial-gradient(circle, transparent 57%, #000 58%, #000 66%, transparent 67%);
    animation: spin 6s linear infinite; }
  #portal .r2 { inset: 7%; background: conic-gradient(from 90deg, transparent, var(--b), transparent 30%, var(--c), transparent 60%, var(--a), transparent);
    -webkit-mask: radial-gradient(circle, transparent 60%, #000 62%, #000 70%, transparent 72%);
            mask: radial-gradient(circle, transparent 60%, #000 62%, #000 70%, transparent 72%);
    animation: spin 3.4s linear infinite reverse; opacity: .9; }
  #portal .glow { position: absolute; inset: -14%; border-radius: 50%;
    background: radial-gradient(circle, rgba(124,92,255,.55), rgba(34,211,238,.18) 45%, transparent 68%);
    filter: blur(18px); animation: breathe 3.2s ease-in-out infinite; }
  #portal .core { position: absolute; inset: 22%; border-radius: 50%;
    background: radial-gradient(circle at 50% 50%, #000 30%, #0b0420 62%, rgba(124,92,255,.5) 100%);
    box-shadow: inset 0 0 40px rgba(124,92,255,.9), 0 0 30px rgba(34,211,238,.35); }
  #vortex { position: absolute; inset: 0; width: 100%; height: 100%; border-radius: 50%; }
  #portal .label { position: absolute; inset: 0; display: grid; place-items: center; text-align: center;
    font-size: 14px; font-weight: 600; color: rgba(255,255,255,.85); pointer-events: none; transition: opacity .3s; }
  #progress { position: absolute; inset: -4%; width: 108%; height: 108%; transform: rotate(-90deg); pointer-events: none; }
  #progress circle { fill: none; stroke: #fff; stroke-width: 2.2; stroke-linecap: round;
    stroke-dasharray: 316; stroke-dashoffset: 316; transition: stroke-dashoffset .2s, opacity .4s; opacity: 0;
    filter: drop-shadow(0 0 6px #fff); }
  #portal.gulp { animation: gulp .55s cubic-bezier(.2,.9,.3,1.4); }
  #portal.spit { animation: spit .6s cubic-bezier(.2,.9,.3,1.4); }
  #portal.hot .glow { animation-duration: .9s; filter: blur(22px) brightness(1.6); }
  #portal.hot .r1 { animation-duration: 1.4s; }
  #portal.hot .r2 { animation-duration: .9s; }
  .shock { position: absolute; left: 50%; top: 50%; width: 10px; height: 10px; margin: -5px; border-radius: 50%;
    border: 2px solid rgba(255,255,255,.9); box-shadow: 0 0 24px var(--b), inset 0 0 18px var(--c);
    animation: shock .9s ease-out forwards; pointer-events: none; }
  .ripple { position: absolute; left: 50%; top: 50%; width: 10px; height: 10px; margin: -5px; border-radius: 50%;
    border: 1.5px solid rgba(160,220,255,.8); animation: ripple 1.6s cubic-bezier(.1,.6,.3,1) forwards; pointer-events: none; }

  /* Flying items */
  .fly { position: fixed; left: 0; top: 0; z-index: 5; width: 76px; height: 76px; border-radius: 18px; overflow: hidden;
    background: rgba(255,255,255,.12); border: 1px solid rgba(255,255,255,.25); display: grid; place-items: center;
    font-size: 30px; box-shadow: 0 10px 30px rgba(0,0,0,.5), 0 0 24px rgba(124,92,255,.5); pointer-events: none;
    will-change: transform, filter, opacity; }
  .fly img { width: 100%; height: 100%; object-fit: cover; }
  .fly small { position: absolute; bottom: 4px; left: 4px; right: 4px; font-size: 9px; text-align: center;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: rgba(255,255,255,.8); }

  /* Controls */
  .row { width: 100%; display: flex; gap: 10px; }
  .glass { background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14);
    -webkit-backdrop-filter: blur(20px) saturate(1.6); backdrop-filter: blur(20px) saturate(1.6); border-radius: 22px; }
  textarea { flex: 1; resize: none; height: 52px; padding: 15px 16px; color: #fff; font: inherit; outline: none; }
  textarea::placeholder { color: rgba(255,255,255,.45); }
  button { font: inherit; font-weight: 600; color: #fff; border: 0; border-radius: 22px; padding: 0 18px;
    background: linear-gradient(135deg, var(--a), var(--b)); box-shadow: 0 6px 22px rgba(124,92,255,.45); }
  button:active { transform: scale(.96); }
  .hint { margin-top: 12px; font-size: 13px; color: rgba(255,255,255,.5); text-align: center; }
  #inbox { width: 100%; margin-top: 16px; display: flex; flex-direction: column; gap: 8px; }
  .item { display: flex; align-items: center; gap: 12px; padding: 10px 12px; animation: land .5s cubic-bezier(.2,.9,.3,1.3); }
  .item .ic { width: 40px; height: 40px; border-radius: 10px; background: rgba(255,255,255,.12); display: grid; place-items: center; font-size: 20px; }
  .item .nm { flex: 1; min-width: 0; font-size: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .item .nm small { display: block; color: rgba(255,255,255,.5); font-size: 12px; }
  .item a { color: #fff; text-decoration: none; font-weight: 600; font-size: 14px; padding: 8px 14px; border-radius: 14px;
    background: linear-gradient(135deg, var(--a), var(--b)); }
  .item .x { background: none; box-shadow: none; padding: 0 4px; color: rgba(255,255,255,.5); font-size: 20px; }
  #toast { position: fixed; z-index: 9; left: 50%; bottom: calc(env(safe-area-inset-bottom) + 24px);
    transform: translate(-50%, 200%); opacity: 0; transition: transform .45s cubic-bezier(.2,.9,.3,1.2), opacity .3s; padding: 12px 18px;
    font-size: 14px; font-weight: 600; white-space: nowrap; }
  #toast.show { transform: translate(-50%, 0); opacity: 1; }
  #pair { width: 100%; margin-top: 2vh; display: none; flex-direction: column; gap: 12px; }
  #pair input { height: 52px; padding: 0 16px; color: #fff; font: inherit; outline: none; }
  #pair button { height: 52px; }
  #home { display: none; margin-top: 10px; padding: 14px 16px; font-size: 14px; color: rgba(255,255,255,.8); text-align: center; }
  details { width: 100%; margin-top: 14px; font-size: 13px; color: rgba(255,255,255,.6); }
  details summary { cursor: pointer; text-align: center; list-style: none; }
  details ol { padding-left: 20px; }
  details code { background: rgba(255,255,255,.1); padding: 1px 5px; border-radius: 5px; word-break: break-all; }

  @keyframes spin { to { transform: rotate(360deg); } }
  @keyframes breathe { 50% { transform: scale(1.08); opacity: .8; } }
  @keyframes gulp { 0% { transform: scale(1); } 30% { transform: scale(.9); } 65% { transform: scale(1.09); } 100% { transform: scale(1); } }
  @keyframes spit { 0% { transform: scale(1); } 35% { transform: scale(1.12); } 100% { transform: scale(1); } }
  @keyframes shock { to { width: 520px; height: 520px; margin: -260px; opacity: 0; border-width: 1px; } }
  @keyframes ripple { to { width: 420px; height: 420px; margin: -210px; opacity: 0; } }
  @keyframes land { from { transform: translateY(-40px) scale(.6); opacity: 0; } }
</style>
</head>
<body>
<canvas id="sky"></canvas>
<main>
  <header><h1>Portal</h1><span id="status"><i class="dot off"></i>Connecting…</span></header>

  <div id="portal" aria-label="Send to your Mac">
    <div class="glow"></div>
    <div class="ring r1"></div>
    <div class="ring r2"></div>
    <div class="core"></div>
    <canvas id="vortex"></canvas>
    <svg id="progress" viewBox="0 0 108 108"><circle cx="54" cy="54" r="50.3"/></svg>
    <div class="label" id="label">Tap to send<br>photos &amp; files</div>
  </div>
  <input type="file" id="files" multiple hidden>

  <section id="send" class="row">
    <textarea id="text" class="glass" placeholder="Text or a link"></textarea>
    <button id="sendText">Send</button>
  </section>
  <div class="hint" id="hint">Drag something to the right edge of your Mac's screen and it comes out here.</div>
  <div id="inbox"></div>

  <section id="pair">
    <div class="hint" style="margin-top:0">Pair this phone with your Mac. You only do this once.</div>
    <input id="name" class="glass" value="iPhone" maxlength="40" aria-label="This phone's name">
    <button id="pairBtn">Pair</button>
  </section>
  <div id="home" class="glass">Tap <b>Share</b>, then <b>Add to Home Screen</b>, to keep Portal one tap away.</div>

  <details id="shortcut">
    <summary>Send from the Share menu</summary>
    <ol>
      <li>In Shortcuts, make a new shortcut and turn on <b>Show in Share Sheet</b>.</li>
      <li>Add <b>Get Contents of URL</b> with this URL, method <b>POST</b>, request body <b>File</b> set to <i>Shortcut Input</i>:<br><code id="shortcutUrl"></code></li>
      <li>Add a header <code>X-Islet-Name</code> set to <i>Shortcut Input → Name</i>.</li>
    </ol>
  </details>
</main>
<div id="toast" class="glass"></div>

<script>
(() => {
  const $ = id => document.getElementById(id);
  const params = new URLSearchParams(location.search);
  let token = params.get("t") || localStorage.getItem("islet-token") || "";
  let effect = "vortex";
  const portal = $("portal");
  // Android: Chrome's own words for the Home screen, no iPhone Shortcuts, a buzz on arrival.
  const android = /Android/i.test(navigator.userAgent);
  const standalone = navigator.standalone || matchMedia("(display-mode: standalone)").matches;
  const extras = android ? ["send", "hint", "inbox"] : ["send", "hint", "inbox", "shortcut"];
  if (android) {
    $("home").innerHTML = "Open Chrome's <b>⋮</b> menu, then <b>Add to Home screen</b>, to keep Portal one tap away.";
    $("name").value = "Android phone";
    $("shortcut").style.display = "none";
  }

  // ---- Background stars and the vortex ----
  const sky = $("sky"), sk = sky.getContext("2d");
  const vortex = $("vortex"), vx = vortex.getContext("2d");
  const dpr = Math.min(devicePixelRatio || 1, 2);
  let stars = [], motes = [], heat = 0;
  function size() {
    sky.width = innerWidth * dpr; sky.height = innerHeight * dpr;
    sky.style.width = innerWidth + "px"; sky.style.height = innerHeight + "px";
    const r = portal.getBoundingClientRect();
    vortex.width = r.width * dpr; vortex.height = r.height * dpr;
    stars = Array.from({ length: 90 }, () => ({ x: Math.random(), y: Math.random(), z: Math.random() * .8 + .2 }));
  }
  function mote() {
    const a = Math.random() * Math.PI * 2;
    return { a, r: 0.55 + Math.random() * 0.12, s: 0.6 + Math.random() * 1.4, h: Math.random() };
  }
  for (let i = 0; i < 140; i++) motes.push(Object.assign(mote(), { r: Math.random() * 0.6 }));
  function frame(t) {
    sk.clearRect(0, 0, sky.width, sky.height);
    for (const s of stars) {
      const tw = .35 + .65 * Math.abs(Math.sin(t / 900 * s.z + s.x * 40));
      sk.fillStyle = `rgba(200,210,255,${tw * s.z * .7})`;
      sk.fillRect(s.x * sky.width, s.y * sky.height, 1.4 * dpr * s.z, 1.4 * dpr * s.z);
    }
    const w = vortex.width, c = w / 2;
    vx.globalCompositeOperation = "destination-out";
    vx.fillStyle = "rgba(0,0,0,.22)"; vx.fillRect(0, 0, w, w);
    vx.globalCompositeOperation = "lighter";
    const speed = 1 + heat * 3;
    for (const m of motes) {
      // Spiral inward, faster near the middle; respawn at the rim.
      m.a += 0.012 * m.s * speed / Math.max(m.r, .08);
      m.r -= 0.0016 * m.s * speed;
      if (m.r < 0.07) Object.assign(m, mote());
      const x = c + Math.cos(m.a) * m.r * w * .5, y = c + Math.sin(m.a) * m.r * w * .5;
      const hue = 250 - m.h * 70 + (1 - m.r) * 80;
      vx.fillStyle = `hsla(${hue},95%,${60 + heat * 20}%,${Math.min(1, m.r * 1.8)})`;
      vx.beginPath(); vx.arc(x, y, (1 + m.s) * dpr * (0.5 + m.r), 0, 7); vx.fill();
    }
    heat *= 0.97;
    requestAnimationFrame(frame);
  }
  addEventListener("resize", size); size(); requestAnimationFrame(frame);

  // ---- Effects ----
  function burst(kind) {
    portal.classList.remove("gulp", "spit"); void portal.offsetWidth;
    portal.classList.add(kind);
    heat = 1;
    const make = cls => { const el = document.createElement("div"); el.className = cls; portal.appendChild(el); setTimeout(() => el.remove(), 1700); };
    if (effect === "ripple") { make("ripple"); setTimeout(() => make("ripple"), 180); setTimeout(() => make("ripple"), 360); }
    else make("shock");
  }
  function hot(on) { portal.classList.toggle("hot", on); }
  function centre() { const r = portal.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
  function card(content, name) {
    const el = document.createElement("div"); el.className = "fly";
    if (content instanceof HTMLElement) el.appendChild(content); else el.textContent = content;
    if (name) { const s = document.createElement("small"); s.textContent = name; el.appendChild(s); }
    document.body.appendChild(el); return el;
  }
  // Into the portal: drift up from the bottom, then spiral in, shrinking and blurring.
  function suck(el) {
    const c = centre(), sx = innerWidth / 2 + (Math.random() - .5) * 160, sy = innerHeight - 140;
    const frames = [];
    for (let i = 0; i <= 24; i++) {
      const p = i / 24, e = p * p * (3 - 2 * p), ang = e * Math.PI * (effect === "ripple" ? .5 : 3);
      const rad = (1 - e) * 120;
      const x = sx + (c.x - sx) * e + Math.cos(ang) * rad * e * (1 - e) * 2 - 38;
      const y = sy + (c.y - sy) * e + Math.sin(ang) * rad * e * (1 - e) * 2 - 38;
      frames.push({ transform: `translate(${x}px,${y}px) rotate(${ang * 57}deg) scale(${1 - e * .95})`,
        filter: `blur(${e * e * 6}px) brightness(${1 + e})`, opacity: p > .92 ? (1 - p) * 12 : 1 });
    }
    return el.animate(frames, { duration: 1100, easing: "cubic-bezier(.5,0,.75,0)", fill: "forwards" }).finished.then(() => el.remove());
  }
  // Out of the portal: burst out spinning, then settle into the list.
  function spit(el, target) {
    const c = centre(), t = target.getBoundingClientRect();
    const frames = [
      { transform: `translate(${c.x - 38}px,${c.y - 38}px) rotate(-540deg) scale(.05)`, filter: "blur(6px) brightness(2)", opacity: 0 },
      { transform: `translate(${c.x - 38}px,${c.y - 120}px) rotate(-60deg) scale(1.25)`, filter: "blur(0) brightness(1.3)", opacity: 1, offset: .55 },
      { transform: `translate(${t.left}px,${t.top - 18}px) rotate(0) scale(.55)`, filter: "none", opacity: .9 }];
    return el.animate(frames, { duration: 1000, easing: "cubic-bezier(.2,.9,.3,1)", fill: "forwards" }).finished.then(() => el.remove());
  }
  function toast(text) { const t = $("toast"); t.textContent = text; t.classList.add("show"); clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove("show"), 2400); }
  function progress(p) {
    const c = $("progress").firstElementChild;
    c.style.opacity = p == null ? 0 : 1; c.style.strokeDashoffset = 316 * (1 - (p || 0));
  }
  function glyph(name, type) {
    if ((type || "").startsWith("video")) return "🎬";
    if ((type || "").startsWith("audio")) return "🎵";
    if (/\.(pdf)$/i.test(name)) return "📄";
    if (/\.(zip|rar|7z)$/i.test(name)) return "🗜️";
    return "📦";
  }

  // ---- Network ----
  function api(path, opts = {}) {
    opts.headers = Object.assign({ "X-Islet-Token": token }, opts.headers || {});
    return fetch(path, opts);
  }
  function setStatus(ok, text) {
    const dot = document.createElement("i"); dot.className = ok ? "dot" : "dot off";
    $("status").replaceChildren(dot, document.createTextNode(text));
  }
  function upload(file) {
    return new Promise((resolve, reject) => {
      const x = new XMLHttpRequest();
      x.open("POST", "/send");
      x.setRequestHeader("X-Islet-Token", token);
      x.setRequestHeader("X-Islet-Kind", "file");
      x.setRequestHeader("X-Islet-Name", encodeURIComponent(file.name || "Photo"));
      x.upload.onprogress = e => e.lengthComputable && progress(e.loaded / e.total);
      x.onload = () => x.status === 200 ? resolve() : reject(x.status);
      x.onerror = () => reject(0);
      x.send(file);
    });
  }
  async function sendFiles(list) {
    hot(true);
    for (const file of list) {
      let face;
      if (file.type.startsWith("image/")) { face = new Image(); face.src = URL.createObjectURL(file); }
      else face = glyph(file.name, file.type);
      const el = card(face, file.name);
      const flight = suck(el);
      try { await upload(file); await flight; burst("gulp"); }
      catch (e) { el.remove(); toast(e === 401 ? "Pair again from your Mac" : "Couldn't reach your Mac"); }
    }
    progress(null); hot(false);
    toast(list.length > 1 ? `${list.length} items sent` : "Sent to your Mac");
  }
  async function sendText() {
    const text = $("text").value.trim(); if (!text) return;
    const el = card(/^https?:\/\//i.test(text) ? "🔗" : "💬", text.slice(0, 24));
    const flight = suck(el); hot(true);
    try {
      const r = await api("/send", { method: "POST", headers: { "X-Islet-Kind": "text", "Content-Type": "text/plain" }, body: text });
      if (!r.ok) throw r.status;
      await flight; burst("gulp"); $("text").value = ""; toast("Sent to your Mac");
    } catch (e) { el.remove(); toast(e === 401 ? "Pair again from your Mac" : "Couldn't reach your Mac"); }
    hot(false);
  }

  // ---- Mac → phone ----
  const seen = new Set();
  async function poll() {
    if (document.hidden || !token) return;
    try {
      const r = await api("/outbox");
      if (r.status === 401) { setStatus(false, "Not paired"); return; }
      const items = await r.json();
      setStatus(true, "Connected");
      for (const it of items) if (!seen.has(it.id)) { seen.add(it.id); arrive(it); }
    } catch { setStatus(false, "Mac not found"); }
  }
  const isImage = name => /\.(png|jpe?g|gif|heic|heif|webp|tiff?)$/i.test(name);
  function face(it, link) {
    if (!isImage(it.name)) return glyph(it.name);
    const img = new Image(); img.src = link; img.style.cssText = "width:100%;height:100%;object-fit:cover"; return img;
  }
  function arrive(it) {
    const link = `/outbox/${encodeURIComponent(it.id)}?t=${encodeURIComponent(token)}`;
    const row = document.createElement("div"); row.className = "item glass"; row.style.visibility = "hidden";
    const ic = document.createElement("div"); ic.className = "ic"; ic.style.overflow = "hidden";
    const f = face(it, link); if (typeof f === "string") ic.textContent = f; else ic.appendChild(f);
    const nm = document.createElement("div"); nm.className = "nm"; nm.textContent = it.name;
    const sz = document.createElement("small"); sz.textContent = `From your Mac · ${(it.size / 1048576).toFixed(it.size > 1048576 ? 1 : 2)} MB`; nm.appendChild(sz);
    const a = document.createElement("a"); a.textContent = "Save"; a.href = link; a.download = it.name;
    const x = document.createElement("button"); x.className = "x"; x.textContent = "×";
    x.onclick = () => { api(`/outbox/${encodeURIComponent(it.id)}`, { method: "DELETE" }); row.remove(); };
    row.append(ic, nm, a, x); $("inbox").prepend(row);
    burst("spit");
    navigator.vibrate?.(30);
    spit(card(face(it, link), it.name), row).then(() => { row.style.visibility = "visible"; });
    toast(`${it.name} arrived`);
  }

  // ---- Pairing ----
  async function pair() {
    const code = params.get("pair");
    try {
      const r = await fetch("/pair", { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code, name: $("name").value }) });
      if (!r.ok) { toast(await r.text()); return; }
      const j = await r.json();
      token = j.token; localStorage.setItem("islet-token", token);
      burst("spit");
      // The token goes in the address, so "Add to Home Screen" keeps it.
      history.replaceState(null, "", `/?t=${encodeURIComponent(token)}&welcome=1`);
      start(true);
    } catch { toast("Couldn't reach your Mac"); }
  }

  function start(welcome) {
    $("pair").style.display = "none";
    for (const id of extras) $(id).style.display = "";
    $("label").innerHTML = "Tap to send<br>photos &amp; files";
    $("home").style.display = (welcome || params.get("welcome")) && !standalone ? "block" : "none";
    $("shortcutUrl").textContent = `${location.origin}/send?t=${token}`;
    api("/config").then(r => r.ok ? r.json() : null).then(j => {
      if (!j) return;
      effect = j.effect; document.title = `Portal · ${j.mac}`;
      setStatus(true, j.mac);
    }).catch(() => {});
    poll(); setInterval(poll, 2500);
  }

  $("files").onchange = e => { const f = [...e.target.files]; e.target.value = ""; if (f.length) sendFiles(f); };
  portal.onclick = () => { if (token) $("files").click(); };
  $("sendText").onclick = sendText;
  $("pairBtn").onclick = pair;
  document.addEventListener("visibilitychange", poll);

  if (params.get("pair")) {
    for (const id of ["send", "hint", "inbox", "shortcut"]) $(id).style.display = "none";
    $("pair").style.display = "flex";
    $("label").innerHTML = "Ready to pair";
    setStatus(true, "Your Mac");
  } else if (token) {
    start(false);
  } else {
    for (const id of ["send", "inbox", "shortcut"]) $(id).style.display = "none";
    $("label").textContent = "Not paired";
    $("hint").textContent = "Open Settings → Portal on your Mac and scan the QR code.";
    setStatus(false, "Not paired");
  }
})();
</script>
</body>
</html>
"""#
}
