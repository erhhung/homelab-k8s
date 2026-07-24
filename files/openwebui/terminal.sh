#!/bin/sh

# this script will be installed on Open Terminal hosts as
# ~/.local/bin/open-terminal-start;  on macOS, it will be
# run by the Platypus-generated app, which, in turn, will
# be run by the macpmd-managed launchd service; on Linux,
# it will be run directly  by the macpmd-managed systemd
# service

cd "$HOME" || exit 1

app_pid=$PPID
uvx open-terminal run &
uvx_pid=$!

cleanup() {
  trap - EXIT INT TERM HUP

  # terminate uvx immediate children,
  # including Python, then uvx itself
  pkill -TERM -P $uvx_pid 2> /dev/null
   kill -TERM    $uvx_pid 2> /dev/null
  sleep 1 # wait for processes to exit

  # now kill forcefully if still exist
  pkill -KILL -P $uvx_pid 2> /dev/null
   kill -KILL    $uvx_pid 2> /dev/null
  wait $uvx_pid           2> /dev/null
}
trap cleanup EXIT INT TERM HUP

while   kill -0  $uvx_pid 2> /dev/null; do
  if !  kill -0  $app_pid 2> /dev/null  || \
     [ $PPID -ne $app_pid ]; then
    # Platypus app has exited or
    # script has been reparented
    exit 0
  fi
  sleep 1
done

wait $uvx_pid
