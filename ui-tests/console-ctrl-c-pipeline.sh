#!/usr/bin/bash
set -euo pipefail

# The native sleeper keeps the console in native mode. Ctrl+C must
# still interrupt the Cygwin sleep at the other end of the pipe.
# See <20260923105326.d57b0710f1519e32b9c5d496@nifty.ne.jp>.
/usr/bin/sleep 10 |
  "$SYSTEMROOT/System32/WindowsPowerShell/v1.0/powershell.exe" \
    -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 10'
