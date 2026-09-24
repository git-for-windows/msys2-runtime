#!/usr/bin/bash
set -euo pipefail

if test "$#" -ne 1 || ! test -t 0 || ! test -t 1
then
  printf 'Job %s requires a console on stdin and stdout\n' \
    "${1-<missing>}" >&2
  exit 125
fi
printf 'hello from TEST %s\n' "$1"
# Keep a native Windows child alive for a random 0-4 seconds.
ping.exe -n "$((1 + RANDOM % 5))" 127.0.0.1 >/dev/null
