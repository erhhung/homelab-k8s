Object call(Closure body) {
  return withCredentials([usernamePassword(
    credentialsId:    'harbor-auth',
    usernameVariable: 'CI_REGISTRY_USER',
    passwordVariable: 'CI_REGISTRY_PASSWORD',
  )]) {
    body()
  }
}
