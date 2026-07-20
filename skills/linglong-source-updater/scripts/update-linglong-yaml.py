#!/usr/bin/env python3
"""
update-linglong-yaml.py — 更新 linglong.yaml 补充上游源码信息和构建规则。

功能：
  1. 添加 sources 段 (archive/git/file/dsc)
  2. build 段首行插入 cd 进入源码目录（archive/git/dsc 使用 ls -d 动态发现）
  3. 确保 build 末尾有 touch/chmod 指令
  4. 修正 ${prefix} → ${PREFIX}

用法:
    python3 update-linglong-yaml.py \\
        --path /path/to/project \\
        --kind archive \\
        --url https://example.com/src.tar.gz \\
        --digest sha256:abc123... \\
        --name kate-src
        [--commit <git-commit>]
"""

import argparse
import os
import re
import sys
from pathlib import Path

try:
    from ruamel.yaml import YAML
    from ruamel.yaml.scalarstring import LiteralScalarString
except ImportError:
    print("ERROR: 'ruamel.yaml' is required. Install: pip install ruamel.yaml", file=sys.stderr)
    sys.exit(1)


HARDCODED_PREFIX_REPLACEMENTS = [
    (re.compile(r'-DCMAKE_INSTALL_PREFIX=/usr/local(?!\w)'), '-DCMAKE_INSTALL_PREFIX=${PREFIX}'),
    (re.compile(r'-DCMAKE_INSTALL_PREFIX=/usr(?!\w)'), '-DCMAKE_INSTALL_PREFIX=${PREFIX}'),
    (re.compile(r'--prefix=/usr/local(?!\w)'), '--prefix=${PREFIX}'),
    (re.compile(r'--prefix=/usr(?!\w)'), '--prefix=${PREFIX}'),
    (re.compile(r'(?<![-\w])PREFIX=/usr/local(?!\w)'), 'PREFIX=${PREFIX}'),
    (re.compile(r'(?<![-\w])PREFIX=/usr(?!\w)'), 'PREFIX=${PREFIX}'),
    # autotools subdirectory overrides
    (re.compile(r'--libdir=/usr(?:/lib(?:/[a-z0-9_.-]+)?)?'), '--libdir=${PREFIX}/lib'),
    (re.compile(r'--bindir=/usr(?:/bin)?'), '--bindir=${PREFIX}/bin'),
    (re.compile(r'--sbindir=/usr(?:/sbin)?'), '--sbindir=${PREFIX}/sbin'),
    (re.compile(r'--includedir=/usr(?:/include)?'), '--includedir=${PREFIX}/include'),
    (re.compile(r'--datarootdir=/usr(?:/share)?'), '--datarootdir=${PREFIX}/share'),
    (re.compile(r'--docdir=/usr(?:/share/doc)?'), '--docdir=${PREFIX}/share/doc'),
    (re.compile(r'--mandir=/usr(?:/share/man)?'), '--mandir=${PREFIX}/share/man'),
    (re.compile(r'--localedir=/usr(?:/share/locale)?'), '--localedir=${PREFIX}/share/locale'),
    # cmake subdirectory overrides
    (re.compile(r'-DCMAKE_INSTALL_LIBDIR=/usr(?:/lib(?:/[a-z0-9_.-]+)?)?'), '-DCMAKE_INSTALL_LIBDIR=${PREFIX}/lib'),
    (re.compile(r'-DCMAKE_INSTALL_BINDIR=/usr(?:/bin)?'), '-DCMAKE_INSTALL_BINDIR=${PREFIX}/bin'),
    (re.compile(r'-DCMAKE_INSTALL_SBINDIR=/usr(?:/sbin)?'), '-DCMAKE_INSTALL_SBINDIR=${PREFIX}/sbin'),
    (re.compile(r'-DCMAKE_INSTALL_INCLUDEDIR=/usr(?:/include)?'), '-DCMAKE_INSTALL_INCLUDEDIR=${PREFIX}/include'),
    (re.compile(r'-DCMAKE_INSTALL_DATADIR=/usr(?:/share)?'), '-DCMAKE_INSTALL_DATADIR=${PREFIX}/share'),
    (re.compile(r'-DCMAKE_INSTALL_DOCDIR=/usr(?:/share/doc)?'), '-DCMAKE_INSTALL_DOCDIR=${PREFIX}/share/doc'),
    (re.compile(r'-DCMAKE_INSTALL_MANDIR=/usr(?:/share/man)?'), '-DCMAKE_INSTALL_MANDIR=${PREFIX}/share/man'),
    (re.compile(r'-DCMAKE_INSTALL_LOCALEDIR=/usr(?:/share/locale)?'), '-DCMAKE_INSTALL_LOCALEDIR=${PREFIX}/share/locale'),
    # qmake
    (re.compile(r'(?<![-\w])QMAKE_INSTALL_PREFIX=/usr(?!\w)'), 'QMAKE_INSTALL_PREFIX=${PREFIX}'),
]


def fix_prefix_variables(build_text: str) -> str:
    text = build_text.replace("${prefix}", "${PREFIX}").replace("$prefix", "${PREFIX}")
    for pattern, replacement in HARDCODED_PREFIX_REPLACEMENTS:
        text = pattern.sub(replacement, text)
    return text


def ensure_build_suffix(build_text: str) -> str:
    lines = build_text.rstrip("\n").split("\n")
    # remove trailing empty lines
    while lines and lines[-1].strip() == "":
        lines.pop()
    required_commands = [
        'touch ${PREFIX}/.linyaps_genius',
        'chmod -R 755 ${PREFIX}',
    ]
    for cmd in required_commands:
        if cmd not in lines:
            lines.append(cmd)
    return "\n".join(lines) + "\n"


def build_cd_command(kind: str, name: str) -> str:
    if kind in ("archive", "git", "dsc"):
        return f"export SRC_ROOT=$(ls -d /project/linglong/sources/{name}/*)\ncd ${{SRC_ROOT}}"
    elif kind == "file":
        return None


def build_source_entry(kind: str, url: str, digest: str, name: str, commit: str = None) -> dict:
    entry = {"kind": kind, "url": url}
    if digest:
        entry["digest"] = digest
    if name:
        entry["name"] = name
    if kind == "git" and commit:
        entry["commit"] = commit
    return entry


def update_linglong_yaml(
    project_dir: str,
    kind: str,
    url: str,
    digest: str,
    name: str,
    commit: str = None,
    inplace: bool = True,
):
    yaml_path = Path(project_dir) / "linglong.yaml"
    if not yaml_path.exists():
        print(f"ERROR: {yaml_path} not found", file=sys.stderr)
        sys.exit(1)

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    yaml.indent(mapping=2, sequence=2, offset=0)

    with open(yaml_path, "r", encoding="utf-8") as f:
        data = yaml.load(f)

    # --- insert sources ---
    source_entry = build_source_entry(kind, url, digest, name, commit)
    insert_after = "package"
    for key in ("runtime", "command", "base"):
        if key in data:
            insert_after = key
            break

    if insert_after:
        keys = list(data.keys())
        idx = keys.index(insert_after)
        keys.insert(idx + 1, "sources")
        data["sources"] = [source_entry]
        data_move = data
        data = {k: data_move[k] for k in keys if k in data_move}

    # --- update build ---
    build_text = data.get("build", "")
    if not build_text:
        print("ERROR: 'build' field is empty or missing", file=sys.stderr)
        sys.exit(1)

    build_text = fix_prefix_variables(str(build_text))

    cd_cmd = build_cd_command(kind, name)
    if cd_cmd:
        build_text = cd_cmd + "\n" + build_text

    build_text = ensure_build_suffix(build_text)
    data["build"] = LiteralScalarString(build_text)

    # --- write output ---
    out_path = yaml_path if inplace else Path(project_dir) / "linglong.yaml.patched"
    with open(out_path, "w", encoding="utf-8") as f:
        yaml.dump(data, f)

    print(f"Updated: {out_path}")


def main():
    parser = argparse.ArgumentParser(description="Update linglong.yaml with upstream source info")
    parser.add_argument("--path", required=True, help="Project directory containing linglong.yaml")
    parser.add_argument("--kind", required=True, choices=["archive", "git", "file", "dsc"],
                        help="Source type")
    parser.add_argument("--url", required=True, help="Upstream source URL")
    parser.add_argument("--digest", default="", help="sha256 digest (with or without 'sha256:' prefix)")
    parser.add_argument("--name", default="", help="Source name (directory name in linglong/sources/)")
    parser.add_argument("--commit", default="", help="Git commit/tag/branch (git kind only)")
    parser.add_argument("--inplace", action="store_true", default=True,
                        help="Update file in-place (default: True)")
    parser.add_argument("--no-inplace", action="store_false", dest="inplace",
                        help="Write to linglong.yaml.patched instead")
    args = parser.parse_args()

    # normalize digest: strip sha256: prefix if present, or add it
    digest = args.digest
    if digest and not digest.startswith("sha256:"):
        digest = f"sha256:{digest}"

    update_linglong_yaml(
        project_dir=args.path,
        kind=args.kind,
        url=args.url,
        digest=digest,
        name=args.name,
        commit=args.commit,
        inplace=args.inplace,
    )


if __name__ == "__main__":
    main()