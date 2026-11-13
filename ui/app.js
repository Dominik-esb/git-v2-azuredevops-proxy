// Status page: polls status.json and draws the data flow Azure DevOps -> mirror -> clients,
// one row per repository, or one row per project once there are more than GROUP_ABOVE repos.
// Below it: a searchable table of repositories and the list of what discovery skipped.
(() => {
  "use strict";

  const POLL_MS = 3000;
  const LIVE_S = 8;          // an edge animates for this long after an event
  const PUSH_RECENT_S = 300; // a push edge stays coloured this long
  const GROUP_ABOVE = 12;    // more repositories than this: one graph row per project

  // Layout (SVG user units)
  const COL = { up: 30, mirror: 410, clients: 790 };
  const BOX_W = 250, BOX_H = 46, ROW_H = 76, PAD_Y = 34;

  const SVG_NS = "http://www.w3.org/2000/svg";
  const $ = (id) => document.getElementById(id);

  let data = null;
  let clockOffset = 0;  // server minus browser clock, in seconds (from the Date header)
  let builtFor = null;  // row ids the graph was last built for
  let drawn = [];       // per graph row: { syncEdge, syncLabel, outEdge }

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
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

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

  // Graph rows: a repository each, or a project each when there are many repositories.
  function graphRows(repos) {
    const active = repos.filter((r) => r.state === "active");
    if (active.length <= GROUP_ABOVE) {
      return active.map((r) => ({
        id: r.name, up: r.name.split("/").pop(), upSub: r.project ? `Azure DevOps · ${r.project}` : "Azure DevOps",
        mirror: `${r.name}.git`, mirrorSub: "mirror", repos: [r],
      }));
    }
    const groups = new Map();
    for (const r of active) {
      const p = r.project || "(no project)";
      if (!groups.has(p)) groups.set(p, []);
      groups.get(p).push(r);
    }
    return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([p, rs]) => ({
      id: `project:${p}`, up: p, upSub: `Azure DevOps · ${plural(rs.length, "repository", "repositories")}`,
      mirror: `${p}/`, mirrorSub: plural(rs.length, "mirror", "mirrors"), repos: rs,
    }));
  }

  // Rebuilt only when the rows change, so animations keep running smoothly between polls.
  function build(rows) {
    const svg = $("graph");
    const height = Math.max(rows.length, 1) * ROW_H + PAD_Y * 2 - (ROW_H - BOX_H);
    svg.setAttribute("viewBox", `0 0 ${COL.clients + BOX_W + 30} ${height}`);
    svg.replaceChildren();

    const edges = el("g", {}, svg);   // edges below boxes
    const labels = el("g", {}, svg);  // labels above edges
    const clientsY = height / 2 - BOX_H / 2;

    drawn = rows.map((row, i) => {
      const y = PAD_Y + i * ROW_H;
      const mid = y + BOX_H / 2;
      const syncEdge = el("path", { class: "edge", d: curve(COL.up + BOX_W, mid, COL.mirror, mid) }, edges);
      const outEdge = el("path", { class: "edge", d: curve(COL.mirror + BOX_W, mid, COL.clients, clientsY + BOX_H / 2) }, edges);
      const syncLabel = el("text", { class: "edge-label", x: (COL.up + BOX_W + COL.mirror) / 2, y: mid - 9 }, labels);
      box(svg, COL.up, y, row.up, row.upSub);
      box(svg, COL.mirror, y, row.mirror, row.mirrorSub);
      return { syncEdge, syncLabel, outEdge };
    });

    if (rows.length) box(svg, COL.clients, clientsY, "Git clients", "clone · fetch · push");
    svg.append(labels);
    builtFor = rows.map((r) => r.id).join("\n");
  }

  function setEdge(edge, kind, live) {
    edge.setAttribute("class", "edge" + (kind ? ` ${kind}` : "") + (live ? " live" : ""));
  }

  // Colour and label of a graph row: a failure wins, then the most recent sync or push.
  function rowState(repos, t, interval) {
    const failing = repos.filter((r) => r.sync_ok === false);
    const lastPush = repos.reduce((m, r) => (r.last_push != null && (m == null || r.last_push > m.last_push) ? r : m), null);
    const lastSync = repos.reduce((m, r) => (r.last_sync != null && (m == null || r.last_sync > m.last_sync) ? r : m), null);
    const pushRecent = lastPush && t - lastPush.last_push < PUSH_RECENT_S;
    let kind = null, at = null, label = "";
    if (failing.length && repos.length > 1) {
      kind = "fail"; label = `${failing.length} failing`;
    } else if (pushRecent && (!lastSync || lastPush.last_push > lastSync.last_sync)) {
      kind = lastPush.push_ok ? "push" : "fail"; at = lastPush.last_push;
      label = `${lastPush.push_ok ? "pushed" : "push failed"} ${since(at)} ago`;
    } else if (lastSync) {
      at = lastSync.last_sync;
      kind = failing.length ? "fail" : (t - at < interval + 15 ? "sync" : null);
      label = `${failing.length ? "failed" : "synced"} ${since(at)} ago`;
    }
    return {
      kind, label, live: at != null && t - at < LIVE_S,
      out: pushRecent ? (lastPush.push_ok ? "push" : "fail") : null,
      outLive: lastPush != null && t - lastPush.last_push < LIVE_S,
    };
  }

  function matches(r, q, filter, t) {
    if (q && !`${r.name} ${r.project || ""}`.toLowerCase().includes(q)) return false;
    if (filter === "failing") return r.sync_ok === false || r.push_ok === false;
    if (filter === "orphaned") return r.state === "orphaned";
    if (filter === "pushed") return r.last_push != null && t - r.last_push < 86400;
    return true;
  }

  function render() {
    if (!data) return;
    const repos = (data.repos || []).slice().sort((a, b) => a.name.localeCompare(b.name));
    const t = now();
    const interval = data.sync_interval || 60;

    // Graph
    const rows = graphRows(repos);
    if (rows.map((r) => r.id).join("\n") !== builtFor) build(rows);
    rows.forEach((row, i) => {
      const s = rowState(row.repos, t, interval);
      setEdge(drawn[i].syncEdge, s.kind, s.live);
      drawn[i].syncLabel.textContent = s.label;
      setEdge(drawn[i].outEdge, s.out, s.outLive);
    });

    // Heading
    const remaining = data.next_sync != null ? Math.round(data.next_sync - t) : null;
    $("next-sync").textContent = remaining == null ? "next sync —"
      : remaining > 0 ? `next sync in ${remaining}s` : "syncing…";
    renderNote(repos, interval);

    // Repositories
    const q = $("search").value.trim().toLowerCase();
    const filter = $("state").value;
    const shown = repos.filter((r) => matches(r, q, filter, t));
    $("count").textContent = shown.length === repos.length ? plural(repos.length, "repository", "repositories")
      : `${shown.length} of ${repos.length}`;
    $("repos").replaceChildren(...(shown.length ? shown.map(repoRow) : [emptyRow(6, repos.length ? "Nothing matches." : "No repositories yet.")]));

    // Not mirrored
    const skipped = (data.skipped || []).filter((s) => !q || s.name.toLowerCase().includes(q));
    $("skipped-box").hidden = !(data.skipped || []).length;
    $("skipped-title").textContent = `Not mirrored (${(data.skipped || []).length})`;
    $("skipped").replaceChildren(...skipped.map((s) => {
      const tr = document.createElement("tr");
      tr.append(text(s.name), text(s.reason, "muted"));
      return tr;
    }));

    const up = data.started ? ` · up ${since(data.started)}` : "";
    $("meta").textContent = `git-v2-azuredevops-proxy ${data.version || ""}${up}`;
  }

  function renderNote(repos, interval) {
    const note = $("note");
    const active = repos.filter((r) => r.state === "active").length;
    const parts = [
      `Mirroring ${plural(active, "repository", "repositories")}`,
      `syncing every ${interval}s`,
      `Azure DevOps auth: ${data.upstream_auth === "entra" ? "Entra ID" : "PAT"}`,
    ];
    if (data.token_scope && data.token_scope !== "none") parts.push(`one token per ${data.token_scope === "global" ? "proxy" : data.token_scope}`);
    note.replaceChildren(parts.join(" · "));
    const d = data.discovery || {};
    if (!d.enabled) return;
    note.append(document.createElement("br"));
    if (d.ok === false) {
      const s = document.createElement("span");
      s.className = "fail";
      s.textContent = `Discovery failed ${d.last_run ? ago(d.last_run) : ""}: ${d.error || "unknown error"} — keeping the previous list`;
      note.append(s);
    } else if (d.last_run) {
      note.append(`Discovery: ${d.found} found, ${d.included} mirrored · scanned ${ago(d.last_run)}` +
        (d.next_run ? ` · next scan in ${Math.max(0, Math.round(d.next_run - now()))}s` : ""));
    } else {
      note.append("Discovery: first scan pending");
    }
  }

  function repoRow(r) {
    const tr = document.createElement("tr");
    tr.append(
      text(r.name),
      text(r.project || "—", r.project ? "" : "muted"),
      text(r.source === "discovered" ? "discovered" : r.source === "static" ? "configured" : "—", "muted"),
      time(r.last_sync, r.sync_ok),
      time(r.last_push, r.push_ok),
      statusCell(r),
    );
    return tr;
  }

  function statusCell(r) {
    const td = document.createElement("td");
    const s = document.createElement("span");
    if (r.state === "orphaned") {
      s.className = "orphaned";
      s.textContent = `going away — not configured or discovered since ${ago(r.orphaned_since)}`;
      s.title = "Still served; moved to /repos/.archive after ARCHIVE_AFTER";
    } else if (r.sync_ok === false) {
      s.className = "fail";
      s.textContent = `sync failed: ${r.error || "fetch failed"}`;
    } else if (r.push_ok === false) {
      s.className = "fail";
      s.textContent = "last push failed";
    } else {
      s.textContent = r.last_sync == null ? "waiting for first sync" : "ok";
      if (r.last_sync == null) s.className = "muted";
    }
    td.append(s);
    return td;
  }

  function text(value, cls) {
    const td = document.createElement("td");
    td.textContent = value;
    if (cls) td.className = cls;
    return td;
  }

  function time(ts, ok) {
    const td = text(ago(ts), ts == null ? "muted" : "");
    td.title = stamp(ts);
    if (ts != null && ok === false) td.className = "fail-text";
    return td;
  }

  function emptyRow(cols, msg) {
    const tr = document.createElement("tr");
    const td = text(msg, "muted");
    td.colSpan = cols;
    tr.append(td);
    return tr;
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

  $("search").addEventListener("input", render);
  $("state").addEventListener("change", render);
  poll();
  setInterval(poll, POLL_MS);
  setInterval(render, 1000);
})();
