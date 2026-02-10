import json
import toml
import base64


class FilterModule(object):
    def filters(self):
        return {
            "to_toml": self.to_toml,
            "b64_decode_k8s_secret": self.b64_decode_k8s_secret,
        }

    # https://www.iops.tech/blog/generate-toml-using-ansible-template
    def to_toml(self, o) -> str:
        s = json.dumps(dict(o))
        d = json.loads(s)
        return toml.dumps(d)

    def b64_decode_k8s_secret(self, secret) -> dict:
        "base64-decode each dict value in secret.data into string"
        d = {}
        for k, v in secret["data"].items():
            d[k] = base64.b64decode(v).decode("utf-8")
        return d
