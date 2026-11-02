## Diagnose local cell selectors in core Js

Extended cell-selector validation to local core/Js references and replaced
lowering's assertion with a diagnostic. The black-box test checks both check
and build, and fails against the previous implementation. Strict erasure of
Cell/Opt is staged on #1738 until HostFree's typed List implementation lands;
its patch and reduced List.map case are preserved separately.
