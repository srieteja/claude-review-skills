#!/usr/bin/env bash
# Adversarial PR review.
#   stage 1  one or more finders review the PR at its head commit, in parallel slices
#   stage 2  `refute` dispatches each finding to a validator, one call per claim
#   stage 3  merge on claim id       -> ~/.reviews/<author>/<repo>/<N>/pr<N>-review.md
#   stage 4  optional `gh pr comment`, confirmed every run
#   stage 5  CONFIRMED findings by an author on PR_REVIEW_FIX_AUTHORS: autofix.sh opens a fix
#            PR stacked on theirs and asks them to review it
#
# exit 4  stage 5 owed a fix PR and opened none (stale head, a refusal, a red test gate)
#
# Targets bash 3.2 (macOS system bash): no mapfile, no `wait -n`, no assoc arrays.
set -euo pipefail

# Assets resolve from this script's own directory, so the toolkit can live anywhere. -P
# resolves a symlinked install back to the checkout, where lib/ sits beside skills/.
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
load_config
anthropic_key_check || exit 1

# Stage 1's finders and stage 2's refuter are resolved after the arg loop (lib/models.sh), for
# this preset: regular, or intense when intense-review.sh runs this script.
PRESET="${PR_REVIEW_PRESET:-regular}"
S1_EFFORT="${PR_REVIEW_S1_EFFORT:-xhigh}"
# The cheaper finder --sonnet opts into.
SONNET_MODEL="${PR_REVIEW_SONNET_MODEL:-claude-sonnet-5-5}"
S1_TIMEOUT="${PR_REVIEW_S1_TIMEOUT:-25m}"
BURDEN="${PR_REVIEW_BURDEN:-strict}"
AGY_TIMEOUT="${PR_REVIEW_AGY_TIMEOUT:-20m}"
REFUTE_TIMEOUT="${PR_REVIEW_REFUTE_TIMEOUT:-$AGY_TIMEOUT}"
JOBS="${PR_REVIEW_JOBS:-4}"
S1_JOBS="${PR_REVIEW_STAGE1_JOBS:-3}"
CHUNK_BYTES="${PR_REVIEW_CHUNK_BYTES:-80000}"
# USD per anthropic slice; `none` removes the cap and S1_TIMEOUT bounds the slice instead.
# A runaway guard, not a budget: an 80KB opus slice measured $3.00-3.24, and a capped slice
# discards what it already paid for. CHUNK_BYTES is what bounds cost.
BUDGET="${PR_REVIEW_BUDGET_USD:-8.00}"
CACHE_ROOT="${TMPDIR:-/tmp}/pr-review-cache"

# --------------------------------------------------------------- stage 0.5 brief
BRIEF_MODEL="${PR_REVIEW_BRIEF_MODEL:-claude-sonnet-5-5}"
# Summarising a diff, not reasoning over a codebase. xhigh here buys thinking tokens billed
# at output rates for no gain; the finder's effort is a separate knob for a separate job.
BRIEF_EFFORT="${PR_REVIEW_BRIEF_EFFORT:-medium}"
# A runaway guard, not a budget. The real cost control is CHUNK_BYTES, which bounds the
# input deterministically; at the 80000 default this call prices out around $0.10. A tight
# cap could only make things worse: --max-budget-usd is checked between turns, and a
# single-turn call has no second turn to stop at -- so the cap cannot prevent the spend,
# only discard what it paid for. That is exactly how slices c03/c04 burned $5.21 for nothing.
BRIEF_BUDGET="${PR_REVIEW_BRIEF_BUDGET_USD:-1.00}"
# Tests are 40%+ of a typical diff here. They are held out of the feature slices and get a
# pass of their own once those finish, judged against the feature findings and the brief.
# PR_REVIEW_SKIP_RE is the variable's old name, still honoured.
TEST_RE="${PR_REVIEW_TEST_RE:-${PR_REVIEW_SKIP_RE:-(^|/)tests?/|_test\.dart$}}"
CROSS_RE="${PR_REVIEW_CROSS_RE:-(pubspec\.yaml|/lib/[^/]+\.dart)\$}"
# Every jq read of model output starts with this, under jq -L "$HERE". The filter lives in
# last-event.jq because refute reads model output too, and is also run on its own.
LAST_EVENT='include "last-event"; last_event'
POST=0
INLINE=0; ASSUME_YES=0; KEEP=0; FINDINGS_IN=""; NO_CACHE=0; SONNET=0; NO_BRIEF=0; NO_BRIEF_WHY=--no-brief; NO_FIX=0
PIN="${PR_REVIEW_SHA:-}"

die() { printf '\033[31mpr-review: %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<USAGE
usage: pr-review.sh <pr> [options]     <pr>: N, owner/repo#N or a PR URL, run from a clone of its repo

  --post              offer to post the result as a PR comment (asks first)
  --inline            with --post, post a review with each finding anchored to its line
  --yes               with --post, skip the prompt (for CI; posts unattended)
  --sonnet            find with $SONNET_MODEL instead of the opus default (cheaper)
  --no-brief          skip stage 0.5, the plain-language brief of the PR
  --findings <file>   skip stage 1, validate an existing findings.json
  --jobs <n>          parallel validators (default $JOBS)
  --no-cache          ignore cached stage-1 slices for this head SHA
  --sha <commit>      review an ancestor of the PR head instead of the head
  --no-fix            skip stage 5, the fix PR for a fix author's confirmed findings
  --keep              keep the work directory for inspection
  -h, --help          this

models: picked from what this machine can reach (claude, agy, OLLAMA_API_KEY), best first
     per models.tsv; REVIEW_SKILLS_MODELS=manual takes the first rows unprobed. Pins:
     PR_REVIEW_FINDERS ("transport:model[@effort] ...", transports anthropic|ollama|agy)
     PR_REVIEW_S1_MODEL (alias PR_REVIEW_OPUS_MODEL) PR_REVIEW_S1_EFFORT PR_REVIEW_TRANSPORT
       -- a single finder, used when PR_REVIEW_FINDERS is unset
     PR_REVIEW_REFUTER ("agy|anthropic|ollama:model"), PR_REVIEW_GEMINI_MODEL (an agy refuter)
     PR_REVIEW_BURDEN (strict|evidence)
     PR_REVIEW_CROSS (1: refuter unavailable -> the other finder family refutes)
     PR_REVIEW_REFUTE_TIMEOUT PR_REVIEW_S1_TIMEOUT PR_REVIEW_AGY_TIMEOUT
     PR_REVIEW_JOBS PR_REVIEW_STAGE1_JOBS PR_REVIEW_CHUNK_BYTES PR_REVIEW_BUDGET_USD (or none)
     PR_REVIEW_TEST_RE PR_REVIEW_CROSS_RE PR_REVIEW_SHA PR_REVIEW_DIR (review store, default ~/.reviews)
     PR_REVIEW_SONNET_MODEL (what --sonnet selects)
     PR_REVIEW_FIX_AUTHORS (alias PEER_REVIEW_FIX_AUTHORS; default none) -- stage 5,
       with autofix.sh's AUTOFIX_* knobs; PR_REVIEW_AUTOFIX (the script run, for tests)
     PR_REVIEW_BRIEF_MODEL PR_REVIEW_BRIEF_EFFORT PR_REVIEW_BRIEF_BUDGET_USD -- stage 0.5

  ollama anywhere: needs OLLAMA_API_KEY. The diff, claims and source it reads leave this
  machine for ollama.com. Measured finder recall is far below the anthropic path -- see SKILL.md.

  Any of these can be set in $(config_file); the environment wins.
USAGE
  exit 1
}

PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --post) POST=1 ;;
    --inline) INLINE=1 ;;
    --yes) ASSUME_YES=1 ;;
    --keep) KEEP=1 ;;
    --no-cache) NO_CACHE=1 ;;
    --sonnet) SONNET=1 ;;
    --no-brief) NO_BRIEF=1 ;;
    --no-fix) NO_FIX=1 ;;
    --sha) PIN="$2"; shift ;;
    --findings) FINDINGS_IN="$2"; shift ;;
    --jobs) JOBS="$2"; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1" ;;
    *) [ -n "$PR" ] && die "unexpected argument: $1"; PR="$1" ;;
  esac
  shift
done
[ -n "$PR" ] || usage
REF="$PR"; parse_pr_ref "$REF" || die "PR must be N, owner/repo#N or a PR URL, got: $REF"

# Stage 1's finders: space-separated transport:model[@effort], one per transport. Resolved
# after the arg loop so --sonnet, parsed above, beats the resolved finders.
resolve_models "$PRESET" || exit 1
REFUTER="$RESOLVED_REFUTER"
if [ "$SONNET" -eq 1 ]; then
  [ -z "${PR_REVIEW_FINDERS:-}" ] || warn "--sonnet overrides PR_REVIEW_FINDERS"
  FINDERS="anthropic:$SONNET_MODEL${S1_EFFORT:+@$S1_EFFORT}"
else
  FINDERS="$RESOLVED_FINDERS"
fi
[ "$CLAUDE_OK" = 1 ] || { NO_BRIEF=1; NO_BRIEF_WHY="claude is not signed in"; }

# ROOT is the repo being reviewed, from cwd.
ROOT="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
# OUT is resolved in stage 0: the layout is keyed on the PR author and repo, known only
# once the metadata is fetched.
REVIEW_ROOT="$(review_store)"
[ -x "$HERE/refute" ] || die "refute is missing or not executable: $HERE/refute"
AUTOFIX="${PR_REVIEW_AUTOFIX:-$HERE/autofix.sh}"

# ------------------------------------------------------------ finders and refuter
NFINDERS=0; SEEN=" "
for f in $FINDERS; do
  t="${f%%:*}"
  case "$SEEN" in *" $t "*) die "PR_REVIEW_FINDERS: one finder per transport, $t appears twice" ;; esac
  SEEN="$SEEN$t "; NFINDERS=$((NFINDERS + 1))
done
[ "$NFINDERS" -gt 0 ] || die "PR_REVIEW_FINDERS is empty"

# EMIT is how a finder hands back findings, and it is dictated by the transport, not a
# preference: --allowedTools is an intersection, never a union. Under CLAUDE_CODE_SIMPLE=1
# (load-bearing for auth on ollama, see lib/transport-env.sh) the harness ships a fixed tool
# surface, grant flags are silently dropped, and there is no Write to give the model.
# See emit/README.md.
#
# load_finder <transport:model[@effort]> sets F_TRANSPORT F_MODEL F_EFFORT F_EMIT F_SCHEMA
# F_LABEL F_NAME F_TAG F_PROMPT_ID F_CACHE_TAG. F_TAG prefixes slice keys and finding ids when
# there is more than one finder.
load_finder() {
  case "$1" in *:?*) ;; *) die "finder must be transport:model[@effort], got: $1" ;; esac
  F_TRANSPORT="${1%%:*}"; spec="${1#*:}"
  F_MODEL="${spec%%@*}"; F_EFFORT=""
  case "$spec" in *@*) F_EFFORT="${spec#*@}" ;; esac
  F_SCHEMA=""
  case "$F_TRANSPORT" in
    anthropic) F_EMIT=file ;;
    ollama) F_EMIT=stdout; F_EFFORT="" ;;
    agy)
      F_EMIT=schema; F_SCHEMA="$HERE/findings.schema.json"
      [ -z "$F_EFFORT" ] || die "agy takes no @effort, the tier is part of the model id: $1" ;;
    *) die "unknown finder transport in $1 (anthropic|ollama|agy)" ;;
  esac
  F_LABEL="$F_MODEL${F_EFFORT:+/$F_EFFORT}"
  [ "$F_TRANSPORT" = anthropic ] && F_NAME="$F_LABEL" || F_NAME="$F_LABEL via $F_TRANSPORT"
  if [ "$NFINDERS" -gt 1 ]; then F_TAG="$F_TRANSPORT."; else F_TAG=""; fi
  # Cache key covers the prompts: editing one must invalidate old slices.
  F_PROMPT_ID="$(cat "$HERE/review.prompt" "$HERE/scope/"*.txt \
                     "$HERE/emit/$F_EMIT.head.txt" "$HERE/emit/$F_EMIT.tail.txt" ${F_SCHEMA:+"$F_SCHEMA"} \
                   | cksum | awk '{print $1}')"
  # The model is part of the key. It was not, and that was a live bug even before a second
  # transport existed: a cheaper model's slices were served back to a later run at the same
  # SHA, under a report that stamped the expensive model's name on them.
  F_CACHE_TAG="$(printf '%s-%s' "$F_TRANSPORT" "$F_LABEL" | tr -c 'A-Za-z0-9._-' '_')"
}

NEED="gh git jq awk"
LABELS=""; HAS_ANTHROPIC=0; HAS_OLLAMA_FINDER=0; HAS_AGY_FINDER=0
for f in $FINDERS; do
  load_finder "$f"
  case "$F_TRANSPORT" in
    anthropic) HAS_ANTHROPIC=1; F_NEED=claude ;;
    ollama) HAS_OLLAMA_FINDER=1; F_NEED="claude python3" ;;
    agy) HAS_AGY_FINDER=1; F_NEED=agy ;;
  esac
  [ -n "$FINDINGS_IN" ] || NEED="$NEED $F_NEED"
  LABELS="${LABELS:+$LABELS + }$F_NAME"
done

case "$REFUTER" in *:?*) ;; *) die "PR_REVIEW_REFUTER must be transport:model, got: $REFUTER" ;; esac
R_TRANSPORT="${REFUTER%%:*}"; R_MODEL="${REFUTER#*:}"
case "$R_TRANSPORT" in
  agy) NEED="$NEED agy"; R_LABEL="$R_MODEL" ;;
  anthropic) NEED="$NEED claude"; R_LABEL="$R_MODEL" ;;
  ollama) NEED="$NEED claude"; R_LABEL="$R_MODEL via ollama" ;;
  *) die "unknown refuter transport in $REFUTER (agy|anthropic|ollama)" ;;
esac
same_family "$REFUTER" $FINDERS
[ "$SAME_FAMILY" = 0 ] || warn "$R_LABEL is of the same model family as a finder ($LABELS): its refutations are not independent$(refuter_why)"
# Set by the intense preset: an unavailable refuter falls through to the other finder's model.
CROSS="${PR_REVIEW_CROSS:+1}"
if [ -n "$CROSS" ]; then
  if command -v agy >/dev/null 2>&1; then NEED="$NEED agy"
  else warn "agy not found: an unavailable refuter has no fallback"; CROSS=""; fi
fi
[ -d "$HERE/burden/$BURDEN" ] || die "unknown PR_REVIEW_BURDEN: $BURDEN (strict|evidence)"

# The refuter's binary is checked here too: better to die before stage 1 spends than after.
for bin in $NEED; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH"
done
check_pr_repo

TIMEOUT_BIN=""
for b in timeout gtimeout; do command -v "$b" >/dev/null 2>&1 && { TIMEOUT_BIN="$b"; break; }; done
[ "$R_TRANSPORT" != anthropic ] || [ -n "$TIMEOUT_BIN" ] \
  || die "an anthropic refuter needs timeout or gtimeout on PATH"
# The anthropic finder's ceiling: --max-budget-usd, or with BUDGET=none, S1_TIMEOUT.
BUDGET_CAP=""; ANTHROPIC_TIMEOUT_BIN=""
if [ "$BUDGET" = none ]; then
  if [ "$HAS_ANTHROPIC" -eq 1 ]; then
    [ -n "$TIMEOUT_BIN" ] || die "PR_REVIEW_BUDGET_USD=none needs timeout or gtimeout on PATH"
    ANTHROPIC_TIMEOUT_BIN="$TIMEOUT_BIN"
  fi
else
  BUDGET_CAP="$BUDGET"
fi

if [ "$HAS_OLLAMA_FINDER" -eq 1 ] || [ "$R_TRANSPORT" = ollama ]; then
  [ -n "${OLLAMA_API_KEY:-}" ] || die "an ollama finder or refuter needs OLLAMA_API_KEY"
  # The only ceiling on an ollama finder. --max-budget-usd is dropped there because the
  # compat layer prices an unrecognized model at Anthropic rates and the flag IS
  # enforced against that fiction: one measured slice billed $4.16 of nothing against
  # a $2.00 cap, and the slice would have been killed mid-review.
  [ "$HAS_OLLAMA_FINDER" -eq 0 ] || [ -n "$TIMEOUT_BIN" ] \
    || warn "no timeout/gtimeout on PATH -- ollama slices run uncapped"
  warn "ollama: the diff, claims and source it reads leave this machine for ollama.com"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-${PR}.XXXXXX")"
TREE="$WORK/tree"
TAB="$(printf '\t')"

cleanup() {
  rc=$?
  if [ "$KEEP" -eq 1 ]; then say "work dir kept: $WORK"; else rm -rf "$WORK"; fi
  pr_unlock
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- stage 0: fetch
say "stage 0: fetching PR #$PR"
gh pr view "$PR" --json number,title,url,author,headRefOid,baseRefName,state,changedFiles,additions,deletions,body \
  > "$WORK/meta.json" || die "stage 0: gh pr view failed (is #$PR a PR in this repo?)"
SHA="$(jq -r '.headRefOid' "$WORK/meta.json")"
TITLE="$(jq -r '.title' "$WORK/meta.json")"
URL="$(jq -r '.url' "$WORK/meta.json")"
pr_lock "$URL"
# One directory per (author, repo, PR): the report, the raw findings and every verdict live
# together, so a review is a self-contained record rather than a lone markdown file.
AUTHOR="$(jq -r '.author.login // "unknown"' "$WORK/meta.json")"
case "$AUTHOR" in ""|null) AUTHOR="unknown" ;; esac
AUTHOR="${AUTHOR#app/}"
OUTDIR="$(review_dir "$REVIEW_ROOT" "$AUTHOR" "$(repo_of_url "$URL")" "$PR")"
OUT="$OUTDIR/pr${PR}-review.md"
# The brief is a sibling of the report, never part of it: $OUT is what --post sends to
# GitHub, and a summary of the author's own PR is noise on their PR. See SKILL.md.
BRIEF="$OUTDIR/pr${PR}-explainer.md"
mkdir -p "$OUTDIR"
[ -n "$SHA" ] && [ "$SHA" != "null" ] || die "stage 0: could not resolve head SHA"

gh pr diff "$PR" > "$WORK/pr.diff" || die "stage 0: gh pr diff failed"
[ -s "$WORK/pr.diff" ] || die "stage 0: empty diff"

# A merged PR's head object may be absent locally; the pull ref always has it. Fetching the
# pull ref also brings the branch's ancestors, which is what --sha needs.
git -C "$ROOT" cat-file -e "$SHA" 2>/dev/null || \
  git -C "$ROOT" fetch --quiet origin "pull/$PR/head" || die "stage 0: cannot fetch pull/$PR/head"

# --sha reviews an ancestor of the head (a commit before a fix landed, for regression
# fixtures). The diff must move with the tree: a head diff against a pinned worktree makes
# stage 1 cite lines stage 2 then validates in a different tree -- the same silent-corruption
# class the worktree pin exists to prevent. meta.json feeds the prompt and the report header,
# so its counts move too.
if [ -n "$PIN" ]; then
  BASEREF="$(jq -r '.baseRefName' "$WORK/meta.json")"
  git -C "$ROOT" cat-file -e "$PIN^{commit}" 2>/dev/null || die "stage 0: --sha $PIN not reachable"
  SHA="$(git -C "$ROOT" rev-parse "$PIN^{commit}")"
  MB="$(git -C "$ROOT" merge-base "origin/$BASEREF" "$SHA")" || die "stage 0: no merge-base for $PIN"
  git -C "$ROOT" diff "$MB...$SHA" > "$WORK/pr.diff" || die "stage 0: --sha diff failed"
  [ -s "$WORK/pr.diff" ] || die "stage 0: --sha produced an empty diff"
  STAT="$(git -C "$ROOT" diff --numstat "$MB...$SHA" | awk '{f++; a+=$1; d+=$2} END{print f+0, a+0, d+0}')"
  jq --arg sha "$SHA" \
     --argjson f "${STAT%% *}" \
     --argjson a "$(echo "$STAT" | awk '{print $2}')" \
     --argjson d "$(echo "$STAT" | awk '{print $3}')" \
     '.headRefOid=$sha | .changedFiles=$f | .additions=$a | .deletions=$d' \
     "$WORK/meta.json" > "$WORK/meta.pinned" && mv "$WORK/meta.pinned" "$WORK/meta.json"
  warn "--sha: reviewing $SHA, not PR head. Diff and counts are ${MB:0:9}...${SHA:0:9}."
fi

# A clone, not a worktree. A worktree's .git is a *file* pointing at $ROOT/.git/worktrees/...,
# and agy follows that pointer to decide where its workspace is: probed, a relative write made
# from inside a worktree landed in $ROOT, ignoring cwd entirely. A clone puts a real .git
# directory at the tree root, so root resolution stops here. --shared keeps it cheap (objects
# come from $ROOT via alternates); the trade is that the clone must not outlive a gc in $ROOT,
# which it never does -- cleanup removes it with $WORK.
git clone --quiet --shared --no-checkout "$ROOT" "$TREE" || die "stage 0: clone failed"
# If $ROOT is shallow, git silently drops the --shared alternates optimization and falls
# back to a transport clone scoped to refs/heads/* -- a PR head that only ever reached
# $ROOT via FETCH_HEAD (never a branch ref) is excluded from $TREE even though it exists
# in $ROOT. Pull it in directly by SHA; harmless no-op when $TREE already has it.
git -C "$TREE" cat-file -e "$SHA" 2>/dev/null || git -C "$TREE" fetch --quiet "$ROOT" "$SHA" 2>/dev/null
git -C "$TREE" checkout --quiet --detach "$SHA" || die "stage 0: checkout failed at $SHA"
say "    $TITLE"
say "    tree $SHA"

# ---------------------------------------------------------------- stage 0.5: brief
# A plain-language summary of the PR for the human about to read the review. It runs before
# stage 1 on purpose: a brief written after the finders would be lost to a stage-1 death,
# and the COUNT==0 path below exits without ever reaching report.jq. Non-fatal throughout --
# stage 1 is the review, and a PR whose brief failed is still reviewable.
BRIEF_OK=0
# The brief's "How it fits together" diagram: parsed by mermaid itself and grounded against the
# diff (diagram.sh), into pr<N>-diagram.{mmd,json} for the Reviews page. Never fatal.
# PR_REVIEW_DIAGRAM=0 skips the check and keeps the explainer as written.
diagram() {
  if [ "${PR_REVIEW_DIAGRAM:-1}" = 0 ]; then say "stage 0.5: diagram check skipped (PR_REVIEW_DIAGRAM=0)"; return; fi
  "$HERE/diagram.sh" --sha "$SHA" --model "$BRIEF_MODEL" "$@" "$BRIEF" "$WORK/pr.diff" \
    || warn "stage 0.5: diagram not checked -- node or $HERE/mermaid missing (selftest.sh installs it)"
}
if [ "$NO_BRIEF" -eq 1 ]; then
  say "stage 0.5: brief skipped ($NO_BRIEF_WHY)"
else
  rm -f "$OUTDIR/pr${PR}-diagram.mmd" "$OUTDIR/pr${PR}-diagram.json"   # the last brief's
  BRIEF_PROMPT_ID="$(cksum < "$HERE/brief.prompt" | awk '{print $1}')"
  BRIEF_CACHE="$CACHE_ROOT/brief-$SHA-$BRIEF_PROMPT_ID-$(printf '%s' "$BRIEF_MODEL" | tr -c 'A-Za-z0-9._-' '_').md"
  if [ "$NO_CACHE" -eq 0 ] && [ -s "$BRIEF_CACHE" ]; then
    cp "$BRIEF_CACHE" "$BRIEF"; BRIEF_OK=1; say "stage 0.5: brief cached"
    diagram   # no repair: this one's diagram was settled before it was cached
  else
    say "stage 0.5: brief ($BRIEF_MODEL/$BRIEF_EFFORT)"
    head -c "$CHUNK_BYTES" "$WORK/pr.diff" > "$WORK/brief.diff"
    {
      cat "$HERE/brief.prompt"
      printf '\n## PR #%s — %s\n\n' "$PR" "$TITLE"
      jq -r '"\(.changedFiles) files changed, +\(.additions)/-\(.deletions), onto \(.baseRefName)"' \
        "$WORK/meta.json"
      printf '\n## The author'"'"'s description\n\n%s\n' "$(jq -r '.body // "" | if . == "" then "(none)" else . end' "$WORK/meta.json")"
      printf '\n## The diff\n\n'
      # The brief is capped at one slice of diff. Say so in the prompt rather than letting
      # the model infer completeness from a cut that looks like a clean end of file.
      if [ "$(wc -c < "$WORK/pr.diff")" -gt "$CHUNK_BYTES" ]; then
        printf 'TRUNCATED at %s bytes of %s. Files changed, in full:\n\n' \
          "$CHUNK_BYTES" "$(wc -c < "$WORK/pr.diff" | tr -d ' ')"
        sed -n 's|^+++ b/||p' "$WORK/pr.diff" | sed 's/^/  - /'
        printf '\n'
      fi
      printf '```diff\n'; cat "$WORK/brief.diff"; printf '\n```\n'
    } > "$WORK/brief.in"
    # No tools at all: the brief reasons from the diff it was handed, so there is nothing
    # for it to read and no way for it to wander into the tree. --setting-sources "" keeps
    # CLAUDE.md and local skills out of a prompt that gains nothing from them.
    if ( cd "$TREE" && anthropic_env claude -p "$(cat "$WORK/brief.in")" \
           --model "$BRIEF_MODEL" --effort "$BRIEF_EFFORT" --output-format json \
           --strict-mcp-config --setting-sources "" \
           ${BRIEF_BUDGET:+--max-budget-usd "$BRIEF_BUDGET"} \
           --disallowedTools Bash Read Grep Glob Write Edit NotebookEdit Task WebSearch WebFetch \
       ) > "$WORK/brief.json" 2>"$WORK/brief.err" \
       && jq -L "$HERE" -e "$LAST_EVENT"' | select(.is_error != true) | .result | select(type == "string" and length > 200)' \
            "$WORK/brief.json" >/dev/null 2>&1
    then
      {
        printf '# PR #%s — %s\n\n%s · `%s`\n\nBrief by %s. Written from the diff and the PR\n' \
          "$PR" "$TITLE" "$URL" "$SHA" "$BRIEF_MODEL"
        printf 'description alone — no source was read, and nothing here is a review finding.\n\n'
        jq -L "$HERE" -r "$LAST_EVENT"' | .result' "$WORK/brief.json"
      } > "$BRIEF"
      # At most one repair call, and it rewrites the block in $BRIEF. Cached only after, so a
      # rerun at this sha is served the checked brief, never one with a broken diagram.
      diagram --repair
      mkdir -p "$CACHE_ROOT" && cp "$BRIEF" "$BRIEF_CACHE"
      BRIEF_OK=1
      say "wrote $BRIEF"
    else
      warn "stage 0.5: brief failed; continuing without it (--keep to inspect brief.err)"
    fi
  fi
fi

# --------------------------------------------------------------- stage 1: review
mkdir -p "$WORK/claims" "$WORK/verdicts" "$WORK/parts" "$WORK/chunks" "$WORK/slices"
GAPS=""; GAP_NOTES=""; FAILED="$OUTDIR/failed-slices"; RAN_LABELS=""; ANTHROPIC_RAN=0
repo_state() { git -C "$ROOT" status --porcelain | LC_ALL=C sort; }

# A slice passes when it reported findings, or when it can name the source files it read.
# The second arm is the no-op guard: a well-formed "findings":[] from a finder that opened
# nothing used to pass the shape check below and cache as a clean pass.
slice_ok() {
  jq -e '(.findings|type=="array") and ((.findings|length)>0 or (.read|type=="array" and length>0))' \
    "$1" >/dev/null 2>&1
}

# Pulls the findings object out of the model's raw reply. Reads stdin, writes the object
# on stdout and nothing else; writes nothing at all when there is no such object.
#
# Only the ollama transport needs this: with no Write tool the model cannot produce $out
# itself, so the object comes back as prose-adjacent text inside the result envelope.
select_findings_json() {
  # Scan every position a JSON object could start at and keep the LAST one that decodes
  # cleanly AND carries a findings key. Last, not first: a model that quotes the schema
  # back at itself mid-reasoning emits a decoy before the real answer. Requiring the key
  # rejects the envelope-shaped noise; requiring a clean decode rejects a fence.
  python3 -c '
import json,sys
s=sys.stdin.read(); d=json.JSONDecoder(); best=None; i=0
while True:
    i=s.find("{",i)
    if i<0: break
    try: o,_=d.raw_decode(s,i)
    except ValueError: i+=1; continue
    if isinstance(o,dict) and "findings" in o: best=o
    i+=1
if best is not None: sys.stdout.write(json.dumps(best))
' 2>/dev/null
}

# Turns an ollama result envelope into $out, or leaves $out absent. Absent is the right
# outcome for a reply we could not parse: slice_ok then fails the slice loudly and its
# files are reported as unreviewed. A guessed or half-written object would instead cache
# as a clean pass -- the one stage-1 failure this pipeline cannot detect in itself.
extract_findings() {
  env_json="$1"; dest="$2"
  raw="$(jq -L "$HERE" -r "$LAST_EVENT"' | .result // empty' "$env_json" 2>/dev/null)" || return 0
  [ -n "$raw" ] || return 0
  cand="$(printf '%s' "$raw" | select_findings_json)" || return 0
  [ -n "$cand" ] || return 0
  printf '%s' "$cand" \
    | jq -e '. as $o | ($o.findings|type=="array") and ($o.read|type=="array") | $o' \
    > "$dest" 2>/dev/null || rm -f "$dest"
}

# Runs one slice for the finder last passed to load_finder. Never fatal: a slice that fails
# leaves a gap we report, rather than discarding the slices that succeeded. That is the
# whole point of slicing. <key> is the finder-tagged slice key; any <ctx> files are context
# the prompt points at, so they key the cache alongside the diff.
review_slice() {
  key="$1"; scope="$2"; diff="$3"; shift 3
  out="$WORK/slices/$key.json"
  cache="$CACHE_ROOT/${SHA}-${F_PROMPT_ID}-${F_CACHE_TAG}"
  mkdir -p "$cache"
  # Keyed on the slice's own bytes, not just its index: retuning CHUNK_BYTES or moving the
  # pin reshuffles which files land in c01, and an index-only key would serve those stale
  # findings for a different file set.
  hit="$cache/$key-$scope-$(cat "$diff" "$@" | cksum | awk '{print $1}').json"
  if [ "$NO_CACHE" -eq 0 ] && slice_ok "$hit"; then
    cp "$hit" "$out"
    printf '    %-7s cached  %s finding(s)\n' "$key" "$(jq '.findings|length' "$out")" >&2
    : > "$WORK/done/$key"
    return 0
  fi
  # Insertions run before the placeholder substitutions: emit/file.head.txt carries
  # __OUT__ of its own and has to be in the text before __OUT__ is resolved.
  sed -e "/__SCOPE__/r $HERE/scope/$scope.txt" -e "/__SCOPE__/d" "$HERE/review.prompt" \
    | sed -e "/__EMIT_TARGET__/r $HERE/emit/$F_EMIT.head.txt" -e "/__EMIT_TARGET__/d" \
    | sed -e "/__EMIT_CLOSE__/r $HERE/emit/$F_EMIT.tail.txt"  -e "/__EMIT_CLOSE__/d" \
    | sed -e "s|__DIFF__|$diff|g" -e "s|__META__|$WORK/meta.json|g" \
          -e "s|__FILES__|$WORK/files.txt|g" -e "s|__OUT__|$out|g" \
          -e "s|__FINDINGS__|$FINDINGS_REF|g" -e "s|__BRIEF__|$BRIEF_REF|g" \
    > "$WORK/chunks/$key.prompt"
  case "$F_TRANSPORT" in
    anthropic)
      # --setting-sources "": no user settings, hooks or CLAUDE.md in the finder session.
      ( cd "$TREE" && anthropic_env ${ANTHROPIC_TIMEOUT_BIN:+"$ANTHROPIC_TIMEOUT_BIN" "$S1_TIMEOUT"} \
          claude -p "$(cat "$WORK/chunks/$key.prompt")" \
          --model "$F_MODEL" ${F_EFFORT:+--effort "$F_EFFORT"} --output-format json --add-dir "$WORK" \
          --strict-mcp-config --setting-sources "" ${BUDGET_CAP:+--max-budget-usd "$BUDGET_CAP"} \
          --allowedTools Read Grep Glob Write "Bash(git diff:*)" "Bash(git log:*)" \
          --disallowedTools Edit NotebookEdit Task WebSearch WebFetch \
      ) > "$WORK/chunks/$key.json" 2>"$WORK/chunks/$key.err" || true
      ;;
    ollama)
      # No Write, so no --add-dir: this model never touches $WORK. --setting-sources ""
      # keeps CLAUDE.md and every local skill out of a prompt bound for a third party.
      ( cd "$TREE" && MODEL="$F_MODEL" ollama_env \
          ${TIMEOUT_BIN:+"$TIMEOUT_BIN" "$S1_TIMEOUT"} \
          claude -p "$(cat "$WORK/chunks/$key.prompt")" \
          --model "$F_MODEL" --output-format json \
          --strict-mcp-config --setting-sources "" \
          --disallowedTools Bash Edit NotebookEdit Task WebSearch WebFetch \
      ) > "$WORK/chunks/$key.json" 2>"$WORK/chunks/$key.err" || true
      extract_findings "$WORK/chunks/$key.json" "$out"
      ;;
    agy)
      ( cd "$TREE" && agy_env agy --sandbox --add-dir "$TREE" --model "$F_MODEL" --output-format json \
          --print-timeout "$S1_TIMEOUT" --json-schema "$F_SCHEMA" \
          -p="$(cat "$WORK/chunks/$key.prompt")" \
      ) > "$WORK/chunks/$key.json" 2>"$WORK/chunks/$key.err" || true
      jq -L "$HERE" -e "$LAST_EVENT"' | .structured_output
             | select((.findings|type=="array") and (.read|type=="array"))' \
        "$WORK/chunks/$key.json" > "$out" 2>/dev/null || rm -f "$out"
      ;;
  esac
  jq -L "$HERE" -r 'include "last-event"; quota_hit' \
    "$WORK/chunks/$key.json" > "$WORK/chunks/$key.quota" 2>/dev/null || true
  [ ! -s "$WORK/chunks/$key.quota" ] || mv "$WORK/chunks/$key.quota" "$WORK/quota"
  if slice_ok "$out"; then
    cp "$out" "$hit"
    printf '    %-7s %s finding(s)\n' "$key" "$(jq '.findings|length' "$out")" >&2
  else
    if jq -e '(.findings|type=="array") and (.findings|length==0) and
              ((.read|type!="array") or (.read|length==0))' "$out" >/dev/null 2>&1; then
      why='no-op: no findings and nothing read'
    elif [ -s "$WORK/chunks/$key.json" ]; then
      why="$(jq -L "$HERE" -r "$LAST_EVENT"'
                    | "\(.subtype // .error // "no findings produced") after \(.num_turns // 0) turns, $\(.total_cost_usd // 0 | .*100 | floor / 100)"' \
            "$WORK/chunks/$key.json" 2>/dev/null || echo 'unparseable output')"
    else
      why='no output (empty transcript)'
    fi
    for ext in json err prompt; do cp "$WORK/chunks/$key.$ext" "$FAILED/" 2>/dev/null || true; done
    [ ! -f "$out" ] || mv "$out" "$FAILED/$key.out.json"
    { printf '%s\n' "$why"; tail -n 20 "$WORK/chunks/$key.err" 2>/dev/null; } > "$FAILED/$key.reason"
    printf '\033[33m    %-7s FAILED — %s\033[0m\n' "$key" "$why" >&2
  fi
  : > "$WORK/done/$key"
}

if [ -n "$FINDINGS_IN" ]; then
  cp "$FINDINGS_IN" "$WORK/findings.json" || die "cannot read --findings $FINDINGS_IN"
  say "stage 1: skipped, using $FINDINGS_IN"
else
  rm -rf "$FAILED" "$WORK/done"; mkdir -p "$FAILED" "$WORK/done"
  awk -v outdir="$WORK/parts" -f "$HERE/split-diff.awk" "$WORK/pr.diff"
  [ -s "$WORK/parts/index.tsv" ] || die "stage 1: could not split the diff into files"
  sort -t"$TAB" -k3,3 "$WORK/parts/index.tsv" > "$WORK/parts/sorted.tsv"
  # Feature slices c01.. hold everything but tests; test slices t01.. hold only tests.
  awk -v cap="$CHUNK_BYTES" -v excl="$TEST_RE" -f "$HERE/bin-chunks.awk" "$WORK/parts/sorted.tsv" \
    | awk -F"$TAB" '$1 != "_skip"' > "$WORK/bins.tsv"
  awk -F"$TAB" -v re="$TEST_RE" 're != "" && $3 ~ re' "$WORK/parts/sorted.tsv" \
    | awk -v cap="$CHUNK_BYTES" -v pfx=t -f "$HERE/bin-chunks.awk" >> "$WORK/bins.tsv"

  # Every changed file, with its diff size — the map of what each slice cannot see.
  awk -F"$TAB" '{printf "%-72s %6d bytes of diff\n", $3, $2}' "$WORK/parts/sorted.tsv" > "$WORK/files.txt"

  KEYS="$(awk -F"$TAB" '$1 ~ /^c/ {print $1}' "$WORK/bins.tsv" | sort -u)"
  TKEYS="$(awk -F"$TAB" '$1 ~ /^t/ {print $1}' "$WORK/bins.tsv" | sort -u)"
  for k in $KEYS $TKEYS; do
    awk -F"$TAB" -v k="$k" '$1==k {print $2}' "$WORK/bins.tsv" | sort \
      | while read -r id; do cat "$WORK/parts/$id.diff"; done > "$WORK/chunks/$k.diff"
  done
  # sorted.tsv is id/bytes/path; bins.tsv is chunk/id/path. The id column differs.
  awk -F"$TAB" -v re="$CROSS_RE" '$3 ~ re {print $1}' "$WORK/parts/sorted.tsv" | sort \
    | while read -r id; do cat "$WORK/parts/$id.diff"; done > "$WORK/chunks/_cross.diff"

  count() { echo $#; }
  NTEST=$(awk -F"$TAB" '$1 ~ /^t/' "$WORK/bins.tsv" | wc -l | tr -d ' ')
  if [ -s "$WORK/chunks/_cross.diff" ]; then
    ALL="$KEYS _cross"; CROSS='+ 1 cross-cutting pass'
  else
    ALL="$KEYS"; CROSS='and no cross-cutting pass (nothing in the diff matches PR_REVIEW_CROSS_RE)'
  fi
  say "stage 1: $LABELS, $(count $KEYS) feature slice(s) $CROSS, $S1_JOBS at a time per transport"
  if [ "$BRIEF_OK" -eq 1 ]; then
    say "         $NTEST test file(s) in $(count $TKEYS) test slice(s), alongside the feature slices with the brief as context"
  else
    say "         $NTEST test file(s) in $(count $TKEYS) test slice(s), after the feature slices with their findings as context"
  fi

  # Every finder-tagged key for the given slices.
  slice_keys() { for k; do for f in $FINDERS; do load_finder "$f"; echo "$F_TAG$k"; done; done; }
  # all_done <tagged-key...>: every one has finished, with or without findings.
  all_done() { for k; do [ -f "$WORK/done/$k" ] || return 1; done; }
  # Runs every finder|slice item, longest first (tests, cross, features), up to S1_JOBS at a
  # time per transport. Test slices take the brief as context; with no brief they wait for
  # every feature slice and take its findings instead. A session-limit result from any slice
  # stops stage 1: nothing more is launched, every running slice is killed with its children,
  # and the run dies naming the limit.
  run_stage1() {
    local queue="" running="" gate="$BRIEF_OK" rest item f k s live still ctx t
    for k in $TKEYS $(printf '%s\n' $ALL | grep -x _cross) $KEYS; do
      for f in $FINDERS; do queue="$queue $f|$k"; done
    done
    while [ -n "$queue$running" ]; do
      live=" $(jobs -pr | tr '\n' ' ')"
      still=""; for t in $running; do case "$live" in *" ${t#*:} "*) still="$still $t" ;; esac; done; running="$still"
      if [ -f "$WORK/quota" ]; then
        for t in $running; do kill_tree "${t#*:}"; done
        wait 2>/dev/null
        die "stage 1: $(head -n 1 "$WORK/quota") -- stopped; finished slices are cached, rerun after the reset"
      fi
      if [ "$gate" -eq 0 ] && all_done $(slice_keys $KEYS); then
        gate=1
        merge_slices $(slice_keys $KEYS) > "$WORK/feature-findings.json"
        [ -z "$TKEYS" ] || say "stage 1: test slices, $(jq '.findings|length' "$WORK/feature-findings.json") feature finding(s) as context"
      fi
      rest=""
      for item in $queue; do
        f="${item%|*}"; k="${item##*|}"
        load_finder "$f"
        case "$k" in t[0-9]*) s=tests; [ "$gate" -eq 1 ] || { rest="$rest $item"; continue; }
                              ctx="$TEST_CTX" ;;
                     _cross)  s=cross; ctx="" ;;
                     *)       s=package; ctx="" ;; esac
        if [ "$(printf '%s\n' $running | grep -c "^$F_TRANSPORT:")" -ge "$S1_JOBS" ]; then
          rest="$rest $item"; continue
        fi
        review_slice "$F_TAG$k" "$s" "$WORK/chunks/$k.diff" $ctx &
        running="$running $F_TRANSPORT:$!"
      done
      queue="$(printf '%s\n' $rest)"
      [ -z "$queue$running" ] || sleep 0.5
    done
    wait
  }
  kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill "$1" 2>/dev/null || true; }
  # Namespaces ids by slice so stage 2's per-claim files and stage 3's join stay unique.
  # Slices that produced nothing are left out.
  merge_slices() {
    set -- $(for k; do
      [ -f "$WORK/slices/$k.json" ] || continue
      jq -c --arg s "$k" '. + {slice:$s}' "$WORK/slices/$k.json" > "$WORK/slices/$k.tagged"
      echo "$WORK/slices/$k.tagged"
    done)
    [ $# -gt 0 ] || { echo '{"findings":[]}'; return; }
    jq -s '{findings: (map(.slice as $s | .findings[] | .id = ($s + "-" + .id)))}' "$@"
  }

  # Snapshot for the report-only check below: changes in $ROOT during an agy finder run.
  [ "$HAS_AGY_FINDER" -eq 0 ] || repo_state > "$WORK/repo.stage1.pre"

  # Copied beside the diff, so a finder that can read its diff can read the brief.
  if [ "$BRIEF_OK" -eq 1 ]; then
    cp "$BRIEF" "$WORK/brief.md"; BRIEF_REF="$WORK/brief.md"; TEST_CTX="$BRIEF_REF"
    FINDINGS_REF="(none: the feature review runs alongside this one)"
  else
    BRIEF_REF="(none: no brief was written for this run)"
    FINDINGS_REF="$WORK/feature-findings.json"; TEST_CTX="$FINDINGS_REF"
  fi
  run_stage1

  if [ "$HAS_AGY_FINDER" -eq 1 ]; then
    repo_state > "$WORK/repo.stage1.post"
    CHANGED="$(comm -13 "$WORK/repo.stage1.pre" "$WORK/repo.stage1.post")"
    [ -z "$CHANGED" ] || warn "stage 1: $ROOT changed while the agy finder ran, left in place:
$(printf '%s\n' "$CHANGED" | sed 's/^/      /')"
  fi

  DONE=""
  for k in $(slice_keys $ALL $TKEYS); do
    if [ -f "$WORK/slices/$k.json" ]; then DONE="$DONE $k"; continue; fi
    GAPS="$GAPS $k"
    why='did not run'; [ ! -s "$FAILED/$k.reason" ] || why="$(head -n 1 "$FAILED/$k.reason")"
    GAP_NOTES="$GAP_NOTES
> - \`$k\`: $why"
  done
  [ -n "$DONE" ] || die "stage 1: every slice failed; rerun with --keep and read \$WORK/chunks/*.err"
  if [ -n "$GAPS" ]; then
    [ "$NFINDERS" -gt 1 ] && lost="those files went unreviewed by that finder" || lost="those files went unreviewed"
    warn "stage 1: no findings from:$GAPS — $lost"
  fi
  # A finder counts as having reviewed the diff only once it finished a slice.
  for f in $FINDERS; do
    load_finder "$f"
    case " $DONE" in *" $F_TAG"*)
      RAN_LABELS="${RAN_LABELS:+$RAN_LABELS + }$F_NAME"
      [ "$F_TRANSPORT" != anthropic ] || ANTHROPIC_RAN=1 ;;
    esac
  done
  merge_slices $DONE > "$WORK/findings.json"
fi

[ -f "$WORK/findings.json" ] || die "stage 1: no findings.json was written"
jq -e '.findings | type == "array"' "$WORK/findings.json" >/dev/null 2>&1 \
  || die "stage 1: findings.json is malformed; rerun with --keep and inspect it"
COUNT="$(jq '.findings | length' "$WORK/findings.json")"
say "stage 1: $COUNT finding(s)"

if [ "$COUNT" -eq 0 ]; then
  {
    echo "# PR #$PR — $TITLE"
    echo
    echo "$URL · reviewed at head \`$SHA\`"
    echo
    if [ -n "$FINDINGS_IN" ]; then
      echo "**No findings** in $(basename "$FINDINGS_IN"); stage 1 was skipped."
    elif [ "$ANTHROPIC_RAN" -eq 1 ]; then
      echo "**No findings.** $RAN_LABELS reviewed the diff and reported nothing worth validating."
    else
      echo "**No findings reported** by $RAN_LABELS."
      echo
      echo "> This is not a clean bill of health. Stage 1 had no result from the anthropic finder,"
      echo "> the only one whose recall has been measured as adequate. Re-run with it before"
      echo "> treating this PR as reviewed."
    fi
    [ -n "$GAPS" ] && { echo; echo "> Slices that produced nothing:$GAPS. Those files went **unreviewed**."; echo ">$GAP_NOTES"; }
  } > "$OUT"
  say "wrote $OUT"
  exit 0
fi

# -------------------------------------------------------------- stage 2: refute
# The refutation is its own command, and it carries the escape guard with it -- so anyone
# invoking it directly gets the same protection $ROOT gets here. Exit 3 means every claim
# has a verdict but scratch was quarantined into $WORK; force --keep, or cleanup deletes
# the evidence.
rc=0
"$HERE/refute" --findings "$WORK/findings.json" --tree "$TREE" --root "$ROOT" \
  --work "$WORK" --jobs "$JOBS" --transport "$R_TRANSPORT" --model "$R_MODEL" \
  --burden "$BURDEN" --timeout "$REFUTE_TIMEOUT" ${CROSS:+--cross} || rc=$?
case "$rc" in
  0) ;;
  3) KEEP=1 ;;
  *) die "stage 2: refute exited $rc" ;;
esac

# --------------------------------------------------------------- stage 3: merge
say "stage 3: merging"
jq -s '{verdicts: .}' "$WORK"/verdicts/*.json > "$WORK/verdicts.json"
jq -n --slurpfile f "$WORK/findings.json" --slurpfile v "$WORK/verdicts.json" '
  ($v[0].verdicts | INDEX(.id)) as $by
  | $f[0].findings
  | map(. + {v: ($by[.id] // {verdict:"ERROR", evidence:"",
                             reason:"no verdict produced; this claim was NOT checked"})})
' > "$WORK/merged.json"
# Sets .also on findings another finder also reported. Needs this run's finder-tagged ids.
if [ "$NFINDERS" -gt 1 ] && [ -z "$FINDINGS_IN" ]; then
  jq -f "$HERE/agree.jq" "$WORK/merged.json" > "$WORK/merged.agreed" || die "stage 3: agree.jq failed"
  mv "$WORK/merged.agreed" "$WORK/merged.json"
fi
# Sets .route: introduced (a line the PR adds) or pre-existing -- which fix lane a finding takes.
"$HERE/route" --diff "$WORK/pr.diff" "$WORK/merged.json" > "$WORK/merged.routed" \
  || die "stage 3: route failed"
mv "$WORK/merged.routed" "$WORK/merged.json"

jq -r -L "$HERE" -f "$HERE/report.jq" \
  --arg pr "$PR" --arg title "$TITLE" --arg url "$URL" --arg sha "$SHA" \
  --arg om "$LABELS" --arg gm "$R_LABEL" --arg same "$SAME_FAMILY" --arg burden "$BURDEN" --arg gaps "$GAPS" --arg gap_notes "$GAP_NOTES" \
  "$WORK/merged.json" > "$OUT" || die "stage 3: report generation failed"
# The record, not just the prose: merged.json is what anchors inline comments to
# file:line, and meta.json pins the head SHA those lines were resolved against.
cp "$WORK/merged.json" "$OUTDIR/merged.json"
cp "$WORK/meta.json"   "$OUTDIR/meta.json"
say "wrote $OUT"

# The inline payload: one review, one comment per finding, each anchored to a line
# GitHub will actually accept. Built every run so it can be read before it is posted.
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")"
if [ -n "$REPO" ]; then
  python3 "$HERE/inline.py" --merged "$OUTDIR/merged.json" --meta "$OUTDIR/meta.json" \
    --repo "$REPO" --out "$OUTDIR/inline.json" || say "inline payload generation failed"
fi

# ---------------------------------------------------------------- stage 4: post
post() {
  [ "$POST" -eq 1 ] || { say "not posting (pass --post to offer it)"; return 0; }
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "stage 4: --post needs a terminal to confirm, or pass --yes"
    printf '\033[33mPost this to %s as a public comment? [y/N] \033[0m' "$URL" >&2
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) ;; *) say "not posted; $OUT kept"; return 0 ;; esac
  fi
  if [ "$INLINE" -eq 1 ]; then
    [ -s "$OUTDIR/inline.json" ] || die "stage 4: --inline needs $OUTDIR/inline.json"
    # "marker" is inline.py's, not GitHub's.
    jq 'del(.comments[].marker)' "$OUTDIR/inline.json" > "$WORK/inline.post.json"
    gh api "repos/$REPO/pulls/$PR/reviews" --input "$WORK/inline.post.json" >/dev/null \
      || die "stage 4: gh api reviews failed"
  else
    gh pr comment "$PR" --body-file "$OUT" || die "stage 4: gh pr comment failed"
  fi
  say "posted to $URL"
}
post

# ------------------------------------------------------------- stage 5: fix PRs
# A fix author's CONFIRMED findings get fix PRs, one per lane (lanes.jq): what the PR introduced
# stacked on its head as this review read it, what was already at its base on trunk's tip, and
# with AUTOFIX_LINT=1 trunk's analyzer issues in the packages it touches. autofix.sh implements,
# gates on the touched packages' tests, pushes, opens each and asks the author to review. A
# lane that owed a PR and didn't open one is exit 4, never a quiet 0.
CONFIRMED="$(jq '[.[] | select(.v.verdict == "CONFIRMED")] | length' "$OUTDIR/merged.json")"
{ [ "$NO_FIX" -eq 0 ] && [ "$CONFIRMED" -gt 0 ] && is_fix_author "$AUTHOR"; } || exit 0
[ -z "$PIN" ] || { say "stage 5: --sha reviewed a pinned commit, not the head -- no fix PR"; exit 0; }
LANES="$(jq -r -L "$HERE" --arg s "$(jq -r .state "$OUTDIR/meta.json")" \
  'include "lanes"; fix_lanes($s) | join(" ")' "$OUTDIR/merged.json")"
[ "${AUTOFIX_LINT:-0}" != 1 ] || LANES="$LANES lint"
say "stage 5: fix PRs for $AUTHOR's $CONFIRMED confirmed finding(s) -- lanes: $LANES"
OWED=0
for lane in $LANES; do
  rc=0
  FIX="$(env -u AUTOFIX_MODE -u AUTOFIX_FROZEN AUTOFIX_LANE="$lane" AUTOFIX_REVIEWER="$AUTHOR" \
    "$AUTOFIX" "$PR" "$SHA" "$ROOT" "$OUTDIR")" || rc=$?
  printf '%s\n' "$FIX" | sed "s/^STATUS=/LANE=$lane STATUS=/"
  case "$rc:$FIX" in
    0:*STATUS=opened:*|0:*STATUS=exists:*|0:*STATUS=none*) ;;
    0:*STATUS=dropped*) warn "stage 5: the trunk lane found nothing to fix on trunk -- dropped; see $OUT" ;;
    *STATUS=stale*) OWED=1; warn "stage 5: #$PR moved past ${SHA:0:12} during the review -- NO fix PR opened ($lane lane); re-run the review" ;;
    *) OWED=1; warn "stage 5: autofix opened NO fix PR for #$PR ($lane lane, exit $rc) -- see above; the findings stand in $OUT" ;;
  esac
done
[ "$OWED" = 0 ] || exit 4
