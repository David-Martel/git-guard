# Pydantic receiver classification

Run the source checks from the repository root:

```sh
sh tests/run.sh pydantic_receiver_classification pydantic_receiver_contexts
sh tests/run.sh quality_mandate pydantic_receiver_classification pydantic_receiver_contexts rule_behaviour
```

The [mandate scanner](../hooks/common/mandate_scan.py) distinguishes a legacy
method name from evidence that its receiver is a Pydantic model. A Markdown
parser can legitimately declare `parse_file()`. The
[strong candidate rule](../rules-examples/mandate/python/mandate-pydantic-v1.yml)
finds the method spelling; receiver analysis determines the applicable policy.
It reads the exported Git snapshot selected by staged, range or census mode.
It never imports or executes repository modules.

Local Pydantic base imports, public settings-module aliases, inheritance,
constructors and direct annotations establish model evidence. Proven model
calls retain the strong policy, including when the ambiguous rule is disabled.
Declared methods on a plain local class clear. Unresolved project imports,
conditional bindings and dynamic receivers use the existing
[ambiguity policy](../rules-examples/mandate/python/mandate-pydantic-v1-ambiguous.yml),
whose default remains WARN. This is bounded local analysis rather than a
whole-program type checker or a guarantee about arbitrary runtime patching.

Ordinary model configuration, data and initialization writes preserve model
type. Non-metaclass configuration keywords on an already known model base do
as well. Explicit metaclass factories and unpacked class options remain
uncertain. Relevant method or type changes invalidate plain receiver proof
through local aliases, inheritance and deferred references. Final class-body
bindings determine method proof; replaced methods and shadowed decorator names
cannot retain a previous exemption.
Quoted annotations use the same rebinding guard as the supported unquoted
evidence root. Nested strings and namespace roots cannot preserve stale proof;
unrelated generic type arguments do not determine the receiver's model ancestry.
Malformed quoted expressions remain unresolved. Each class base is captured when
its expression is visited, then revalidated against later base and keyword
effects. A later name-only write does not change the captured object; relevant
method or type mutations retain the existing conservative proof loss. This does
not infer arbitrary factory returns, MRO proxies or multiple-inheritance order.
For supported subscriptions, the owner is captured before its index, including nested
subscriptions. Supported model-class ownership survives name-only index writes;
actual type effects still invalidate it. Plain generic return values remain
unresolved, and index expressions retain their independent call findings.
Class bases use that same evaluation-time evidence. Annotation-order alternatives
merge cached subscription evidence rather than retaining the last visited branch.

Nested definition defaults and decorators, and nested class bases and keywords,
contribute their eager bindings to the enclosing scope's local-name inventory.
Deferred nested bodies and class-local assignments remain separate scopes.

Binding events are counted individually even within one compound statement.
Deferred generator bodies use capture safeguards; their first iterator remains
eager. Chained comparisons merge conditional bindings. A class name is published
after its immediate suite, separately from the future self/cls view in methods.
Lambdas summarize their own local rebinding and mutation events before analyzing
nested captures, using the same safeguards as deferred function bodies.
Known bare decorator calls feed the existing local-effect summary and are applied
in reverse order after eager definition expressions and the immediate class suite.
Merely declaring a mutating decorator does not apply it; ordinary field writes
and known model type retain their existing treatment. Decorator return values
and arbitrary decorator dispatch remain outside this local analysis.
Sensitive immediate class-suite mutations, including nested suites, invalidate
enclosing plain proofs without copying class-local bindings back. Unsupported
plain initializers with sensitive writes or opaque calls forfeit plain proof;
simple data-only initialization and known model configuration retain precision.
Aliased or decorated plain initializers remain unsupported. Plain bases with
`__init_subclass__` hooks cannot establish inherited method ownership; an already
known model base retains its model evidence.

Annotations without assigned values preserve existing runtime bindings and
method declarations, including the mutation and capture-event summaries.
Multiple plain bases remain unsupported rather than
unioning method names across an unproven resolution order. Class-comprehension
bodies skip the class namespace, while the first iterator uses it immediately.
Their lexical view shares mutation, rebinding and wildcard-import uncertainty
with the other deferred visitors. Generator assignment expressions also merge
their possible enclosing writes even when consumption is not known.

Wildcard imports invalidate existing bindings and deferred captures. Calling a
locally declared function or method whose syntactic body contains a sensitive
write forfeits plain proofs; merely defining it does not execute that effect.
This conservative name-based barrier does not infer arbitrary call graphs,
external effects or aliased dynamic dispatch. Ordinary field writes do not
activate it. No general runtime or alias-safety guarantee is claimed.
Matching local calls also invalidate names actually written through declared
`global` or `nonlocal` bindings. A declaration without a write is not an effect;
name rebinding does not invalidate the previous object's unrelated aliases.
The same one-level eager-call summary feeds captures and outward class, loop and
comprehension effects. Deferred bodies are not executed by that prepass; generator
bodies conservatively merge potential outer writes even when consumption is not
established, with their first iterator handled eagerly. Class suites propagate
only actually written declared global or nonlocal names, never unrelated
class-local assignments or declarations alone.
Tuple, list and starred mutation targets share the same leaf traversal in
immediate invalidation and capture summaries. Those summaries include immediately
executed class suites while continuing to exclude uncalled function bodies.
Loop, comprehension and context-manager Store targets use that same traversal.
Assignment containers process their leaves in left-to-right store order, so
later target expressions observe earlier method writes and name stores.
Loaded expressions within a target retain their own side-effect bindings;
only an actual annotated name receives declaration evidence. Unpacked values
remain unresolved rather than inferring a relationship with each RHS element.
Function-header scanning processes defaults once before annotations. For mixed
positional-only and normal positional annotations it joins the two observed
Python 3.10 and 3.15 group orders, followed by vararg, keyword-only, keyword-vararg
and return annotations. Environments and constructor-callee proofs merge
conservatively; model-call evidence from either order remains strong. The scanner
does not infer the repository's target runtime or enumerate arbitrary orders.
It visits source syntax without executing callbacks or forcing annotation
evaluation. Current
regression fixtures use compile-valid call expressions. Historical annotation
walrus controls retain their older-language scope and current Ruff syntax
limitation rather than serving as current-runtime qualification.
An unresolved method mutation root forfeits plain proof rather than guessing
aliases; type-changing writes also forfeit uncertain model proof. Ordinary data
writes keep method ownership, and method replacement alone preserves model type.
This includes non-name roots such as `type(parser)` and container expressions.

Class and instance evidence are distinct. Calling a supported class constructs
an instance; calling that instance has an unresolved return type. Parameters and
implicit `self` represent instances, while trusted builtin classmethods retain
class evidence for `cls`. Ownership joins preserve known model membership when
only the class/instance distinction differs. No callable return body is inferred.
Subscription of a known model class retains model evidence; lookup on a model
instance has an unresolved return type and cannot inherit that model ownership.
The callee expression is visited once before recording method ownership, so
effects in constructor arguments apply before the outer method lookup. Outer
call arguments are visited afterwards, preserving lookup-before-argument order.
Constructor evidence retains the callee selected before its arguments, while
known argument method/type mutations still invalidate uncertain proof. Mere
name rebinding does not change the class already selected. A while header is
also checked with conservative later-iteration bindings; a known-model finding
from its initial evaluation stays strong. Context-manager targets take effect
before the next item, with unresolved returned ownership. Variable annotation
fallbacks represent instances consistently with parameter annotations.
Potential outer-name writes in repeated comprehension expressions forfeit plain
proof, while initial model evidence remains available. Per-iteration summaries
include executable targets and keep the first iterator separate. Captured
assignment values are rechecked after each target's method/type effects before
later names receive their evidence; ordinary data and name-only rebinding do
not mutate the captured object. Constructor arguments share that same guard.

Conditional expressions and short-circuit operations merge binding evidence;
comprehension assignment expressions account for their outer bindings. Lambdas
use deferred capture rules while their defaults are visited at definition time.
Nested comprehensions keep the lambda's parameter scope rather than borrowing
the enclosing class namespace; eager defaults still use that class namespace.
Nested class bodies and method free names also skip enclosing class-local
namespaces. Their base expressions remain eager in the immediate outer class;
a nested class name is not inserted into the module's future bindings.
Executable assignment, annotated-assignment, augmented-assignment and deletion
targets are inspected, including comprehension target expressions. Dictionaries
visit each key followed by its value, including unpacking before later keys.
Class headers and source annotations are inspected too;
annotation expressions are never evaluated by the scanner. Mutation uncertainty
survives loops and context managers. UTF-8 decoding accepts an optional BOM
without rewriting the source bytes.

Namespace imports, deprecated validator decorators and nested Config constructs
retain their strong rule. Existing `.dict()` and `.copy(update=...)` policy,
severity overrides, suppression rules and other mandate rules remain in place.
Unsupported syntax records unresolved receiver evidence; Ruff owns syntax
validation. Unknown receivers are not silently described as proven models.

The [category 32 controls](../tests/32-quality-mandate.t.sh) separate basic
receiver classification from expression and closure contexts. Real temporary
Git repositories verify both directions of staged-versus-unstaged divergence,
range selection and index/selected-revision census. Census without `--rev`
remains index-based. The [category 27 controls](../tests/27-rule-behaviour.t.sh)
verify raw candidate discovery and its v2 negative control; a raw match alone
is not proof of model ownership.

Current source qualification and exact receipt hashes are in the
[review register](PYDANTIC_RECEIVER_REVIEW.json). Historical 84/418, 116/450 and
137/471 results remain attached to their original source snapshots. Confirmed
review defects in expression contexts supersede the previous whole-revision
KEEP at source 365650 / metadata 223bb5; its receipt remains historical evidence,
not approval of this successor. The later 42cc source is also held after four
further scope/effect findings; its 207/541 results remain source-specific
historical evidence. The e0d88 / 081be79 source and its 243/577 results are also
held after annotation, inheritance, comprehension, import and called-effect
findings. Its recorded root KEEP is historical and does not admit this successor.
Source 445b7af7 and its 666 selected checks are also held after the later target,
capture, control, declared-write and callable-instance findings. Those passes
retain their recorded scope and do not approve the current successor.
Source f9ffbf60 / metadata 6b94f5e8 and its 772 selected checks are held after
the actual outside review and staged receiver-evaluation, opaque-root,
initializer and subclass-hook failures. Its source KEEP retains only its
original review scope and does not admit this corrected successor.
The intermediate 562709 source's 815 selected checks also remain held after
the staged comprehension-target and dictionary-order failures.
Source 8e76e12c / metadata 7ac5c1b5 and its 827 selected checks are held after
the model-instance subscript false block. Its source KEEP remains historical.
The intermediate FAE4F0F6 source's 843 checks are also held after constructor,
loop-header, sequential context-target and annotation-instance findings.
Source e1d51938 / metadata cf3f8080 and its 872 checks remain held after repeated
comprehension and captured-assignment-target findings.
Source b038e161 / metadata 28b1cb0b and its 903 checks remain held after
lambda-local capture and implicit bare-decorator effect findings. Its source
KEEP is historical and does not admit the current successor.
Source 8fb562b2 / metadata daf7ce9f and its 940 checks remain held after
annotated-target binding, unpacked-store order and parameter/return annotation
order findings. Its root source KEEP920AE retains only its recorded scope.
Source 518eabb9 / metadata 3288b309 and its 1,010 checks remain held after
quoted-annotation capture and delayed class-base resolution findings. Its
root source KEEP6DE508 retains only its recorded scope.
Local source aa3d4452 and its 1,060 checks remained unreviewed after the same
capture issue was found inside a single subscript base. That local snapshot is
preserved as source-specific evidence, not independent approval.
Source ea055bf2 / metadata 045190e5 and its 1,089 checks remain held after missed
nested-header local bindings and ordinary subscription-owner rereading findings.
Its source and metadata KEEP receipts retain only their original review scope;
the green CI at that head does not qualify this corrected successor.
Recorded current results must name the exact
source and tests, with new selector bindings and fresh independent dispositions.
Existing raw-rule skips retain their documented reasons; they are not counted
as newly qualified behavior.

A real Pydantic 2.14.3 control corroborates the legacy deprecation and ordinary
class-configuration boundary. Framework controls intentionally activate the
owned environment with an invocation-scoped `VIRTUAL_ENV` and `uv run --active`;
`--isolated --python <venv-path>` does not establish that the environment's
packages are used. Receipts record the actual prefix and imported library path.
The scanner itself needs no Pydantic runtime dependency.

See [QA tooling](QA_TOOLING.md#13-quality-mandate) and the [rule inventory](RULES.md)
for the surrounding policy. Normal signed hooks, exact-head Linux CI,
independent outside-family review and merge-autopilot admission remain required.
No installed release is changed here. Deployment needs a new accepted immutable
release and the supported installer; another repository's evidence gates remain
mandatory.
