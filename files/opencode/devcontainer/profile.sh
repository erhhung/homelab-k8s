PS1="\[\033[1;36m\]$USER\[\033[1;31m\]@\[\033[1;32m\]\h:\[\033[1;35m\]\w\[\033[1;31m\]$\[\033[0m\] "

# only works once VSCode remote SSH server
# is dynamically installed upon connection
EDITOR="code --wait"
VISUAL="$EDITOR"

LESS="-RFKMi -x4 -z-4"
LESSOPEN="|-$HOME/.lessopen %s"
LESS_ADVANCED_PREPROCESSOR=1
LESSCOLORIZER=pygmentize
LESSCHARSET=utf-8
LESSQUIET=1

LESS_TERMCAP_mb=$'\E[1;31m'     # begin bold
LESS_TERMCAP_md=$'\E[1;36m'     # begin blink
LESS_TERMCAP_me=$'\E[0m'        # reset bold/blink
LESS_TERMCAP_so=$'\E[01;44;33m' # begin reverse video
LESS_TERMCAP_se=$'\E[0m'        # reset reverse video
LESS_TERMCAP_us=$'\E[1;32m'     # begin underline
LESS_TERMCAP_ue=$'\E[0m'        # reset underline

MISE_ENV_FILE=.env
GREP_OPTIONS="--color=auto"
DELTA_PAGER="less -RFKLMin"

# secret key from Secret-mounted volume
AGE_KEY_FILE=/run/secrets/AGE_SECRET_KEY

# ~/.kube/config-vclusters is volume-mounted read-only file
KUBECONFIG="$HOME/.kube/config:$HOME/.kube/config-vclusters"
