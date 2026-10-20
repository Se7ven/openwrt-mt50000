#!/usr/bin/env python3
"""merge-config.py - merge OpenWrt config fragments into a .config file.

The classic "scripts/diffconfig.sh -m <fragment> .config" was removed from
upstream OpenWrt in 2026, therefore this builder ships its own merger. It is
independent of the OpenWrt version in the tree and behaves the same way:

  * every "CONFIG_X=y" / "CONFIG_X=value" line of a fragment replaces the
    value of CONFIG_X in the .config
  * every "# CONFIG_X is not set" line of a fragment unsets CONFIG_X
  * symbols that do not exist in the tree are kept in the .config and are
    dropped by "make defconfig" with a warning - that is the wanted behaviour,
    it allows one fragment to be used with different OpenWrt versions
  * the order of the .config is preserved, new symbols are appended

Usage:
    merge-config.py --config .config --merge buildinfo.config [--merge ...]
"""

import argparse
import re
import sys

SET_RE = re.compile(r"^(CONFIG_[A-Za-z0-9_-]+)=(.*)$")
UNSET_RE = re.compile(r"^# (CONFIG_[A-Za-z0-9_-]+) is not set$")


def parse(lines):
    """Return (order, values) of a config file."""
    order = []
    values = {}
    for line in lines:
        line = line.rstrip("\n")
        m = SET_RE.match(line)
        if m:
            if m.group(1) not in values:
                order.append(m.group(1))
            values[m.group(1)] = ("set", m.group(2))
            continue
        m = UNSET_RE.match(line)
        if m:
            if m.group(1) not in values:
                order.append(m.group(1))
            values[m.group(1)] = ("unset", "")
            continue
    return order, values


def render(order, values):
    out = []
    for symbol in order:
        kind, value = values[symbol]
        if kind == "set":
            out.append("%s=%s" % (symbol, value))
        else:
            out.append("# %s is not set" % symbol)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True, help="the .config file to patch")
    ap.add_argument("--merge", action="append", default=[],
                    help="fragment to merge into the .config (can be given several times)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(args.config) as fh:
        order, values = parse(fh.readlines())

    added = 0
    for fragment in args.merge:
        with open(fragment) as fh:
            frag_order, frag_values = parse(fh.readlines())
        for symbol in frag_order:
            if symbol not in values:
                order.append(symbol)
                added += 1
            values[symbol] = frag_values[symbol]

    result = render(order, values)
    if args.dry_run:
        print("\n".join(result))
        return 0

    with open(args.config, "w") as fh:
        fh.write("\n".join(result) + "\n")

    print("merged %d fragment(s) into %s (%d new symbols)"
          % (len(args.merge), args.config, added))
    return 0


if __name__ == "__main__":
    sys.exit(main())
