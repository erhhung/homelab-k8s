void call() {
  section('checkout', 'Checkout Git Repo') {
    Map<String, String> scmEnv = checkout(scm)
    flushLog()

    scmEnv.each { key, value -> env[key] = value }
    env.GIT_COMMIT_SHORT_SHA = scmEnv.GIT_COMMIT.take(8)
  }
}
