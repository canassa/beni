# Exercise restored readers with actual trie lists

The existing Cloudflare reader fixture covered arrays, suffix views and tiny
synthetic objects exposing $plain. Those mocks did not demonstrate that a real
Beni trie reached each reader. The fixture now builds41-element lists with
List.push after a40-element array, exercising a trie root and a live tail.

The platform checks complete definitions and header values, accepted socket tags,
serialized attachment tags and WebSocket protocols. All five native catalogue
readers updated during trie restoration are covered. The WebSocket stub is
restored in a finally block. The original small representation cases remain.

A core run fixture checks the full logical contents through checked data,
Debug's generic borrowed inspection and the Js.array function-value wrapper.
It also verifies the total and suffix total through List's restored base/offset
readers. This uses the public formatter, preserving Inspect's Debug-only fence.

Both fixtures pass twice through the targeted ReleaseSafe corpus test, in
both development and release. Their scoped run hashes are refreshed under the
shared lock. Evidence: `~/worktree-evidence/hostfree-review1/trie-readers/` and
`schema-cleanup/direct-datum/`. This accompanies the browser reader fix #1787;
full hostfree gates remain for the completed PR.
