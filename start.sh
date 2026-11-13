#!/bin/sh
set -e

# ── Config ────────────────────────────────────────────────────────────────────
REPOS_CONF="${REPOS_CONF:-/etc/git-proxy/repos.conf}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
# Fetch this many repos at once in each sync.
SYNC_PARALLEL="${SYNC_PARALLEL:-4}"
# basic (default): generated tokens, printed to the log. none: no auth on the git endpoints - only
# safe when something else (e.g. a NetworkPolicy) restricts who can reach them.
GIT_PROXY_AUTH="${GIT_PROXY_AUTH:-basic}"
# Which token opens which repo: repo (one per repository), project (one per Azure DevOps project)
# or global (one for everything; set GIT_PROXY_TOKEN to supply it, e.g. from a Kubernetes Secret).
GIT_PROXY_TOKEN_SCOPE="${GIT_PROXY_TOKEN_SCOPE:-repo}"
GIT_PROXY_USER="${GIT_PROXY_USER:-git}"
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
# on (default): read-only status page at / - repo names and sync/push times, no URLs or secrets.
STATUS_PAGE="${STATUS_PAGE:-on}"

# Discovery: mirror every repository in an Azure DevOps organization or project that matches the
# filters. DISCOVERY_URL is https://dev.azure.com/<org> or https://dev.azure.com/<org>/<project>.
DISCOVERY_URL="${DISCOVERY_URL:-}"
DISCOVERY_INTERVAL="${DISCOVERY_INTERVAL:-300}"
# Comma- or space-separated patterns, matched against "<project>/<repo>". Shell globs by default;
# prefix a pattern with re: for an extended regular expression. Exclude wins over include.
DISCOVERY_INCLUDE="${DISCOVERY_INCLUDE:-*}"
DISCOVERY_EXCLUDE="${DISCOVERY_EXCLUDE:-}"
DISCOVERY_INCLUDE_FORKS="${DISCOVERY_INCLUDE_FORKS:-false}"
DISCOVERY_INCLUDE_EMPTY="${DISCOVERY_INCLUDE_EMPTY:-false}"

# A mirror whose repository disappears (no longer discovered, or removed from repos.conf) is still
# served, read-only in practice, for this many seconds, then moved to /repos/.archive. 0: never.
ARCHIVE_AFTER="${ARCHIVE_AFTER:-604800}"

# Cost control for large repos: mirror only these branches (patterns such as "main release/*"),
# and optionally no tags. Default: every ref.
MIRROR_BRANCHES="${MIRROR_BRANCHES:-}"
MIRROR_TAGS="${MIRROR_TAGS:-true}"

STATE_DIR=/tmp/state     # private: holds PATs
STATUS_DIR=/tmp/status   # public: served as /status.json, names and timestamps only
TAB=$(printf '\t')

# The proxy runs unprivileged. A /repos volume created by an older, root-running image is still
# owned by root - say how to fix that instead of failing on the first write.
# Checks OWNERSHIP inside /repos, not just writability: a volume can be world-writable at its
# root while the mirrors the old image cloned into it are root-owned, and the setup below has to
# chmod files it owns (the post-receive hook).
not_writable=""
for dir in /repos /etc/git-proxy /tmp; do
    [ -w "$dir" ] || not_writable="$dir"
done
# Only the top levels: a 1.x volume is root-owned throughout, so this finds it without walking
# every object on each start. lost+found is root-owned on any fresh ext4 volume - skip it.
[ -n "$not_writable" ] || not_writable=$(find /repos -mindepth 1 -maxdepth 3 \
    -path /repos/lost+found -prune -o ! -user "$(id -u)" -print -quit 2>/dev/null)
if [ -n "$not_writable" ]; then
    echo "[init] ERROR: $not_writable is not owned or writable by uid $(id -u). If it was created by" \
         "an older image that ran as root, fix the ownership once: chown -R $(id -u):$(id -g) /repos" \
         "(see docs/upgrading-to-v2.md)." >&2
    exit 1
fi
mkdir -p /tmp/nginx /repos/.auth /repos/.tokens /repos/.lifecycle
(umask 077; mkdir -p "$STATE_DIR")
rm -rf "$STATUS_DIR" && mkdir -p "$STATUS_DIR"

# Upstream auth. UPSTREAM_AUTH=auto (default) picks Entra when AZURE_CLIENT_ID and
# AZURE_TENANT_ID are set together with AZURE_FEDERATED_TOKEN_FILE (workload identity) or
# AZURE_CLIENT_SECRET, otherwise a PAT. Set pat or entra to stop auto-detection - e.g. on AKS,
# where the workload identity webhook injects the AZURE_* variables into any labelled pod.
ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"
ENTRA_AUTH_FILE="/etc/git-proxy/entra-auth.gitconfig"
# Authorization header for Azure DevOps REST calls (discovery). A file, so it never appears on a
# command line.
API_AUTH_HEADER="$STATE_DIR/api-auth-header"
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
echo "[init] upstream auth: $UPSTREAM_AUTH${ENTRA_CREDENTIAL:+ ($ENTRA_CREDENTIAL)}, proxy auth: $GIT_PROXY_AUTH${GIT_PROXY_AUTH:+ (token scope: $GIT_PROXY_TOKEN_SCOPE)}"

case "$GIT_PROXY_TOKEN_SCOPE" in
    repo|project|global) ;;
    *) echo "[init] ERROR: GIT_PROXY_TOKEN_SCOPE must be repo, project or global" >&2; exit 1 ;;
esac

if [ ! -s "$REPOS_CONF" ] && [ -n "$AZURE_DEVOPS_URL" ] && { [ -n "$AZURE_PAT" ] || [ "$UPSTREAM_AUTH" = entra ]; }; then
    echo "[init] No repos.conf found — building from AZURE_DEVOPS_URL env var"
    mkdir -p "$(dirname "$REPOS_CONF")"
    printf '%s  %s\n' "$AZURE_DEVOPS_URL" "${AZURE_PAT:--}" > "$REPOS_CONF"
fi
if [ ! -s "$REPOS_CONF" ] && [ -z "$DISCOVERY_URL" ]; then
    echo "[init] ERROR: nothing to mirror: no repos config at $REPOS_CONF and no DISCOVERY_URL" >&2
    echo "[init] Mount a repos.conf, set AZURE_DEVOPS_URL (plus AZURE_PAT or the Entra variables)," \
         "or set DISCOVERY_URL to mirror a whole organization or project" >&2
    exit 1
fi
if [ -n "$DISCOVERY_URL" ] && [ "$UPSTREAM_AUTH" = pat ] && [ -z "$AZURE_PAT" ]; then
    echo "[init] ERROR: DISCOVERY_URL needs AZURE_PAT (Code: Read & Write) or the Entra variables" >&2
    exit 1
fi

# ── Azure DevOps credentials ──────────────────────────────────────────────────
# Entra: exchanges the projected service account token or the client secret for an Azure DevOps
# access token and writes it as an http.extraHeader include, which every mirror's config points
# at. Refreshed by the sync loop well before expiry, so the post-receive hook always finds a valid
# one. PAT: the PAT goes into each mirror's remote URL.
TOKEN_EXPIRES_AT=0
ENTRA_TOKEN=""

# Percent-encodes every byte. Valid for application/x-www-form-urlencoded whatever the input,
# so no assumption is needed about which characters a secret contains.
urlencode() {
    printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/../%&/g'
}

# scheme://host/ of every upstream. The bearer header is scoped to these, so it is never sent to
# another remote or a redirect target.
upstream_origins() {
    {
        [ -s "$REPOS_CONF" ] && grep -v '^[[:space:]]*#' "$REPOS_CONF" | awk '{print $1}'
        [ -s "$STATE_DIR/discovered.tsv" ] && cut -f2 "$STATE_DIR/discovered.tsv"
        [ -n "$DISCOVERY_URL" ] && printf '%s\n' "$DISCOVERY_URL"
    } | sed -n 's|^\([a-z][a-z0-9+.-]*://[^/]*\).*|\1/|p' | sort -u
}

# Writes the credential files from the current token: the git include for Entra, and the header
# for REST calls. Called after a token refresh and when discovery finds a new upstream host.
write_credentials() {
    (
        umask 077
        if [ "$UPSTREAM_AUTH" = entra ]; then
            [ -n "$ENTRA_TOKEN" ] || exit 0
            for origin in $(upstream_origins); do
                printf '[http "%s"]\n\textraHeader = Authorization: Bearer %s\n' "$origin" "$ENTRA_TOKEN"
            done > "${ENTRA_AUTH_FILE}.tmp" && mv "${ENTRA_AUTH_FILE}.tmp" "$ENTRA_AUTH_FILE"
            printf 'Authorization: Bearer %s\n' "$ENTRA_TOKEN" > "$API_AUTH_HEADER"
        elif [ -n "${AZURE_PAT:-}" ]; then
            printf 'Authorization: Basic %s\n' "$(printf ':%s' "$AZURE_PAT" | base64 | tr -d '\n')" > "$API_AUTH_HEADER"
        fi
    )
}

refresh_entra_token() {
    if [ "$ENTRA_CREDENTIAL" = workload-identity ]; then
        credential="client_assertion_type=$(urlencode urn:ietf:params:oauth:client-assertion-type:jwt-bearer)&client_assertion=$(urlencode "$(cat "$AZURE_FEDERATED_TOKEN_FILE")")"
    else
        credential="client_secret=$(urlencode "$AZURE_CLIENT_SECRET")"
    fi
    # The body holds the credential, so it goes in a private file rather than on curl's command
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
    token=$(printf '%s' "$response" | jq -r '.access_token // empty')
    expires_in=$(printf '%s' "$response" | jq -r '.expires_in // 3600')
    if [ -z "$token" ]; then
        echo "[entra] ERROR: no access_token in response" >&2
        return 1
    fi
    ENTRA_TOKEN="$token"
    if ! write_credentials; then
        echo "[entra] ERROR: could not write $ENTRA_AUTH_FILE" >&2
        return 1
    fi
    TOKEN_EXPIRES_AT=$(( $(date +%s) + expires_in ))
    echo "[entra] token refreshed, expires in ${expires_in}s"
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
    # One password file per repository ($1 is the repository's URL path), so a token only opens
    # the repositories its scope covers.
    basic) GIT_AUTH_DIRECTIVES='auth_basic "Git Proxy"; auth_basic_user_file /repos/.auth$1.htpasswd;' ;;
    none)
        GIT_AUTH_DIRECTIVES=''
        echo "[init] WARNING: GIT_PROXY_AUTH=none - anyone who can reach this proxy can clone, push" \
             "and delete branches in Azure DevOps as the proxy's identity. Restrict access to it," \
             "e.g. with the NetworkPolicy in k8s/components/network-policy." >&2
        ;;
    *) echo "[init] ERROR: GIT_PROXY_AUTH must be basic or none" >&2; exit 1 ;;
esac
case "$STATUS_PAGE" in
    on)  STATUS_LOCATIONS='include /etc/nginx/git-proxy-status.conf;' ;;
    off) STATUS_LOCATIONS='' ;;
    *) echo "[init] ERROR: STATUS_PAGE must be on or off" >&2; exit 1 ;;
esac
export GIT_AUTH_DIRECTIVES HTTP_PORT HTTPS_PORT STATUS_LOCATIONS
envsubst '${GIT_HTTP_BACKEND} ${GIT_AUTH_DIRECTIVES} ${HTTP_PORT} ${HTTPS_PORT} ${STATUS_LOCATIONS}' \
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

write_credentials
ensure_entra_token

# ── Status page state (see /usr/local/bin/git-proxy-status) ──────────────────
printf 'version=%s\nstarted=%s\nsync_interval=%s\nupstream_auth=%s\ntoken_scope=%s\n' \
    "${GIT_PROXY_VERSION:-dev}" "$(date +%s)" "$SYNC_INTERVAL" "$UPSTREAM_AUTH" \
    "$( [ "$GIT_PROXY_AUTH" = basic ] && echo "$GIT_PROXY_TOKEN_SCOPE" || echo none)" > "$STATUS_DIR/meta"
printf 'enabled=%s\n' "$( [ -n "$DISCOVERY_URL" ] && echo true || echo false)" > "$STATUS_DIR/discovery"

# A repo is identified by its path under /repos without ".git": "dashboards" for repos.conf
# entries (served at /dashboards.git), "<project>/<repo>" for discovered ones. State files use
# the path with "/" replaced by "~".
key_of() { printf '%s' "$1" | tr '/' '~'; }
record() { printf '%s %s\n' "$(date +%s)" "$3" > "$STATUS_DIR/$(key_of "$1").$2"; }
# URL-safe path segment: anything but letters, digits, ".", "_" and "-" becomes "-".
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g; s/^\.*//'; }
# "<project>" from https://dev.azure.com/<org>/<project>/_git/<repo> (or *.visualstudio.com).
project_of_url() {
    printf '%s' "$1" | sed -n 's|.*/\([^/]*\)/_git/[^/]*$|\1|p' | sed 's/%20/ /g'
}

# ── Discovery ─────────────────────────────────────────────────────────────────
split_patterns() { printf '%s' "$1" | tr ',' ' '; }
# Whether "<project>/<repo>" matches any pattern; prints the pattern that matched.
match_any() {
    name="$1"; shift
    set -f
    for p in $(split_patterns "$*"); do
        case "$p" in
            re:*) printf '%s' "$name" | grep -Eq -- "${p#re:}" && { set +f; printf '%s' "$p"; return 0; } ;;
            *)
                # shellcheck disable=SC2254 # unquoted on purpose: $p is a glob
                case "$name" in $p) set +f; printf '%s' "$p"; return 0 ;; esac
                ;;
        esac
    done
    set +f
    return 1
}

DISCOVERY_NEXT=0
# Lists the repositories at DISCOVERY_URL and splits them into discovered.tsv (path, url,
# project) and skipped.tsv (name, reason). On any error the previous list is kept, so a failing
# API call never makes repositories look deleted.
discover() {
    [ -n "$DISCOVERY_URL" ] || return 0
    DISCOVERY_NEXT=$(( $(date +%s) + DISCOVERY_INTERVAL ))
    api="${DISCOVERY_URL%/}/_apis/git/repositories?api-version=7.1"
    json="$STATE_DIR/repositories.json"
    rc=0
    status=$(curl -sS --max-time 60 -H @"$API_AUTH_HEADER" -o "$json" -w '%{http_code}' "$api" 2>"$STATE_DIR/discover.err") || rc=$?
    case "$api" in file://*) [ "$rc" -eq 0 ] && status=200 ;; esac
    if [ "$rc" -ne 0 ] || [ "$status" != 200 ] || ! jq -e '.value | type == "array"' "$json" >/dev/null 2>&1; then
        case "$status" in
            401|203) reason="authentication failed (HTTP $status)" ;;
            403) reason="access denied (HTTP 403) - the identity needs Code: Read on the organization" ;;
            404) reason="organization or project not found (HTTP 404)" ;;
            000|"") reason="Azure DevOps not reachable: $(head -c 200 "$STATE_DIR/discover.err")" ;;
            *) reason="unexpected response (HTTP $status)" ;;
        esac
        echo "[discovery] ERROR: $reason - keeping the previous list" >&2
        { printf 'enabled=true\nlast_run=%s\nok=false\n' "$(date +%s)"; printf 'error=%s\n' "$reason";
          sed -n 's/^\(found\|included\)=/&/p' "$STATUS_DIR/discovery" 2>/dev/null; } > "$STATUS_DIR/discovery.tmp"
        mv "$STATUS_DIR/discovery.tmp" "$STATUS_DIR/discovery"
        return 1
    fi

    : > "$STATE_DIR/discovered.tsv.new"
    : > "$STATUS_DIR/skipped.tsv.new"
    found=0; included=0
    jq -r '.value[] | [.project.name, .name, (.webUrl // ""), (.isDisabled // false), (.isFork // false), (.size // 0), (.defaultBranch // "")] | @tsv' "$json" \
        | sort > "$STATE_DIR/repositories.tsv"
    while IFS="$TAB" read -r project repo url disabled fork size branch; do
        found=$((found + 1))
        name="$project/$repo"
        reason=""
        if [ "$disabled" = true ]; then
            reason="disabled in Azure DevOps"
        elif [ "$fork" = true ] && [ "$DISCOVERY_INCLUDE_FORKS" != true ]; then
            reason="fork (DISCOVERY_INCLUDE_FORKS=false)"
        elif [ -z "$branch" ] && [ "$size" = 0 ] && [ "$DISCOVERY_INCLUDE_EMPTY" != true ]; then
            reason="empty (DISCOVERY_INCLUDE_EMPTY=false)"
        elif p=$(match_any "$name" "$DISCOVERY_EXCLUDE"); then
            reason="excluded by \"$p\""
        elif ! match_any "$name" "$DISCOVERY_INCLUDE" >/dev/null; then
            reason="not matched by DISCOVERY_INCLUDE"
        elif [ -z "$url" ]; then
            reason="no URL in the API response"
        fi
        if [ -n "$reason" ]; then
            printf '%s\t%s\n' "$name" "$reason" >> "$STATUS_DIR/skipped.tsv.new"
            continue
        fi
        path="$(slug "$project")/$(slug "$repo")"
        if cut -f1 "$STATE_DIR/discovered.tsv.new" | grep -qxF "$path"; then
            printf '%s\t%s\n' "$name" "path /$path.git is already taken by another repository" >> "$STATUS_DIR/skipped.tsv.new"
            continue
        fi
        printf '%s\t%s\t%s\n' "$path" "$url" "$project" >> "$STATE_DIR/discovered.tsv.new"
        included=$((included + 1))
    done < "$STATE_DIR/repositories.tsv"
    mv "$STATE_DIR/discovered.tsv.new" "$STATE_DIR/discovered.tsv"
    mv "$STATUS_DIR/skipped.tsv.new" "$STATUS_DIR/skipped.tsv"
    printf 'enabled=true\nlast_run=%s\nok=true\nfound=%s\nincluded=%s\nnext_run=%s\n' \
        "$(date +%s)" "$found" "$included" "$DISCOVERY_NEXT" > "$STATUS_DIR/discovery"
    echo "[discovery] $found repositories found, $included mirrored, $((found - included)) skipped"
    # New hosts need the Entra header too.
    write_credentials
}

# ── Desired repositories ──────────────────────────────────────────────────────
# desired.tsv: path, url, pat, project, source. repos.conf entries come first and win a clash.
build_desired() {
    : > "$STATE_DIR/desired.tsv.new"
    if [ -s "$REPOS_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in '#'*|'') continue ;; esac
            url=$(printf '%s' "$line" | awk '{print $1}')
            pat=$(printf '%s' "$line" | awk '{print $2}')
            [ -z "$url" ] && continue
            # A line without its own PAT uses AZURE_PAT, so one PAT can serve several repos.
            [ "$UPSTREAM_AUTH" = pat ] && [ -z "$pat" ] && pat="${AZURE_PAT:-}"
            if [ "$UPSTREAM_AUTH" = pat ] && [ -z "$pat" ]; then
                echo "[init] WARNING: $(basename "$url"): no PAT in $REPOS_CONF and AZURE_PAT is not set - skipped" >&2
                continue
            fi
            if [ "$UPSTREAM_AUTH" = entra ] && [ -n "$pat" ] && [ "$pat" != "-" ]; then
                [ "$1" = quiet ] || echo "[init] WARNING: $(basename "$url"): ignoring the PAT in $REPOS_CONF - upstream auth is" \
                     "Entra. Set UPSTREAM_AUTH=pat to use the PAT instead." >&2
            fi
            project=$(project_of_url "$url")
            printf '%s\t%s\t%s\t%s\tstatic\n' "$(basename "$url")" "$url" "$pat" "${project:--}" >> "$STATE_DIR/desired.tsv.new"
        done < "$REPOS_CONF"
    fi
    if [ -s "$STATE_DIR/discovered.tsv" ]; then
        while IFS="$TAB" read -r path url project; do
            if cut -f1 "$STATE_DIR/desired.tsv.new" | grep -qxF "$path"; then
                continue
            fi
            printf '%s\t%s\t%s\t%s\tdiscovered\n' "$path" "$url" "${AZURE_PAT:--}" "$project" >> "$STATE_DIR/desired.tsv.new"
        done < "$STATE_DIR/discovered.tsv"
    fi
    (umask 077; mv "$STATE_DIR/desired.tsv.new" "$STATE_DIR/desired.tsv")
}

# ── Access tokens ─────────────────────────────────────────────────────────────
# Returns (prints) the token for a scope id, creating it once. Tokens persist in the volume.
token_for() {
    file="$1"
    if [ "$GIT_PROXY_TOKEN_SCOPE" = global ] && [ -n "${GIT_PROXY_TOKEN:-}" ]; then
        printf '%s' "$GIT_PROXY_TOKEN"
        return
    fi
    if [ ! -s "$file" ]; then
        (umask 077; openssl rand -hex 20 > "$file")
        NEW_TOKENS=1
    fi
    tr -d '\n' < "$file"
}

# Writes /repos/.auth/<path>.git.htpasswd with the one user that may open this repository, and
# adds a line to the credentials table.
write_auth() {
    path="$1"; project="$2"
    [ "$GIT_PROXY_AUTH" = basic ] || return 0
    case "$GIT_PROXY_TOKEN_SCOPE" in
        repo)    user="$path";            token=$(token_for "/repos/$path.git/proxy-token") ;;
        project) user="$(slug "$project")"; token=$(token_for "/repos/.tokens/project~$(slug "$project")") ;;
        global)  user="$GIT_PROXY_USER";  token=$(token_for /repos/.tokens/global) ;;
    esac
    mkdir -p "$(dirname "/repos/.auth/$path.git.htpasswd")"
    printf '%s:%s\n' "$user" "$(openssl passwd -apr1 "$token")" > "/repos/.auth/$path.git.htpasswd.tmp"
    mv "/repos/.auth/$path.git.htpasswd.tmp" "/repos/.auth/$path.git.htpasswd"
    case "$GIT_PROXY_TOKEN_SCOPE" in
        repo) printf '  %-35s  %-30s  %s\n' "$path" "$user" "$token" ;;
        *)    printf '%s\t%s\n' "$user" "$token" ;;
    esac >> "$STATE_DIR/creds.txt"
}

print_credentials() {
    [ "$GIT_PROXY_AUTH" = basic ] && [ -s "$STATE_DIR/creds.txt" ] || { rm -f "$STATE_DIR/creds.txt"; return 0; }
    echo ""
    echo "[credentials] Git credentials (token scope: $GIT_PROXY_TOKEN_SCOPE):"
    echo "[credentials] Repository URL pattern: https://<host>/<repo-path>.git"
    echo ""
    if [ "$GIT_PROXY_TOKEN_SCOPE" = repo ]; then
        printf '  %-35s  %-30s  %s\n' "REPO" "USERNAME" "ACCESS TOKEN"
        printf '  %-35s  %-30s  %s\n' "----" "--------" "------------"
        cat "$STATE_DIR/creds.txt"
    elif [ "$GIT_PROXY_TOKEN_SCOPE" = global ] && [ -n "${GIT_PROXY_TOKEN:-}" ]; then
        echo "  username: $GIT_PROXY_USER, token: from GIT_PROXY_TOKEN (not printed)"
    else
        printf '  %-35s  %s\n' "USERNAME" "ACCESS TOKEN"
        sort -u "$STATE_DIR/creds.txt" | awk -F "$TAB" '{printf "  %-35s  %s\n", $1, $2}'
    fi
    echo ""
    rm -f "$STATE_DIR/creds.txt"
}

# ── Mirrors ───────────────────────────────────────────────────────────────────
# Fetch refspecs: every ref by default; with MIRROR_BRANCHES only those branches, plus tags
# unless MIRROR_TAGS=false.
set_refspecs() {
    git config --unset-all remote.origin.fetch 2>/dev/null || true
    # Without this, git still follows tags that point at fetched commits.
    if [ "$MIRROR_TAGS" = true ]; then
        git config --unset remote.origin.tagOpt 2>/dev/null || true
    else
        git config remote.origin.tagOpt --no-tags
    fi
    if [ -z "$MIRROR_BRANCHES" ] && [ "$MIRROR_TAGS" = true ]; then
        git config --add remote.origin.fetch '+refs/*:refs/*'
        return
    fi
    if [ -z "$MIRROR_BRANCHES" ]; then
        git config --add remote.origin.fetch '+refs/heads/*:refs/heads/*'
    else
        set -f
        for b in $(split_patterns "$MIRROR_BRANCHES"); do
            git config --add remote.origin.fetch "+refs/heads/$b:refs/heads/$b"
        done
        set +f
    fi
    [ "$MIRROR_TAGS" = true ] && git config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
    return 0
}

# Creates (first time) and configures one mirror. Returns non-zero if the first fetch fails; the
# repo is then retried on the next reconcile.
setup_repo() {
    path="$1"; url="$2"; pat="$3"; project="$4"
    repo_path="/repos/$path.git"
    auth_url=$(upstream_url "$url" "$pat")
    created=""
    if [ ! -d "$repo_path" ]; then
        echo "[init] $path  ->  /$path.git  (cloning)"
        mkdir -p "$(dirname "$repo_path")"
        git init -q --bare "$repo_path"
        created=1
    fi
    (
        cd "$repo_path"
        git config core.protocolVersion 2
        git config http.receivepack true
        git config uploadpack.allowAnySHA1InWant true
        git config uploadpack.allowFilter true
        git config uploadpack.allowRefInWant true
        git config gc.auto 6700
        if git config remote.origin.url >/dev/null; then
            git remote set-url origin "$auth_url"
        else
            git remote add origin "$auth_url"
        fi
        set_refspecs
        if [ "$UPSTREAM_AUTH" = entra ]; then
            git config include.path "$ENTRA_AUTH_FILE"
        else
            git config --unset-all include.path 2>/dev/null || true
        fi
        mkdir -p hooks
        cp /usr/local/share/git-proxy/post-receive hooks/post-receive
        chmod +x hooks/post-receive
    )
    if [ -n "$created" ]; then
        if (cd "$repo_path" && git fetch -q --prune origin 2>"$STATE_DIR/clone.err"); then
            (cd "$repo_path" && git-proxy-set-head && git update-server-info)
            record "$path" sync ok
        else
            echo "[init]   $path: first fetch failed: $(sed 's#//[^/@]*@#//#g' "$STATE_DIR/clone.err" | tail -1)" >&2
            rm -rf "$repo_path"
            record "$path" sync failed
            git-proxy-sync-error "$path" < "$STATE_DIR/clone.err"
            return 1
        fi
    fi
    write_auth "$path" "$project"
}

# Brings /repos in line with desired.tsv: sets up new mirrors, (re)configures all of them when
# $1 = all, and handles repositories that are no longer wanted.
reconcile() {
    mode="$1"
    build_desired "$( [ "$mode" = all ] && echo verbose || echo quiet)"
    : > "$STATE_DIR/creds.txt"
    NEW_TOKENS=""
    now=$(date +%s)
    : > "$STATUS_DIR/repos.tsv.new"
    while IFS="$TAB" read -r path url pat project source; do
        rm -f "/repos/.lifecycle/$(key_of "$path")"
        if [ "$mode" = all ] || [ ! -d "/repos/$path.git" ]; then
            setup_repo "$path" "$url" "$pat" "$project" || true
        fi
        [ -d "/repos/$path.git" ] || [ -f "$STATUS_DIR/$(key_of "$path").sync" ] || continue
        printf '%s\t%s\t%s\t%s\tactive\t\n' "$(key_of "$path")" "$path" "$project" "$source" >> "$STATUS_DIR/repos.tsv.new"
    done < "$STATE_DIR/desired.tsv"

    # Mirrors on disk that are no longer wanted: keep serving them during the grace period, then
    # archive. Never deleted.
    find /repos -mindepth 1 -maxdepth 2 -type d -name '*.git' ! -path '/repos/.*' 2>/dev/null | sort |
    while read -r dir; do
        path="${dir#/repos/}"; path="${path%.git}"
        cut -f1 "$STATE_DIR/desired.tsv" | grep -qxF "$path" && continue
        marker="/repos/.lifecycle/$(key_of "$path")"
        [ -s "$marker" ] || { echo "$now" > "$marker"; echo "[lifecycle] $path is no longer configured or discovered - archiving it in ${ARCHIVE_AFTER}s"; }
        since=$(cat "$marker")
        if [ "$ARCHIVE_AFTER" -gt 0 ] && [ $(( now - since )) -ge "$ARCHIVE_AFTER" ]; then
            dest="/repos/.archive/$path.git.$(date -u +%Y%m%dT%H%M%SZ)"
            mkdir -p "$(dirname "$dest")"
            mv "$dir" "$dest"
            rm -f "/repos/.auth/$path.git.htpasswd" "$marker"
            echo "[lifecycle] $path archived to $dest"
            continue
        fi
        project=$(printf '%s' "$path" | sed -n 's|/.*||p')
        printf '%s\t%s\t%s\t-\torphaned\t%s\n' "$(key_of "$path")" "$path" "${project:--}" "$since" >> "$STATUS_DIR/repos.tsv.new"
    done
    mv "$STATUS_DIR/repos.tsv.new" "$STATUS_DIR/repos.tsv"
    if [ "$mode" = all ] || [ -n "$NEW_TOKENS" ]; then
        print_credentials
    else
        rm -f "$STATE_DIR/creds.txt"
    fi
}

# Fetches every active mirror, SYNC_PARALLEL at a time.
sync_all() {
    cut -f1 "$STATE_DIR/desired.tsv" | while read -r path; do
        [ -d "/repos/$path.git" ] && printf '%s\n' "$path"
    done | xargs -r -P "$SYNC_PARALLEL" -n 1 git-proxy-sync-one
}

# ── Initial reconcile ─────────────────────────────────────────────────────────
discover || true
reconcile all
REPO_COUNT=$(grep -c "${TAB}active${TAB}" "$STATUS_DIR/repos.tsv" || true)
if [ "$REPO_COUNT" -eq 0 ] && [ -z "$DISCOVERY_URL" ]; then
    echo "[init] ERROR: no valid repos found in $REPOS_CONF" >&2
    exit 1
fi

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
echo "[ready] Serving ${REPO_COUNT} repo(s) on :${HTTP_PORT} (http) and :${HTTPS_PORT} (https) — sync every ${SYNC_INTERVAL}s${DISCOVERY_URL:+, discovery every ${DISCOVERY_INTERVAL}s}"

# ── Main loop ─────────────────────────────────────────────────────────────────
# Wakes at least every 60s to keep the Entra token fresh, independently of SYNC_INTERVAL - the
# post-receive hook reads the same token, so it must never expire between fetches.
TICK=$(( SYNC_INTERVAL < 60 ? SYNC_INTERVAL : 60 ))
[ -n "$DISCOVERY_URL" ] && [ "$DISCOVERY_INTERVAL" -lt "$TICK" ] && TICK="$DISCOVERY_INTERVAL"
NEXT_SYNC=$(( $(date +%s) + SYNC_INTERVAL ))
echo "$NEXT_SYNC" > "$STATUS_DIR/next_sync"
git-proxy-status || true
while true; do
    sleep "$TICK"
    ensure_entra_token || echo "[entra] WARN: keeping the previous token" >&2
    if [ -n "$DISCOVERY_URL" ] && [ "$(date +%s)" -ge "$DISCOVERY_NEXT" ]; then
        discover || true
        reconcile changed
        git-proxy-status || true
    fi
    [ "$(date +%s)" -ge "$NEXT_SYNC" ] || continue
    NEXT_SYNC=$(( $(date +%s) + SYNC_INTERVAL ))
    echo "$NEXT_SYNC" > "$STATUS_DIR/next_sync"
    # Also advances the archive timers of repositories that went away.
    [ -n "$DISCOVERY_URL" ] || reconcile changed
    sync_all
    git-proxy-status || true
done
