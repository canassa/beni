## 2026-11-09 13:48 CET — Browser capability base design

**What I did**

Read the browser-base lane brief, repository rules, direct rewrite plan,
prerender contract, platform layering contract and GPU placement/realm
contract. Inspected the current Cmd/Sub/Listen implementations and their
capability dependencies. Wrote the local proposal in
`docs/design/browser-capability-base.md`, including owner questions,
required measurements and black-box acceptance scenarios.

Before the manager's stop instruction, opened #2381 for the requested zorg
build prerequisite, labelled it in progress and posted an assignment
comment. The original build failed at `Contract.zig:746` on array element
comparison in std.mem.eql. After the instruction, made no further GitHub
changes, applied no fix and started no new build. No commit, push or PR.
The proposal remains local and unapproved.

**What I learned**

Platform dependency visibility prevents the proposed base from importing
renderer-owned Browser, Cmd or Sub. Shared nominal effect types require a
real lowering change. Listen.on also differs materially between renderers:
inline guards the event reader itself, before it sends. Hosted.job captures
log context at command construction, so moving constructors needs explicit
purity and context evidence. Navigation facades must preserve the existing
Browser.UrlRequest constructors; a type alias does not re-export them.
The existing size benchmark's TodoMVC entry targets browser-tea, and
cannot serve as an inline size baseline without checking a fixed inline
source first.
