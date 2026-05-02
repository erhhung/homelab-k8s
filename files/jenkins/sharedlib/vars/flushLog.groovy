// https://javadoc.jenkins.io/hudson/model/TaskListener.html
import hudson.model.TaskListener

void call() {
  TaskListener listener = getContext(TaskListener)
  listener.logger.flush()
}
