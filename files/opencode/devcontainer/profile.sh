PS1="\[\033[1;36m\]$USER\[\033[1;31m\]@\[\033[1;32m\]\h:\[\033[1;35m\]\w\[\033[1;31m\]$\[\033[0m\] "

# only works once VSCode remote SSH server
# is dynamically installed upon connection
EDITOR="code --wait"
VISUAL="$EDITOR"

# secret key from Secret-mounted volume
AGE_KEY_FILE=/run/secrets/AGE_SECRET_KEY
