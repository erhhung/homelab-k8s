#!/usr/local/bin/python3

# not sure why using shebang "#!/usr/bin/env python3" doesn't
# work as Ansible invokes this module script via "/bin/sh -c"
# (/bin/sh: /usr/bin/env python3: No such file or directory),
# but actual interpreter in $PATH is "~/.pyenv/shims/python3"

import toml
import json


class FilterModule(object):
    def filters(self):
        return {
            "to_toml": self.to_toml,
        }

    # https://www.iops.tech/blog/generate-toml-using-ansible-template/
    def to_toml(self, variable):
        s = json.dumps(dict(variable))
        d = json.loads(s)
        return toml.dumps(d)
