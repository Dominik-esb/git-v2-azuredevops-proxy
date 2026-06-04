#!/bin/sh
set -e

# ── Required env vars ──────────────────────────────────────────────────────────
# AZURE_DEVOPS_URL  Full HTTPS URL to the Azure DevOps repo
#                   e.g. https://dev.azure.com/myorg/myproject/_git/myrepo
# AZURE_PAT         Personal Access Token (needs Code: Read & Write)
# REPO_NAME         Local repo name, e.g. "myrepo" or "myrepo.git"
#
# Optional:
# SYNC_INTERVAL     Seconds between background fetches from Azure (default 60)
# ──────────────────────────────────────────────────────────────────────────────

: "${AZURE_DEVOPS_URL:?AZURE_DEVOPS_URL is required}"
: "${AZURE_PAT:?AZURE_PAT is required}"
: "${REPO_NAME:?REPO_NAME is required}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"

# Normalise: ensure name ends with .git
case "$REPO_NAME" in
    *.git) ;;
    *)     REPO_NAME="${REPO_NAME}.git" ;;
esac

REPO_PATH="/repos/${REPO_NAME}"

# Embed PAT in URL for git operations (never logged after this point)
AUTH_URL=$(printf '%s' "$AZURE_DEVOPS_URL" | sed "s|https://|https://pat:${AZURE_PAT}@|")

# ── Git global config ─────────────────────────────────────────────────────────
git config --global protocol.version 2
git config --global user.email "proxy@localhost"
git config --global user.name  "Git Proxy"
git config --global safe.directory '*'

# ── Initial clone ─────────────────────────────────────────────────────────────
if [ ! -d "${REPO_PATH}" ]; then
    echo "[init] Cloning mirror from Azure DevOps..."
    git clone --mirror "$AUTH_URL" "$REPO_PATH"
    echo "[init] Clone complete"
else
    echo "[init] Repo already present at ${REPO_PATH}"
fi

# ── Per-repo config for serving ───────────────────────────────────────────────
cd "$REPO_PATH"

git config core.protocolVersion  2
git config http.receivepack       true
git config uploadpack.allowAnySHA1InWant true
git config uploadpack.allowFilter true
git config uploadpack.allowRefInWant true
git config remote.origin.url     "$AUTH_URL"

git update-server-info

# ── post-receive hook: forward pushes upstream ────────────────────────────────
mkdir -p hooks
cat > hooks/post-receive << 'HOOK'
#!/bin/sh
# Forward each pushed ref to Azure DevOps.
UPSTREAM=$(git config remote.origin.url)

echo "[proxy] Forwarding push to Azure DevOps..."

STATUS=0
while read oldrev newrev refname; do
    if [ "$newrev" = "0000000000000000000000000000000000000000" ]; then
        # Branch/tag deletion
        if git push "$UPSTREAM" ":${refname}" 2>&1; then
            echo "[proxy] Deleted ${refname} upstream"
        else
            echo "[proxy] WARN: failed to delete ${refname} upstream" >&2
            STATUS=1
        fi
    else
        if git push "$UPSTREAM" "${newrev}:${refname}" 2>&1; then
            echo "[proxy] Forwarded ${refname}"
        else
            echo "[proxy] WARN: failed to forward ${refname}" >&2
            STATUS=1
        fi
    fi
done

exit "$STATUS"
HOOK
chmod +x hooks/post-receive

echo "[init] post-receive hook installed"

# ── Locate git-http-backend and render nginx config ──────────────────────────
GIT_HTTP_BACKEND=$(command -v git-http-backend 2>/dev/null || \
                   find /usr -name git-http-backend -type f 2>/dev/null | head -1)
if [ -z "$GIT_HTTP_BACKEND" ]; then
    echo "[init] ERROR: git-http-backend not found in PATH or /usr" >&2
    exit 1
fi
echo "[init] git-http-backend: $GIT_HTTP_BACKEND"
export GIT_HTTP_BACKEND

# envsubst only replaces ${GIT_HTTP_BACKEND}; nginx vars ($1, $uri, etc.) are left alone
envsubst '${GIT_HTTP_BACKEND}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# ── Start fcgiwrap ────────────────────────────────────────────────────────────
echo "[init] Starting fcgiwrap..."
fcgiwrap -s unix:/var/run/fcgiwrap.sock &

# Wait for socket to appear
TRIES=0
until [ -S /var/run/fcgiwrap.sock ] || [ "$TRIES" -ge 10 ]; do
    sleep 0.5
    TRIES=$((TRIES + 1))
done
chmod 777 /var/run/fcgiwrap.sock 2>/dev/null || true

# ── Start nginx ───────────────────────────────────────────────────────────────
echo "[init] Starting nginx..."
nginx

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           Git Protocol v2 Proxy — ready                 ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  Upstream : %-46s ║\n" "$AZURE_DEVOPS_URL"
printf "║  Local    : http://localhost/%-33s ║\n" "$REPO_NAME"
printf "║  Sync     : every %-43s ║\n" "${SYNC_INTERVAL}s"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Clone:  git clone http://localhost/${REPO_NAME}         "
echo "║  Force v2: git -c protocol.version=2 clone ...          ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Background sync loop ──────────────────────────────────────────────────────
while true; do
    sleep "$SYNC_INTERVAL"

    cd "$REPO_PATH"
    git remote set-url origin "$AUTH_URL"

    echo "[sync] Fetching from Azure DevOps..."
    if git fetch --prune origin '+refs/*:refs/*' 2>&1; then
        git update-server-info
        echo "[sync] OK"
    else
        echo "[sync] Fetch failed — will retry in ${SYNC_INTERVAL}s"
    fi
done
