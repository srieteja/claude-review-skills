# agy-quota.sh -- sourced by refute. Targets bash 3.2.
#
# agy meters quota per model: `RESOURCE_EXHAUSTED (code 429): Individual quota reached` on one
# model leaves every other model runnable, so the right response is the next model, not a wait
# (the reset can be days out -- PR 2373's was 95h).

# The signal is agy's own AGY_ERROR line on stderr, and only that. The stdout envelope is no
# use: a model that dies mid-run has already narrated its reads there, and a task about rate
# limiting would mention 429 in prose. Exit codes are not documented, so they are not used.
agy_quota_hit() { # err-file
  grep '^AGY_ERROR:' "$1" 2>/dev/null | grep -qE 'RESOURCE_EXHAUSTED|"error_code": *429'
}

# Model lists come from flags and env as comma- or space-separated ids. Normalise to one
# space-separated line, first occurrence wins -- so `agy_models "$head" "$list"` puts a
# preferred model first without running it twice.
agy_models() { # list...
  printf '%s\n' "$*" | tr ', ' '\n\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//'
}
