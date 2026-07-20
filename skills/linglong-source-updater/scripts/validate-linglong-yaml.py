#!/usr/bin/env python3
"""
validate-linglong-yaml.py — 检测 linglong.yaml 格式化问题。

改造自 examples/validate-linglong-yaml.py，新增 --allow-sources 参数：
- 不加 --allow-sources：要求无 sources 段（用于输入校验）
- 加 --allow-sources：要求有 sources 段且字段完整（用于输出校验）

用法:
    python3 validate-linglong-yaml.py <path> [--allow-sources]
    python3 validate-linglong-yaml.py <path> --allow-sources

退出码: 0 = 通过, 1 = 失败
"""

import argparse
import json
import re
import sys
import yaml

COMMAND_MUST_BE_LIST = "field 'command' must be a list (not string/null/missing)"
VERSION_MUST_BE_STR = "field 'version' must be a string"
PACKAGE_MUST_HAVE = "package must have non-empty 'id', 'name', 'version', 'kind'"
BASE_RUNTIME_REQUIRED = "fields 'base' and 'runtime' must be non-empty strings"
BUILDEXT_APT_REQUIRED = "buildext.apt must be present"
DEPS_MUST_BE_LIST = "buildext.apt.{key} must be a list"
BUILD_MUST_BE_STR = "field 'build' must be a string"
NO_SOURCES = "sources section should not be present (use constraint)"
SOURCES_REQUIRED = "sources section must be present when --allow-sources is set"
NO_VERSION_CONSTRAINT = "dep entry '{dep}' still contains version constraint"

SOURCES_KINDS = {"archive", "git", "file", "dsc"}
SOURCES_REQUIRED_FIELDS = {
    "archive": ["kind", "url", "digest"],
    "git": ["kind", "url", "commit"],
    "file": ["kind", "url"],
    "dsc": ["kind", "url", "digest"],
}


def validate_sources(sources: list) -> list:
    errors = []
    if not isinstance(sources, list):
        return ["'sources' must be a list"]
    for i, src in enumerate(sources):
        if not isinstance(src, dict):
            errors.append(f"sources[{i}] must be a mapping")
            continue
        kind = src.get("kind")
        if not isinstance(kind, str) or kind not in SOURCES_KINDS:
            errors.append(f"sources[{i}].kind must be one of {SOURCES_KINDS}, got {kind!r}")
            continue
        required = SOURCES_REQUIRED_FIELDS.get(kind, [])
        for field in required:
            val = src.get(field)
            if not isinstance(val, str) or not val:
                errors.append(f"sources[{i}].{field} is required for kind '{kind}'")
    return errors


def validate(path: str, allow_sources: bool = False) -> list:
    errors = []

    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        return [f"YAML parse error: {e}"]

    if not isinstance(data, dict):
        return [f"Top-level must be a mapping, got {type(data).__name__}"]

    try:
        json.dumps(data)
    except (TypeError, ValueError) as e:
        errors.append(f"JSON serialization error: {e}")

    cmd = data.get('command')
    if not isinstance(cmd, list):
        errors.append(f"{COMMAND_MUST_BE_LIST} (got {type(cmd).__name__}: {cmd!r})")
    else:
        for i, item in enumerate(cmd):
            if not isinstance(item, str):
                errors.append(f"command[{i}] must be a string, got {type(item).__name__}: {item!r}")

    ver = data.get('version')
    if not isinstance(ver, str) or not ver:
        errors.append(f"{VERSION_MUST_BE_STR} (got {type(ver).__name__}: {ver!r})")

    pkg = data.get('package')
    if not isinstance(pkg, dict):
        errors.append(f"package must be a mapping, got {type(pkg).__name__}")
    else:
        for field in ('id', 'name', 'version', 'kind'):
            val = pkg.get(field)
            if not isinstance(val, str) or not val:
                errors.append(f"{PACKAGE_MUST_HAVE} (field '{field}' is {val!r})")

    for field in ('base', 'runtime'):
        val = data.get(field)
        if not isinstance(val, str) or not val:
            errors.append(f"{BASE_RUNTIME_REQUIRED} (field '{field}' is {val!r})")

    buildext = data.get('buildext')
    if not isinstance(buildext, dict):
        errors.append(f"buildext must be a mapping, got {type(buildext).__name__}")
    else:
        apt = buildext.get('apt')
        if not isinstance(apt, dict):
            errors.append(f"{BUILDEXT_APT_REQUIRED} (got {type(apt).__name__})")
        else:
            for key in ('build_depends', 'depends'):
                val = apt.get(key)
                if val is not None and not isinstance(val, list):
                    errors.append(DEPS_MUST_BE_LIST.format(key=key))
                elif val is not None:
                    for i, entry in enumerate(val):
                        if not isinstance(entry, str):
                            errors.append(f"buildext.apt.{key}[{i}] must be a string")

    build_val = data.get('build')
    if not isinstance(build_val, str):
        errors.append(f"{BUILD_MUST_BE_STR} (got {type(build_val).__name__})")

    if allow_sources:
        if 'sources' not in data:
            errors.append(SOURCES_REQUIRED)
        else:
            errors.extend(validate_sources(data['sources']))
    else:
        if 'sources' in data:
            errors.append(NO_SOURCES)

    apt = (data.get('buildext') or {}).get('apt') or {}
    for dep in apt.get('build_depends') or []:
        if isinstance(dep, str):
            if re.search(r'\([^)]*\)', dep) or re.search(r'[><=!]', dep):
                errors.append(NO_VERSION_CONSTRAINT.format(dep=dep))

    # 额外检查：build 段约束
    if isinstance(build_val, str):
        if allow_sources:
            if "cd /project/linglong/sources/" not in build_val:
                errors.append("build must contain 'cd /project/linglong/sources/' as first step")
            if "touch ${PREFIX}/.linyaps_genius" not in build_val:
                errors.append("build must contain 'touch ${PREFIX}/.linyaps_genius'")
            if "chmod -R 755 ${PREFIX}" not in build_val:
                errors.append("build must contain 'chmod -R 755 ${PREFIX}'")

    return errors


def main():
    parser = argparse.ArgumentParser(description='Validate linglong.yaml formatting')
    parser.add_argument('path', help='Path to linglong.yaml')
    parser.add_argument('--allow-sources', action='store_true',
                        help='Allow and validate sources section (for output validation)')
    args = parser.parse_args()

    errors = validate(args.path, allow_sources=args.allow_sources)

    if errors:
        print(f"FAIL: {len(errors)} issue(s) found", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)
    else:
        print("PASS: linglong.yaml format is valid")
        sys.exit(0)


if __name__ == '__main__':
    main()