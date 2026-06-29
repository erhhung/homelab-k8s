# Bazel Remote Build Test

This Bazel project builds a Hello World C++ project using **Buildfarm** CAS and RBE endpoints, as well as **BuildBuddy** BES endpoints.

## Prerequisites

This build test requires [**Bazelisk**](https://github.com/bazelbuild/bazelisk) (`brew install bazelisk`) and `envsubst` (`brew install gettext`).

## Setup/Reset

```bash
bazel mod tidy
bazel clean --expunge
rm -f MODULE.bazel.lock
```

## Run Build

```bash
# run build without using cached artifacts
bazel build --noremote_accept_cached //main:hello-world

# run normal build reusing cached artifacts
bazel build //main:hello-world
```

Open the results URL shown at the end of the build.  
The BuildBuddy UI displays many useful build stats.

```
...
Target //main:hello-world up-to-date:
  bazel-bin/main/hello-world
INFO: Elapsed time: 80.042s, Critical Path: 2.88s
INFO: 1773 processes: 59 action cache hit, 1772 remote cache hit, 1 internal.
INFO: Build completed successfully, 1773 total actions
INFO: 
INFO: Streaming build results to: https://buildbuddy.fourteeners.local/invocation/d79da48c-d31e-4785-9740-05c96ba026ff
```

## Run Tests

```bash
bazel test --test_output=all //test:hello-test
```

## Run Binary

```bash
docker run --rm --platform linux/amd64 \
  -v "$PWD/bazel-bin/main/hello-world:/hello-world:ro" \
  alpine /hello-world Bazel
```

## Build History

To show the BuildBuddy build history, run:

```bash
./history.sh [max-results=10]
```
