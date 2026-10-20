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

Choice handling (important for the target/profile selection):

  The target, the subtarget and the device are members of Kconfig choices.
  If the .config still selects another member of the same choice, "make
  defconfig" keeps the *old* member and silently drops the new one - the
  device would not be built at all.  When a Kconfig file is given with
  --kconfig, the other members of the same choice are unset automatically.

Usage:
    merge-config.py --config .config --merge buildinfo.config [--merge ...]
                    [--kconfig tmp/.config-target.in]
"""

import argparse
import re
import sys

SET_RE = re.compile(r"^(CONFIG_[A-Za-z0-9_-]+)=(.*)$")
UNSET_RE = re.compile(r"^# (CONFIG_[A-Za-z0-9_-]+) is not set$")
CHOICE_MEMBER_RE = re.compile(r"^(?:menu)?config ([A-Za-z0-9_-]+)$")


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


def parse_choices(path):
    """Return the list of Kconfig choices (lists of member symbols)."""
    choices = []
    stack = []
    current = None
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return choices

    for raw in lines:
        line = raw.strip()
        if line == "choice" or line.startswith("choice "):
            stack.append([])
            current = stack[-1]
            continue
        if line == "endchoice":
            if stack:
                choices.append(stack.pop())
            current = stack[-1] if stack else None
            continue
        m = CHOICE_MEMBER_RE.match(line)
        if m and current is not None:
            current.append(m.group(1))
    return choices


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True, help="the .config file to patch")
    ap.add_argument("--merge", action="append", default=[],
                    help="fragment to merge into the .config (can be given several times)")
    ap.add_argument("--kconfig", default="",
                    help="Kconfig file used to detect the members of the choices "
                         "(e.g. tmp/.config-target.in)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(args.config) as fh:
        order, values = parse(fh.readlines())

    choices = parse_choices(args.kconfig) if args.kconfig else []

    added = 0
    unset_by_choice = 0
    for fragment in args.merge:
        with open(fragment) as fh:
            frag_order, frag_values = parse(fh.readlines())
        for symbol in frag_order:
            if symbol not in values:
                order.append(symbol)
                added += 1
            values[symbol] = frag_values[symbol]

            # unset the other members of the same Kconfig choice, otherwise
            # "make defconfig" would keep the old one and drop ours
            # (the members of a choice are stored without the CONFIG_ prefix)
            #
            # only a symbol that is *enabled* selects a member of the choice,
            # an explicit "is not set" must not touch the other members
            if values[symbol][0] != "set":
                continue
            plain = symbol[len("CONFIG_"):] if symbol.startswith("CONFIG_") else symbol
            for choice in choices:
                if plain in choice:
                    for other in choice:
                        if other == plain:
                            continue
                        other_symbol = "CONFIG_" + other
                        if other_symbol in values and values[other_symbol][0] == "set":
                            values[other_symbol] = ("unset", "")
                            unset_by_choice += 1

    result = render(order, values)
    if args.dry_run:
        print("\n".join(result))
        return 0

    with open(args.config, "w") as fh:
        fh.write("\n".join(result) + "\n")

    print("merged %d fragment(s) into %s (%d new symbols, %d choice members unset)"
          % (len(args.merge), args.config, added, unset_by_choice))
    return 0


if __name__ == "__main__":
    sys.exit(main())
