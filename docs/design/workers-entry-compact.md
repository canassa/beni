# Compact static entry analysis implementation

Normative implementation detail for workers.md and workers-emission.md, parent
#1295 / existing PR #1304. The core first-order kernel and declaration/capture
amendment were manager/independently reviewed before replacement code, 2026-10-31.
Review-driven correction sections were specified before their respective code;
final implementation review and integration gates remain manager-owned. This defines a deliberately partial first-order
analysis kernel, not a reduction of the decided full worker contract. The
previous full-caller-context prototype is rejected research and is not reused.

The first section records the finite symbolic kernel. The declaration sealing
and paired W/S rules in the second section supersede corresponding first-section
rules. The final Seal formula includes BOTH newly sealed and already-bound self
profiles. All unsupported cases remain explicit compiler residuals; no public
worker emission/launch or C/EntryHost/Wire/ownership proof is enabled here.
Source summary and graph IR use SoA columns, typed source indices and flat ranges;
no environment/caller-chain key is introduced. The reviewed structural counters
and fixture requirements are acceptance criteria, not deferred budget waivers.

# Finite first-order kernel

Normative implementation detail, 2026-10-31. This replaces the rejected
prototype and does not amend the full worker contract.
No general higher-order guard algebra is claimed by this kernel. Its invocation
boundary is precise below. Residual relations are compiler implementation gaps,
not opaque source origins, language refusals or permission to emit workers.
The kernel and its amendment were reviewed before code.

## 1. Finite identities and answers

One source template T exists for each function, lambda, local function and
zero-argument declaration initializer. Its source value ports are globally
indexed; P below also includes the finite source-pair launch-export ports. F(T,j) is its j-th formal/capture input. Caller actuals are NEVER seeded
into those input ports. Each input initially answers symbolically about itself.

The observation domain D is fixed before solving, from source and manifest rows:

- W: whole-value executable/allocation origin;
- S: static-capture provenance obligation;
- C(L,k): the direct k-th capture of source lambda/local-function L;
- P(s,m): one source field/tuple selector s followed by mode m;
- R(K,r,m): one metadata callback role r of kind K followed by mode m.

Here m is W, S, or one C(L,k). Selector s is a canonical field symbol or tuple
index; source position is retained separately. These are finite product domains,
not arbitrary selector/capture paths. A request needing composition outside this
grammar stays a residual ProjectionComposition relation. Known local allocations
can consume selectors one at a time, so deep source-closed records need no path
string or recursive walker. A composed unresolved formal projection is not
silently approximated as dynamic. General regular structural summaries are a
future extension, not a hidden depth limit or a claim that this kernel implements
all first-order selectors.

A query is q = (source port p, observation d). Its owner template is owner(p).
Its answer set contains ONLY:

1. Input(T,j,d'): a symbolic dependency on that same template's input j with
   observation d';
2. Origin(tag, source ID): declaration function, source closure/allocation,
   metadata constructor, literal, genuine opaque-result site, or runtime input;
3. Provenance(tag, source ID): a static declaration/read or source-closed value,
   a proven free runtime input, or an unresolved materialization obligation;
4. Residual(reason, source equation ID): unsupported invocation/projection/etc.

The answer never contains an environment, caller chain, nested substitution
object, arbitrary type instance or expanded path. A closure Origin(L) is NOT
an instantiated closure and must NEVER be used as a global key for its captures.
Captures are answered at the queried VALUE PORT: q(p,C(L,k)). This distinction
preserves the same lambda source returned with different actual captures.

All queries/answers/edges are SoA columns with typed indices. Arguments, formals,
fields and captures use flat index ranges. Symbols are interned source IDs;
diagnostic text is formatted later. The observation table is itself indexed and
has a flat, finite product layout.

## 2. Exact kernel rules

Rules below operate on symbolic facts relative to the owner template. Every rule
has a reverse dependency index; a new edge replays existing facts and subscribes
to future ones. Every (edge,answer) delivery is deduplicated.

**Input:** q(F(T,j),d) produces Input(T,j,d). No caller writes into F(T,j).

**Alias/union:** q(alias p,d) subscribes to q(p,d). A union subscribes to each
alternative independently; equal answers deduplicate. Evaluation dependencies of
all source alternatives remain separate from these value facts.

**Closed origin:** q(source function declaration,W) produces its declaration
origin. q(source lambda,W) produces its source closure origin. A genuine opaque
call RESULT produces Opaque(site), not a guessed source closure. A global read
keeps that value origin unchanged; its static declaration provenance is another
fact, not a conversion of Opaque into Known.

**Closure capture:** q(lambda L,C(L,k)) subscribes to its defining lexical port
with W (or to the corresponding S obligation for static-capture validation).
Lexical ports are explicit inputs when the lambda is summarized independently.
Other closure-capture channels do not match that lambda. Source-closedness is a
separate finite obligation graph over direct captures, not enumeration of nested
capture tuples. A genuinely free RuntimeInput is non-static; an opaque captured
materialization not covered by the kernel is residual, not automatically a false
non-static verdict. A lambda's own callback formals are not free captures.

**Known local allocation:** q(record A,P(field,m)) subscribes to the selected
field operand with m. Tuples use their indexed operand. A closure/record inside
that operand is then queried at its own source port. This consumes the selector;
it does not append a path to an existing symbolic answer.

**Record update:** q({ B | f=V },P(f,m)) subscribes ONLY to q(V,m).
q({ B | f=V },P(g,m)) for g!=f subscribes to q(B,P(g,m)). Independently, evaluation
of the update always evaluates B and every override operand. Never walk every
base field to decide the effective callback fields. A role whose field is
replaced cannot inherit that old field's opaque callback origin.

**Projection of an input:** a source field read from a formal produces
Input(T,j,P(field,m)). Identity forwarding can retain that observation unchanged.
If another unresolved formal selector would have to be prepended and the result
is not in D, produce Residual(ProjectionComposition,source equation). Do not
invent an expanded selector identity or a source-level not_static error.

**Metadata construction:** its result has a constructor-source origin with an
unbound anchor. q(result,R(K,r,m)) follows the constructor callback argument's
EFFECTIVE protocol field r with mode m, using the rules above. Root binding to a
top Program definition supplies foo/bar as the anchor. A descriptor returned
from a declaration/alias forwards its already bound definition identity.

**Known call substitution:** a direct checked call c of template U has actual
ports a[0..n], result port z and explicit lexical-capture bindings. Query
q(z,d) subscribes to the already shared summary q(U.result,d). For EACH answer:

- Input(U,j,d') installs q(z,d) <- q(a[j],d') at THIS source call c;
- a closed source origin/provenance/residual is forwarded unchanged;
- lexical-input dependencies use that source call's explicit capture port.

If q(a[j],d') returns Input(T,k,d''), the caller answer is Input(T,k,d'').
It is NEVER written into U's formal. The subscription key is
(c,d,U-input j,d'), a tuple of finite SOURCE IDs. It contains no incoming caller
identity. All source calls of U reuse U's summary; each source result port keeps
its own substitution answers. Recursive known calls add cyclic subscriptions
and finite Input/origin facts, not new template/port identities.

**Execution/liveness:** known direct calls add source execution dependencies;
function/lambda values retain ordinary declaration liveness without asserting
invocation. Reach remains the checked implicit/liveness authority. Effects,
native callback execution, C, EntryHost, Wire and ownership remain unproved.

**Launch summaries:** a source metadata launch contributes an export query for
its argument, not merely a value-result fact. A known caller subscribes to each
callee launch-argument export and applies the SAME Input substitution rules.
An export is indexed by (owner template, original source launch site, argument
role), not a call path. This is essential for a Unit-returning helper that launches
its Program argument. Installing a new callee export notifies existing known
call sites and recursively creates the caller export. Record source call-site
execution edges separately so the export does not erase evaluation multiplicity.
The finite launch-export port universe is at most T*L*A for L source launch sites
and A declared argument roles; allocate it sparsely. It is included in P below.
An unsupported invocation also has an execution residual export even if its
return value is ignored: absence of a value-result dependency cannot prove that
it executes no nested launch. Evaluation/liveness uses source edges, not a
flattened list of every transitive call path.

## 3. Precise higher-order boundary

Forwarding a function/closure as a VALUE is supported by the rules above.
Constructing a closure that CAPTURES such a value is supported by direct capture
observations and symbolic input dependencies. This does not invoke that value.

A source call whose callee is a formal, a captured input, a computed property or
an escaped closure value remains Residual(InvokeFormal/Captured/Computed,site),
even when a later root query reveals one known lambda origin. This kernel does
not use a globally joined origin set to guess an invocation environment. A direct
checked declaration call is supported. An immediate source lambda/local function
is supported only with explicit defining lexical-port bindings; if those cannot
be expressed by existing source inputs, its invocation is residual.

For `invoke g x = g x`, retain the source callee/argument/result ports and the
residual equation. Calling invoke through an ordinary known helper forwards
that residual, using ordinary source dependency edges for its witness; it does
not nest environment objects or promote the residual to Opaque. An entry may
still have known static callback roots and captures while its execution/launch
discovery is incomplete. A launch verdict depending on this invocation is an
explicit analysis gap. This is a foundation only, never full worker discovery.
No unspecified guard matching algorithm is used in this kernel.

## 4. Required worked challenge

```
wrap f = lambda capturing f
relay f = wrap f                 # one shared internal call site
foo = make (relay first)
bar = make (relay second)        # or an opaque-produced value
```

Let the wrap lambda be L and its capture be k.

- wrap summary W: Origin(L).
- wrap summary C(L,k): Input(wrap,0,W).
- relay's wrap call substitutes its OWN formal port: relay summary W is
  Origin(L), and relay summary C(L,k) is Input(relay,0,W).
- foo's relay-result port answers C(L,k) with Origin(first).
- bar's distinct relay-result port answers C(L,k) with Origin(second), or the
  actual opaque/provenance/residual fact from bar's argument.

There is one wrap template, one relay template and one internal call binding.
Neither foo nor bar modifies either template's formal input. Lambda L and the
inner call site are identical, yet capture queries are distinct because the
outer VALUE PORTS differ. There is no caller chain or capture-environment tuple.
The make summary forwards its start-role mode to its own formal; R(start,C(L,k))
therefore reaches the same matched first/second capture through the same rules.
Adding `forward x=x` between relay and wrap simply substitutes another symbolic
Input and does not change this result.

If bar's opaque value is itself the requested callback, it remains a genuine
unknown executable origin. If it is only captured inside known L and static
materialization is unproved, preserve that obligation/residual; do not poison
foo or invent a not_static capture claim. If L calls captured f, that invocation
is residual in BOTH entries in this kernel; foo's known capture remains first,
bar's remains second/opaque, and neither is falsely claimed to have executed.
Calling either returned closure through `invoke` is explicitly residual, not
misclassified as opaque or silently run with another caller's capture.

## 5. Delta saturation and root anchoring

Summary solving happens in the finite symbolic domain above. Closed entry/root
queries are separate seed bindings, also persistent; they do not feed caller
actuals into template inputs. Top definitions bind constructor anchors; aliases
forward definition IDs. Root/role/capture query answers retain their source port
and entry binding identity, so another entry cannot change their capture facts.

A runtime formal-0 binding is a persistent entry seed edge, not a copy of its
currently known values. New Program facts traverse it later. A metadata launch
with that formal as its argument therefore discovers runtime-forwarded self
launches without requiring a new entry count. Installing new entries, roles,
runtime roots or propagation edges also backfills existing facts.

Saturate the summary/root/entry/edge queues to emptiness before verdicts. An
empty transient cell is not opaque. Runtime self-launch and late-fact fixtures
must show the same final graph under different queue schedules/jobs settings.

## 6. Bound and structural scaling assertions

Let P include source ports plus the bounded launch-export ports, F be
formal/capture slots, O source origins, D the PREBUILT observation count, and K
the fixed residual-reason count. At most P*D SYMBOLIC summary queries exist.
Let E be finite Program identities and Sroot be entry/runtime/callback seed
bindings: at most E*(1+O*R) for R protocol roles, without caller paths. Closed root
queries are keyed by (seed ID, source query); at most Sroot*P*D exist. A seed is
an entry/runtime/constructor-role identity, NEVER an arbitrary invocation frame. Each answer is an origin, one Input(F,d), provenance source ID or residual
source equation ID: at most O + F*D + O + K*P alternatives per query. Thus a loose
symbolic fact bound is P*D*(2O + F*D + K*P). Closed seed facts have a further
factor at most Sroot and finite bound constructor identity pairs E*O; a loose
combined bound is (1+Sroot)*P*D*(2O + F*D + K*P + E*O). It is independent of
call-path count or concrete runtime type instantiations. No operation constructs an observation outside D;
unsupported compositions are finite source residuals. D itself is a finite
product of source selector/capture IDs and manifest role IDs, not a type-unroll
or call-string domain. Storage is sparse; do not allocate that bound as a matrix.

Call-substitution subscriptions are keyed by source call, requested observation
and callee Input answer. Their loose count is B*D*F*D for B source calls.
Other dependencies are source equation/observation/answer tuples. Each new fact
is queued once and delivered once per subscribed edge. Reverse indexes and
(edge,fact) dedup make transfer work bounded by the actual edge/fact join, not
whole-template rescanning. All construction/projection/capture walks are explicit
work queues with indexed visited states; no source-depth C recursion.

For the forwarding diamond family, D is constant, every level's result summary
has EXACTLY one formal-0/W answer, and there are EXACTLY two direct source calls
per level. With N diamond levels plus the base identity:

- function templates = N+1 (plus fixed fixture declarations);
- source diamond call bindings = 2N;
- boundary formal-result summary pairs = N+1;
- deliveries of those boundary pairs to diamond call bindings = 2N.

Additional local query facts are at most D per active diamond port because each
port has one symbolic forwarding answer; two closed entry seeds only add their
fixed per-root answers, not per-path template copies. Assert aggregate facts
against D*activePorts plus the separately counted root answers, and aggregate
deliveries against D*activeDependencyEdges plus root-edge deliveries. These are
IR-shape equations, not guessed wall-time thresholds. Run sizes 8/16/32/64 and
inspect ALL counters so hidden invocation/capture context copies cannot escape
the assertion. A two-anchor relay/wrap family must retain distinct capture
answers with one template per source lambda/function and linear source edges.

Hash-index facts, queries, edges, roots and collision digests. Canonical identity
sorting is O(E log E); digest collision lookup is indexed with canonical-byte
comparison only on a matching digest. No all-pairs collision scan. Counters,
IR-shape formulas, deep-stack fixtures and ordinary emitted-tree equality are
required focused evidence before integrated full gates. Existing compiler
budgets remain binding; polynomial sparse-domain bounds alone are not a claim
that actual throughput/allocation budgets have passed.


# Declaration sealing and paired capture obligations

Normative implementation detail, 2026-10-31. This supersedes the corresponding
rules of the first kernel section. It preserves the decided worker contract. General
higher-order invocation and unsupported selector composition remain explicit
residual relations, never a guessed dynamic origin or a launch permission.

## 1. A Program declaration seals its own initializer before any read

Each checked VALUE declaration d whose alias-expanded OUTER nominal head is an
entryKinds Program K gets two distinct ports:

- init(d): the ordinary symbolic initializer result;
- export(d): Seal(d,K,init(d)). Every top/ext declaration read subscribes ONLY
  to export(d), including reads from aliases, helpers and another Program's body.

This edge is installed from checked decl_heads when source templates are built.
It is independent of which declaration/launch is queried first. Functions whose
result type is Program are still functions: their outer head is not Program, so
there is no seal at a function entry/return. Containers merely containing a
Program are not Program declaration boundaries either.

Constructor result facts have two statuses:

- U(o,K): source constructor origin o with NO Program definition identity;
- B(d,o,K): that origin was bound at declaration d's seal.

Seal(d,K) transforms ONLY U(o,K) arriving from init(d) into B(d,o,K). It forwards
an existing B(e,o,K) unchanged, even if e!=d. It forwards opaque/residual facts
without purifying them. It never changes the shared source constructor object.
An ordinary factory/known call forwards U until a checked Program declaration
boundary actually receives it. A launch site is NOT a sealing boundary.

Final emitted identity, when that later phase is enabled, is canonical package /
module / PROGRAM DECLARATION d, not constructor site or discovery order. Analysis
retains (d,o) provenance pairs because one declaration can have several possible
constructor origins. At most E*O such bound pairs exist for E Program declarations
and O source constructor sites. Aliases that forward existing identities create
no new Program identity. An unbound origin reaching a launch remains a missing
named executable root; naming a container or an ordinary factory does not bind it.

### Origin-indexed callback profiles

Profiles must retain this same origin status. Add a finite origin filter to
constructor-role observations:

    Role(U(o,K), r, mode)
    Role(B(d,o,K), r, mode)

At Seal(d,K), a query about B(d,o,K) unions BOTH init(d)'s U(o,K)
contribution newly sealed to d AND init(d)'s already-bound B(d,o,K) contribution
forwarded unchanged. For e!=d, B(e,o,K) profiles forward unchanged as well.
No already-bound contribution is discarded, including the e=d case. In equations:

    export(d).Role(B(d,o), r, m)
        = init(d).Role(U(o), r, m) union init(d).Role(B(d,o), r, m)
    export(d).Role(B(e,o), r, m) = init(d).Role(B(e,o), r, m)   when e!=d

Other already-bound profiles keep their own origin filter and are not merged
into d's newly sealed U profile. Forwarding/union/call substitution preserves the filter.
This matters even when the bound and unbound alternatives came from the SAME
shared make constructor site. Captures remain queried at the particular value
port plus origin/role filter, never globally by lambda/record/constructor site.

For each source origin there is one unbound filter and at most E bound filters.
This adds a finite factor at most (E+1)*O to role-query keys, not a caller chain.
Anchor binding does not specialize concrete source types or duplicate templates.

### Required declaration-boundary oracle

Using the same constructor site inside make:

    foo = make first
    a = foo
    b = a
    forward p = p
    c = forward b
    mixed = if flag then c else make second

Expected exports and profiles:

| Declaration | Exported constructor facts | Program identities | Own callback binding |
| --- | --- | --- | --- |
| foo | B(foo,o) | foo | first |
| a / b / c | B(foo,o) | foo only | forwarded foo profile |
| mixed | B(foo,o), B(mixed,o) | foo and mixed | foo keeps first; mixed's U branch binds second |

A helper mk f = make f still returns U(o) symbolically; bar = mk second seals
only that result to bar. Querying c/mixed before foo, and different delta queue
orders, must give identical results. A mixed bound/unbound union returned by a
factory directly to a launch is NOT sealed by that launch. A source container
holding a newly constructed Program does not acquire an anchor merely because
the container itself is a top-level declaration.

Fixtures must cover alias-of-alias, helper forwarding of an existing descriptor,
helper construction, mixed bound/unbound alternatives from the SAME constructor
site, first-query order, and the matching origin-filtered capture observations.

## 2. Every capture observation has an explicit mode

There are two modes:

- W: executable/allocation/value origin;
- S: static-capture/source-materialization obligation.

The finite observation grammar is:

    Mode(m)                                m in {W,S}
    Capture(L,k,m)                         a direct source capture slot
    Select(s,Mode(m))
    Select(s,Capture(L,k,m))
    Role(originFilter,r,Mode(m))
    Role(originFilter,r,Capture(L,k,m))

s is one interned source field symbol or tuple index; L,k is an existing source
lambda/local-function capture slot. There is no capture/selector path string.
Every W capture channel now has its paired S channel. Source role fields and
origin filters are prebuilt finite IDs. Before origin-filtered roles, the domain
has at most 2*(1+C)*(1+Ssel) channels for C source capture slots and Ssel selectors.
Roles add at most 2*(E+1)*O*R*(1+C), for R protocol role positions. Channels are
stored sparsely with indexed interning, but no rule creates another grammar form.
Composition outside this grammar remains a finite source residual.

q(lambda L,Capture(L,k,W)) follows the capture's defining value port in mode W.
q(lambda L,Capture(L,k,S)) follows that SAME defining port in mode S. A wrong-L
capture query does not match. For a known call these produce symbolic Input(T,j,d)
answers and use the same call-local substitution as W; actuals never populate
another template's formals. A closure origin alone carries NO S proof.

## 3. Exact S transfer and finalization rules

S is an AND obligation graph, not a positive bit attached to an origin. It has
source query nodes and indexed dependency edges. Requirements are retained
symbolically in summaries; source Input(T,j,S-channel) is a requirement on that
input, not a runtime failure and not automatically Closed.

Primitive S evidence/obstructions are distinct:

- StaticLeaf: a literal or a source function declaration with no lexical runtime
  environment, or a separately justified static declaration reference. Its
  executable origin remains separate; this is not a rule turning opaque results
  into known source functions.
- RuntimeExternal(site): a PROVEN free value supplied by a runtime/callback input.
- UnknownMaterialization(site): an opaque result whose static materialization is
  not established by this kernel. It is not automatically RuntimeExternal.
- Residual(reason,equation): an unsupported projection/invocation/materialization
  proof. A residual is not an opaque source origin.

Transfer table:

| Source/query | S obligation or result |
| --- | --- |
| formal/capture input | symbolic requirement on its own paired S channel |
| alias / possible-value union | ALL contributing alternatives' S obligations |
| source function declaration / literal | StaticLeaf under the source rule above |
| source lambda L | AND of EVERY direct lexical capture's paired S query |
| record / tuple / tagged allocation | AND of EVERY stored field/element's S query |
| record update | AND of EVERY EFFECTIVE stored field's S query, overrides before base |
| known call | substitute EACH callee S requirement through this call's actual port |
| proven free runtime input | RuntimeExternal, propagated through aliases/fields/captures |
| opaque computed value with no static materialization proof | UnknownMaterialization, propagated without upgrading it |
| unsupported composition | Residual, propagated without relabeling it RuntimeExternal |

A named global VALUE does not bypass its initializer's closure/allocation S
obligations. Keep StaticDeclRead(d) provenance as evidence, but it is NOT by
itself a discharge of the environment of a value returned by that initializer.
In particular a globally named closure still has its actual direct captures
queried through the declaration's value profile. A source function declaration's
code dependencies on other declarations remain ordinary liveness/execution
facts; they are not anonymous lexical value captures created at that read.
Native availability, effects and ownership remain separate unproved obligations.

For a record update, effective fields must be computed from the checked closed
record shape/source fields. If the kernel cannot enumerate the effective shape,
retain Residual(AllocationShape), not a pass or a false opaque callback. Base
EVALUATION and all override expression evaluations are separate edges regardless
of effective field selection. Thus replacing base.init=opaqueCallback() with
init=first can have known effective init W/S while retaining the base call's
evaluation/effect obligations. The unselected opaque field does not contaminate
the update's effective callback/capture value.

After GLOBAL delta quiescence, finalize S with an explicit iterative SCC walk.
The nodes/edges include instantiated entry/runtime/role seed requirements, but no
arbitrary invocation environment. Symbolic template requirements remain symbolic;
a closed root must discharge every reachable input requirement through its seed
bindings. No early positive S is published while facts/edges can still arrive.

On the SCC condensation graph:

1. RuntimeExternal reachable through an actual capture/field obligation is a
   proven non-static free-value obstruction. It propagates through its dependent
   components.
2. UnknownMaterialization, Residual or an undispatched root requirement means
   Unproved and propagates. Do not manufacture a non-static-language verdict from
   this implementation gap. A genuine opaque executable callback in W remains a
   separate unknown-code-origin verdict; S does not purify it.
3. A component with no obstruction, whose outgoing obligations are discharged,
   is Closed ONLY when its value equations have productive source witnesses
   (explicit lambda/allocation/static-leaf production), not merely an alias-only
   cycle or an empty answer. W origins identify the source production but are
   not sufficient: every field/capture obligation above is also required.
4. Known mutually recursive source closures/records may close coinductively:
   their finite source productions exist and every outgoing dependency is Closed
   or internal to that SCC. Add one external RuntimeExternal capture and the
   SCC becomes non-static; add one unknown/residual and it becomes Unproved.
   An originless alias-only cycle remains Unproved/missing executable production,
   never vacuously SourceClosed.

SourceClosed therefore means a completed finite S obligation proof. It is NEVER
inferred solely from Origin(L), Origin(record A), a global name, lack of a known
negative fact, or a presently empty queue for one entry.

## 4. Captured-record challenge, worked without an environment tuple

    wrap x = lambda capturing r, where r = { payload = x }
    relay x = wrap x                  # same shared internal source call
    foo = make (relay first)
    bar = make (relay runtime/opaque)

Let L capture k=r, and let the source record be A. Then:

| Query | wrap summary | relay summary | foo result | bar result |
| --- | --- | --- | --- | --- |
| Mode(W) | Origin(L) | Origin(L) | Origin(L) | Origin(L) |
| Capture(L,k,W) | Origin(A) | Origin(A) | Origin(A) | Origin(A) |
| Capture(L,k,S) | Input(wrap,0,S) via payload | Input(relay,0,S) | StaticLeaf(first) | RuntimeExternal OR UnknownMaterialization/residual, matching the actual argument |
| Mode(S) | same required payload-S obligation via capture r | same symbolic requirement | Closed | NonStatic for proven external runtime capture; Unproved for unsupported opaque materialization |

The identical lambda and record origins are intentional. They do NOT imply equal
S. Every paired S query is still attached to the outer VALUE PORT/profile and
substituted through that source call's actuals. Nothing writes first/runtime/
opaque into wrap or relay's global formal cells. There is one template for wrap,
one for relay, one shared internal call and one source record/lambda production.

If the captured x is itself a source closure/allocation, its S obligation follows
its own direct captures/fields through the same graph. No arbitrary nested
capture channel is created: the paired capture-S query leads to an S node at the
actual producing port. If that reduction would require an unsupported composed
formal observation, retain a projection residual instead of guessing.

If a nested invoke helper calls the returned closure through a formal, its
invocation remains an explicit residual under kernel-v1's boundary. The distinct
capture/S facts above are still preserved; no guard approximation executes one
entry's closure with another entry's captured record. No full discovery or
worker proof is claimed.

## 5. Bound and required evidence after this amendment

Only finite factors are added: paired W/S modes, source capture/selector/role
IDs, E*O bound constructor provenance and origin filters. Queries/requirements
remain keyed by source ports and finite observations; S dependency pairs have a
loose Q^2 bound for Q queries. No key contains a caller chain, capture-value tuple,
expanded selector path or concrete generic instantiation. The precise sparse
count formulas in kernel-v1 acquire these explicit finite factors. AND edges
store factored dependencies, not a DNF/Cartesian expansion of possible records.

Required fixtures before any integration:

- alias-of-alias/helper forwarding and mixed B(foo,o)+U(o) at one shared ctor site,
  including first-query order and origin-filtered role/capture observations;
- the captured-record challenge with first vs second, a proven runtime formal,
  and an opaque-materialization residual; compare W AND paired S, not only W;
- globally named closure values retain capture obligations; naming an opaque
  callback value never upgrades W to a known source callback;
- effective record overrides retain base evaluation but discard overwritten
  callback value obligations;
- guarded mutual closure/record SCC closes; the same SCC with external runtime,
  unknown/residual, or no productive source witness does not pass;
- old diamond structural-count, late runtime/self-launch, explicit-stack depth,
  jobs/order/cache/relocation and unchanged ordinary-output requirements remain.

The kernel and this amendment were reviewed before replacement code. Any
remaining materialization case outside these exact rules remains a compiler
proof gap; it is not a new source rule, owner decision or budget waiver.

## Representation of an absent filtered profile

A proved nonmatching origin/field/capture channel has an explicit absent-profile
answer. It is distinct from a temporarily empty query or an originless recursive
value. This implements the reviewed Seal union: the U and already-B(d) inputs
can each be absent without turning the other matching profile into an S gap.
Absent profiles contribute no value and are neutral for the all-existing-values
S obligation. They do not certify a callback or executable root: those still
need a productive W origin and the required matching role/capture profile.
Unknown/residual source values never produce a guessed absent answer.

## Source-pair launch export storage

Each (template, original launch-site) summary export has one sparse indexed port.
A known source call forwards a callee export through the same actual binding as
its ordinary result; its export-call port names the callee export as the queried
result instead of the ordinary function body. This is a source pair, never an
invocation/environment. Export contributions are collected by a delta walk over
reverse source call edges, then frozen as flat union ranges before value solving.
The extra port bound includes T*L union exports and B*L export-call ports for T
templates, B known source calls and L original launch sites. Original source
calls remain separate execution edges. A Unit result cannot hide a launch export
or an execution residual. No expanded call path is stored.

## Internal inspection lifecycle

The hidden `dump --stage=entries --platform=P` and `check --entries --platform=P`
hooks run the same compact collector after a clean ordinary check, full platform
contract validation and fresh main selection. `dump` retains its existing refusal
of persistent-cache flags; cached `check --entries` reads the actually installed
and validated `decl_heads` artifact. Missing platform is a usage error. With
`--continuations --entries`, continuation metadata prints first and entry facts
print after successful contract/main validation. Default check/build output and
exit codes are unchanged. Analysis residuals and candidate non-static origins are
printed facts of this partial inspector, not new default source errors or an
entry-launch permission. Contract and main errors use the existing diagnostic
renderer and publish no entry graph. All whole-worker proof columns remain
unproved and `discoveryComplete` remains false.

`Emit.inspectEntry` returns owned diagnostic messages and a caller-scratch Reach
input after `checkContract` and fresh `findEntry` only. The caller renders before
resetting scratch. Session graph rows are cleared before metadata revalidation
and before replacing the checked store. Collection copies its index-addressed
source descriptors and evidence into Session-owned SoA storage before releasing
phase arenas. Mutable phase ports, substitution edges and query cells do not
escape. Output is not a serialized cache or a new checker authority.

Checked dispatch terms outside direct top/ext callees and record-field calls are
reported as a separate `dispatch` residual. In particular a checked primitive
comparison is not a higher-order formal call and is not an opaque Program
producer. This partial kernel does not invent a scalar-provenance model for
those terms; their result/evaluation transfer remains unproved. Annotated
recursive source functions still share one template and finite call equations
when an independent comparison operation has this residual. Residual reason is
stored on the source Call row so value queries and execution rows agree.

## Conservative checked-declaration liveness

The first artifact publishes a separately labeled conservative declaration set
using existing `Reach.run`, with roots at each canonical anchor declaration, its
metadata runtime declaration and its known callback source declarations. A nested
lambda's source declaration is the coarse code root. Checked implicit/evidence,
constructor guards and ordinary materialized function-body references remain in
the existing resolver/walker. The source-entry pass does not replace that logic.

There are no deferred-site cuts in this slice: today's ordinary constructor
body can eagerly invoke a callback, and construction-effect/C proofs plus the
paired deferred-descriptor/emission rewrite are still absent. The conservative
set may therefore contain a different Program's callbacks and unexecuted ordinary
function bodies. It is neither evaluated-initializer isolation, exact per-entry
code nor proof of host/realm availability. Callback/runtime/evaluated source roots
remain distinct from declaration liveness, with all execution/C proof columns
unproved. Exact deferred cuts remain the already-decided later paired phase;
ordinary Cycles is unchanged. Fixtures must pin preservation and intentional
overapproximation rather than assert unsupported pruning precision.

The copied live-node IR uses typed entry/module/node IDs and a kind column. A
source-indexed root relation and dense declaration marks deduplicate roots;
module bitsets are copied into graph-owned rows before a reusable per-entry
Reach arena resets. No borrowed liveness bitmap escapes. Report liveness run and
node counts separately from symbolic solver evaluations.

A successful legacy platform contract without resolved entry-kind rows is not an
entry-analysis proof. Its hidden inspector returns the empty partial artifact
with `inputSupported=false`; it does not run the compact collector or the typed
role inspector without both Plan validation and a selected resolved entry kind.
Legacy contract validation can finish an empty Plan; `validated` alone is not
evidence that resolved worker entry rows exist. Missing validated metadata inside a
selected current plan is an explicit compiler-inspection failure, not a silent
Writer failure or a source-language rejection.

## Shared source-field lookup and measured work

Field selection must not linearly scan a wide allocation once per selector. The
solver builds one shared sparse `(AllocationId, SelectorId) -> PortId` index from
immutable source Field rows, once before its first lookup. Both direct field
projection and the source-local reduction used for a second selector use that
same index. Its storage is proportional to actual source fields, not the dense
allocation/selector product. Duplicate source rows (if an internal probe creates
them) retain the first row, matching the old source-first selection rule; ordinary
checked records already reject duplicate labels. The original SoA field order
is unchanged for source evaluation/provenance traversal and emitted code.

Expose actual index-row insertion work, field lookup requests, field-edge visits
and source-local projection walk steps alongside the existing query/fact counters.
The real checked-source wide-record oracle captures every `wide.fi.payload` from
one source-local wide allocation: outer selection exercises the local reduction
and inner selection exercises ordinary projection. Increase width with one
Program root, so measured field work cannot hide a quadratic scan behind a growing
entry-root product. Counter acceptance is linear in width, not just wall-clock
or count of successful result facts.

## Conservative initializer attribution and indexed metadata

A checked Program read records its descriptor identity AND conservative evaluation
of its ordinary initializer in the originating execution graph. A descriptor
marker cannot suppress eager source effects or launches before the paired deferred
constructor/emission rewrite and construction/C proofs exist. A candidate entry's
own initializer projection is still unproved; it does not replace the originating
entry's evaluation dependency. Ordinary Cycles and default emission stay unchanged.

Before translating calls, index checked `(module, declaration)` identities to
source-ordered constructor/launch metadata relations. A call performs one indexed
lookup, then visits only its matching rows. Emit every matching launch argument,
including when that function also has a constructor row; do not silently choose
one launch parameter or lose constructor-body execution dependencies. Equivalent
repeated constructor descriptions are idempotent. Multiple distinct constructor
views at one function remain an explicit partial-kernel metadata residual until
that transfer is implemented; they are not a new language refusal or permission
to invent a callback view. Exact nominal heads use a dense checked TypeId-to-kind
index, not repeated scans or textual type-name guesses. Report source index rows,
lookup requests and matched rows as builder work.

## Memoized exact record shapes

The ordinary checker requires an update base to HAVE every updated field and
keeps the base's type (`check/constrain/Expr.zig`, record_update). An update never
widens a record. This existing checked guarantee permits its field-name shape to
share its base shape; replacement values still come from the update's own source
fields through indexed value lookup. Source evaluation order remains base first,
then written fields, and the conservative execution graph retains those effects.

Intern each source literal's sorted selector set once as a canonical closed shape.
Memoize shape equations per source port with explicit enter/exit stacks: aliases
forward a shape; updates forward their base's shape; alternatives require the same
closed canonical shape on every branch. Calls, unresolved inputs, unsupported
materialization and cyclic equations remain unknown, never inferred closed from
a source allocation origin. All updates sharing a shape reuse one flat selector
range; no ancestry walk or growing selector copy occurs per allocation. Canonical
shape hashing has indexed collision buckets and exact selector comparison.
Counter fields count port visits, equation edges and selector words/comparisons.
The deep checked-source oracle repeatedly replaces one existing field, observes
its final captured record and requires linear builder work across chain lengths.

## Case materialization control channel

A source `case` retains its scrutinee port independently from its alternative
value ports. W origins still union finite alternatives. Whole-value S additionally
subscribes to the scrutinee under an S-only `control` observation bit. This is a
finite paired provenance channel (at most twice the existing observation domain),
not a guard formula, caller environment, new type or language syntax. Descriptor
identity/role filters continue to select their existing value profiles; actual
capture materialization eventually queries whole-value S at the capture source.

The control bit survives aliases, source projections, capture transfers and
symbolic Input/call substitution. Source-local reduction of a composed field
selector retains every encountered case scrutinee as a separate S-control
obligation, even when all selected fields are statically known. These obligations
use the same seed and preserve the existing already-bound role-profile exclusion;
W follows only the selected value ports. Reducing two known selectors must not
silently erase control that materialized the intermediate record. A statically closed control contributes only
closed provenance obligations. A runtime_external fact entering a control query
becomes an explicit materialization_control residual, hence Unproved rather than
NonStatic; a symbolic Input retains that control observation until substitution.
Opaque/residual control stays Unproved. This avoids certifying captured literals
selected by runtime/opaque control as SourceClosed, while not blindly labeling
identical static alternatives NonStatic. Identical alternatives with unresolved
control may remain Unproved in this partial kernel; no value-equality guard
simplification is claimed. Runtime payload facts from the selected value itself
still retain their ordinary S meaning. All whole-worker proofs remain unproved.

A W runtime_external answer from a deliberately seeded runtime formal is positive
runtime-input evidence, just like an explicit source RuntimeInput origin. The
collector reports its needed executable/Program value as candidate not-static
runtime; it must not relabel that known fact as an unimplemented projection.
Unseeded symbolic inputs and unimplemented native/result transfers remain
residuals. This classification is not a new default source error.

Control obligations also apply when S observes a selected field or a direct
capture: materialization can choose different data behind the same source
allocation/closure site. They apply to unbound-constructor role profiles U(o),
where a controlling case can select different actual captures at one factory
site. The one exclusion is an already-bound Program role profile B(e,o): selecting
an existing immutable Program identity forwards that identity's original profile
and does not synthesize new captures. Its declaration initializer already retained
any control that built that value. Thus cases between existing Program references
remain finite aliases, while controlled construction/field/capture materialization
cannot become SourceClosed merely by filtering a shared source origin.

Canonical literal shape sets are built on demand when an update's shape equation
needs them. Unused wide literals are not sorted/preprocessed merely because they
exist in the checked store.

Imported nullary Beni constructors are closed literals under the same rule as
local nullary constructors. Read their arity from the already resolved checked
interface constructor row named by BIR.ext_ctor; do not infer it from spelling or
repeat import/provenance resolution. Constructors requiring arguments remain an
explicit unsupported callable-value transfer. This lets a static `False` actual
discharge its control obligation instead of manufacturing an analysis gap.

## Owned role-transfer producer

[workers-entry-role-transfers.md](workers-entry-role-transfers.md) specifies the bounded Session-owned publication of this algebra's exact Entry/Anchor/role/capture queries, original source sidecars and shared substitution derivations. Its structural validation does not certify local answer equations or authorize callback execution/native lowering; existing static statuses remain producer observations.
