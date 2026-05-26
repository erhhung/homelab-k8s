from ansible.utils.display import Display
from typing import TypeVar, overload

log = Display()
U = TypeVar("U")


class FilterModule(object):
    def filters(self):
        return {
            "substr": self.substr,
            "append": self.append,
            "prepend": self.prepend,
            "to_case": self.to_case,
            "omit_keys": self.omit_keys,
            "local_iso_to_utc_iso": self.local_iso_to_utc_iso,
            "b64_decode_k8s_secret": self.b64_decode_k8s_secret,
        }

    # Jinja's `slice` filter isn't Python string
    # slicing, and there isn't a `substr` filter
    def substr(self, str: str, start: int, end: int = None) -> str:
        "Python string slicing"
        return str[start:end]

    @overload
    def append(self, item1: str, item2: str) -> str: ...

    @overload
    def append(self, item1: list[U], item2: list[U]) -> list[U]: ...

    def append(self, item1, item2):
        "append second of two items of the same type (str or list) to the first"
        return item1 + item2

    @overload
    def prepend(self, item1: str, item2: str) -> str: ...

    @overload
    def prepend(self, item1: list[U], item2: list[U]) -> list[U]: ...

    def prepend(self, item1, item2):
        "prepend second of two items of the same type (str or list) to the first"
        return item2 + item1

    def to_case(self, str: str, case: str) -> str:
        "convert string to upper|lower|title|camel|pascal|snake|kebab case"
        import re

        def split_words(s):
            # handle camelCase & PascalCase by
            # inserting spaces before capitals
            s = re.sub(r"([a-z])([A-Z])", r"\1 \2", s)
            # split on separators & filter out empty strings
            return [w for w in re.split(r"[\s_-]+", s) if w]

        words = split_words(str)
        if not words:
            return str

        match case:
            case "upper":
                return " ".join(w.upper() for w in words)
            case "lower":
                return " ".join(w.lower() for w in words)
            case "title":
                return " ".join(w.title() for w in words)
            case "camel":
                return words[0].lower() + "".join(w.title() for w in words[1:])
            case "pascal":
                return "".join(w.title() for w in words)
            case "snake":
                return "_".join(w.lower() for w in words)
            case "kebab":
                return "-".join(w.lower() for w in words)
            case _:
                raise ValueError(f"Invalid case: {case}")

    def omit_keys(self, obj: dict, keys: list) -> dict:
        r"""
        return a copy of obj without the specified keys
        (remove nested keys by using dot.notation keys)

        e.g. "metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration"

        if omitting a nested key like "a.b.c.d", interior
        keys like "b" and "c" may refer to lists of dicts
        """
        import copy
        import re

        def _descend(nodes, part):
            children = []

            for node in nodes:
                if isinstance(node, dict) and part in node:
                    child = node[part]
                    if isinstance(child, list):
                        children.extend(child)
                    elif child is not None:
                        children.append(child)

            return children

        result = copy.deepcopy(obj)

        for path in keys:
            nodes = [result]

            # split on non-backslash-escaped '.'
            parts = re.split(r"(?<!\\)\.", path)
            # unescape '.' in each key path part
            parts = [p.replace("\\.", ".") for p in parts]

            parents = parts[:-1]
            omit_key = parts[-1]

            for part in parents:
                nodes = _descend(nodes, part)
                if not nodes:
                    break

            for node in nodes:
                items = node if isinstance(node, list) else [node]
                for item in items:
                    if isinstance(item, dict) and omit_key in item:
                        del item[omit_key]

        return result

    def local_iso_to_utc_iso(
        self, iso: str, tz: str, precision: str = "seconds"
    ) -> str:
        """
        convert local ISO date/time string to ISO UTC format

        tz: IANA name (America/Los_Angeles)
        precision: seconds|s|milliseconds|ms
        """
        from datetime import datetime, UTC
        from zoneinfo import ZoneInfo

        try:
            tz = ZoneInfo(tz)
        except Exception:
            raise ValueError(f"Invalid time zone: {tz}")
        dt = datetime.fromisoformat(iso).replace(tzinfo=tz)

        tspec = precision.lower()
        if tspec in ["seconds", "s"]:
            tspec = "seconds"
        elif tspec in ["milliseconds", "ms"]:
            tspec = "milliseconds"
        else:
            raise ValueError(f"invalid precision: {precision}")

        return dt.astimezone(UTC).isoformat(timespec=tspec).replace("+00:00", "Z")

    def b64_decode_k8s_secret(self, secret: dict) -> dict:
        "base64-decode each dict value in secret.data into string"
        import base64

        d = {}
        if secret is not None and "data" in secret:
            for k, v in secret["data"].items():
                d[k] = base64.b64decode(v).decode("utf-8")
        return d
