# Child processes

On the `node` platform, the `ChildProcess` module starts another program and waits for its end.
The output is kept whole. Call it in a fiber that can wait, for example under `Io.run`.

## Run a program

`ChildProcess.command program args` gives a `Command` with defaults. `ChildProcess.run cmd` waits
until the child has exited and its output has ended.

```beni platform=node
import ChildProcess
import Io
import Node exposing (Program)


main : Program
main = Io.run λ⊤ →
    case ChildProcess.run (ChildProcess.command "git" [ "status", "--short" ]) of
        Err _ →
            Node.exitWith "cannot run git" 1

        Ok output →
            case output.status of
                ChildProcess.Exited 0 →
                    Node.print output.stdout

                _ →
                    Node.exitWith output.stderr 1
```

- There is no shell. Each argument goes to the program as it is: a space, a `$` or a `*` has no
  meaning. To run a shell script, start the shell: `ChildProcess.command "/bin/sh" [ "-c", script ]`.
- A program name without a `/` is looked up in the `PATH` of the child's environment.
- The answer is `Ok { status, stdout, stderr }` when the child started. `status` is `Exited code`
  or `Signalled name` (`"SIGTERM"`, …). A non-zero exit is `Ok`, not `Err`.
- Both streams are decoded as UTF-8. Standard input is empty.
- A child that leaves a descendant with its output open keeps `run` waiting.

## Change a default

Use record update on the command:

| Field | Default | Meaning |
|---|---|---|
| `cwd` | `Nothing` | the child's working directory |
| `env` | `ChildProcess.Inherit` | `Inherit`, `Extend pairs` (the program's environment with these set), or `Only pairs` |
| `killAfter` | `Duration.seconds 1` | the time between `SIGTERM` and `SIGKILL` when the fiber is cancelled |
| `maxOutput` | 16 MiB | the most bytes kept of each stream; more is `Err OutputTooLarge` |

```text
ChildProcess.run { ChildProcess.command "make" [] | cwd = Just "build" }
```

## Errors

`Err` has a `RunError`: `NotFound` (no such program or working directory), `PermissionDenied`,
`NotADirectory`, `ArgumentsTooLong`, `NameTooLong`, `SymlinkLoop`, `FileBusy`, `BadExecutable`,
`TooManyOpenFiles`, `TooManyProcesses`, `OutOfMemory`, `InvalidArgument` (an empty program, a NUL
character, or an environment name that is empty or holds `=`) and `OutputTooLarge`. Any other
failure stops the program.

## Cancel and time out

A cancelled fiber stops its child: `SIGTERM`, then `SIGKILL` after `killAfter`. The cancellation
ends when the child has exited, and the output is dropped. A timeout is a cancellation:

```text
Task.timeout (Duration.seconds 5) λ⊤ → ChildProcess.run cmd
```

When `Io.run`'s fiber ends, every child that still runs is stopped the same way.

Sources: `docs/design/boundary.md` §9.14; `docs/design/transparent-effects-proposal.md` §16.5; the module's doc comments.
