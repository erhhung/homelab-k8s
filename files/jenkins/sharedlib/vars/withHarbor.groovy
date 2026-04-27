Object call(Closure body) {
  return withCredentials([usernamePassword(
    credentialsId:    'harbor-creds',
    usernameVariable: 'CI_REGISTRY_USER',
    passwordVariable: 'CI_REGISTRY_PASSWORD',
  )]) {
    body()
  }
}
