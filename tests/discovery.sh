#!/bin/sh
# Discovery end-to-end test: serves a fake Azure DevOps "list repositories" response from a file
# (DISCOVERY_URL=file://...) and checks filters, skip reasons, project paths, the global token,
# branch-limited mirrors, push forwarding, runtime additions, archiving, and that a failing API
# never orphans anything.
#
#   docker build -t git-proxy:test . && tests/discovery.sh git-proxy:test
set -eu

IMAGE="${1:-git-proxy:test}"
NAME="git-proxy-discovery-$$"
PORT="${SMOKE_HTTP_PORT:-17081}"
WORK=$(mktemp -d)
TOKEN=discovery-test-token

export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}" no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}"

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "--- container logs ---"
        docker logs "$NAME" 2>&1 | tail -60 || true
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run --rm --user 0 -v "$WORK:/w" "$IMAGE" rm -rf /w/upstream /w/fixtures >/dev/null 2>&1 || true
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
git_() { git -c http.proxy= -c credential.helper= -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
status() { curl -fsS "http://127.0.0.1:${PORT}/status.json"; }
wait_for() { # <description> <command...>
    what="$1"; shift
    i=0
    until "$@" >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -ge 40 ] && fail "timed out waiting for: $what"
        sleep 1
    done
}

# ── Fake upstream repositories ────────────────────────────────────────────────
mkrepo() { # <project> <repo> [extra branch]
    git_ init -q --bare "$WORK/upstream/$1/$2"
    git_ clone -q "$WORK/upstream/$1/$2" "$WORK/seed" 2>/dev/null
    echo "$1/$2" > "$WORK/seed/README.md"
    git_ -C "$WORK/seed" add README.md
    git_ -C "$WORK/seed" commit -qm init
    git_ -C "$WORK/seed" tag v1
    git_ -C "$WORK/seed" push -q --tags origin main
    if [ -n "${3:-}" ]; then
        git_ -C "$WORK/seed" checkout -qb "$3"
        git_ -C "$WORK/seed" push -q origin "$3"
    fi
    rm -rf "$WORK/seed"
}
mkdir -p "$WORK/upstream" "$WORK/fixtures/org/_apis/git" "$WORK/config"
mkrepo Alpha dashboards feature/x
mkrepo Alpha alerts
mkrepo "Beta Team" dashboards
mkrepo Gamma secret-stuff
mkrepo static legacy
chmod -R a+rwX "$WORK/upstream"

# entry <project> <repo> [disabled] [fork] [size]
entry() {
    printf '{"name":"%s","project":{"name":"%s"},"webUrl":"file:///upstream/%s/%s","isDisabled":%s,"isFork":%s,"size":%s,"defaultBranch":%s}' \
        "$2" "$1" "$1" "$2" "${3:-false}" "${4:-false}" "${5:-1024}" \
        "$( [ "${5:-1024}" = 0 ] && echo null || echo '"refs/heads/main"')"
}
api() { printf '{"count":0,"value":[%s]}\n' "$(IFS=,; echo "$*")" > "$WORK/fixtures/org/_apis/git/repositories"; }
api "$(entry Alpha dashboards)" "$(entry Alpha alerts)" "$(entry 'Beta Team' dashboards)" \
    "$(entry Beta old true)" "$(entry Beta forky false true)" "$(entry Beta empty false false 0)" \
    "$(entry Gamma secret-stuff)"
chmod -R a+rX "$WORK/fixtures"
printf 'file:///upstream/static/legacy\n' > "$WORK/config/repos.conf"

# ── Start the proxy ───────────────────────────────────────────────────────────
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:8080" \
    -e REPOS_CONF=/config/repos.conf \
    -e DISCOVERY_URL=file:///fixtures/org \
    -e DISCOVERY_EXCLUDE='re:secret' \
    -e DISCOVERY_INTERVAL=3 -e SYNC_INTERVAL=3 -e ARCHIVE_AFTER=6 \
    -e AZURE_PAT=not-used-for-file-urls \
    -e GIT_PROXY_TOKEN_SCOPE=global -e GIT_PROXY_TOKEN="$TOKEN" \
    -e MIRROR_BRANCHES=main -e MIRROR_TAGS=false \
    -v "$WORK/upstream:/upstream" -v "$WORK/fixtures:/fixtures:ro" -v "$WORK/config:/config:ro" \
    "$IMAGE" >/dev/null
wait_for "health" curl -fsS "http://127.0.0.1:${PORT}/health"
pass "started"

# ── Filters and skip reasons ──────────────────────────────────────────────────
s=$(status)
mirrored=$(printf '%s' "$s" | jq -r '[.repos[] | select(.state == "active") | .name] | sort | join(",")')
[ "$mirrored" = "Alpha/alerts,Alpha/dashboards,Beta-Team/dashboards,legacy" ] || fail "mirrored: $mirrored"
pass "discovered and static repos mirrored, project paths slugged ($mirrored)"
for want in "Beta/old=disabled in Azure DevOps" "Beta/forky=fork" "Beta/empty=empty" 'Gamma/secret-stuff=excluded by "re:secret"'; do
    printf '%s' "$s" | jq -e --arg n "${want%%=*}" --arg r "${want#*=}" \
        '.skipped[] | select(.name == $n and (.reason | startswith($r)))' >/dev/null || fail "skip reason for $want: $s"
done
pass "skipped: disabled, fork, empty, excluded by regex"
printf '%s' "$s" | grep -q 'not-used-for-file-urls\|file://' && fail "status.json leaks a URL or PAT"
pass "status.json has no URLs or credentials"

# ── Global token, project paths, branch filter ────────────────────────────────
code=$(curl -s -o /dev/null -w '%{http_code}' -u "git:wrong" "http://127.0.0.1:${PORT}/Alpha/dashboards.git/info/refs?service=git-upload-pack")
[ "$code" = 401 ] || fail "wrong token: expected 401, got $code"
for path in Alpha/dashboards Beta-Team/dashboards legacy; do
    git_ clone -q "http://git:${TOKEN}@127.0.0.1:${PORT}/$path.git" "$WORK/clone-$(echo "$path" | tr / _)"
done
[ "$(cat "$WORK/clone-Alpha_dashboards/README.md")" = "Alpha/dashboards" ] || fail "wrong content in Alpha/dashboards"
pass "global token from GIT_PROXY_TOKEN opens discovered and static repos"
refs=$(git_ ls-remote "http://git:${TOKEN}@127.0.0.1:${PORT}/Alpha/dashboards.git" | cut -f2 | sort | tr '\n' ' ')
[ "$refs" = "HEAD refs/heads/main " ] || fail "MIRROR_BRANCHES=main, MIRROR_TAGS=false: got $refs"
pass "MIRROR_BRANCHES/MIRROR_TAGS: only main mirrored, no feature branch, no tags"
for p in .auth/Alpha/dashboards.git.htpasswd .tokens/global .archive; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "git:${TOKEN}" "http://127.0.0.1:${PORT}/$p")
    [ "$code" = 404 ] || fail "/$p must not be served, got $code"
done
pass "internal directories are not served"

# ── Push through a discovered repo ────────────────────────────────────────────
echo pushed > "$WORK/clone-Alpha_dashboards/pushed.txt"
git_ -C "$WORK/clone-Alpha_dashboards" add pushed.txt
git_ -C "$WORK/clone-Alpha_dashboards" commit -qm push
git_ -C "$WORK/clone-Alpha_dashboards" push -q origin main
[ "$(git -C "$WORK/upstream/Alpha/dashboards" -c safe.directory='*' rev-parse main)" = \
  "$(git -C "$WORK/clone-Alpha_dashboards" rev-parse HEAD)" ] || fail "push not forwarded"
pass "push to a discovered repo forwarded upstream"

# ── A repo appears; another disappears and is archived ────────────────────────
mkrepo Alpha new-one
# Only the new repo: the container (uid 10001) owns objects it pushed into the others, and on
# Linux this user cannot chmod those.
chmod -R a+rwX "$WORK/upstream/Alpha/new-one"
api "$(entry Alpha dashboards)" "$(entry Alpha new-one)" "$(entry 'Beta Team' dashboards)" \
    "$(entry Beta old true)" "$(entry Beta forky false true)" "$(entry Beta empty false false 0)" \
    "$(entry Gamma secret-stuff)"
wait_for "Alpha/new-one discovered" git_ ls-remote "http://git:${TOKEN}@127.0.0.1:${PORT}/Alpha/new-one.git"
pass "a repository created in Azure DevOps is picked up at runtime"
wait_for "Alpha/alerts orphaned" sh -c "curl -fsS http://127.0.0.1:${PORT}/status.json | jq -e '.repos[] | select(.name == \"Alpha/alerts\" and .state == \"orphaned\")'"
pass "a repository that went away is marked orphaned (still served during the grace period)"
wait_for "Alpha/alerts archived" sh -c "! curl -fsS http://127.0.0.1:${PORT}/status.json | jq -e '.repos[] | select(.name == \"Alpha/alerts\")'"
docker exec "$NAME" sh -c 'ls -d /repos/.archive/Alpha/alerts.git.*' >/dev/null || fail "Alpha/alerts not in /repos/.archive"
pass "after ARCHIVE_AFTER it is moved to /repos/.archive, not deleted"

# ── A failing API must not orphan anything ────────────────────────────────────
echo 'not json' > "$WORK/fixtures/org/_apis/git/repositories"
wait_for "discovery error reported" sh -c "curl -fsS http://127.0.0.1:${PORT}/status.json | jq -e '.discovery.ok == false'"
sleep 4
orphaned=$(status | jq '[.repos[] | select(.state == "orphaned")] | length')
[ "$orphaned" = 0 ] || fail "a failed discovery orphaned $orphaned repositories"
pass "a failed discovery keeps the previous list"

echo "all discovery tests passed"
