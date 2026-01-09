#!/usr/bin/env bash
set -eo pipefail

# shellcheck disable=SC2016 # Expr won't expand in '' quotes

sanitize() (
  while read -r file; do
    # this yq command does the following:
    # dedup keys with last-occurrence-wins
    # keep order of keys' first occurrence
    # preserve all docs with --- delimiter
    # preserve comments & trim whitespace

    # https://mikefarah.gitbook.io/yq/usage/tips-and-tricks#logic-without-if-elif-else
    # https://mikefarah.gitbook.io/yq/operators/multiply-merge#objects-and-arrays-merging

    yq -i --header-preprocess=false '{} as $temp
      | with(select(kind == "map"); $temp.init = {})
      | with(select(kind == "seq"); $temp.init = [])
      | . as $item ireduce ($temp.init; . *d $item)
      | "---\n\(to_yaml | trim)"' "$file"
  done < <(
    find "$1" \( -name '*.yaml' -o -name '*.yml' \)
  )
)
for arg in "$@"; do
  case "$arg" in
    build) build=1
           ;;
       -h|--help)
            help=1
           ;;
       -*) ;;
        *) [ ! "$build_dir" ] && [ "$build" ] \
           && [ -d "$arg" ] && build_dir="$arg"
           ;;
  esac
done

# sanitize only if actually building
[ "$build" ] && [ ! "$help" ] && \
  sanitize "${build_dir:-.}"

exec kustomize "$@"
