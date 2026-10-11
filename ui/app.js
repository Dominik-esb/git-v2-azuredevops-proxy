// Read-only status page: polls status.json and renders the flow diagram, summary and repo table.
(() => {
  "use strict";

  const POLL_MS = 3000;
  const SYNC_ACTIVE_S = 6;   // how long a lane stays highlighted after an event
  const PUSH_ACTIVE_S = 10;

  const $ = (id) => document.getElementById(id);
  let data = null;
  let clockOffset = 0;       // server clock minus browser clock, in seconds (from the Date header)
  let online = false;

  const now = () => Date.now() / 1000 + clockOffset;

  function ago(ts) {
    if (ts == null) return "never";
    const s = Math.max(0, Math.round(now() - ts));
    if (s < 5) return "just now";
    if (s < 60) return `${s} s ago`;
    if (s < 3600) return `${Math.floor(s / 60)} min ago`;
    if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
    return `${Math.floor(s / 86400)} d ago`;
  }

  function duration(s) {
    if (s < 60) return `${s} s`;
    if (s < 3600) return `${Math.floor(s / 60)} min`;
    if (s < 86400) return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
    return `${Math.floor(s / 86400)} d ${Math.floor((s % 86400) / 3600)} h`;
  }

  const absolute = (ts) => (ts == null ? "" : new Date(ts * 1000).toLocaleString());

  function latest(repos, key) {
    let best = null;
    for (const r of repos) if (r[key] != null && (best == null || r[key] > best[key])) best = r;
    return best;
  }

  function badge(ok) {
    const el = document.createElement("span");
    el.className = "badge " + (ok == null ? "none" : ok ? "ok" : "bad");
    el.textContent = ok == null ? "—" : ok ? "OK" : "Failed";
    return el;
  }

  function cell(text, cls, title) {
    const td = document.createElement("td");
    if (cls) td.className = cls;
    if (title) td.title = title;
    if (text instanceof Node) td.append(text); else td.textContent = text;
    return td;
  }

  function setLane(id, active, failed) {
    const el = $(id);
    el.classList.toggle("active", active && !failed);
    el.classList.toggle("failed", failed);
  }

  function render() {
    if (!data) return;
    const repos = data.repos || [];
    const t = now();

    // Flow diagram
    const sync = latest(repos, "last_sync");
    const push = latest(repos, "last_push");
    const syncRecent = sync && t - sync.last_sync < SYNC_ACTIVE_S;
    const pushRecent = push && t - push.last_push < PUSH_ACTIVE_S;
    const syncFailed = repos.some((r) => r.sync_ok === false);
    setLane("lane-sync", syncRecent, syncFailed);
    setLane("lane-push-in", pushRecent, false);
    setLane("lane-push-out", pushRecent, pushRecent && push.push_ok === false);
    setLane("lane-serve", false, false);

    $("proxy-sub").textContent = `${repos.length} ${repos.length === 1 ? "repository" : "repositories"}`;
    $("ado-sub").textContent = data.upstream_auth === "entra" ? "Entra ID" : "PAT";

    // Next sync countdown
    const interval = data.sync_interval || 0;
    const remaining = data.next_sync != null ? Math.round(data.next_sync - t) : null;
    const ring = $("countdown");
    if (remaining == null || interval <= 0) {
      $("next-sync").textContent = "Next sync —";
      ring.style.strokeDashoffset = 100;
    } else if (remaining <= 0) {
      $("next-sync").textContent = "Syncing…";
      ring.style.strokeDashoffset = 100;
    } else {
      $("next-sync").textContent = `Next sync in ${duration(remaining)}`;
      ring.style.strokeDashoffset = 100 * (1 - Math.min(1, remaining / interval));
    }

    // Summary
    $("stat-repos").textContent = repos.length;
    $("stat-sync").textContent = sync ? ago(sync.last_sync) : "never";
    $("stat-sync").title = sync ? absolute(sync.last_sync) : "";
    $("stat-push").textContent = push ? ago(push.last_push) : "never";
    $("stat-push").title = push ? absolute(push.last_push) : "";
    $("stat-interval").textContent = interval ? duration(interval) : "—";

    // Repositories
    const rows = repos
      .slice()
      .sort((a, b) => a.name.localeCompare(b.name))
      .map((r) => {
        const tr = document.createElement("tr");
        tr.append(
          cell(r.name, "name"),
          cell(ago(r.last_sync), "time", absolute(r.last_sync)),
          cell(badge(r.sync_ok)),
          cell(ago(r.last_push), "time", absolute(r.last_push)),
          cell(badge(r.push_ok)),
        );
        return tr;
      });
    $("repos").replaceChildren(...(repos.length ? rows : [emptyRow("No repositories configured")]));

    // Footer
    const parts = [data.version ? `Version ${data.version}` : null];
    if (data.started) parts.push(`up ${duration(Math.max(0, Math.round(t - data.started)))}`);
    $("meta").textContent = parts.filter(Boolean).join(" · ");
  }

  function emptyRow(text) {
    const tr = document.createElement("tr");
    const td = cell(text, "empty");
    td.colSpan = 5;
    tr.append(td);
    return tr;
  }

  function setLive(ok, text) {
    online = ok;
    $("live").className = "live " + (ok ? "ok" : "bad");
    $("live-text").textContent = text;
  }

  async function poll() {
    try {
      const res = await fetch("status.json", { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      data = await res.json();
      // status.json is only rewritten on sync/push, so take the server's clock from the response.
      const date = Date.parse(res.headers.get("Date"));
      if (!Number.isNaN(date)) clockOffset = (date - Date.now()) / 1000;
      setLive(true, "Live");
    } catch (err) {
      setLive(false, online ? "Connection lost" : "Unavailable");
    }
    render();
  }

  poll();
  setInterval(poll, POLL_MS);
  setInterval(render, 1000);
})();
