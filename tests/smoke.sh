#!/bin/sh
# End-to-end smoke test: runs the image against a local bare repo standing in for Azure DevOps,
# then checks auth, a protocol v2 clone over HTTP and HTTPS, and that a push is forwarded upstream.
#
#   docker build -t git-proxy:test . && tests/smoke.sh git-proxy:test
set -eu

IMAGE="${1:-git-proxy:test}"
NAME="git-proxy-smoke-$$"
PORT="${SMOKE_HTTP_PORT:-17080}"
TLS_PORT="${SMOKE_HTTPS_PORT:-17443}"
WORK=$(mktemp -d)

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "--- container logs ---"
        docker logs "$NAME" 2>&1 | tail -50 || true
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # The upstream repo holds files from both the host user and the container (uid 10001), so
    # remove it from a root container.
    docker run --rm --user 0 -v "$WORK:/w" "$IMAGE" rm -rf /w/upstream >/dev/null 2>&1 || true
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

git_() { git -c credential.helper= -c user.name=smoke -c user.email=smoke@example.com -c init.defaultBranch=main "$@"; }

# ── Fake upstream ─────────────────────────────────────────────────────────────
mkdir -p "$WORK/upstream" "$WORK/config"
git_ init -q --bare "$WORK/upstream/demo"
git_ clone -q "$WORK/upstream/demo" "$WORK/seed" 2>/dev/null
echo hello > "$WORK/seed/README.md"
git_ -C "$WORK/seed" add README.md
git_ -C "$WORK/seed" commit -qm "seed"
git_ -C "$WORK/seed" push -q origin main
chmod -R a+rwX "$WORK/upstream"
printf 'file:///upstream/demo  unused-pat\n' > "$WORK/config/repos.conf"

# ── Start the proxy ───────────────────────────────────────────────────────────
docker run -d --name "$NAME" \
    -p "127.0.0.1:${PORT}:8080" -p "127.0.0.1:${TLS_PORT}:8443" \
    -e SYNC_INTERVAL=5 \
    -e REPOS_CONF=/config/repos.conf \
    -v "$WORK/upstream:/upstream" \
    -v "$WORK/config:/config:ro" \
    "$IMAGE" >/dev/null

i=0
until curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 60 ] && fail "proxy did not become healthy"
    sleep 1
done
pass "health endpoint"

TOKEN=$(docker logs "$NAME" 2>&1 | awk '$1 == "demo" && $2 == "demo" {print $3}' | tail -1)
[ -n "$TOKEN" ] || fail "no access token in the log"
pass "access token printed"

# ── Auth ──────────────────────────────────────────────────────────────────────
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/demo.git/info/refs?service=git-upload-pack")
[ "$code" = 401 ] || fail "no credentials: expected 401, got $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -u demo:wrong "http://127.0.0.1:${PORT}/demo.git/info/refs?service=git-upload-pack")
[ "$code" = 401 ] || fail "wrong token: expected 401, got $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "demo:${TOKEN}" "http://127.0.0.1:${PORT}/demo.git/config")
[ "$code" = 404 ] || fail "repo internals must not be served: expected 404, got $code"
pass "rejects missing/wrong credentials and non-git paths"

# ── Clone (protocol v2) over HTTP and HTTPS ───────────────────────────────────
GIT_TRACE_PACKET="$WORK/trace" git_ -c protocol.version=2 \
    clone -q "http://demo:${TOKEN}@127.0.0.1:${PORT}/demo.git" "$WORK/clone"
grep -q "version 2" "$WORK/trace" || fail "server did not speak protocol v2"
[ "$(cat "$WORK/clone/README.md")" = hello ] || fail "cloned content mismatch"
pass "clone over HTTP with protocol v2"

git_ -c http.sslVerify=false clone -q "https://demo:${TOKEN}@127.0.0.1:${TLS_PORT}/demo.git" "$WORK/clone-tls"
pass "clone over HTTPS (self-signed)"

# ── Push is forwarded upstream ────────────────────────────────────────────────
echo forwarded > "$WORK/clone/pushed.txt"
git_ -C "$WORK/clone" add pushed.txt
git_ -C "$WORK/clone" commit -qm "pushed through proxy"
git_ -C "$WORK/clone" push -q origin main
want=$(git -C "$WORK/clone" rev-parse HEAD)
got=$(git -C "$WORK/upstream/demo" -c safe.directory='*' rev-parse main)
[ "$want" = "$got" ] || fail "push not forwarded upstream ($want != $got)"
pass "push forwarded upstream"

# ── Upstream changes are synced back ──────────────────────────────────────────
git_ -C "$WORK/seed" pull -q origin main
echo upstream > "$WORK/seed/upstream.txt"
git_ -C "$WORK/seed" add upstream.txt
git_ -C "$WORK/seed" commit -qm "direct upstream commit"
git_ -C "$WORK/seed" push -q origin main
want=$(git -C "$WORK/seed" rev-parse HEAD)
i=0
until [ "$(git -C "$WORK/clone" ls-remote origin refs/heads/main | cut -f1)" = "$want" ]; do
    i=$((i + 1)); [ "$i" -ge 30 ] && fail "upstream commit not synced to the proxy"
    sleep 1
done
pass "upstream commit synced by the background loop"

echo "all smoke tests passed"
