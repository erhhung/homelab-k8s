// https://jenkins.fourteeners.local/plugin/job-dsl/api-viewer/index.html#path/pipelineJob
pipelineJob('Argo CD') {
  description('Pipeline for github.com/erhhung/argo-cd')

  properties {
    // https://jenkins.fourteeners.local/plugin/job-dsl/api-viewer/index.html#path/pipelineJob-properties-githubProjectUrl
    githubProjectUrl('https://github.com/erhhung/argo-cd')
  }
  triggers {
    // https://jenkins.fourteeners.local/plugin/job-dsl/api-viewer/index.html#path/pipelineJob-triggers-scm
    scm('H/10 * * * *')
  }

  definition {
    cpsScm {
      scm {
        // https://jenkins.fourteeners.local/plugin/job-dsl/api-viewer/index.html#path/pipelineJob-definition-cpsScm-scm-git
        git {
          remote {
            name('origin')
            url('git@github.com:erhhung/argo-cd.git')
            credentials('erhhung-ssh')
            refspec('+refs/heads/jenkins-ci:refs/remotes/origin/jenkins-ci')
          }
          // in order for `lightweight(true)` to
          // work, `branch` must match `refspec`
          branch('refs/heads/jenkins-ci')
          browser {
            github {
              repoUrl('https://github.com/erhhung/argo-cd')
            }
          }
        }
      }
      scriptPath('Jenkinsfile')
      lightweight(true)
    }
  }
}
