#!/usr/bin/python

# Ansible rewrites its standard Python shebang using `ansible_python_interpreter`.

import time

from ansible.module_utils.basic import AnsibleModule  # type: ignore[import-not-found]


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
