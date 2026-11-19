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
The inventory also includes legacy eager parameter annotations of every argument
kind and return annotations. Quoted annotation strings introduce no such writes.
Annotation walrus fixtures are direct AST controls with Python 3.10 witnesses;
Python 3.14+ compilation and the current staged Ruff syntax gate reject them.
The classifier defect therefore does not demonstrate a default-pipeline bypass.

Binding events are counted individually even within one compound statement.
Formal arguments, including implicit self/cls, start with a binding at scope
entry and shadow inherited outer-name rebound state. Later local reassignment
expires deferred capture proof; unchanged formals and ordinary data writes retain
their existing method/type evidence.
Comprehension iteration targets remain local to their implicit scope; enclosing
binding inventories retain iterator, condition and body assignment expressions.
Executable target expressions are still inspected for independent call findings.
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
Plain initializer proof is positive: literal or Name stores to the first
argument's ordinary fields, with supported no-op statements. Existing decorator,
header, explicit-call and sensitive-write exclusions still apply. A subscription,
attribute protocol, overloaded expression or unsupported control flow cannot
become data-only merely because its AST contains no explicit call.

A closed namespace prescan runs before any deferred method body is trusted.
Automatic `__set_name__` callbacks can replace methods after the suite finishes,
including methods declared before the descriptor field. Local class bindings
retain a small presence fact through inheritance, joins and aliases; explicit
namespace replacement expires absence through the existing mutation effects.
The prescan accepts literal data, proved descriptor-free Names, ordinary
undecorated functions, unshadowed classmethod/staticmethod wrappers, and closed
local ordinary-instance construction without the hook. Unknown/imported field
values, arbitrary decorated functions and unsupported returned values remain
uncertain. Constructor argument unpacking is not a closed proof; ordinary
literal/Name arguments remain supported. Ordinary function-object evidence is
separate from the stronger literal-data callback-body proof and remains an
unknown API receiver. No descriptor body, arbitrary return, metaclass identity
or global purity analysis is inferred. Literal containers are checked recursively
through their evaluated elements and dictionary keys/values. Function eager
headers and lambda defaults use the same supported-value boundary; lambda bodies
remain deferred. A Name load in an eager default is inert, while a namespace
field Name still needs positive descriptor absence. Unsupported namespace effects
expire enclosing and captured plain proofs through the existing namespace barrier,
including the inherited parent and method/comprehension views. Direct known-model
ancestry and default severities retain their existing treatment.
Immediate evaluation uses a finite positive prefix, independently of final
descriptor-free namespace closure. Inert values, closed literal containers and
explicitly staged call/header/default/first-iterator lookups retain their evidence.
Every other expression or branch expires plain evidence before traversal; new AST
forms default to uncertainty. This is a conservative boundary, not an expanding
list of Python operators or an assumption that unknown expressions are pure.
The original decorator-order, first comprehension iterator, lambda-default and
nested-class-base lookup controls retain their meaning. Six later precision-only
controls for lookups inside unsupported containers/branches now require UNKNOWN:
their real runtime can remain plain, but this finite proof no longer exempts them.
Default warnings, strict ambiguity blocking and all closed-value positives stay.
Copied immediate views share the boundary; deferred bodies use tainted captured
views without executing their effects in the current prefix. Namespace effects
also reach enclosing and captured plain views for model-class bodies, while direct
model ancestry remains strong. Captured class/constructor/store facts revalidate
across opaque effects; a legacy function already looked up before its arguments
is not retroactively relabelled.
Every admitted prefix also has an execution boundary: comprehension iterator
acquisition happens after the first expression, even when a generator body is
deferred. Unproved decorator application follows its observed loads/defaults,
and unproved class creation follows its observed headers/body. Those tails expire
plain evidence before the following statement. Decorator safety is captured at
load and retained only for supported builtins or an unchanged literal-data hook.
Namespace preparation is a separate boundary after header expressions and before
the class body. Unproved metaclass/base preparation expires body evidence there;
an unsupported later body expression does not erase the earlier header prefix.
An unproved namespace mapping stays opaque for the whole immediate suite. Its
loads and stores cannot establish plain, model, module, function or builtin
identity, including freshly defined classes and synthetic class-store facts.
Copied immediate views retain that mode; a nested class body, deferred function
or comprehension body uses its own actual lookup frame. Lexical class `global`
declarations are distinguished from nested declarations and declared writes.
Genuine global/deferred model ancestry remains strong. Builtin shortcuts share
one ordinary/global, unshadowed, no-star-import predicate; a class header captures
its `type` witness at evaluation, before switching to the nested body's scope.
Implicit method receivers use four roles: an undecorated instance method, a proved
classmethod, a proved staticmethod, or an unknown decorator layout. Unknown layout
never manufactures a model first argument. Deferred builtin absence also excludes
module names that may be bound, including first writes and lexical global writes;
immediate headers keep their already observed objects. A nested class lexical
global cannot borrow a function-local value; the same conservative rule applies
to explicit globals in nested synchronous/asynchronous functions. This finite
analysis marks that identity unknown without interpreting module execution or
call timing. Implicit self/cls requires a real positional-only or positional-or-
keyword first formal; keyword-only, varargs and kwargs never supply it. All
argument annotations retain their existing independent processing.
An unknown instance binding alone does not imply unsafe class creation: dormant
own hooks stay dormant. Creation needs a closed namespace and proved class bases,
without opaque subclass/header operations. An unshadowed `type` base is a creation
positive only; this does not infer the result of arbitrary `type(...)` calls.
Non-writing global/nonlocal declarations do not themselves execute a protocol.
Dictionary keys and set members need builtin literal hash inputs: constants or
recursive tuples of constants. Name loads in lists, tuples and dictionary values
remain inert; inserting a Name as a hash key can invoke user code. Unsupported
hash containers forfeit immediate proofs before their evaluation, without claiming
a universal insertion position across interpreter bytecode implementations.
Immediate branch copies retain that eager context; function and lambda bodies
explicitly leave it until execution is otherwise supported by the existing analysis.

Ordinary class-data writes preserve precision only through positively known class
owners. Direct closed plain CLASS-to-CLASS stores retain facts in the same scoped
environment, keyed by owner identity with both owner and value dependencies.
Overwrites, namespace changes and unknown effects expire these facts through the
existing join and invalidation machinery. Functions, instances, getters, imported
values and arbitrary returns do not establish this stored-class proof.
Aliased or decorated plain initializers remain unsupported. Plain bases with
`__init_subclass__` hooks cannot establish inherited method ownership; an already
known model class retains its direct API evidence. Unsupported subclass hooks
make future subclass creation uncertain; data-only known-model hooks retain
the existing supported boundary.
Explicit later `__init__` and `__init_subclass__` namespace writes also revoke
plain construction/subclass proof. They preserve direct known-model ancestry;
the existing `__new__` allocation/type barrier remains separate and unchanged.
This does not infer arbitrary initializer, factory or MRO effects.

Receiver evidence now carries four finite opaque-operation flags: construction,
instance access, class subscription and subclass creation. Type changes,
method-namespace changes and operation effects merge explicitly; a namespace
change is a real event, distinct from no effect. Aliases, deferred captures and
one-level local call summaries share those categories. A known class's direct
model ancestry is separate from the result of an unsupported operation.

The [Python data model](https://docs.python.org/3.15/reference/datamodel.html#customizing-attribute-access)
defines implicit setter and deleter dispatch. Visible or later replaced
`__setattr__`/`__delattr__` hooks therefore revoke plain instance-access proof.
Custom defined, assigned, inherited or later replaced `__class_getitem__`
hooks make subscription results unresolved; the analyzer does not infer their
returns. [Metaclass subscription takes precedence](https://docs.python.org/3.15/reference/datamodel.html#class-getitem-versus-getitem).
Unresolved shared-metaclass call/subscription changes conservatively mark the
corresponding projections. An unresolved initializer owner may be a shared
metaclass, so its effects also cover future subclass creation; a known ordinary
class initializer retains construction-only treatment. Control-flow joins union
opaque operations only when kind, identity and ownership evidence match;
different ancestry remains unresolved. A positively resolved, unshadowed
`classmethod` callback may preserve known model subclass ownership when its local
body only writes literal or name data to its first argument's ordinary fields.
Unsupported targets, protocol-bearing RHS expressions, calls, decorators and
other statements remain uncertain. This is a small structural proof, not a
purity or arbitrary return analysis. Earlier opaque metaclass/type effects still
win. Internal callback evidence never establishes a plain API receiver.
Callback bindings carry identity dependencies through the existing Name-alias
machinery. Explicit function `__code__` writes expire their structural evidence,
including deferred and known local-call effects. An unresolved mutation owner
uses the same conservative fallback for callback evidence as for other proofs;
it does not infer the owner through a container or arbitrary return. A code read or an uncalled
mutator does not execute that write. The namespace event leaves ordinary known
model ancestry intact; it does not infer the replacement function's behavior.
Exact type changes invalidate a trusted module namespace; unrelated module data
writes retain their existing treatment. Immediate class-suite mutation retains
the original barrier across all enclosing plain proofs when the true nested
owner cannot be established. Explicit metaclasses, non-type MRO proxies and
instance-subscription results remain unsupported. The existing `__new__`
allocation/type barrier stays intact. This is not metaclass identity or MRO
inference, and it does not execute hook bodies.

Direct model APIs, stock generic model specialization and ordinary data writes
retain their separate positive controls. Earlier owner-capture fixtures used a
custom hook returning `cls`; those fixtures now use stock `Generic[T]` with
valid type indices, retaining their mutation/evaluation triggers and every
assertion kind. Their old/new sources and real Pydantic specialization/receiver
observations are preserved separately; unsupported instance subscription and
deliberate type-mutation controls are explicitly distinguished from execution.

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
Source 5eab494a / metadata 416c6fcd and its 1,145 checks, including both successful
CI jobs, remain source-specific history after the legacy annotation inventory
defect was confirmed. The outside read-only review's stated unread limits are
retained with its result; it did not execute the finding or grant admission.
Source 23bca8f6 / metadata fa630dd7 and its 1,191 checks remain source-specific
history after formal-binding capture and later initializer-hook findings.
Their source/metadata KEEP receipts do not admit this corrected successor.
The unsigned53A9 descriptor snapshot and its 1,422 checks remain held after
container/default protocols retained stale parent/outer proofs; raw receipts
and root holds are preserved without claiming a reviewed source commit.
Source 94407c2d / metadata c848dc16 and their 1,506 unprofiled and profiled checks
remain held after the actual implicit-BinOp witness A6AB. Their 91.91% module line
and 85.59% branch measurements describe that old snapshot, not the new prefix gate.
The PR stays draft pending new source qualification and independent dispositions.
The unsigned853 prefix candidate and its 398 focused checks are also held: actual
iterator-acquisition witness91DD and the two other completion gaps require a new
snapshot. Its eight passing resolver/runtime controls describe only those cases.
The unsigned5108 completion snapshot and its 413 focused checks remain held after
the preparation-before-body witness56BE. The unsigned01D0 snapshot passed 1,556
native and profiled checks, measuring 92.15% module lines and 86.10% branches with
574 retained raw inputs, but remains held after the actual outside review and
root345C namespace-identity controls. These are measured historical snapshots,
not admission for the current opaque-view correction.
Source 22fbf2c0 / metadata f4b4b83e and its 1,359 checks, including both green
CI jobs, remain held after initializer-protocol and descriptor-completion
findings at6978689569. Source/metadata review receipts retain their original
scopes and do not admit the corrected successor.
Source 2a857b53 / metadata c437d6cc and its 1,226 checks remain held after
implicit write/delete hooks and custom subscription ownership findings. Their
source-only KEEP receipts do not admit the operation-projection successor.
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

Stored class owners are distinct from the syntactic holder. A relevant write or
delete snapshots the existing class-to-class owner before clearing stored facts,
then expires that owner's dependent proofs through the same effect lattice. An
unresolved multi-step owner in a deferred summary remains conservative. Ordinary
data writes do not become namespace mutations; a known constructor mutation does
not imply a subclass hook. This uses existing recorded fields and does not infer
getters, arbitrary attribute returns or a general alias graph. The public stored-
owner finding is covered by default/strict, deferred, alias, delete, unknown-owner
and unrelated-class controls. A read-only class `__dict__` assignment is explicitly
a conservative scanner syntax control, not a runtime model-call witness.

The list/set/dict repeated-iteration contract now has persistent set and dict
controls for the exact later-iteration walrus trigger, paired with initial-model
and stable-plain cases. Historical receipts remain bound to their original source;
the new fixture map closes a durable-test gap without adding inference features.

Ordinary stored-field replacement is a binding change, distinct from mutation of
the class previously loaded from that field. Deferred horizons count field writes
by member: a single initial store remains usable, while a later overwrite expires
matching cached slots. A known local callable may write its fields even once, so
its field-only summary is applied when called. Simple callable-name aliases and
local wrappers propagate those finite member sets to convergence; other existing
namespace/operation call summaries keep their previous scope.

Field markers expire only matching stored-class keys. They never become ordinary
environment names and do not mutate a saved Parser class or existing instance.
Unrelated member writes retain proof. Summaries deliberately conflate the same
member across unrelated owners or colliding local callable names; such ownership
ambiguity is UNKNOWN rather than a new heap, descriptor or return-value solver.
Loop/comprehension and class capture boundaries apply may-written slots through
the same dispatcher, preserving already-observed eager prefixes. Annotation-only
statements are not stores. Mappingproxy, deletion and augmented-operation errors
remain explicit conservative syntax controls, not invented runtime model calls.


Stored-slot call effects now distinguish a complete empty summary from absent
or opaque evidence. Genuine builtin mutators use their evaluated owner; argument
rebinding does not redirect the mutation onto a new object. Recognized namespace
members reuse the existing effect map, including finite local aliases and nested
consumers. Unknown callbacks forfeit construction safety through the existing
CONSTRUCT projection. This preserves receiver identity; it does not infer arbitrary
call returns, MROs, object lifetimes or dynamic global mutation.

An empty constructor requires a closed namespace, no unproved destructor, and
current descriptor-free initializer fields. An exact integer fact is stored only
for an explicit closed-class Attribute assignment with an exact builtin integer
constant. One Add with a literal integer consumes that fact. Unknown calls,
operators/getters, namespace changes, overwrites and uncertain joins expire it;
no numeric result or general value analysis is performed. Valued annotations do
not seed this fact. Header-effect controls distinguish actual Python 3.10.22 eager
annotation witnesses from current Python 3.15 lazy annotation behavior.

Only an actual resolved module invocation can add a finite initial MODEL witness.
Its global/free receiver path must have no repeated/rebound marker, local binding
(including annotation-only names and pattern-rest names), opaque predecessor,
unsupported argument or accessor. The existing conservative result stays in the
join. No provisional PLAIN result or runtime-once certificate is published.

The new after-plain-lookup control (source SHA-256
`8142529581d46e2b32004261a6c17cd69393213d388d44c95f036e4813f66370`)
has an explicit conservative UNKNOWN expectation: its recorded runtime Parser
answer does not establish safety against opaque reentry. This changes only a new
precision target. The prior 713 assertion bytes and historical external RED
expectations/results remain unchanged. Existing selected-receiver and pure-getter
positives are reused rather than rewritten.

Historical held9073 planning enumerated 179 cases / 530 assertions in addition
to the original 713 assertions, for an expected 1,243. That was a planning count
at that source snapshot, not a completed native, coverage, integration or fleet
qualification result. Current source-bound terminal
receipts and independent review determine admission; historical results do not
transfer to this source. The register and this document remain the traceability
entrypoints for the source and its recorded review.

The held 9073 preservation run completed with 1,238 passes and five failures:
two historical literal-data subclass callbacks lost MODEL evidence, and a
resolved stored-owner mutation lost the unrelated Other receiver's PLAIN proof.
The reviewed repair separates synthetic unsupported-call construction uncertainty
from genuine namespace effects. It also supplies an ephemeral, post-argument
constructor proof only for an actual direct call in the original module frame;
argument effects and current descriptor/destructor guards remain authoritative.

Deferred summaries keep their conservative stable-binding rules. Aggregate helper
publishers can still re-escalate synthetic construction uncertainty, an explicit
precision limit rather than a supported plain-proof exemption. For the 5F7319 predecessor, the original 713 and then-appended 530 assertions
remained unchanged. Its focused repair passed 91 assertions with no failures or
skips.
The same scanner passed 199 direct AST controls and 14 MODEL-classification /
inert-FakeBase runtime controls. The corrected 5F7319 full 1,243-assertion run later passed with actual exit 0
(2026-11-19); that result belongs only to that predecessor. No native or coverage
result is claimed here.
Breadcrumb: hooks/common/mandate_scan.py call_effects, field_call_effects,
field_call, invocation_namespace_effect and visit_Call.


Descriptor absence after live class field writes

The exact5F predecessor passed its full1,243 assertions, but the subsequent outside
review returned FIX/PARTIAL. Genuine builtin setattr and known helper field writes
could leave an unrecorded constructor field indistinguishable from proved absence.
Actual default/strict countercontrols reproduced12PASS/6FAIL; the private-name
counterpart already remained UNKNOWN and needs no mangling change.

The hash-reviewed338111 repair captures unique currently live plain class values
before a whole expiry batch and records UNKNOWN only for their finite initializer
Store fields intersecting the affected member or wildcard. It reuses existing
stored-class keys, preserves strict positive facts and the independent operation
flags, and does not select future classes from the declaration catalogue. Direct
module and builtin writes retain negative evidence even when CLASS_SUBSCRIPT-only
opacity forbids positive facts. The added default/strict cases preserve every
old1,243 assertion byte for byte under an inverse insertion proof. Bounded focused qualification passed 181 staged assertions, 199 historical AST
controls, 14 MODEL classifications and inert-runtime witnesses, 30 new AST/runtime
controls, and nine dispatcher invariants. The 2A04 predecessor subsequently passed its 1,333-assertion preservation run
with actual exit 0 at 2026-11-19T02:06Z. The following outside review remained
FIX/PARTIAL; neither result qualifies the proposed repair below. Breadcrumb: hooks/common/mandate_scan.py constructor_store_members,
constructor_write_keys, apply_written, record_class_store and field_constructor.


Current proposed deferred/unknown-write repair: qualification pending

The exact 2A04 predecessor missed a single later descriptor graft when analysing
an earlier deferred constructor call, and immediate ordinary stores through an
unresolved owner left recorded fields stale. Default/strict staged reproduction
completed 42 passes and 12 failures across 54 assertions, with 18 matching inert
FakeBase runtime witnesses. The opaque setter changing a different field was
already UNKNOWN and remains a preservation control, not a fifth reproduced bug.

The proposed correction keeps the complete containing statement and later siblings
for each existing capture scope, then expires only finite constructor-field
metadata for future may-writes. It does not slice by source line or discard loop
prefixes. Earlier module-int/no-later-write and annotation-only controls retain
their existing meaning. An unproved attribute write/delete uses the existing FIELD wildcard regardless
of its spelling; a proved ordinary class, including independent CSub
opacity, keeps exact immediate key handling. Positive stored facts remain strict.
Breadcrumb: receiver_capture_suffix, field_write_effects, deferred_bindings and
invalidate_target in hooks/common/mandate_scan.py.

The proposed insertion adds 30 cases / 90 assertions. Removing only its marked
insertion reconstructs every prior 1,333 assertion byte exactly; the resulting
1,423 total is planned, not executed. The eight new operation/compound controls have not been run. Four additional
legacy/dunder spelling controls passed all 12 assertions with matching inert
runtime witnesses on 2A04; they are preservation controls, not extra reproduced
defects. The all-attribute unsafe-operation boundary is a reviewed consistency
guard, and has not yet been executed in the proposed source. Focused, full, native, coverage and outside KEEP for this
proposed source are pending. Historic 713/530/1,243/1,333 measurements are source
scoped above and do not transfer to this proposal.


### Bulk target lexical successor (qualification pending)

Frozen 7EF completed 1,423 preservation assertions with zero failures or skips;
its subsequent outside verdict remained FIX/PARTIAL. Bounded follow-up reproduced
plain false clears for unresolved `for` and eager-comprehension Attribute targets:
18 staged assertions passed and six failed. Their four unsafe inert-runtime cases
selected Model; four finite CLASS counterparts retained Parser. The class-body
projection counterpart was already protected: 12 staged assertions and four
inert-runtime observations passed. A rejected consistency proposal weakened the
supported class-local `Alias = Holder; Alias.other = 1` case, so `visit_ClassDef`
and its specialized namespace prescan remain byte-identical to 7EF.

The proposed repair changes only the bulk applications in `comprehension` and
`conservative_control`, plus their existing `field_write_effects` classifier.
Scratch owner decisions use the selected local/post-header frame after bound or
may-mutated roots are forfeited. Effects apply to the original pre-expiry view so
constructor-key dispatch sees live classes, and the captured set is reused for
outward projection without re-evaluating targets.

One further actual AST/inert-runtime counter found that a nested comprehension
local `Alias` could borrow the finite global CLASS of the same spelling in the
flat outer summary; both 7EF and the rejected proposal reported plain while the
runtime selected Model. Target-local quarantine now refuses that borrowed root
only when that exact write lies in a comprehension body binding the name. Body
identity sets are transient and computed once per classifier invocation; the
first iterator stays outside its own local frame, and the existing target walker
still controls deferred exclusions. This also protects the existing deferred
capture-suffix consumer. No positive key, count/call-graph collector, class flag,
alias graph, epoch, callback solver or default/strict severity is widened.

Sixteen regression cases add 48 assertions. Removing their marked insertion
restores every original 1,423 expectation byte-for-byte. The proposed full total
is 1,471; focused/full/static/outside qualification of these bytes is UNRUN.


### Owner-capture protocol successor (unapplied; broader qualification pending)

Frozen72CE completed the private1,471 assertion pass, but its subsequent outside
reviews required source fixes. The earlier unapplied74DEE prototype passed only
the24-case AST/inert comparison and four static checks (qualification8E774);
staged66, focused204, full1,537 and outside approval were not run for it. Its
AF14 review found two blockers: a syntactic __dict__ exemption and unavailable
ast.TryStar access on older Python versions still admitted by the shell wrapper.

Three bounded namespace-owner sources then confirmed the exemption gap: an
unproved getter returned a callback mapping, and a key expression could rebind
its owner name to an ordinary class. Both remained plain in72CE/74DEE while the
inert runtime selected Model. A closed CLASS/CSub control caught the real
mappingproxy TypeError and retained Parser; it does not claim class __dict__ is
writable. The successor captures the namespace owner before key evaluation,
revalidates it through key effects, and retains an exemption only for the existing
finite owner domain with an inert literal key. Other keys conservatively forfeit
the exemption, so a post-key class binding cannot certify an older mapping.
No general Attribute-getter, alias, return or MRO solver is claimed. A getter
that itself executes before the key remains outside this Store-callback proof.

TryStar selection now uses an availability-independent type-name guard while
keeping the same first-MODEL certificate. A private missing-feature control may
validate that dispatch without installing or claiming runtime qualification of
Python3.8-3.10. Current314/315 NUL SyntaxError evidence remains stdlib-only;
encoding, recursion and older parse exceptions are still unexecuted scanner
robustness leads. No blanket fail-closed claim covers every exception path.

The bounded successor comparison/static outcome is recorded separately in
qualification.json and its exact source hashes; this preparation prose does not
invent a passed result. Thirty regression cases add84 assertions; inverse
insertion restores all old1,471 bytes and expectations. Staged84, focused222,
full1,555/native/coverage and outside approval remain UNRUN until independently
recorded. The old function-call certificate, model ancestry and CLASS/CSub proof
domains are unchanged; no existing severity or expectation is weakened.


### Scoped namespace-getter prefix successor

The F05 bounded30-row AST/inert comparison, four static checks and missing-TryStar
control passed in qualification84B33, but its08D48 review still required a getter
ordering fix. A further single source confirmed that an unproved __dict__ getter
could patch Parser.parse_file and return an ordinary dictionary before the key's
legacy call;72CE/74DEE/F05 all recorded plain while the inert key result was Model.

This successor applies the existing FIELD/NAMESPACE loss after the namespace base
is observed and before its key, including AugAssign's separate prefix. Its getter
certificate depends only on the captured existing owner domain: ordinary proved
CLASS/CSub or function/data-hook. It deliberately does not depend on literal-key
eligibility. A proved getter therefore keeps pre-key call evidence until actual
key events; the separate post-key Store certificate and revalidation stay intact.
This remains scoped __dict__ handling, not a general Attribute-getter solver.
The TryStar availability guard and its version-qualified evidence are unchanged.

Two additional cases contribute six assertions. Removing their inner marker
restores every previous30-case proposed fixture byte; removing the full protocol
marker restores the original1,471 bytes. The new total is32 cases/90 assertions,
with staged90/focused228/full1,561/native/coverage/outside still UNRUN. Bounded
comparison/static/feature-control results, when available, are separately bound
in qualification.json; no earlier prototype result qualifies changed source.


### Retained reference-sequence preservation successor

The held `59F76E` focused run passed 199 AST and 14 Model/runtime controls, but
its 78-case bank found the old annotation-only unresolved-field pair ambiguous:
the earlier builtin `[Data][0]` getter had erased the ordinary class evidence.
The remaining diagnostic passed 9 dispatcher and 17 operation controls and
completed 223/5/0 staged assertions. Three failures came from that pair; two
were independent `except_pass` blocks in the newly added mappingproxy control.
The exact B041 default/strict replay retained both `[except_pass]` diagnostics;
both Pydantic plain-marker assertions and the inert Parser result passed.

This successor suppresses only the local generic getitem negative event for a
finite Name-only builtin List/Tuple getter whose retained class/function
references are captured before its elements and unchanged after the constant
index. It publishes no sequence result binding. NamedExpr remains restricted
to reviewed current-Call Tuple argument observations, with trusted retained
prior target identity; missing targets and List NamedExpr are rejected. Cold
summaries stay conservative without actual current-region evidence.

Only the two new B041 fixture handlers replace `pass` with an ordinary boolean
marker assignment. The mappingproxy TypeError remains caught, Parser/PLAIN and
expected rc0 stay unchanged, and no rule is disabled or exempted. All other 76
runtime sources and every original 1,471 fixture byte remain unchanged. Totals
remain 78 cases/228 focused assertions and 1,561 full assertions.

An external hash-bound private comparison closed with 199 AST preservation
controls, 14 Model AST/inert-runtime controls, 78 AST/inert-runtime cases,
9 dispatcher controls, 17 operation controls, 20 finite predicates, four static
checks, and default/strict CLI runs for only the two updated mappingproxy
fixtures. Its receipt SHA-256 is
`7712a8e2ada774bdbf6749a4acc1331b61e8b3acc6045fd34142564a9251bab0`.
The maintained [receiver fixtures](../tests/32-quality-mandate.t.sh) and
[scanner](../hooks/common/mandate_scan.py) describe the code and assertions.
At proposal sealing, changed-source staged 228/full 1,561, native, coverage
and outside qualification remained UNRUN. The earlier failed runs remain
historical, source-specific evidence.


### Closed private source-preservation qualification

The complete private focus passed 228/0/0 staged assertions and its associated
AST, inert-runtime and static controls. Its receipt SHA-256 is
`dfced16331542f410ca7d5f16ec3bfe6cddcb42292976f73b444de944f468dea`.
The subsequent full private preservation run closed with inner and outer exit
0, exactly 1,561 unique expected labels, one 1,561/0/0 footer, equal source/input/
Git custody guards and confirmed owned cleanup, environment and cwd restoration.
The independent root readback SHA-256 is
`8eec63cffcadaf11b780946588258cde957643fc6e20d8b274f731fe8d1e8776`.
These are source-preservation results for the archived D294 scanner, F0FB tests
and A201 review-document snapshot. This documentation-only successor retains
all other 175 files byte-for-byte, including the
[scanner](../hooks/common/mandate_scan.py) and
[receiver fixtures](../tests/32-quality-mandate.t.sh); it does not transfer the
full-run result to a different 176-file documentation snapshot.

The full run initially lacked its planned BelowNormal/two-CPU admission and
was corrected by the root owner while running. The governing correction record
SHA-256 is
`bd46f47deda4314132df3eb131796c6f0f537486a3a320a3ceafeab100491e23`.
That initial resource-contract gap remains explicit: the source-preservation
pass does not establish resource compliance from launch or a performance result.
A separate future-only controller repair adds maintained resource admission
before spawning owned work. Its 20 tiny controls cover 18 failure paths and
two real inert-child resource readbacks; the exact review SHA-256 is
`9965384466a4a5ca4e1276812723929f389f334f8b7ab95572c5042073052e06`.
Those controls do not retroactively qualify the completed full run, execute a
replacement full harness, or establish a hard memory quota.

Current-source native four-category, coverage, outside review and source
adoption remain UNRUN. The earlier partial outside findings and all failed
preservation/driver runs retain their original source-specific scope.


### Protocol consumers and negative callback provenance (unapplied proposal)

The supplemental D294 source review returned FIX/PARTIAL. Bounded inert and
staged counters confirmed namespace callbacks behind in-place addition, rich
comparison, unary operations and direct namespace-mapping mutators. A later
6F23 review and counter found lost effects at comprehension, loop, anchored
capture and named Lambda callback consumers. The named FunctionDef callback
was already conservative and remains a preservation control. These findings
and earlier failed source, driver and mode-setup runs remain historical;
none is restamped as approval.

The proposed [scanner](../hooks/common/mandate_scan.py) keeps setup and persistent
explicit summaries in `include_protocols=False` mode while actual, captured and
callback consumers use full effects. `ReceiverBinding.protocol_effect` carries
only possible negative effects: Lambda values gain no positive kind, identity
or return-value proof. Copies and joins retain that possibility; definite
replacement and real local/formal shadows reset it. Selected callees and early
arguments retain their evaluated values across later rebinding. Bulk projection
uses fresh selected-visit observations, and deferred summaries use their captured
view with restoration. The existing stored-int premise remains checked per
invocation; no return, MRO, arbitrary alias or whole-language purity solver is
claimed. Default and strict finding policies are unchanged.

An external hash-bound private EC4 comparison closed with actual outer and
worker exit0: 199 AST preservation controls, 14 Model controls, 78 prior cases, 24 operator cases and 12 consumer-counter AST/inert-runtime
rows; 9 dispatcher, 17 operation, 21 predicate, 13 mode and 7 lifecycle controls;
and four static checks all passed. Its changed-file CLI bank passed 142/0/0
with 142 unique source-derived labels. The qualification SHA-256 is
`1abbaeeb589a21d244e9c92b8efcd1d3a47f7e810dd0ff3a5a58ab54f7da4d94`.
This is a bounded private result for EC4 and the prior F0FB/D7F30 fixture/document
snapshot, not execution of this proposed maintained insertion or a whole-suite
result. The earlier D294 full 1,561 source-preservation result and its initial
resource gap retain exactly their recorded scope. The EC4 workload had recorded
BelowNormal/two-CPU admission before UV and confirmed cleanup; its elapsed time
is not a performance benchmark or a hard memory quota.

The [maintained receiver tests](../tests/32-quality-mandate.t.sh)
`_qm_receiver_protocol_consumer_contexts` append 46 default/strict rows protecting
the callback and evaluation-order boundaries above. They reuse the existing
stored-int positive rather than duplicate its private pair. The mode contract
adds one cohesive shell assertion over 13 direct checks, including proper module
prescan and real cache producers. The lifecycle contract adds one cohesive shell
assertion over 7 checks for branch/empty-loop may-loss, hidden local scope,
definite reset, Name copy, argument ordering and constructor-slot expiry. Its
runtime dispatch uses an inert FakeBase; import/deletion/formal and slot tests
are explicitly AST metadata checks rather than invented successful Model calls.
All original 1,561 fixture bytes and expectations are restored by the inverse
insertion proof.

At original proposal sealing, literal source counting gave 136 new CLI
assertions plus 2 cohesive contract assertions: planned focus 366 (baseline 228)
and full 1,699 (baseline 1,561). Both totals were UNRUN at that historical
proposal boundary. The later actual results below supersede only that pending
private-preservation status; the historical register and partial outside
findings remain preserved with their original source-specific scope.


### Current private source-preservation qualification

On 2026-11-19 the maintained focused run passed 366/0/0 with 366 unique,
source-derived labels and actual outer/worker exits 0. It executed the reviewed
46-row consumer insertion and the cohesive 13-mode and 7-lifecycle contracts in
the [receiver tests](../tests/32-quality-mandate.t.sh). Its external qualification
SHA-256 is
`471db2846bfd2c752107a8551bf7d730b8b85f31bbcbb5c8315a0d336d9196f3`.

The subsequent full private preservation run passed 1,699/0/0 with 1,699 unique
expected labels, one exact footer, no missing or extra labels, and actual outer
exit 0. The root independently rehashed all 2,998 protected inputs, 176 candidate
files, six pinned tools and 176 historical EAD files with zero mismatches; recorded
primary/index/ref/foreign custody matched. The root post-run readback SHA-256 is
`9eb92c451f1cdffd51b12ccbc040106431c1d3ae387337b4cede8e9a274f503f`;
the controller terminal is
`4361cbda8aa7687ed41aa593cb73a2955176e001eb5e9652752e9c1d3df3dce6`
and caller terminal is
`e78d5a54d01f629a11bae23abac6cb63b9cfe900898dad9ea740ba608435aa0c`.
Cleanup and restoration completed, and fallback terminals were absent.

The owned computational workload had BelowNormal priority, affinity mask 3
(two CPUs) and a fresh 2 GiB free-memory admission before UV. Both maintained
caller and runner Job boundaries applied and read back those resource settings;
the independent readback records 2,891.95 MiB before UV, 2,865 MiB at the caller
and 2,678 MiB at the runner. The initial console host is outside that resource
claim. This is neither a process-birth/all-tree claim nor a hard system RAM quota
or performance benchmark. The older D294 full 1,561 run's initial resource
violation (BD46) remains historical and is not retroactively qualified.

These actual runs bind the EC4 scanner, 09BF tests and EA62 review-document
snapshot. This documentation-only successor preserves the other 175 file bytes;
it does not transfer a full-result claim to all 176 changed-document snapshot
files or constitute source approval. The
[scanner](../hooks/common/mandate_scan.py) and test expectations are unchanged.
Fresh native four-category qualification, coverage with whole-module line AND
branch coverage at least 85% and zero exclusions, full outside review and source
adoption remain pending. No fleet-wide, installed-route or global-native claim
follows from the private preservation runs.
