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

    def append(self, str: str, suffix: str) -> str:
        "add suffix to string"
        return str + suffix

    def prepend(self, str: str, prefix: str) -> str:
        "add prefix to string"
        return prefix + str

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
        """
        import copy
        import re

        result = copy.deepcopy(obj)

        for path in keys:
            node = result
            try:
                # split on non-backslash-escaped '.'
                parts = re.split(r"(?<!\\)\.", path)
                # unescape '.' in each key path part
                parts = [p.replace("\\.", ".") for p in parts]

                # find parent dictionary
                for part in parts[:-1]:
                    node = node[part]
                omit_key = parts[-1]

                if isinstance(node, dict) and omit_key in node:
                    del node[omit_key]
            except (KeyError, TypeError):
                continue

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

    def b64_decode_k8s_secret(self, secret) -> dict:
        "base64-decode each dict value in secret.data into string"
        import base64

        d = {}
        for k, v in secret["data"].items():
            d[k] = base64.b64decode(v).decode("utf-8")
        return d
