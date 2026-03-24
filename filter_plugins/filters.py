import json
import toml
import base64


class FilterModule(object):
    def filters(self):
        return {
            "substr": self.substr,
            "append": self.append,
            "prepend": self.prepend,
            "to_toml": self.to_toml,
            "b64_decode_k8s_secret": self.b64_decode_k8s_secret,
        }

    # Jinja's `slice` filter isn't Python string
    # slicing, and there isn't a `substr` filter
    def substr(self, str, start, end=None) -> str:
        "Python string slicing"
        return str[start:end]

    def append(self, str, suffix) -> str:
        "add suffix to string"
        return str + suffix

    def prepend(self, str, prefix) -> str:
        "add prefix to string"
        return prefix + str

    # https://www.iops.tech/blog/generate-toml-using-ansible-template
    def to_toml(self, obj) -> str:
        "convert dict to TOML string"
        s = json.dumps(dict(obj))
        d = json.loads(s)
        return toml.dumps(d)

    def b64_decode_k8s_secret(self, secret) -> dict:
        "base64-decode each dict value in secret.data into string"
        d = {}
        for k, v in secret["data"].items():
            d[k] = base64.b64decode(v).decode("utf-8")
        return d
