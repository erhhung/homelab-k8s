#!/usr/local/bin/python3

# not sure why using shebang "#!/usr/bin/env python3" doesn't
# work as Ansible invokes this module script via "/bin/sh -c"
# (/bin/sh: /usr/bin/env python3: No such file or directory),
# but actual interpreter in $PATH is "~/.pyenv/shims/python3"

from ansible.module_utils.basic import AnsibleModule
import time


def get_local_timezone_offset():
    secs = -time.timezone if time.localtime().tm_isdst == 0 else -time.altzone
    return {
        "in_seconds": secs,
        "in_hours": secs // 3600,
    }


def main():
    module = AnsibleModule(argument_spec={})
    offset = get_local_timezone_offset()
    module.exit_json(changed=False, **offset)


if __name__ == "__main__":
    main()
