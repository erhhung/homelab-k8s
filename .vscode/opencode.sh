# shellcheck disable=SC2148 # Tips depend on target shell

lock_dir=/tmp/opencode/.vscode
lock_file=$lock_dir/opencode.lock
lock_owner=$lock_dir/owner.yaml

mkdir -p $lock_dir

# keep file descriptor 9 open for
# the entire lifetime of OpenCode
exec 9> $lock_file

if ! flock -n 9; then
  echo
  echo "OpenCode is already running in another VS Code workspace:"
  echo
  [ -r $lock_owner ] && yq < $lock_owner || \
    echo "(workspace information not available)"
  echo
  exit 75 # EX_TEMPFAIL
fi

cat > $lock_owner <<EOF
workspace: $PWD
started: $(date)
pid: $$
EOF

export SLACK_AGENT_ENABLED=true
exec opencode
