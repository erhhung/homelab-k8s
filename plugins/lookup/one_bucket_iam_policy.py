# https://docs.ansible.com/ansible/latest/dev_guide/developing_plugins.html#lookup-plugins

from __future__ import absolute_import, division, print_function

__metaclass__ = type

from ansible.plugins.lookup import LookupBase
from ansible.utils.display import Display

log = Display()

DOCUMENTATION = r"""
  name: one_bucket_iam_policy
  short_description: Generate IAM policy restricting access to an existing S3 bucket.
  description:
    - >-
      This lookup returns a dictionary containing Statement as its sole key, under
      which a list of policy statements are defined according to the options given.
  options:
    _terms:
      description: Bucket name
      required: True
    readonly:
      type: bool
      description: Allow read-only actions on the bucket
      default: False
  notes:
    - The default read-write policy is broad, allowing "s3:*" actions on the bucket.
    - The read-only policy is also broad, allowing "s3:Get*" and "s3:List*" actions.
    - https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-policies-s3.html
"""


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)

        ret = []
        for bucket in terms:
            log.debug(f"S3 bucket name: {bucket}")
            if self.get_option("readonly"):
                log.debug("Generating read-only policy")
                actions = [
                    "s3:Get*",
                    "s3:List*",
                ]
            else:
                log.debug("Generating read-write policy")
                actions = [
                    "s3:*",
                ]
            ret.append(
                {
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": "s3:ListBucket",
                            "Resource": f"arn:aws:s3:::{bucket}",
                        },
                        {
                            "Effect": "Allow",
                            "Action": actions,
                            "Resource": f"arn:aws:s3:::{bucket}/*",
                        },
                        {
                            "Effect": "Deny",
                            "Action": "s3:*",
                            "NotResource": [
                                f"arn:aws:s3:::{bucket}",
                                f"arn:aws:s3:::{bucket}/*",
                            ],
                        },
                    ]
                }
            )
        return ret
