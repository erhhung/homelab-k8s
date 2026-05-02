import groovy.transform.Field

@Field private static final String YELLOW = '\u001B[1;33m'
@Field private static final String BLUE   = '\u001B[1;34m'
@Field private static final String CYAN   = '\u001B[0;36m'
@Field private static final String CLEAR  = '\u001B[0m'

void call(String section, String title, Closure body) {
  sectionStart(section, title)
  try {
    body()
  } finally {
    sectionEnd(section)
  }
}

private void sectionStart(String section, String title) {
  String text = ">>>${YELLOW}${section}${CLEAR}>>> ${BLUE}${title}${CLEAR}"
  String line = '-' * ">>>${section}>>> ${title}".length()
  println "${text}\n${CYAN}${line}${CLEAR}"
}

private void sectionEnd(String section) {
  String text = "<<<${YELLOW}${section}${CLEAR}<<<"
  String line = '-' * "<<<${section}<<<".length()
  println "${CYAN}${line}${CLEAR}\n${text}"
}
