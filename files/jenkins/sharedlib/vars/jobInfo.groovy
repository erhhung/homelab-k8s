Object call() {
  return bash('''
    identities
    sys_info
    env_vars
  ''')
}
