#!/usr/bin/env python3
"""Generate offline Ruby test fixtures by executing a pinned Google TextFSM checkout.

Usage: python3 script/generate_conformance.py /path/to/google/textfsm
The upstream checkout is test tooling only; the Ruby gem never invokes Python.
"""

import copy
import io
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import unittest

REFERENCE = "f80bbb459c55ff5f21651e48d2529722d667af97"
root = Path(__file__).resolve().parents[1]
upstream = Path(sys.argv[1]).resolve()
revision = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
if revision != REFERENCE:
    raise SystemExit(f"Expected {REFERENCE}, received {revision}")
sys.path.insert(0, str(upstream))
os.chdir(upstream)

import textfsm  # noqa: E402
from tests import textfsm_test  # noqa: E402

cases = []
label = "upstream"
original_init = textfsm.TextFSM.__init__
original_parse = textfsm.TextFSM.ParseText
original_reset = textfsm.TextFSM.Reset


def initialize(self, template, *args, **kwargs):
    position = template.tell()
    source = template.read()
    template.seek(position)
    case = {"name": f"{label}/{len(cases):03d}", "template": source, "events": []}
    cases.append(case)
    self._ruby_case = case
    self._ruby_initializing = True
    try:
        original_init(self, template, *args, **kwargs)
    except textfsm.TextFSMTemplateError:
        case["error"] = "TemplateError"
        raise
    finally:
        self._ruby_initializing = False
    case["header"] = self.header
    case["normalized"] = str(self)
    case["options"] = {name: self.GetValuesByAttrib(name) for name in ("Filldown", "Fillup", "List", "Required", "Key")}


def parse(self, text, eof=True):
    event = {"operation": "parse", "text": text, "eof": eof}
    self._ruby_case["events"].append(event)
    try:
        result = original_parse(self, text, eof)
    except textfsm.TextFSMError:
        event["error"] = "ParseError"
        raise
    event["rows"] = copy.deepcopy(result)
    event["state"] = self._cur_state_name
    return result


def reset(self):
    if not self._ruby_initializing:
        self._ruby_case["events"].append({"operation": "reset"})
    return original_reset(self)


textfsm.TextFSM.__init__ = initialize
textfsm.TextFSM.ParseText = parse
textfsm.TextFSM.Reset = reset


class Result(unittest.TextTestResult):
    def startTest(self, test):
        global label
        label = test.id()
        super().startTest(test)


suite = unittest.defaultTestLoader.loadTestsFromModule(textfsm_test)
result = unittest.TextTestRunner(resultclass=Result).run(suite)
if not result.wasSuccessful():
    raise SystemExit("Upstream tests failed; fixtures were not written")

for path in sorted((upstream / "examples").glob("*_template")):
    label = f"examples/{path.name}"
    parser = textfsm.TextFSM(io.StringIO(path.read_text()))
    parser.ParseText(path.with_name(path.name.replace("_template", "_example")).read_text())

# Exercise stateful option interactions over deterministic varied input.
randomizer = random.Random(20260911)
option_sets = ["", "Required", "Filldown", "Fillup", "List", "Key", "List,Required",
               "Required,List", "List,Filldown", "Filldown,List", "Required,Filldown",
               "Filldown,Required", "List,Filldown,Required", "Required,List,Filldown"]
for number in range(140):
    label = f"generated/options-and-actions-{number}"
    option = option_sets[number % len(option_sets)]
    declaration = f"Value {option + ' ' if option else ''}X (x.*)"
    template = declaration + r"""
Value Filldown Y (y.*)
Value Required ID (r\d+)

Start
  ^${X}
  ^${Y}
  ^${ID} -> Record
  ^clear$$ -> Clear
  ^clearall$$ -> Clearall
  ^continue -> Continue.Record
  ^continue -> Clearall
  ^state -> Body

Body
  ^${X} -> Record Start
  ^end -> End
  ^eof -> EOF
  ^${ID} -> Continue
  ^.* -> Record Start
"""
    if number % 3 == 0:
        template += "\nEOF\n"
    parser = textfsm.TextFSM(io.StringIO(template))
    choices = ["x1", "x2", "x", "y1", "y2", "r1", "r2", "clear", "clearall", "continue", "state", "unmatched", ""]
    for _ in range(2):
        parser.ParseText("\n".join(randomizer.choices(choices, k=30)) + "\n", eof=False)
    parser.ParseText("state\n" + ("end" if number % 2 else "eof"))
    parser.Reset()
    parser.ParseText("xnew\nynew\nr3\n")

target = root / "test/fixtures/python_conformance.json"
target.write_text(json.dumps({"upstream_commit": revision, "python_version": sys.version.split()[0], "cases": cases}, indent=2, ensure_ascii=False) + "\n")
print(f"Wrote {len(cases)} cases to {target}")

