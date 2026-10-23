#!/usr/bin/env bash
# peer-review.sh -- preflight refusals, the ollama probe and engine choice, the decision a
# review ends in, and what each decision's ship posts. gh, curl, both review engines and
# autofix.sh are stubbed, so it costs nothing and never touches GitHub; autofix.sh's own
# behaviour is pr-review/autofix-test.sh's job.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/peer-review-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
fail=0; n=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

REV=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa      # the SHA every stub review reads
NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb      # a head pushed after it
URL=https://github.com/acme/widgets/pull/7#pullrequestreview-1

mkdir -p "$SB/bin"
cat > "$SB/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/gh"
case "$1 $2" in
  "pr view")  echo "$STUB_PRVIEW" ;;
  "api user") echo "$STUB_ME" ;;
  "repo view") echo acme/widgets ;;
  "api -X")   # a review post: keep the body it read, answer with the review's URL
    while [ $# -gt 0 ]; do
      case "$1" in -F) case "$2" in body=@*) cp "${2#body=@}" "$STUB_LOG/posted-body" ;; esac ;; esac
      shift
    done
    [ "${STUB_POST_RC:-0}" = 0 ] || exit "$STUB_POST_RC"
    echo "$STUB_URL" ;;
  *) echo "gh stub: unhandled: $*" >&2; exit 64 ;;
esac
STUB
# The probe. Its config arrives on stdin (that's where the key must be); argv is logged.
cat > "$SB/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/curl"; cat >> "$STUB_LOG/curl-config"
[ "${STUB_CURL_RC:-0}" = 0 ] || exit "$STUB_CURL_RC"
printf '%s' "${STUB_CURL_CODE:-200}"
STUB
# Both engines, writing a store the way pr-review.sh does: keyed on the raw author login;
# merged.json and meta.json only when something was found; the report always.
cat > "$SB/bin/engine" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
echo "$* REFUTER=${PR_REVIEW_REFUTER:-} FINDERS=${PR_REVIEW_FINDERS:-} PRESET=${PR_REVIEW_PRESET:-}" >> "$STUB_LOG/$name"
echo "${REVIEW_SKILLS_LOCK_HELD:-none}" >> "$STUB_LOG/lock"
[ "${STUB_ENGINE_RC:-0}" = 0 ] || exit "$STUB_ENGINE_RC"
case "$name" in intense-review.sh) store="$PR_REVIEW_INTENSE_DIR" ;; *) store="$PR_REVIEW_DIR" ;; esac
d="$store/$STUB_AUTHOR/widgets/$1"; mkdir -p "$d"
case "$STUB_REVIEW" in
  clean)        printf '# PR #%s\n\nu · reviewed at head `%s`\n\n**No findings.** opus reviewed the diff.\n' "$1" "$STUB_SHA" ;;
  gaps)         printf '# PR #%s\n\nu · reviewed at head `%s`\n\n**No findings.** opus reviewed the diff.\n\n> Slices that produced nothing: c02. Those files went **unreviewed**.\n' "$1" "$STUB_SHA" ;;
  no-anthropic) printf '# PR #%s\n\nu · reviewed at head `%s`\n\n**No findings reported** by agy.\n\n> This is not a clean bill of health.\n' "$1" "$STUB_SHA" ;;
  *)            cp "$STUB_REVIEW" "$d/merged.json"
                printf '{"url":"u","headRefOid":"%s","author":{"login":"%s"}}' "$STUB_SHA" "$STUB_AUTHOR" > "$d/meta.json"
                printf '# PR #%s\n\nu · reviewed at `%s`\n%s\n' "$1" "$STUB_SHA" "${STUB_REPORT_EXTRA:-}" ;;
esac > "$d/pr$1-review.md"
STUB
cp "$SB/bin/engine" "$SB/bin/intense-review.sh"; cp "$SB/bin/engine" "$SB/bin/pr-review.sh"
cat > "$SB/bin/autofix.sh" <<'STUB'
#!/usr/bin/env bash
echo "MODE=$AUTOFIX_MODE FROZEN=$AUTOFIX_FROZEN REVIEWER=${AUTOFIX_REVIEWER:-} ARGS=$*" >> "$STUB_LOG/autofix"
if [ -n "${STUB_AUTOFIX_OUT:-}" ]; then echo "$STUB_AUTOFIX_OUT"; exit "${STUB_AUTOFIX_RC:-0}"; fi
[ "${STUB_AUTOFIX_RC:-0}" = 0 ] || exit "$STUB_AUTOFIX_RC"
case "$AUTOFIX_MODE" in
  prepare) mkdir -p "$AUTOFIX_FROZEN"; echo "$2" > "$AUTOFIX_FROZEN/sha"
           for f in fix.patch title body.md; do echo x > "$AUTOFIX_FROZEN/$f"; done
           echo IMPLEMENTER=claude-opus-5-5; echo STATUS=prepared ;;
  ship)    echo "STATUS=opened:https://github.com/acme/widgets/pull/99"
           echo "REVIEWER=requested:$AUTOFIX_REVIEWER" ;;
esac
STUB
chmod +x "$SB/bin/"*
export PATH="$SB/bin:$PATH" PEER_REVIEW_INTENSE="$SB/bin/intense-review.sh" \
       PEER_REVIEW_REGULAR="$SB/bin/pr-review.sh" PEER_REVIEW_AUTOFIX="$SB/bin/autofix.sh"
unset PEER_REVIEW_FIX_AUTHORS PR_REVIEW_INTENSE_REFUTER PR_REVIEW_FINDERS PR_REVIEW_PRESET
export REVIEW_SKILLS_CONFIG="$SB/no-config" PR_REVIEW_FIX_AUTHORS=carol REVIEW_SKILLS_LOCK_DIR="$SB/locks"
export REVIEW_SKILLS_MODELS=manual REVIEW_SKILLS_CACHE="$SB/models-cache"

finding() {  # finding <verdict> <claim>
  printf '{"claim":"%s","file":"lib/a.dart","line":3,"mechanism":"reset skips _@x_ and @override","v":{"verdict":"%s"}}' "$2" "$1"
}
merged() { printf '[%s]' "$(IFS=,; echo "$*")" > "$C/merged.json"; echo "$C/merged.json"; }
prview() {  # prview <login> <is_bot> <state> <isCrossRepository> -- the live head is $STUB_LIVE
  printf '{"url":"https://github.com/acme/widgets/pull/7","author":{"login":"%s","is_bot":%s},"headRefOid":"%s","state":"%s","isCrossRepository":%s}' \
    "$1" "$2" "$STUB_LIVE" "$3" "$4"
}
author() { export STUB_AUTHOR="$1" STUB_PRVIEW="$(prview "$1" false OPEN false)"; at; }
at() { INT="$C/intense/$STUB_AUTHOR/widgets/7"; REG="$C/regular/$STUB_AUTHOR/widgets/7"; }
setup() {
  n=$((n + 1)); C="$SB/case$n"; mkdir -p "$C/log" "$C/intense" "$C/regular"
  git init -q "$C/repo"; ROOT="$(git -C "$C/repo" rev-parse --show-toplevel)"
  export STUB_LOG="$C/log" PR_REVIEW_INTENSE_DIR="$C/intense" PR_REVIEW_DIR="$C/regular" \
         OLLAMA_API_KEY=k-secret-123 STUB_SHA="$REV" STUB_LIVE="$REV" STUB_ME=me STUB_URL="$URL" \
         STUB_REVIEW=clean STUB_REPORT_EXTRA="" STUB_ENGINE_RC=0 STUB_AUTOFIX_RC=0 STUB_AUTOFIX_OUT="" \
         STUB_CURL_RC=0 STUB_CURL_CODE=200 STUB_POST_RC=0
  author alice
}
run() { rc=0; ( cd "${CWD:-$C/repo}" && "$HERE/peer-review.sh" "$@" ) >"$C/stdout" 2>"$C/stderr" || rc=$?; }
rc_is()  { [ "$rc" = "$1" ]; }
said()   { grep -qxF -- "$1" "$C/stdout"; }
silent() { ! grep -q "^$1=" "$C/stdout"; }               # no line of that kind at all
logged() { [ -f "$C/log/$1" ] && grep -qF -- "$2" "$C/log/$1"; }
says()   { grep -qiE -- "$1" "$C/stderr"; }               # a refusal must name its reason
calls()  { if [ -f "$C/log/$1" ]; then wc -l < "$C/log/$1" | tr -d ' '; else echo 0; fi; }
posts()  { if [ -f "$C/log/gh" ]; then grep -c '^api -X POST' "$C/log/gh" || true; else echo 0; fi; }
not()    { ! "$@"; }
absent() { for p; do [ ! -e "$p" ] || return 1; done; }
decided() { [ "$(cat "$1/decision/decision")" = "$2" ]; }

echo "engine: ollama probed, intense if it answers"
setup; run 7 --no-cache
check "probe passes: exits 0"                      rc_is 0
check "  runs intense, options passed through"     logged intense-review.sh "7 --no-cache"
check "  never runs the regular review"            [ "$(calls pr-review.sh)" = 0 ]
check "  tells the engine its fix PR is ours"      logged intense-review.sh "7 --no-cache --no-fix"
check "  says so"                                  said "ENGINE=intense"
check "  probes the refuter's model, not a default" logged curl '"model":"glm-5.3-flash"'
check "  the key goes on stdin"                    logged curl-config "Bearer k-secret-123"
check "  never on argv"                            not logged curl "k-secret-123"
check "  decides in the intense store"             decided "$INT" approve

setup; export PR_REVIEW_INTENSE_REFUTER=ollama:qwen-9; run 7; unset PR_REVIEW_INTENSE_REFUTER
check "a configured refuter is the one probed"     logged curl '"model":"qwen-9"'

setup; unset OLLAMA_API_KEY; export PR_REVIEW_REFUTER=ollama:glm-5.3-flash PR_REVIEW_FINDERS="ollama:x"; run 7
unset PR_REVIEW_REFUTER PR_REVIEW_FINDERS
check "no key: exits 0"                            rc_is 0
check "  never calls curl"                         [ "$(calls curl)" = 0 ]
check "  runs the regular review"                  [ "$(calls pr-review.sh)" = 1 ]
check "  says so"                                  said "ENGINE=regular"
check "  with pr-review's own defaults, no ollama leaking in from env" \
      logged pr-review.sh "7 --no-fix REFUTER= FINDERS="
check "  decides in the regular store"             decided "$REG" approve
check "  nothing in the intense store"             [ ! -e "$INT/decision" ]

setup; export STUB_CURL_CODE=401; run 7
check "probe 401: falls back to regular"           said "ENGINE=regular"
unset STUB_CURL_CODE

setup; export PR_REVIEW_INTENSE_FINDERS=anthropic:claude-opus-5-5@max PR_REVIEW_INTENSE_REFUTER=agy:gemini-x; run 7
unset PR_REVIEW_INTENSE_FINDERS PR_REVIEW_INTENSE_REFUTER
check "an intense refuter not on ollama: intense, no probe" said "ENGINE=intense"
check "  never calls curl"                         [ "$(calls curl)" = 0 ]

setup; export PR_REVIEW_INTENSE_REFUTER=anthropic:claude-x; run 7; unset PR_REVIEW_INTENSE_REFUTER
check "an intense refuter of a finder's family: regular" said "ENGINE=regular"
check "  never calls curl"                         [ "$(calls curl)" = 0 ]

setup; unset OLLAMA_API_KEY; export PR_REVIEW_PRESET=intense; run 7; unset PR_REVIEW_PRESET
check "the regular engine never inherits a preset" logged pr-review.sh "PRESET="
check "  of any kind"                              not logged pr-review.sh "PRESET=intense"
check "  never runs intense"                       [ "$(calls intense-review.sh)" = 0 ]
setup; export STUB_CURL_RC=28 STUB_CURL_CODE=000; run 7
check "probe times out: falls back to regular"     said "ENGINE=regular"
check "  probe is capped"                          logged curl "--max-time"

echo "decision"
setup; run 7
check "clean: STATUS=prepared"                     said "STATUS=prepared"
check "  DECISION=approve"                         said "DECISION=approve"
check "  pinned to the SHA the report says it read" [ "$(cat "$INT/decision/sha")" = "$REV" ]
check "  never calls autofix"                      [ "$(calls autofix)" = 0 ]
check "  posts nothing yet"                        [ "$(posts)" = 0 ]

setup; export STUB_REVIEW="$(merged "$(finding REFUTED 'r1')" "$(finding UNVERIFIABLE 'u1')")"; run 7
check "only refuted/unverifiable: DECISION=approve" said "DECISION=approve"
check "  pinned to meta.json's SHA"                [ "$(cat "$INT/decision/sha")" = "$REV" ]
check "  the approval names no unchecked claim"    not grep -q u1 "$INT/decision/body.md"

setup; export STUB_REVIEW=gaps; run 7
check "slices went unreviewed: no approval"        rc_is 1
check "  says why"                                 says "unreviewed|incomplete"
check "  no decision"                              silent DECISION
check "  nothing to ship"                          [ ! -e "$INT/decision" ]
setup; export STUB_REVIEW=no-anthropic; run 7
check "no anthropic finder: no approval"           rc_is 1
check "  no decision"                              silent DECISION
setup; export STUB_REVIEW="$(merged "$(finding REFUTED r1)")" \
  STUB_REPORT_EXTRA="> ⚠️ **Incomplete.** These review slices produced nothing: c02."; run 7
check "findings but incomplete: no approval"       rc_is 1
check "  no decision"                              silent DECISION

setup; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)" "$(finding ERROR e1)")"; run 7
check "an ERROR verdict: exits 1"                  rc_is 1
check "  says why"                                 says "ERROR|not checked"
check "  no decision"                              silent DECISION
check "  never calls autofix"                      [ "$(calls autofix)" = 0 ]
setup; export STUB_REVIEW="$(merged "$(finding MAYBE m1)")"; run 7
check "an unknown verdict counts as unchecked"     rc_is 1
check "  no decision"                              silent DECISION

setup; author carol; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7
check "carol, CONFIRMED: DECISION=fix"               said "DECISION=fix"
check "  prepares the fix from the reviewed SHA"   logged autofix "MODE=prepare FROZEN=$INT/autofix REVIEWER= ARGS=7 $REV $ROOT $INT"
check "  relays autofix's status"                  said "STATUS=prepared"
check "  records the decision"                     decided "$INT" fix
check "  relays which model wrote the fix"         said "IMPLEMENTER=claude-opus-5-5"

setup; export STUB_REVIEW="$(merged "$(finding CONFIRMED 'Old value leaks past @reset')" "$(finding UNVERIFIABLE 'SECRET-UNCHECKED')")"; run 7
check "anyone else, CONFIRMED: DECISION=request-changes" said "DECISION=request-changes"
check "  never calls autofix"                      [ "$(calls autofix)" = 0 ]
check "  body names the confirmed finding"         grep -qF "Old value leaks past" "$INT/decision/body.md"
check "  and only that one"                        not grep -q SECRET-UNCHECKED "$INT/decision/body.md"
check "  no live @ in it"                          not grep -qE '(^|[^A-Za-z0-9])@[A-Za-z0-9_]' "$INT/decision/body.md"
setup; export PR_REVIEW_FIX_AUTHORS="bob alice" STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7
export PR_REVIEW_FIX_AUTHORS=carol
check "the fix allowlist is configurable"          said "DECISION=fix"

setup; author carol; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")" STUB_AUTOFIX_RC=1; run 7
check "autofix refuses carol's patch: exits 0"       rc_is 0
check "  falls back to DECISION=request-changes"   said "DECISION=request-changes"
check "  leaves no half-made fix to --ship"        [ ! -e "$INT/autofix" ]
setup; author carol; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")" STUB_AUTOFIX_OUT=STATUS=stale STUB_AUTOFIX_RC=1; run 7
check "carol pushed during the review: exits 1"      rc_is 1
check "  relays stale"                             said "STATUS=stale"
check "  no decision"                              silent DECISION
setup; author carol; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")" STUB_AUTOFIX_OUT=STATUS=exists:https://x/pull/5; run 7
check "a fix PR already exists: relayed"           said "STATUS=exists:https://x/pull/5"
check "  no decision"                              silent DECISION

setup; mkdir -p "$INT/decision" "$INT/autofix" "$REG/decision"; touch "$INT/autofix/left-over"
echo "$REV" > "$REG/decision/sha"; echo approve > "$REG/decision/decision"; export STUB_ENGINE_RC=3; run 7
check "review failed: non-zero"                    [ "$rc" != 0 ]
check "  no decision"                              silent DECISION
check "  leaves no earlier decision in either store" absent "$INT/decision" "$REG/decision"
check "  nor an earlier fix"                       [ ! -e "$INT/autofix" ]
setup; mkdir -p "$INT"; export STUB_ENGINE_RC=0
# an engine that exits 0 having written nothing must not let an older report approve --
# and that older report is a clean one at the live head, so only the set-aside stops it
printf 'u · reviewed at head `%s`\n\n**No findings.** opus reviewed the diff.\n' "$REV" > "$INT/pr7-review.md"
cat > "$C/quiet" <<'Q'
#!/usr/bin/env bash
exit 0
Q
chmod +x "$C/quiet"; PEER_REVIEW_INTENSE="$C/quiet" run 7
check "an engine that wrote no report: no decision" silent DECISION
check "  exits 1"                                  rc_is 1
check "  says why"                                 says "no report"
check "  the older report is set aside"            [ -f "$INT/pr7-review.md.prev" ]

setup; mkdir -p "$REG/decision"; echo "$REV" > "$REG/decision/sha"; echo approve > "$REG/decision/decision"; run 7
check "a review that succeeds in one store clears the other's earlier decision" absent "$REG/decision"

echo "refused before spending on a review"
setup; export STUB_ME=ALICE; run 7
check "your own PR"                                rc_is 1
check "  says why"                                 says "your own"
check "  no probe, no review"                      [ "$(calls curl)$(calls intense-review.sh)$(calls pr-review.sh)" = 000 ]
setup; export STUB_PRVIEW="$(prview app/dependabot true OPEN false)"; run 7
check "bot author"                                 rc_is 1
check "  says why"                                 says bot
check "  no review"                                [ "$(calls intense-review.sh)$(calls pr-review.sh)" = 00 ]
setup; export STUB_PRVIEW="$(prview alice false MERGED false)"; run 7
check "PR not open"                                rc_is 1
check "  says why"                                 says "not open"
setup; export STUB_PRVIEW="$(prview alice false OPEN true)"; run 7
check "fork PR"                                    rc_is 1
check "  says why"                                 says fork
for opt in --post --inline --yes; do
  setup; run 7 $opt
  check "$opt (the decision is posted by --ship)"  rc_is 1
  check "  says why"                               says "$opt"
  check "  no review"                              [ "$(calls intense-review.sh)" = 0 ]
done
setup; run 7 --sha abc123
check "--sha (the decision is about the live head)" rc_is 1
check "  says why"                                 says "--sha"
setup; CWD="$C" run 7
check "outside a git repo"                         rc_is 1
check "  says why"                                 says "git repo"
setup; run
check "no PR number"                               rc_is 1
check "  prints usage"                             says usage

echo "ship"
setup; run 7 --ship
check "nothing prepared: refused"                  rc_is 1
check "  says why"                                 says "nothing prepared"
check "  posts nothing"                            [ "$(posts)$(calls autofix)" = 00 ]

setup; run 7; run 7 --ship
check "approve: exits 0"                           rc_is 0
check "  posts APPROVE"                            logged gh "event=APPROVE"
check "  pinned to the reviewed SHA"               logged gh "commit_id=$REV"
check "  posts the frozen body"                    cmp -s "$C/log/posted-body" "$INT/decision/body.md"
check "  relays it"                                said "STATUS=approved:$URL"
check "  never re-runs the review"                 [ "$(calls intense-review.sh)" = 1 ]
run 7 --ship
check "  a second ship posts nothing more"         [ "$(posts)" = 1 ]
check "  and says where the first went"            said "STATUS=exists:$URL"

setup; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7
printf '\nEDITED BEFORE SHIPPING\n' >> "$INT/decision/body.md"; run 7 --ship
check "request-changes: posts REQUEST_CHANGES"     logged gh "event=REQUEST_CHANGES"
check "  pinned to the reviewed SHA"               logged gh "commit_id=$REV"
check "  posts the body as edited"                 grep -q "EDITED BEFORE SHIPPING" "$C/log/posted-body"
check "  relays it"                                said "STATUS=changes-requested:$URL"
setup; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7
printf '  \n' > "$INT/decision/body.md"; run 7 --ship
check "request-changes with a blank body: refused" rc_is 1
check "  posts nothing"                            [ "$(posts)" = 0 ]

setup; run 7; export STUB_LIVE="$NEW"; author alice; run 7 --ship
check "head moved since the review: STATUS=stale"  said "STATUS=stale"
check "  exits 1"                                  rc_is 1
check "  posts nothing"                            [ "$(posts)" = 0 ]
setup; run 7; export STUB_PRVIEW="$(prview alice false MERGED false)"; run 7 --ship
check "merged since the review: refused"           rc_is 1
check "  posts nothing"                            [ "$(posts)" = 0 ]
setup; run 7; export STUB_POST_RC=1; run 7 --ship
check "the post fails: exits 1"                    rc_is 1
check "  not marked as posted, so a re-run retries" [ ! -e "$INT/decision/posted" ]

setup; run 7; mkdir -p "$REG/decision"; cp "$INT/decision/"* "$REG/decision/"; run 7 --ship
check "a decision in both stores: refused"         rc_is 1
check "  says why"                                 says "both"
check "  posts nothing"                            [ "$(posts)" = 0 ]

setup; unset OLLAMA_API_KEY; run 7; run 7 --ship
check "ships from the store the review used"       said "STATUS=approved:$URL"

setup; author carol; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7; run 7 --ship
check "fix: ships the frozen patch, asking the author" \
      logged autofix "MODE=ship FROZEN=$INT/autofix REVIEWER=carol ARGS=7 $REV $ROOT $INT"
check "  relays the opened PR"                     said "STATUS=opened:https://github.com/acme/widgets/pull/99"
check "  relays the reviewer request"              said "REVIEWER=requested:carol"
check "  posts no review of its own"               [ "$(posts)" = 0 ]
check "  records where the fix PR went"            [ "$(cat "$INT/decision/posted")" = https://github.com/acme/widgets/pull/99 ]
run 7 --ship
check "  a second ship opens nothing more"         [ "$(grep -c MODE=ship "$C/log/autofix")" = 1 ]
check "  and says where the first went"            said "STATUS=exists:https://github.com/acme/widgets/pull/99"
setup; author carol; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7; export STUB_AUTOFIX_RC=1; run 7 --ship
check "fix ship failed: exits 1"                   rc_is 1

echo "store layout, config file, PR references"
# home_run: a run with no store env, HOME in the sandbox -- the defaults and the config file.
home_run() { ( unset PR_REVIEW_DIR PR_REVIEW_INTENSE_DIR; HOME="$C/home"; export HOME; run "$@" ); }
setup; home_run 7
check "the intense store defaults to ~/.reviews/_intense/<author>/<repo>/<N>" decided "$C/home/.reviews/_intense/alice/widgets/7" approve
setup; export STUB_PRVIEW="$(prview alice false OPEN false)" STUB_CURL_CODE=401; home_run 7
check "the regular store defaults to ~/.reviews/<author>/<repo>/<N>" decided "$C/home/.reviews/alice/widgets/7" approve
setup; home_run 7; home_run 7 --ship
check "ship finds a decision in the default store"  said "STATUS=approved:$URL"
setup; author alice; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"
printf 'PR_REVIEW_FIX_AUTHORS=alice\n' > "$C/config.env"; chmod 600 "$C/config.env"
( unset PR_REVIEW_FIX_AUTHORS; REVIEW_SKILLS_CONFIG="$C/config.env" run 7 )
check "fix authors come from the config file"      said "DECISION=fix"
setup; author alice; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"
( unset PR_REVIEW_FIX_AUTHORS; run 7 )
check "no fix authors configured: request-changes" said "DECISION=request-changes"
setup; run acme/widgets#7
check "owner/repo#N is accepted"                   decided "$INT" approve
setup; run https://github.com/acme/widgets/pull/7
check "a PR URL is accepted"                       decided "$INT" approve
setup; run other/thing#7
check "a PR in another repo is refused"            rc_is 1
check "  naming both repos"                        says "other/thing.*acme/widgets"
check "  before any probe or review"               [ "$(calls curl)$(calls intense-review.sh)$(calls pr-review.sh)" = 000 ]
setup; run 7
check "the engine runs under this run's lock"      logged lock "$SB/locks/github.com_acme_widgets_pull_7"
check "  released when the run ends"               [ ! -L "$SB/locks/github.com_acme_widgets_pull_7" ]
setup; mkdir -p "$SB/locks"; ln -s $$ "$SB/locks/github.com_acme_widgets_pull_7"; run 7
check "a PR another live run holds is refused"     rc_is 1
check "  naming why"                               says "already being reviewed"
check "  before any probe or review"               [ "$(calls curl)$(calls intense-review.sh)$(calls pr-review.sh)" = 000 ]
check "  and the holder's lock is left alone"      [ "$(readlink "$SB/locks/github.com_acme_widgets_pull_7")" = "$$" ]
rm -f "$SB/locks/github.com_acme_widgets_pull_7"
setup; run 7x
check "junk is refused"                            rc_is 1

echo "decide: re-freeze a different decision from the review already done"
setup; run 7 --decide approve
check "nothing reviewed: refused"                  rc_is 1
check "  says why"                                 says "nothing reviewed"

setup; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7; run 7 --decide approve
check "approve over request-changes: exits 0"      rc_is 0
check "  says so"                                  said "DECISION=approve"
check "  records it"                               decided "$INT" approve
check "  keeps the reviewed SHA"                   [ "$(cat "$INT/decision/sha")" = "$REV" ]
check "  the body is an approval"                  grep -q "confirmed no findings" "$INT/decision/body.md"
check "  never re-runs the review"                 [ "$(calls intense-review.sh)" = 1 ]
check "  posts nothing"                            [ "$(posts)" = 0 ]

setup; run 7; run 7 --decide request-changes
check "request-changes, nothing confirmed, no body: refused" rc_is 1
check "  says why"                                 says "body"
check "  the earlier decision stands"              decided "$INT" approve
setup; run 7; printf 'Please add a test.\n' > "$C/b.md"; run 7 --decide request-changes --body-file "$C/b.md"
check "request-changes with a body file: decided"  decided "$INT" request-changes
check "  the body is that file"                    cmp -s "$C/b.md" "$INT/decision/body.md"

setup; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7; run 7 --decide fix
check "fix for an author not on the list"          said "DECISION=fix"
check "  prepares from the reviewed SHA"           logged autofix "MODE=prepare FROZEN=$INT/autofix REVIEWER= ARGS=7 $REV $ROOT $INT"
check "  records it"                               decided "$INT" fix
setup; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7; export STUB_AUTOFIX_RC=1; run 7 --decide fix
check "autofix refuses the override: exits 1"      rc_is 1
check "  the earlier decision stands"              decided "$INT" request-changes
check "  leaves no half-made fix"                  [ ! -e "$INT/autofix" ]
setup; run 7; echo x > "$C/b.md"; run 7 --decide fix --body-file "$C/b.md"
check "fix takes no body file"                     rc_is 1

setup; author carol; export STUB_REVIEW="$(merged "$(finding CONFIRMED c1)")"; run 7; run 7 --decide approve
check "approve over fix: drops the frozen fix"     [ ! -e "$INT/autofix" ]
check "  records it"                               decided "$INT" approve

setup; run 7; run 7 --ship; echo x > "$C/b.md"; run 7 --decide request-changes --body-file "$C/b.md"
check "after shipping: refused"                    rc_is 1
check "  says why"                                 says "already"
setup; run 7; run 7 --decide maybe
check "an unknown decision: refused"               rc_is 1
setup; run 7; run 7 --decide approve --no-cache
check "--decide takes no review options"           rc_is 1
setup; run 7; run 7 --decide approve --ship
check "--decide and --ship together: refused"      rc_is 1
setup; run 7; run 7 --decide
check "--decide needs a value"                     rc_is 1

echo "a running review is visible, and stops being so when it ends"
setup
cat > "$C/peek" <<'P'
#!/usr/bin/env bash
cat "$PR_REVIEW_INTENSE_DIR/$STUB_AUTHOR/widgets/$1/running" > "$STUB_LOG/marker" 2>/dev/null || true
exec "$(dirname "$STUB_LOG")/../bin/intense-review.sh" "$@"
P
chmod +x "$C/peek"; PEER_REVIEW_INTENSE="$C/peek" run 7
check "the store dir holds a pid while it runs"    grep -qE '^[0-9]+$' "$C/log/marker"
check "  and not after"                            [ ! -e "$INT/running" ]
setup; export STUB_ENGINE_RC=3; run 7
check "a failed review leaves no marker"           [ ! -e "$INT/running" ]

echo "the report wording this script keys on still exists"
PRR="$HERE/../pr-review"
check "zero findings, anthropic finder ran"        grep -qF 'echo "**No findings.** ' "$PRR/pr-review.sh"
check "zero findings, the head it read"            grep -qF 'reviewed at head \`$SHA\`' "$PRR/pr-review.sh"
check "zero findings, slices lost"                 grep -qF 'Slices that produced nothing' "$PRR/pr-review.sh"
check "with findings, slices lost"                 grep -qF '**Incomplete.**' "$PRR/report.jq"
check "verdicts the refuter emits"                 grep -qF 'REFUTED needs quoted counter-evidence, else UNVERIFIABLE' "$PRR/refute"
check "a missing verdict is ERROR"                 grep -qF 'verdict:"ERROR"' "$PRR/pr-review.sh"

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
