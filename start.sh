#!/bin/sh
set -e

# ── Config ────────────────────────────────────────────────────────────────────
REPOS_CONF="${REPOS_CONF:-/etc/git-proxy/repos.conf}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
# basic (default): per-repo generated token, printed to the log. none: no auth on the git
# endpoints - only safe when something else (e.g. a NetworkPolicy) restricts who can reach them.
GIT_PROXY_AUTH="${GIT_PROXY_AUTH:-basic}"
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-8443}"

# The proxy runs unprivileged. A /repos volume created by an older, root-running image is still
# owned by root - say how to fix that instead of failing on the first write.
# Checks OWNERSHIP inside /repos, not just writability: a volume can be world-writable at its
# root while the mirrors the old image cloned into it are root-owned, and the setup below has to
# chmod files it owns (the post-receive hook).
not_writable=""
for dir in /repos /etc/git-proxy /tmp; do
    [ -w "$dir" ] || not_writable="$dir"
done
[ -n "$not_writable" ] || not_writable=$(find /repos -mindepth 1 ! -user "$(id -u)" -print -quit 2>/dev/null)
if [ -n "$not_writable" ]; then
    echo "[init] ERROR: $not_writable is not owned or writable by uid $(id -u). If it was created by" \
         "an older image that ran as root, fix the ownership once: chown -R $(id -u):$(id -g) /repos" \
         "(see \"Upgrading\" in the README)." >&2
    exit 1
fi
mkdir -p /tmp/nginx

# Upstream auth. UPSTREAM_AUTH=auto (default) picks Entra when AZURE_CLIENT_ID and
# AZURE_TENANT_ID are set together with AZURE_FEDERATED_TOKEN_FILE (workload identity) or
# AZURE_CLIENT_SECRET, otherwise a PAT. Set pat or entra to stop auto-detection - e.g. on AKS,
# where the workload identity webhook injects the AZURE_* variables into any labelled pod.
ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"
ENTRA_AUTH_FILE="/etc/git-proxy/entra-auth.gitconfig"
UPSTREAM_AUTH="${UPSTREAM_AUTH:-auto}"
AZURE_AUTHORITY_HOST="${AZURE_AUTHORITY_HOST:-https://login.microsoftonline.com/}"

ENTRA_CREDENTIAL=""
if [ -n "$AZURE_CLIENT_ID" ] && [ -n "$AZURE_TENANT_ID" ]; then
    if [ -n "$AZURE_FEDERATED_TOKEN_FILE" ]; then
        ENTRA_CREDENTIAL=workload-identity
    elif [ -n "$AZURE_CLIENT_SECRET" ]; then
        ENTRA_CREDENTIAL=client-secret
    fi
fi

case "$UPSTREAM_AUTH" in
    auto)
        if [ -n "$ENTRA_CREDENTIAL" ]; then
            UPSTREAM_AUTH=entra
        else
            UPSTREAM_AUTH=pat
            if [ -n "$AZURE_CLIENT_ID$AZURE_TENANT_ID$AZURE_FEDERATED_TOKEN_FILE$AZURE_CLIENT_SECRET" ]; then
                echo "[init] WARNING: Entra variables are only partly set - Entra needs AZURE_CLIENT_ID," \
                     "AZURE_TENANT_ID and one of AZURE_FEDERATED_TOKEN_FILE or AZURE_CLIENT_SECRET." \
                     "Falling back to PAT." >&2
            fi
        fi
        ;;
    entra)
        if [ -z "$ENTRA_CREDENTIAL" ]; then
            echo "[init] ERROR: UPSTREAM_AUTH=entra needs AZURE_CLIENT_ID, AZURE_TENANT_ID and one of" \
                 "AZURE_FEDERATED_TOKEN_FILE or AZURE_CLIENT_SECRET" >&2
            exit 1
        fi
        ;;
    pat)
        ENTRA_CREDENTIAL=""
        ;;
    *)
        echo "[init] ERROR: UPSTREAM_AUTH must be auto, pat or entra" >&2
        exit 1
        ;;
esac
echo "[init] upstream auth: $UPSTREAM_AUTH${ENTRA_CREDENTIAL:+ ($ENTRA_CREDENTIAL)}, proxy auth: $GIT_PROXY_AUTH"

if [ ! -s "$REPOS_CONF" ]; then
    if [ -n "$AZURE_DEVOPS_URL" ] && { [ -n "$AZURE_PAT" ] || [ "$UPSTREAM_AUTH" = entra ]; }; then
        echo "[init] No repos.conf found — building from AZURE_DEVOPS_URL env var"
        mkdir -p "$(dirname "$REPOS_CONF")"
        printf '%s  %s\n' "$AZURE_DEVOPS_URL" "${AZURE_PAT:--}" > "$REPOS_CONF"
    else
        echo "[init] ERROR: repos config not found at $REPOS_CONF" >&2
        echo "[init] Mount a repos.conf, or set AZURE_DEVOPS_URL plus AZURE_PAT or the Entra variables" >&2
        exit 1
    fi
fi

# ── Entra token ───────────────────────────────────────────────────────────────
# Exchanges the projected service account token or the client secret for an Azure DevOps
# access token and writes it as an http.extraHeader include, which every mirror's config points at.
# Refreshed by the sync loop well before expiry, so the post-receive hook always finds a valid one.
TOKEN_EXPIRES_AT=0

# Percent-encodes every byte. Valid for application/x-www-form-urlencoded whatever the input,
# so no assumption is needed about which characters a secret contains.
urlencode() {
    printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/../%&/g'
}

# scheme://host/ of every repo in repos.conf. The bearer header is scoped to these, so it is never
# sent to another remote or a redirect target.
upstream_origins() {
    grep -v '^[[:space:]]*#' "$REPOS_CONF" | awk '{print $1}' \
        | sed -n 's|^\([a-z][a-z0-9+.-]*://[^/]*\).*|\1/|p' | sort -u
}

refresh_entra_token() {
    if [ "$ENTRA_CREDENTIAL" = workload-identity ]; then
        credential="client_assertion_type=$(urlencode urn:ietf:params:oauth:client-assertion-type:jwt-bearer)&client_assertion=$(urlencode "$(cat "$AZURE_FEDERATED_TOKEN_FILE")")"
    else
        credential="client_secret=$(urlencode "$AZURE_CLIENT_SECRET")"
    fi
    # The body holds the credential, so it goes in a private file rather than on wget's command
    # line, where any process in the container could read it from /proc/<pid>/cmdline.
    body=$(umask 077; mktemp)
    printf 'client_id=%s&scope=%s&grant_type=client_credentials&%s' \
        "$(urlencode "$AZURE_CLIENT_ID")" "$(urlencode "${ADO_RESOURCE}/.default")" "$credential" > "$body"
    unset credential
    # curl rather than wget: wget drops the response body on a 401, which is exactly where Entra
    # explains a wrong or expired secret (AADSTS7000215, AADSTS7000222, ...).
    rc=0
    response=$(curl -sS --max-time 30 --data-binary @"$body" \
        -H 'Content-Type: application/x-www-form-urlencoded' -w '\n%{http_code}' \
        "${AZURE_AUTHORITY_HOST%/}/${AZURE_TENANT_ID}/oauth2/v2.0/token" 2>&1) || rc=$?
    rm -f "$body"
    status=$(printf '%s' "$response" | tail -n 1)
    response=$(printf '%s' "$response" | sed '$d')
    if [ "$rc" -ne 0 ] || [ "$status" != 200 ]; then
        echo "[entra] ERROR: token request failed (curl exit $rc, HTTP ${status:-none}): $response" >&2
        return 1
    fi
    token=$(printf '%s' "$response" | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')
    expires_in=$(printf '%s' "$response" | sed -n 's/.*"expires_in" *: *\([0-9]*\).*/\1/p')
    if [ -z "$token" ]; then
        echo "[entra] ERROR: no access_token in response" >&2
        return 1
    fi
    if ! (
        umask 077
        trap 'rm -f "${ENTRA_AUTH_FILE}.tmp"' EXIT
        for origin in $(upstream_origins); do
            printf '[http "%s"]\n\textraHeader = Authorization: Bearer %s\n' "$origin" "$token"
        done > "${ENTRA_AUTH_FILE}.tmp"
        mv "${ENTRA_AUTH_FILE}.tmp" "$ENTRA_AUTH_FILE"
    ); then
        echo "[entra] ERROR: could not write $ENTRA_AUTH_FILE" >&2
        return 1
    fi
    TOKEN_EXPIRES_AT=$(( $(date +%s) + ${expires_in:-3600} ))
    echo "[entra] token refreshed, expires in ${expires_in:-3600}s"
}

# Refresh when less than 15 minutes remain.
ensure_entra_token() {
    [ "$UPSTREAM_AUTH" = entra ] || return 0
    if [ $(( TOKEN_EXPIRES_AT - $(date +%s) )) -lt 900 ]; then
        refresh_entra_token
    fi
}

upstream_url() {
    if [ "$UPSTREAM_AUTH" = entra ]; then
        printf '%s' "$1"
    else
        printf '%s' "$1" | sed "s|https://|https://pat:${2}@|"
    fi
}

# ── Locate git-http-backend and render nginx config ───────────────────────────
GIT_HTTP_BACKEND=$(command -v git-http-backend 2>/dev/null || \
                   find /usr -name git-http-backend -type f 2>/dev/null | head -1)
if [ -z "$GIT_HTTP_BACKEND" ]; then
    echo "[init] ERROR: git-http-backend not found" >&2
    exit 1
fi
echo "[init] git-http-backend: $GIT_HTTP_BACKEND"
export GIT_HTTP_BACKEND
case "$GIT_PROXY_AUTH" in
    basic) GIT_AUTH_DIRECTIVES='auth_basic "Git Proxy"; auth_basic_user_file /repos/.htpasswd;' ;;
    none)
        GIT_AUTH_DIRECTIVES=''
        echo "[init] WARNING: GIT_PROXY_AUTH=none - anyone who can reach this proxy can clone, push" \
             "and delete branches in Azure DevOps as the proxy's identity. Restrict access to it," \
             "e.g. with the NetworkPolicy in k8s/components/network-policy." >&2
        ;;
    *) echo "[init] ERROR: GIT_PROXY_AUTH must be basic or none" >&2; exit 1 ;;
esac
export GIT_AUTH_DIRECTIVES HTTP_PORT HTTPS_PORT
envsubst '${GIT_HTTP_BACKEND} ${GIT_AUTH_DIRECTIVES} ${HTTP_PORT} ${HTTPS_PORT}' \
    < /etc/nginx/nginx.conf.template \
    > /tmp/nginx/nginx.conf

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

ensure_entra_token

# ── Helper: setup one repo ────────────────────────────────────────────────────
setup_repo() {
    url="$1"
    pat="$2"
    repo_name=$(basename "$url")
    local_name="${repo_name}.git"
    repo_path="/repos/${local_name}"
    auth_url=$(upstream_url "$url" "$pat")

    echo "[init] $repo_name  ->  /${local_name}"

    if [ ! -d "$repo_path" ]; then
        echo "[init]   cloning..."
        if [ "$UPSTREAM_AUTH" = entra ]; then
            git -c "include.path=$ENTRA_AUTH_FILE" clone --mirror "$auth_url" "$repo_path"
        else
            git clone --mirror "$auth_url" "$repo_path"
        fi
    fi

    cd "$repo_path"
    git config core.protocolVersion 2
    git config http.receivepack true
    git config uploadpack.allowAnySHA1InWant true
    git config uploadpack.allowFilter true
    git config uploadpack.allowRefInWant true
    git remote set-url origin "$auth_url"
    if [ "$UPSTREAM_AUTH" = entra ]; then
        git config include.path "$ENTRA_AUTH_FILE"
    else
        git config --unset-all include.path 2>/dev/null || true
    fi
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

    if [ "$GIT_PROXY_AUTH" = basic ]; then
        # ── Per-repo access token (persists in the git-repos volume) ──────────
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
    fi

    echo "[init]   ready"
}

# ── Process repos.conf ────────────────────────────────────────────────────────
: > /repos/.htpasswd.tmp
printf '  %-35s  %-30s  %s\n' "REPO" "USERNAME" "ACCESS TOKEN" > /tmp/creds.txt
printf '  %-35s  %-30s  %s\n' "----" "--------" "------------" >> /tmp/creds.txt

REPO_COUNT=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '#'*|'') continue ;; esac
    url=$(printf '%s' "$line" | awk '{print $1}')
    pat=$(printf '%s' "$line" | awk '{print $2}')
    [ -z "$url" ] && continue
    [ "$UPSTREAM_AUTH" = pat ] && [ -z "$pat" ] && continue
    if [ "$UPSTREAM_AUTH" = entra ] && [ -n "$pat" ] && [ "$pat" != "-" ]; then
        echo "[init] WARNING: $(basename "$url"): ignoring the PAT in $REPOS_CONF - upstream auth is" \
             "Entra. Set UPSTREAM_AUTH=pat to use the PAT instead." >&2
    fi
    setup_repo "$url" "$pat"
    REPO_COUNT=$((REPO_COUNT + 1))
done < "$REPOS_CONF"

if [ "$REPO_COUNT" -eq 0 ]; then
    echo "[init] ERROR: no valid repos found in $REPOS_CONF" >&2
    exit 1
fi

mv /repos/.htpasswd.tmp /repos/.htpasswd
chmod 644 /repos/.htpasswd

if [ "$GIT_PROXY_AUTH" = basic ]; then
    echo ""
    echo "[credentials] Grafana Git provisioning credentials:"
    echo "[credentials] Repository URL pattern: https://<host>/<repo-name>.git"
    echo ""
    cat /tmp/creds.txt
    echo ""
fi
rm -f /tmp/creds.txt

# ── Start fcgiwrap ────────────────────────────────────────────────────────────
echo "[init] Starting fcgiwrap..."
# A container restart keeps /tmp when it is a volume, and a stale socket would block the bind.
rm -f /tmp/fcgiwrap.sock
fcgiwrap -s unix:/tmp/fcgiwrap.sock &
TRIES=0
until [ -S /tmp/fcgiwrap.sock ] || [ "$TRIES" -ge 20 ]; do
    sleep 0.5; TRIES=$((TRIES + 1))
done

# ── Start nginx ───────────────────────────────────────────────────────────────
echo "[init] Starting nginx..."
# -e: never try the compiled-in /var/log/nginx/error.log, which is not writable here.
nginx -e /dev/stderr -c /tmp/nginx/nginx.conf

echo ""
echo "[ready] Serving ${REPO_COUNT} repo(s) on :${HTTP_PORT} (http) and :${HTTPS_PORT} (https) — sync every ${SYNC_INTERVAL}s"

# ── Sync loop (all repos, every SYNC_INTERVAL seconds) ───────────────────────
# Wakes at least every 60s to keep the Entra token fresh, independently of SYNC_INTERVAL - the
# post-receive hook reads the same token, so it must never expire between fetches.
TICK=$(( SYNC_INTERVAL < 60 ? SYNC_INTERVAL : 60 ))
NEXT_SYNC=$(( $(date +%s) + SYNC_INTERVAL ))
while true; do
    sleep "$TICK"
    ensure_entra_token || echo "[entra] WARN: keeping the previous token" >&2
    [ "$(date +%s)" -ge "$NEXT_SYNC" ] || continue
    NEXT_SYNC=$(( $(date +%s) + SYNC_INTERVAL ))

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '#'*|'') continue ;; esac
        url=$(printf '%s' "$line" | awk '{print $1}')
        pat=$(printf '%s' "$line" | awk '{print $2}')
        [ -z "$url" ] && continue
        [ "$UPSTREAM_AUTH" = pat ] && [ -z "$pat" ] && continue

        repo_name=$(basename "$url")
        repo_path="/repos/${repo_name}.git"
        auth_url=$(upstream_url "$url" "$pat")

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
