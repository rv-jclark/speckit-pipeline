#!/usr/bin/env bash
#
# dashboard.sh — open the pipelines dashboard straight from this clone, with
# nothing installed.
#
#   ./dashboard.sh                  serve ~/code on http://127.0.0.1:8788 and open it
#   ./dashboard.sh --root ~/work    any spec-dashboard option passes through
#
# Opens the browser by default. If a dashboard is already running, it just
# opens the page again. Ctrl-C stops the server.
exec "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/plugins/speckit-pipeline/bin/spec-dashboard" --open "$@"
