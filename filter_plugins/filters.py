import toml
import json


class FilterModule(object):
    def filters(self):
        return {
            "to_toml": self.to_toml,
        }

    # https://www.iops.tech/blog/generate-toml-using-ansible-template/
    def to_toml(self, o):
        s = json.dumps(dict(o))
        d = json.loads(s)
        return toml.dumps(d)
