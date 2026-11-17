# Pydantic receiver classification

Run the focused source checks from the repository root:

```sh
sh tests/run.sh pydantic_receiver_classification
sh tests/run.sh quality_mandate pydantic_receiver_classification rule_behaviour
```

The [mandate scanner](../hooks/common/mandate_scan.py) now distinguishes a
legacy method name from evidence that its receiver is a Pydantic model.
`MarkdownParser.parse_file()` is a legitimate application API. Renaming that
API to satisfy a model-library rule would conceal the rule's false positive.
The [strong candidate rule](../rules-examples/mandate/python/mandate-pydantic-v1.yml)
still discovers all four legacy method names. The scanner then classifies them
using the exact exported Git snapshot selected for staged, range or census mode.
It does not import or execute repository Python modules.

Local Pydantic base imports, aliases, inheritance, constructor calls and direct
annotations establish model evidence. Those calls retain the configured strong
severity, including when the ambiguous rule is disabled. Plain local classes
with a declared matching method clear. Unknown external types, parameter
shadowing, incompatible branch bindings and dynamic construction or attribute
dispatch remain under the
[ambiguous rule](../rules-examples/mandate/python/mandate-pydantic-v1-ambiguous.yml).
Its default remains WARN. This analysis is deliberately local; it does not claim
whole-program type inference or resolve arbitrary imported project classes.
Changes to a plain receiver's legacy-method namespace invalidate its local
aliases, instances and derived plain classes. Ordinary configuration and data
writes preserve known model type and plain method proof; actual type/base or
dynamic-dispatch changes invalidate type certainty. Deferred functions account
for relevant later mutations in their enclosing scope. Shadowed
`classmethod` and `staticmethod` names do
not establish plain-method proof. This is bounded static analysis, rather than
a guarantee about arbitrary cross-module runtime monkey-patching.
The public `pydantic_settings.BaseSettings` namespace works both directly and
through a module alias. A method call on the settings module itself remains
unresolved; the namespace is not treated as a model instance.

Namespace imports, deprecated validator decorators and the existing nested
Config matcher retain their strong classification. Existing `.dict()` and
`.copy(update=...)` handling, severity overrides, suppression policy and all
other mandate rules retain their existing behavior. An unsupported Python AST
leaves receiver evidence unresolved; Ruff still owns syntax validation.

The [category 32 selector](../tests/32-quality-mandate.t.sh)
`t_case_pydantic_receiver_classification` exercises real Git repositories and
the real scanner. Its controls protect model class and instance calls, import
and class aliases, BaseSettings, annotations, strong namespace/decorator/Config
findings, local Markdown parsers, relative imports, rebinding, decorated and
dynamic receivers, and ambiguity opt-outs. For both model and plain cases it
stages one source while leaving the opposite source unstaged. Staged checks and
index census must use the staged blob; range and selected-revision census must
use the committed blob. Census without `--rev` remains index-based.
The [category 27 controls](../tests/27-rule-behaviour.t.sh) separately prove raw
candidate discovery and its v2 negative control; they do not prove receiver type.

The initial implementation with these controls failed the intended boundaries:
the first author red run reported 20 passed and 24 failed. Additional controls
exposed relative-import and dynamic-dispatch misclassification and were kept
when those defects were corrected. The final focused Windows/Git Bash run
reported **84 passed, zero failures and zero skips** at the first source head.
A real Pydantic 2.14.3
model's legacy `parse_file()` produced the expected deprecation warnings;
`model_validate_json()` returned the same value without warnings. These runtime
observations corroborate the model-library boundary without making Pydantic an
execution dependency of the static scanner.

The combined Windows regression command above reported **418 passed, zero
failures and 14 skips**. Those skips are the existing raw-rule controls whose
inert or overmatching behavior is described in their test output; none belongs
to the new receiver selector. Independent review then rejected that head:
replacing a parser's method with `Model.parse_file` still cleared its finding.
Seven new real scanner controls reproduced the defect with **98 passed and
seven failed assertions**. A further deferred-classmethod control failed after
the first correction (**115 passed, one failed**). Both red receipts are kept.
That correction passed **116 focused checks** and **450 broader checks** with
the same 14 existing raw-rule skips. Independent review rejected it as well:
ordinary `Model.model_config = {}` incorrectly weakened a still-known model to
an ambiguous receiver. Configuration, data-member, initialization and type-change
counterparts reproduced nine failed assertions (**121 passed, nine failed**).
The narrower correction now passes **130 focused checks, with no failures or
skips**, and **464 broader checks** with the same 14 existing raw-rule skips.
Two public settings-module import forms then reproduced four failed assertions
(**133 passed, four failed**). Their bounded namespace correction now passes
**137 focused checks, with no failures or skips**. The broader suite is being
recorded separately at this final source: **471 passed, zero failures and the
same 14 existing raw-rule skips**. The register separates current receipts from
the earlier source snapshots and both rejected predecessor heads.
No Linux execution is claimed by these author receipts.

ShellCheck passed at warning severity for the two changed test files and runner.
The installed global pre-commit hook passed and made no source changes; it
reported non-blocking basedpyright and walrus-style warnings. The author also
measured 1,000 actual AST model calls in approximately 0.21 seconds on CPython
3.15.2. This single-fixture measurement is not a fleet performance benchmark.

The [review register](PYDANTIC_RECEIVER_REVIEW.json) binds source and selector
hashes to actual review dispositions. Pending independent review is recorded
explicitly; author executions do not count as independent approval. The
[QA tooling policy](QA_TOOLING.md#13-quality-mandate) and
[rule inventory](RULES.md) describe the surrounding policy.
This source qualification does not modify an installed git-guard release or
waive another repository's evidence gates. Normal signed commits, exact-head
CI, independent outside-family review, merge autopilot and supported deployment
remain required.
