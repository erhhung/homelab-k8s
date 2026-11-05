# shellcheck disable=SC2148 # Tips depend on target shell

# stop_openclaw_relay       # default port 18799
# stop_openclaw_relay 18800 # another relay port
#
stop_openclaw_relay() {
  local port="${1:-18799}" pid command

  for pid in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN); do
    command="$(ps -p "$pid" -o command=)" || continue

    case "$command" in
      *relay-daemon-entry.js*)
        printf 'Stopping OpenClaw relay PID %s\n' "$pid"
        kill -TERM "$pid"
        ;;
      *)
        printf >&2 'Skipping non-relay process PID %s: %s\n' "$pid" "$command"
        ;;
    esac
  done
}
