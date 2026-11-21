# shellcheck shell=bash
# Helpers shared by the offline tests (autofix-test.sh, offline-test.sh). Sourced.

# 12-hour clock text for an epoch ("9:20pm"), portable: BSD date has no -d and no %P.
clock() { python3 -c 'import sys,time;t=time.gmtime(int(sys.argv[1]));print("%d:%02d%s"%(t.tm_hour%12 or 12,t.tm_min,"am" if t.tm_hour<12 else "pm"))' "$1"; }
