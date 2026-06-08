#!/bin/sh
set -e

# ── Config ────────────────────────────────────────────────────────────────────
REPOS_CONF="${REPOS_CONF:-/etc/git-proxy/repos.conf}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"

if [ ! -s "$REPOS_CONF" ]; then
    if [ -n "$AZURE_DEVOPS_URL" ] && [ -n "$AZURE_PAT" ]; then
        echo "[init] No repos.conf found — building from AZURE_DEVOPS_URL + AZURE_PAT env vars"
        mkdir -p "$(dirname "$REPOS_CONF")"
        printf '%s  %s\n' "$AZURE_DEVOPS_URL" "$AZURE_PAT" > "$REPOS_CONF"
    else
        echo "[init] ERROR: repos config not found at $REPOS_CONF" >&2
        echo "[init] Mount a repos.conf or set AZURE_DEVOPS_URL + AZURE_PAT env vars" >&2
        exit 1
    fi
fi

# ── Locate git-http-backend and render nginx config ───────────────────────────
GIT_HTTP_BACKEND=$(command -v git-http-backend 2>/dev/null || \
                   find /usr -name git-http-backend -type f 2>/dev/null | head -1)
if [ -z "$GIT_HTTP_BACKEND" ]; then
    echo "[init] ERROR: git-http-backend not found" >&2
    exit 1
fi
echo "[init] git-http-backend: $GIT_HTTP_BACKEND"
export GIT_HTTP_BACKEND
envsubst '${GIT_HTTP_BACKEND}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# ── TLS certificate ───────────────────────────────────────────────────────────
TLS_DIR="/etc/git-proxy/tls"
mkdir -p "$TLS_DIR"
if [ ! -f "$TLS_DIR/tls.crt" ] || [ ! -f "$TLS_DIR/tls.key" ]; then
    echo "[init] No TLS cert found — generating self-signed certificate..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$TLS_DIR/tls.key" \
        -out    "$TLS_DIR/tls.crt" \
        -subj   "/CN=git-proxy/O=git-proxy" \
        -addext "subjectAltName=DNS:git-proxy,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    echo "[init] Self-signed cert generated (valid 10 years)"
    echo "[init] To use a real cert, mount tls.crt + tls.key to $TLS_DIR"
else
    echo "[init] TLS cert found at $TLS_DIR"
fi

# ── Git global config ─────────────────────────────────────────────────────────
git config --global protocol.version 2
git config --global user.email "proxy@localhost"
git config --global user.name  "Git Proxy"
git config --global safe.directory '*'

# ── Helper: setup one repo ────────────────────────────────────────────────────
setup_repo() {
    url="$1"
    pat="$2"
    repo_name=$(basename "$url")
    local_name="${repo_name}.git"
    repo_path="/repos/${local_name}"
    auth_url=$(printf '%s' "$url" | sed "s|https://|https://pat:${pat}@|")

    echo "[init] $repo_name  ->  /${local_name}"

    if [ ! -d "$repo_path" ]; then
        echo "[init]   cloning..."
        git clone --mirror "$auth_url" "$repo_path"
    fi

    cd "$repo_path"
    git config core.protocolVersion 2
    git config http.receivepack true
    git config uploadpack.allowAnySHA1InWant true
    git config uploadpack.allowFilter true
    git config uploadpack.allowRefInWant true
    git remote set-url origin "$auth_url"
    git update-server-info

    mkdir -p hooks
    cat > hooks/post-receive << 'HOOK'
#!/bin/sh
UPSTREAM=$(git config remote.origin.url)
echo "[proxy] Forwarding push to upstream..."
STATUS=0
while read oldrev newrev refname; do
    if [ "$newrev" = "0000000000000000000000000000000000000000" ]; then
        git push "$UPSTREAM" ":${refname}" 2>&1 \
            && echo "[proxy] Deleted   ${refname}" \
            || { echo "[proxy] WARN: failed to delete ${refname}" >&2; STATUS=1; }
    else
        git push "$UPSTREAM" "${newrev}:${refname}" 2>&1 \
            && echo "[proxy] Forwarded ${refname}" \
            || { echo "[proxy] WARN: failed to forward ${refname}" >&2; STATUS=1; }
    fi
done
exit "$STATUS"
HOOK
    chmod +x hooks/post-receive

    # ── Per-repo access token (persists in the git-repos volume) ──────────────
    TOKEN_FILE="${repo_path}/proxy-token"
    if [ ! -f "$TOKEN_FILE" ]; then
        TOKEN=$(openssl rand -hex 20)
        printf '%s' "$TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        echo "[init]   token generated"
    else
        TOKEN=$(cat "$TOKEN_FILE")
        echo "[init]   token loaded"
    fi
    HASHED=$(openssl passwd -apr1 "$TOKEN")
    printf '%s:%s\n' "$repo_name" "$HASHED" >> /repos/.htpasswd.tmp
    printf '  %-35s  %-30s  %s\n' "$repo_name" "$repo_name" "$TOKEN" >> /tmp/creds.txt

    echo "[init]   ready"
}

# ── Process repos.conf ────────────────────────────────────────────────────────
# Reset temp files for this run
: > /repos/.htpasswd.tmp
printf '  %-35s  %-30s  %s\n' "REPO" "USERNAME" "ACCESS TOKEN" > /tmp/creds.txt
printf '  %-35s  %-30s  %s\n' "----" "--------" "------------" >> /tmp/creds.txt

REPO_COUNT=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '#'*|'') continue ;; esac
    url=$(printf '%s' "$line" | awk '{print $1}')
    pat=$(printf '%s' "$line" | awk '{print $2}')
    [ -z "$url" ] || [ -z "$pat" ] && continue
    setup_repo "$url" "$pat"
    REPO_COUNT=$((REPO_COUNT + 1))
done < "$REPOS_CONF"

if [ "$REPO_COUNT" -eq 0 ]; then
    echo "[init] ERROR: no valid repos found in $REPOS_CONF" >&2
    exit 1
fi

mv /repos/.htpasswd.tmp /repos/.htpasswd
chmod 644 /repos/.htpasswd

echo ""
echo "[credentials] Grafana Git provisioning credentials:"
echo "[credentials] Repository URL pattern: https://<host>/<repo-name>.git"
echo ""
cat /tmp/creds.txt
echo ""

# ── Start fcgiwrap ────────────────────────────────────────────────────────────
echo "[init] Starting fcgiwrap..."
fcgiwrap -s unix:/var/run/fcgiwrap.sock &
TRIES=0
until [ -S /var/run/fcgiwrap.sock ] || [ "$TRIES" -ge 20 ]; do
    sleep 0.5; TRIES=$((TRIES + 1))
done
chmod 777 /var/run/fcgiwrap.sock 2>/dev/null || true

# ── Start nginx ───────────────────────────────────────────────────────────────
echo "[init] Starting nginx..."
nginx

echo ""
echo "[ready] Serving ${REPO_COUNT} repo(s) on :80 — sync every ${SYNC_INTERVAL}s"

# ── Sync loop (all repos, every SYNC_INTERVAL seconds) ───────────────────────
while true; do
    sleep "$SYNC_INTERVAL"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '#'*|'') continue ;; esac
        url=$(printf '%s' "$line" | awk '{print $1}')
        pat=$(printf '%s' "$line" | awk '{print $2}')
        [ -z "$url" ] || [ -z "$pat" ] && continue

        repo_name=$(basename "$url")
        repo_path="/repos/${repo_name}.git"
        auth_url=$(printf '%s' "$url" | sed "s|https://|https://pat:${pat}@|")

        [ -d "$repo_path" ] || continue
        cd "$repo_path"
        git remote set-url origin "$auth_url"

        if git fetch --prune origin '+refs/*:refs/*' 2>&1; then
            git update-server-info
            echo "[sync] $repo_name OK"
        else
            echo "[sync] $repo_name FAILED"
        fi
    done < "$REPOS_CONF"
done
