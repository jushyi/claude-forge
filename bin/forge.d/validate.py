import json
import re
import sys

import jsonschema
import regress

RFC3339 = re.compile(
    r"""
    ^
    (?:\d{4})
    -
    (?:0[1-9]|1[0-2])
    -
    (?:[0-3]\d)
    (?:[Tt])
    (?:[01]\d|2[0123])
    :
    (?:[0-5]\d)
    :
    (?:[0-5]\d)
    (?:[\.,]\d+)?
    (?:
        [Zz]
        | [+-](?:[01]\d|2[0123]):[0-5]\d
    )
    $
""",
    re.VERBOSE | re.ASCII,
)


def date_time(s):
    if not isinstance(s, str):
        return True
    if not RFC3339.match(s):
        return False
    year, month, day = int(s[:4]), int(s[5:7]), int(s[8:10])
    if month in {4, 6, 9, 11}:
        last = 30
    elif month == 2:
        last = 29 if year % 4 == 0 and (year % 100 != 0 or year % 400 == 0) else 28
    else:
        last = 31
    return 1 <= day <= last


def pattern(validator, p, instance, schema):
    if validator.is_type(instance, "string") and not regress.Regex(p, flags="u").find(instance):
        yield jsonschema.ValidationError(f"{instance!r} does not match {p!r}")


def check(schemafile, files):
    with open(schemafile) as f:
        schema = json.load(f)
    base = jsonschema.validators.validator_for(schema)
    formats = jsonschema.FormatChecker()
    formats.checkers = dict(base.FORMAT_CHECKER.checkers)
    formats.checks("date-time")(date_time)
    validator = jsonschema.validators.extend(base, {"pattern": pattern})(schema, format_checker=formats)
    parse, errors = {}, {}
    for path in files:
        with open(path, "rb") as f:
            data = f.read()
        try:
            doc = json.loads(data)
        except json.JSONDecodeError as e:
            parse.setdefault(path, []).append(e)
            continue
        for err in validator.iter_errors(doc):
            errors.setdefault(path, []).append(err)
    out = []
    if parse:
        out.append("Several files failed to parse.")
        for path, es in parse.items():
            for e in es:
                out += [f"  Failed to parse {path}", f"    JSONDecodeError: {e}"]
    if errors:
        out.append("Schema validation errors were encountered.")
        for path, es in errors.items():
            for e in es:
                out.append(f"  {path}::{e.json_path}: {e.message}")
    return out


args = sys.argv[1:]
starts = [i for i, a in enumerate(args) if a == "--schemafile"] + [len(args)]
rc = 0
for i, j in zip(starts, starts[1:]):
    out = check(args[i + 1], args[i + 2 : j])
    if out:
        sys.stderr.write("\n".join(out) + "\n")
        rc = 1
sys.exit(rc)
