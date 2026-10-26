#!/usr/bin/env python3
"""YAML loading that rejects a repeated mapping key (used by check_params.py).

PyYAML, yq and most tools keep the last duplicate and say nothing, so a pair of
lines pasted under the wrong key silently changes what an entry means (Round 23:
`disableInitialBackup` carried the `fleet:` and `format:` of `backupEnableSSL`).

  python3 dupkeys.py FILE...    print "FILE:LINE: duplicate key 'K' (first at line N)"
                                for each repeat; exit 1 when there is any
"""
import sys

import yaml


class DuplicateKey(yaml.YAMLError):
    def __init__(self, key, line, first):
        super().__init__(f"{line}: duplicate key {key!r} (first at line {first})")
        self.key, self.line, self.first = key, line, first


class UniqueKeyLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        seen = {}
        for key_node, _ in node.value:
            if key_node.tag == "tag:yaml.org,2002:merge":
                continue
            key = self.construct_object(key_node, deep=True)
            try:
                hash(key)
            except TypeError:
                continue   # a complex key: the base class refuses it
            line = key_node.start_mark.line + 1
            if key in seen:
                raise DuplicateKey(key, line, seen[key])
            seen[key] = line
        return super().construct_mapping(node, deep)


def check_file(path):
    """The first problem of the file as 'path:line: message', or None."""
    try:
        with open(path) as fh:
            for _ in yaml.load_all(fh, Loader=UniqueKeyLoader):
                pass
    except DuplicateKey as e:
        return f"{path}:{e}"
    except yaml.YAMLError as e:
        return f"{path}: {str(e).splitlines()[0]}"
    return None


if __name__ == "__main__":
    found = [m for m in (check_file(p) for p in sys.argv[1:]) if m]
    print("\n".join(found))
    sys.exit(1 if found else 0)
