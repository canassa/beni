# Type worker Wire traversal

The Wire-plan walker no longer erases Array.find and Array.some callbacks.
Its searches and copy-on-change traversal are beni. Key enumeration and
Object.is use generated native data operations, and typed List.copy unwraps
list views. The obsolete discovered $plain method call is removed.

Native catalogue validation and the managed-worker Chromium corpus passed,
including generic, list, mixed and open-row Wire messages. Behavioral goldens
stayed unchanged. The main worker peer and transport storage still need migration.
