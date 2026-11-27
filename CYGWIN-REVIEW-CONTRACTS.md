# Cygwin terminal review contracts

A review method for Cygwin/MSYS2 runtime changes, followed by source-pinned
PTY/PseudoConsole contracts. Apply the relevant checks to the changed behavior
and its callers; a small patch does not require an audit of the entire runtime.

## Review method

**Establish the revision.** Compare the exact base and complete patched state,
not just the changed lines or changelog. Identify the revision and enclosing
function when citing a diff hunk; its header may name an internal label.

**Identify ownership.** Distinguish descriptor, archetype, process, terminal,
and kernel-object state. Follow aliases through copying, replacement, and
close. Readiness and cached settings must track the lifetime and authority of
the data they describe, including changes through another descriptor or process.

**Trace caller-held locks.** Follow callbacks, echo, signals, and alternative
public entry points. A deadlock needs the same kernel objects and a feasible
interleaving, not merely opposite variable-name arrows. Preserve waits that
deliberately retain a lock to protect a protocol.

**Check acquisition and failure paths.** Handle creation, duplication, and
wait results matter. `WAIT_ABANDONED` grants mutex ownership but calls for a
consistency check; timeout and failure do not grant it. Inspect initialization,
rebinding, and startup/debugger exceptions before assuming exclusion.
[Wait semantics][windows-wait].

**Separate protocol roles.** Requests, acknowledgements, ownership, and
observations are different state. Identify who advances each wait and what
happens on timeout, exit, or replacement. A completion must not erase a newer
request; an absent worker does not make its successor's required state
irrelevant.

**Follow deferred work.** When moving an operation, check retries, partial
success, timeouts, errors, signals, and cancellation. Work may need completion
before the next wait, not merely at the function's final return.

**Require progress.** Each retry needs consumed data, changed state, or a wait
for new information. Distinguish empty input, errors, incomplete input, and
completed input. A readiness indication or quota is an observation, not proof
of the higher-level condition a caller wants.

**Preserve interfaces.** Check virtual dispatch when changing signatures or
introducing helpers; adding a defaulted parameter does not preserve an override.
Preserve return-value, error, and EOF meanings as well.

**State the evidence.** Give a reachable before/after sequence, including
foreground groups, callbacks, and alternative repairs. Explain the causal
failure and actual terminal/runtime combination. Separate source reasoning,
observed runtime behavior, and unverified hypotheses.

## Scope of the concrete reference

**Source baseline:** `524d75ff73986b263161665af771cc90e55b5e01`, not necessarily
current Cygwin, MSYS2, or Git for Windows. Unless noted otherwise, source-line
links below use that revision; later fixes are identified separately.
**Required** means an explicit source obligation or documented fix contract.
**Observed** means only the cited code paths, not a global guarantee.

The following lock and routing contracts concern `fhandler_pty_*`. Do not
apply them to `fhandler_console` merely because a field or helper has the same
name. Recheck object identity, initialization, and callers in the target
revision.

## Lock responsibilities

| Lock | Observed scope | Obligation when reviewing a change |
| --- | --- | --- |
| `input_mutex` | Reader masking, input transfer, cursor-handshake state, and input-availability updates. [Masking][mask], [handshake][request], [transfer completion][transfer-finish]. | **Required:** every caller of `transfer_input()` holds it. This is an explicit non-local precondition, not something the callee acquires for itself. Preserve it when moving or adding a caller. |
| `pipe_sw_mutex` | Native setup encloses `setup_pseudoconsole()`; native cleanup encloses close/handover; `setpgid_aux()` encloses foreground-driven input switching. [Source][pipe-switch]. | Preserve those operation scopes. Cleanup releases `input_mutex` before closing/handing over the pseudo console, but retains `pipe_sw_mutex`. Do not infer that every `h_pcon_*` or owner-PID access is guarded by it. |
| `attach_mutex` | `attach_console_temporarily()` acquires it and leaves it held until `resume_from_temporarily_attach()` restores attachment and releases it. [Source][attach]. | Treat the helpers as a pair, including early returns and caller-held locks. Locking only the `AttachConsole()` call would not protect the console operations between attachment and restoration. |
| `output_mutex` | Slave writes serialize `process_opost_output()`; the non-PseudoConsole forwarding branch also uses it. [Slave write][output], [forwarding][forward-output]. | Preserve serialization of output postprocessing and column state on those paths. Do not mistake it for the input-routing or handle-ownership lock, or assume all output branches use it. |

The PTY master creates per-PTY named mutexes; slaves open them by name.
[Creation][mutex-create], [opening][mutex-open].

**Initialization determines the object.** `attach_mutex` is a process-global
`NO_COPY` handle, not necessarily a process-private mutex. PTY creation assigns
a named mutex; slave fork/exec fixup opens one by name. Console setup creates an
unnamed, non-inheritable fallback only if that same global handle is null.
Trace initialization and rebinding before deciding which processes share the
object. [Handle][attach-handle], [fixup][attach-fixup],
[console fallback][console-attach-init].

**A wait call is not proof of ownership.** Check its result and lifetime before
relying on exclusion. In particular, `acquire_attach_mutex()` returns
`WAIT_OBJECT_0` when its global `NO_COPY` handle is null, without acquiring an
initialized mutex. [Implementation][attach-handle].

### Do not invent a universal acquisition order

Native cleanup and `setpgid_aux()` show `pipe_sw_mutex` then `input_mutex`,
with attachment/transfer inside selected branches. Conversely,
`process_sigs()` temporarily attaches, calls `release_ownership_of_nat_pipe()`,
then restores attachment; that callee takes `pipe_sw_mutex` while the caller
already holds the attachment lock. [Cleanup/setpgid][pipe-switch],
[signal path][signal-path], [ownership release][ownership-release].

These observations require caller-aware review. They establish neither a
universal hierarchy nor a deadlock: that needs the identities of the mutex
objects and a feasible concurrent process/lifecycle sequence.

## Input routing and progress

**Do not steal input from an active Cygwin reader.** The `cat | native-app`
case can start reading before the native app configures its pseudo console.
Native setup must respect the reader mask rather than unconditionally switch
input to the native pipe. The mask uses `TTY_SLAVE_READING` and archetype
`num_reader` under `input_mutex`. [Fix rationale][mask-fix], [mask code][mask].

**One wait deliberately retains `input_mutex`.** At the end of a transfer to
Cygwin, waiting for `input_transferred_to_cyg` to clear while holding the mutex
prevents newly arriving master input from mixing with input still awaiting
line editing. "Release the lock before waiting" is not a safe blanket cleanup.
[Explicit comment and event ordering][transfer-finish].

**Preserve the handshake-aware pipe-switch probe.**
`to_be_read_from_nat_pipe()` probes `pipe_sw_mutex` with zero timeout and can
return false while setup owns it and `pcon_start`, `pcon_start_csi_c`, or
`pcon_start_pid` is set. Replacing that with an unconditional blocking wait
would discard the documented handshake/input-routing behavior. [Source][probe].

**A handle's role matters, not just its validity.** With `pcon_activated`,
`transfer_input(to_cyg, ...)` uses console-input APIs on its `from` handle.
A live raw-pipe handle is not an interchangeable substitute.
[Consumer][console-transfer].

## Cursor handshake

Treat `req_xfer_input`, `req_fixup_pcon_cur_pos`, `pcon_start`, and
`pcon_start_pid` as a protocol, not unrelated flags.

- **Request ownership:** `req_fixup_pcon_state()` reserves under `input_mutex`,
  releases it before waiting for the master, and rechecks the requester PID
  under the lock before clearing a timed-out request. Its two polling phases
  have 3000 ms deadlines, but mutex waits use `mutex_timeout`, normally
  `INFINITE`: this is not an operation-wide time bound or a bound on other
  reuse paths. [Source][request], [timeout default][mutex-timeout].
- **Reply meaning:** the master combines fragmented CSI 6 n / CSI c replies.
  Cursor-fixup replies are consumed locally, not forwarded as application input.
  Preserve that distinction when enabling a new producer. [Parser][parser].
- **Completion belongs inside the reservation lock:** the baseline clears
  `pcon_start_pid` after releasing `input_mutex`. Later fix `9e2f67d8b4ad`
  moves the clear before release, alongside enabling reuse cursor correction.
  An old completion must not clear a newer request's waiter.
  [Baseline][completion], [fix][handshake-fix], [discussion][handshake-thread].

## Handle ownership and archetypes

**Replacing shared handle values is not a per-descriptor operation.**
`open_with_arch()` can reuse an existing archetype without calling `open()`.
On first open, it snapshots the fhandler before calling `open_setup()`.
The PTY `copy_from()` copies handle values rather than duplicating the Windows
handles. [Call order][archetype], [copy][archetype-copy].

The adoption fix therefore moves replacement before the archetype snapshot.
Closing the old handles afterward leaves stale values in the archetype;
later reuse of the same numeric value can turn a repeated close into closing
a different live handle. [Fix explanation][adoption-thread].

**Preserve the pair transaction:** only replace the original input/output pair
after both duplications succeed. `OpenProcess()` failure retains the originals;
partial duplication failure closes only the temporary successes. Fixing the
snapshot order must not reintroduce the earlier leak or half-replaced pair.
[Earlier fix contract][pair].

Do not assume `open()` means "only the first process that opened this PTY."
Native-parent Cygwin startup also reaches it after `6eed1ef74869`; the
maintainer's review explicitly revisits that mistaken assumption.
[Review explanation][adoption-review].

## Other retained obligations

**Keep native-parent startup's no-PseudoConsole path cheap.**
`find_pcon_pty()` checks shared flags before lazily fetching the console process
list. Filtering candidates with `tty::exists()` creates/deletes named pipes;
hoisting `GetConsoleProcessList()` pays a cross-process cost even without a
candidate. These are documented reasons for the existing structure.
[Commit rationale][startup].

**Do not conflate pipe observations with their meaning.** POSIX `O_NONBLOCK`
and the Windows handle's mode can differ. Reported write quota is not always
free space: the SSH fix documents an empty 8192-byte pipe with a pending
8191-byte native read reporting quota 1. Changes must preserve both progress
and nonblocking behavior, including readiness consumers. [Fix rationale][quota].

**Reproduce the actual runtime combination.** For the adoption regression,
the thread specifies MinTTY, the downstream backport combination, and native
Git's choice of `sh`/`MSYSTEM`. An upstream-master run can hide the symptom
without fixing the handle error. [Reproduction clarification][clarification].

## Evidence limits

A claim about failed adoption followed by reopen needs a complete feasible
sequence in both base and patched code, including `setpgid_aux()`, startup
callbacks, foreground groups, caller-held locks, and alternative repairs.
Arbitrary combinations of flags are not a witness. [Source][pipe-switch].

This reference is neither an exhaustive field-to-lock map nor a universal lock
hierarchy. Its citations do not establish runtime validation for a new scenario.
Do not promote unverified findings into contracts.

[mask]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L1541-L1586
[transfer-finish]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L4666-L4679
[pipe-switch]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L4730-L4837
[attach]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L4870-L4909
[output]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L1520-L1536
[forward-output]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L3442-L3455
[attach-handle]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L233-L247
[attach-fixup]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L2927-L2933
[console-attach-init]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/console.cc#L1058-L1060
[mutex-timeout]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/termios.cc#L25-L29
[windows-wait]: https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject
[mutex-create]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L3573-L3588
[mutex-open]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L1021-L1042
[probe]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L1590-L1622
[signal-path]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/termios.cc#L339-L383
[ownership-release]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L4850-L4866
[archetype]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/base.cc#L437-L475
[archetype-copy]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/local_includes/fhandler.h#L2499
[request]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L391-L437
[parser]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L2560-L2637
[completion]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L2673-L2675
[console-transfer]: https://github.com/cygwingitgadget/cygwin/blob/524d75ff73986b263161665af771cc90e55b5e01/winsup/cygwin/fhandler/pty.cc#L4562-L4569
[mask-fix]: https://github.com/cygwingitgadget/cygwin/commit/4c0fc56cad9d39afbacebcc58d2174d1af131b2c
[handshake-fix]: https://github.com/cygwingitgadget/cygwin/commit/9e2f67d8b4ad7f229dc0e8d3e74f00a07ec0952e
[handshake-thread]: https://inbox.sourceware.org/cygwin-patches/20260720200802.436-1-takashi.yano@nifty.ne.jp/T/
[adoption-thread]: https://inbox.sourceware.org/cygwin-patches/pull.8.cygwin.1784540598759.gitgitgadget@gmail.com/T/
[adoption-review]: https://inbox.sourceware.org/cygwin-patches/20260807194730.736e6364077b65db9afe2daa@nifty.ne.jp/
[clarification]: https://inbox.sourceware.org/cygwin-patches/44947be6-f15d-8e6b-2b8a-295f54bc6b1e@gmx.de/
[pair]: https://github.com/git-for-windows/msys2-runtime/commit/425004632e4bb42211c0a781e30255aff9204415
[startup]: https://github.com/git-for-windows/msys2-runtime/commit/b9c42477004de85d75623f4c0b228cb8bb577ebc
[quota]: https://github.com/git-for-windows/msys2-runtime/commit/0ae6a6fa743c0adca21e16bf8bc7baee6c3c2d0b
