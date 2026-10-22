## 2026-10-22 02:18 CEST — isolate DictFocus grow and find another verdict

**What I did**

Resumed the owner's request to land #456 with one accepted false refusal:
DictFocus.grow, recovered by #294. The owner explicitly required stopping if any
other verdict changes. Opened #663, Recover DictFocus.grow via #294. Moved grow
from the corpus source to tests/pending/ownership/DictFocusGrow.beni, keeping its
golden's accepted verdicts from the pinned baseline. Existing refusal goldens
were not blessed.

Rebased fix-approximate-occurrences onto origin/master at 776a3930b. Git initially
could write its index but Btrfs returned ENOSPC on renaming index.lock over index.
Removed only this worktree's generated .zig-cache; sources, saved binaries,
logs and archives were preserved. The stash and rebase then succeeded. Retained
the backup stash after restoring the candidate. The new master commits have no
changes to ownership code, core, platforms or the ownership corpus. Btrfs later
refused an editor's rename too; preserved a backup and wrote the completed edit
in place instead, without losing the original or modified file.

Compared the isolated DictFocus source with the pinned baseline and the latest
completed candidate. The readLater callback's Maybe.map at 44:34 still changes
from accepted callback-param to rejected exclusive. Its full readLater example
was already rejected, but the callback's verdict is an additional change, outside
the owner's grow exception. Counts after removing grow change from eight accepted
and four rejected to seven accepted and five rejected. The comparison is preserved
in zig-out/dictfocus-moved-verdict.diff, with both complete reports beside it.

Stopped under step 4. No compiler change was made in this session. No summary or
refusal golden was re-recorded to hide the additional verdict, no production PR
or red implementation commit was created, and no merge was attempted. Recorded
the owner's grow exception and remaining landing blocker in the dated §16.7
amendment. The rebased candidate, pending fixture and diary remain preserved
uncommitted in the isolated dagon worktree. F2 and all later work stay unstarted.
No Zig command ran on the Mac.

**What I learned**

Moving the known safe example to pending does not remove the second callback
verdict change in DictFocus. The surrounding program already failing is not
permission to change that callback's expected verdict: the owner's acceptance
exception names grow only and explicitly stops on any other change.
