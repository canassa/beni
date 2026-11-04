## 2026-11-03 04:30 CET — Typed renderer job storage

**What I did**

Added generated native maps and DOM/error adapters. Migrated crash listeners,
Inline write buckets, command sends and grouped root mounts to typed jobs.
Targeted development/release fixtures pass, including root mounts and commands
in happy-dom and Chrome. Browser readers now accept the restored List forms.
These independent changes are committed and pushed; the renderer migration
continues. Indexed native storage and a per-site closure proof are in progress.

**What I learned**

A generic row type can stay inside a site's closed render function. Only the
site's item and key types need Any identities; raw callback keys remain intact.
Integer duplicate-key links can avoid a recursive boxed row representation.
The pinned native generator's import layout conflicts with beni fmt on the
parent branch; issue #1746 records the independent baseline failure.
