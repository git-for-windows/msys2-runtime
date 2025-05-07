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
"$SYSTEMROOT/System32/WindowsPowerShell/v1.0/powershell.exe" \
  -NoProfile -NonInteractive \
  -Command "Start-Sleep -Milliseconds $((RANDOM % 4336))"
