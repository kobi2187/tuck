## report_format — the shared machine-readable output for compiler reports.
##
## Every report tool (tuck audit, later tuck timing and tuck decode-crash)
## emits findings through this layer. Two formats, both with existing parsers:
##   json  — one object per report; `jq` and dashboards read it
##   sarif — SARIF 2.1.0; GitHub/Azure/GitLab code-scanning UIs read it
##
## Rule ids are the permanent TK-XXNN diagnostic codes, so a SARIF rule is the
## same thing a `tuck explain` lookup names. No bespoke text format that would
## need a bespoke parser.

import std/json

type
  Finding* = object
    code*: string     ## TK-XXNN, also the SARIF ruleId
    msg*: string
    path*: string
    line*: int
    col*: int

proc findingJson(f: Finding): JsonNode =
  %*{"code": f.code, "message": f.msg, "path": f.path,
     "line": f.line, "col": f.col}

proc toJson*(findings: seq[Finding]): string =
  ## JSON array of findings, pretty-printed. Includes the count so a script
  ## can short-circuit without parsing every element.
  var arr = newJArray()
  for f in findings: arr.add findingJson(f)
  pretty(%*{"count": findings.len, "findings": arr})

proc toSarif*(findings: seq[Finding], toolName = "tuck"): string =
  ## SARIF 2.1.0: one run, one rule per distinct diagnostic code, one result
  ## per finding with its physical location. Levels are error for codes that
  ## gate a build and warning for the rest (today all findings gate under
  ## --isr-check:error, so all are reported as errors).
  var rules = newJArray()
  var seen: seq[string]
  for f in findings:
    if f.code in seen: continue
    seen.add f.code
    rules.add %*{"id": f.code, "shortDescription": %*{"text": f.code}}
  var results = newJArray()
  for f in findings:
    results.add %*{
      "ruleId": f.code,
      "level": "error",
      "message": %*{"text": f.msg},
      "locations": [%*{
        "physicalLocation": %*{
          "artifactLocation": %*{"uri": f.path},
          "region": %*{"startLine": f.line, "startColumn": f.col}
        }
      }]
    }
  let doc = %*{
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    "version": "2.1.0",
    "runs": [%*{
      "tool": %*{"driver": %*{"name": toolName, "rules": rules}},
      "results": results
    }]
  }
  pretty(doc)
