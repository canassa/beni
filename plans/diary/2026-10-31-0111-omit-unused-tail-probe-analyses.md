# Omit unused complete-handler replay analyses

Part of #894; PR #1304. Specified the §8.5 implementation boundary before code.
The independent replay never consumes replacement identity, message escapes,
post-evaluation command classification or the published model-field count.
Omit those computations only in the probe; retain abstract evaluation of source
commands and continuations. Keep model_type and charge needed type resolution,
field traversal and symbol copies before work/allocation. Propagate probe abort
past the existing ordinary type-helper OOM fallback.

The real Inline regression uses 256/512-field models and message records, a
record-update arm and a complete-literal arm. Optional existing self-profile
counters record actual walk bodies. Positive ordinary identity/in-place work and
positive eligible probe work prevent vacuous zero assertions. Instrumented prior
source has probe identity8/escape4; corrected replay has0/0. The element command
fixture preserves ordinary command3 and still joins for unresolved command-source
equality, while unused probe command4 becomes0. Both black-box tests fail before
and pass after. No runtime lowering or markup API change; no performance result
or UI acceptance claimed. Parent owns final review, integration and full gates.
