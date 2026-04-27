// groovylint-disable CompileStatic, UnusedVariable

import groovy.transform.Field

@Field
private String ciUtils = null

Object call(String script) {
  return sh(script: wrapScript(script))
}

Object call(Map args, String script) {
  Map shArgs = new LinkedHashMap(args)
  shArgs.script = wrapScript(script)
  return sh(shArgs)
}

private String utils() {
  if (ciUtils == null) {
    ciUtils = libraryResource('ciutils.sh')
  }
  return ciUtils
}

private String wrapScript(String script) {
  return """\
#!/usr/bin/env bash
set -eo pipefail
${utils()}
${script}
"""
}
