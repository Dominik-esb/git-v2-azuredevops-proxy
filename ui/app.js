// Status page: polls status.json and draws one row per repository,
// Azure DevOps -> mirror -> clients, with the last sync/push on each edge.
(() => {
  "use strict";

  const POLL_MS = 3000;
  const LIVE_S = 8;          // an edge animates for this long after an event
  const PUSH_RECENT_S = 300; // a push edge stays coloured this long

  // Layout (SVG user units)
  const COL = { up: 30, mirror: 410, clients: 790 };
  const BOX_W = 250, BOX_H = 46, ROW_H = 76, PAD_Y = 34;

  const SVG_NS = "http://www.w3.org/2000/svg";
  const $ = (id) => document.getElementById(id);

  let data = null;
  let clockOffset = 0;  // server minus browser clock, in seconds (from the Date header)
  let builtFor = null;  // repo names the graph was last built for
  let rows = [];        // per repo: { syncEdge, syncLabel, outEdge }

  const now = () => Date.now() / 1000 + clockOffset;

  function since(ts) {
    const s = Math.max(0, Math.round(now() - ts));
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.floor(s / 60)}m`;
    if (s < 86400) return `${Math.floor(s / 3600)}h`;
    return `${Math.floor(s / 86400)}d`;
  }
  const ago = (ts) => (ts == null ? "never" : `${since(ts)} ago`);
  const stamp = (ts) => (ts == null ? "" : new Date(ts * 1000).toLocaleString());

  function el(name, attrs, parent) {
    const node = document.createElementNS(SVG_NS, name);
    for (const [k, v] of Object.entries(attrs || {})) node.setAttribute(k, v);
    if (parent) parent.append(node);
    return node;
  }

  function box(svg, x, y, title, sub) {
    const g = el("g", { class: "box" }, svg);
    el("rect", { x, y, width: BOX_W, height: BOX_H, rx: 3 }, g);
    el("text", { x: x + BOX_W / 2, y: y + 18 }, g).textContent = title;
    el("text", { x: x + BOX_W / 2, y: y + 33, class: "sub" }, g).textContent = sub;
    el("circle", { class: "port", cx: x, cy: y + BOX_H / 2, r: 3.5 }, svg);
    el("circle", { class: "port", cx: x + BOX_W, cy: y + BOX_H / 2, r: 3.5 }, svg);
  }

  function curve(x1, y1, x2, y2) {
    const dx = (x2 - x1) / 2;
    return `M${x1} ${y1} C${x1 + dx} ${y1}, ${x2 - dx} ${y2}, ${x2} ${y2}`;
  }

  // Rebuilt only when the set of repositories changes, so animations keep running smoothly.
  function build(repos) {
    const svg = $("graph");
    const height = Math.max(repos.length, 1) * ROW_H + PAD_Y * 2 - (ROW_H - BOX_H);
    svg.setAttribute("viewBox", `0 0 ${COL.clients + BOX_W + 30} ${height}`);
    svg.replaceChildren();

    const edges = el("g", {}, svg);   // edges below boxes
    const labels = el("g", {}, svg);  // labels above edges
    const clientsY = height / 2 - BOX_H / 2;

    rows = repos.map((r, i) => {
      const y = PAD_Y + i * ROW_H;
      const mid = y + BOX_H / 2;
      const syncEdge = el("path", { class: "edge", d: curve(COL.up + BOX_W, mid, COL.mirror, mid) }, edges);
      const outEdge = el("path", {
        class: "edge",
        d: curve(COL.mirror + BOX_W, mid, COL.clients, clientsY + BOX_H / 2),
      }, edges);
      const syncLabel = el("text", { class: "edge-label", x: (COL.up + BOX_W + COL.mirror) / 2, y: mid - 9 }, labels);
      box(svg, COL.up, y, r.name, "Azure DevOps");
      box(svg, COL.mirror, y, `${r.name}.git`, "mirror");
      return { syncEdge, syncLabel, outEdge };
    });

    if (repos.length) box(svg, COL.clients, clientsY, "Git clients", "clone · fetch · push");
    svg.append(labels);
    builtFor = repos.map((r) => r.name).join("\n");
  }

  function setEdge(edge, kind, live) {
    edge.setAttribute("class", "edge" + (kind ? ` ${kind}` : "") + (live ? " live" : ""));
  }

  function render() {
    if (!data) return;
    const repos = (data.repos || []).slice().sort((a, b) => a.name.localeCompare(b.name));
    if (repos.map((r) => r.name).join("\n") !== builtFor) build(repos);
    const t = now();
    const interval = data.sync_interval || 60;

    repos.forEach((r, i) => {
      const row = rows[i];
      const pushNewer = r.last_push != null && (r.last_sync == null || r.last_push > r.last_sync);
      const pushRecent = r.last_push != null && t - r.last_push < PUSH_RECENT_S;

      // Azure DevOps <-> mirror: shows whichever happened last, a sync or a forwarded push.
      let kind = null, at = null, verb = "";
      if (pushNewer && pushRecent) {
        kind = r.push_ok ? "push" : "fail"; at = r.last_push; verb = r.push_ok ? "pushed" : "failed";
      } else if (r.last_sync != null) {
        kind = r.sync_ok ? (t - r.last_sync < interval + 15 ? "sync" : null) : "fail";
        at = r.last_sync; verb = r.sync_ok ? "synced" : "failed";
      }
      setEdge(row.syncEdge, kind, at != null && t - at < LIVE_S);
      row.syncLabel.textContent = at == null ? "" : `${verb} ${since(at)} ago`;

      // mirror <-> clients: coloured while a push from a client is recent.
      setEdge(row.outEdge, pushRecent ? (r.push_ok ? "push" : "fail") : null,
        r.last_push != null && t - r.last_push < LIVE_S);
    });

    // Heading
    const remaining = data.next_sync != null ? Math.round(data.next_sync - t) : null;
    $("next-sync").textContent = remaining == null ? "next sync —"
      : remaining > 0 ? `next sync in ${remaining}s` : "syncing…";
    $("note").textContent = repos.length
      ? `Mirroring ${repos.length} ${repos.length === 1 ? "repository" : "repositories"} · ` +
        `syncing every ${interval}s · Azure DevOps auth: ${data.upstream_auth === "entra" ? "Entra ID" : "PAT"}`
      : "No repositories configured.";

    // Table
    $("repos").replaceChildren(...repos.map((r) => {
      const tr = document.createElement("tr");
      const name = document.createElement("td");
      name.textContent = r.name;
      tr.append(name, cell(r.last_sync, r.sync_ok, "sync"), cell(r.last_push, r.push_ok, "push"));
      return tr;
    }));

    const up = data.started ? ` · up ${since(data.started)}` : "";
    $("meta").textContent = `git-v2-azuredevops-proxy ${data.version || ""}${up}`;
  }

  function cell(ts, ok, what) {
    const td = document.createElement("td");
    td.title = stamp(ts);
    if (ts == null) {
      td.innerHTML = '<span class="muted">never</span>';
    } else if (ok === false) {
      const s = document.createElement("span");
      s.className = "fail";
      s.textContent = `${ago(ts)} — ${what} failed`;
      td.append(s);
    } else {
      td.textContent = ago(ts);
    }
    return td;
  }

  async function poll() {
    try {
      const res = await fetch("status.json", { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      data = await res.json();
      const date = Date.parse(res.headers.get("Date"));
      if (!Number.isNaN(date)) clockOffset = (date - Date.now()) / 1000;
    } catch (err) {
      $("note").textContent = "Can't reach the proxy — retrying…";
      return;
    }
    render();
  }

  poll();
  setInterval(poll, POLL_MS);
  setInterval(render, 1000);
})();
