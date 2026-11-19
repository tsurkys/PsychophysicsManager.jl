# Presentation workers

A **worker** is a program outside Julia that owns the display and the input
device and presents on PsychophysicsManager's behalf. PsychophysicsManager connects to it with
`RemoteEngine` and sends one JSON line per presentation; the worker answers with
one JSON line. Nothing about the worker is Julia-specific: any language that can
read a line, decode JSON, and drive a screen can be one.

This directory holds the reference implementation,
[`psychtoolbox_worker.m`](psychtoolbox_worker.m), for MATLAB with
Psychtoolbox-3. **It has never been run against real hardware.** It was written
against the protocol and validated only by the mock worker in
`test/test_remote.jl`, which speaks the same lines. Verify it on your own rig
before a participant sits in front of it — `verify_engine(engine, stim_par)` is
the first check to run, and it refuses a worker whose timestamps are not unix
times.

## Running one

Start the worker first: it listens, PsychophysicsManager connects.

```matlab
>> psychtoolbox_worker(5555)
```

Then name its address in the `[remote]` section of the `settings.toml` that
PsychophysicsManager finds (`settings.toml.example` documents every section):

```toml
[remote]
host = "127.0.0.1"
port = 5555
read_timeout_s = 60.0
```

and run the session as usual — `RemoteEngine` is a registered engine type, so a
saved session restores it like any other:

```julia
engine = initialize_engine(RemoteEngine, session.stim_par, load_display_config())
try
    verify_engine(engine, session.stim_par)
    run_experiment!(session, engine)
finally
    close_engine!(engine)
end
```

## The protocol in one page

Every command is one JSON object on one
line, and every command except `close` and `abandon` is answered by exactly one
JSON object on one line.

| Command    | PsychophysicsManager sends                                                             | The worker answers                                            |
| ---------- | --------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `hello`    | `{"command":"hello","protocol":1}`                                          | `{"worker":"name","protocol":1,"version":"…","capabilities":[…],"stimuli":{…},"display_info":{…}}` |
| `present`  | `{"command":"present","protocol":1,"presentation":n,"stimulus":{"_type":…,"fields":{…}},"values":[…],"timeout_s":null,"min_response_s":0.0}` | `{"response":…,"onset":…,"timestamp_response":…}` |
| `abandon`  | `{"command":"abandon","protocol":1,"presentation":n}`                       | nothing; presentation *n* is answered `{"response":"abandoned"}` |
| `feedback` | `{"command":"feedback","protocol":1,"correct":true}`                        | `{"ok":true}`                                                 |
| `message`  | `{"command":"message","protocol":1,"kind":"break","text":"…","dismissible":true,"min_s":30}` | `{"ok":true}`, after the participant dismissed it (dismissible) or once shown |
| `close`    | `{"command":"close","protocol":1}`                                          | nothing; the connection closes                                |

`response` is a number in the abstract −1 / 0 / +1 coding, `null` when the
worker reads no input (PsychophysicsManager then collects the response from its own
response source), or `"timeout"` when the response window closed with nothing
answered. `onset` and `timestamp_response` are **unix times measured in the
worker**, or `null`. A worker that cannot present answers `{"error":"…"}` to any
command, and the session stops with those words rather than recording a trial
that did not happen.

## Declaring the stimuli

A worker may name the stimuli it presents in its hello reply, each with its
parameters and their defaults:

```json
"stimuli": {"oppel_kundt": {"Ref": 100, "DistrN": 3, "StimConfig": "r d t"},
            "number": {"value": 100, "text_size": 48}}
```

PsychophysicsManager then needs no Julia type for them: it holds such a stimulus as a
`WorkerStimulus` — the name and the parameters, in the worker's order — and a
parameter added to the worker's stimulus needs no change on the Julia side. A
default is a number, `true` or `false`, text, a list, or `null`, and the
parameter keeps that kind: the operator types a number for one that holds a
number. Make the session from what the worker declares and save it as a template,
which the dashboard then lists like any other:

```julia
engine = RemoteEngine("127.0.0.1", 5555)
declared_stimuli(engine)                      # ["oppel_kundt", "number"]
stimulus = worker_stimulus(engine, "oppel_kundt")
set_parameter!(stimulus, :Ref, 120)
session = SessionContext(ExperimentParameters("Oppel-Kundt", :DistrN, 0:4, 5),
                         stimulus, ConstantStimuli())
session.engine_name = "RemoteEngine"
save_session_checkpoint(session, resolve_templates_dir(); filename = "oppel_kundt.json")
close_engine!(engine)
```

Every `present` sends `_type` as the stimulus's name and `fields` with
**every** parameter the worker declares — the variable of the trial already
bound into the one it names — so the session file records each value the
stimulus was drawn with. When a session starts or continues, its stimulus is
compared with what the worker declares then: a parameter the worker no longer
declares stops it with that parameter's name, before the first presentation,
and one the worker declares that the session lacks is sent with its default and
written into the session (on a continued session, with the trial it began at).
The worker validates the values itself and refuses one with `{"error":"…"}`.

A whole number crosses as JSON writes it — `100`, not `100.0` — so read numbers
by value. A program that cannot be changed — a binary, a third-party tool — is
reached through a small worker of this kind that declares its parameters and
drives the program with them (its arguments, a configuration file).

## Ending a presentation early

The operator may want another stimulus at once, or stop the session, while a
presentation awaits its response. PsychophysicsManager cannot end a wait that happens in
another process, and an answer it stopped waiting for would be read as the
answer to its next command, so a worker that does not say it can end a
presentation is waited for: the operator's stimulus comes right after the
answer, and Stop takes effect then.

A worker that can lists `"abandon"` among the `capabilities` of its hello reply.
PsychophysicsManager then sends `abandon`, naming the presentation, while that presentation
awaits its response; it sends nothing else meanwhile. The worker ends the
presentation and answers that `present` with `{"response":"abandoned"}` —
`abandon` has no reply of its own. Nothing is recorded for an abandoned
presentation, so the timestamps may be left out. An `abandon` naming a
presentation already answered came too late: ignore it, and the answer stands.
The reference worker reads the connection between its keyboard checks
(`abandonRequested`).

## Messages to the participant

The instructions, breaks and closing text a session declares (`set_messages!`)
are shown by a worker that lists `"message"` in `capabilities`, in its own
window and style; `kind` says which. A dismissible message is answered once the
participant has pressed a key, no sooner than `min_s` seconds after it appeared;
a non-dismissible one (a break the operator ends) is answered at once and stays
on screen until the next `present` or `message`. A worker without the capability
needs nothing — its messages appear on the operator's screen or console. The
operator's Resume or Stop takes effect once a worker's dismissible message has
been answered.

## The clock

This is the part most likely to be wrong, and the part that cannot be repaired
afterwards. Psychtoolbox's `GetSecs` counts from an arbitrary origin, usually
system boot. Capture the offset **once**, at startup, and add it to every
reported timestamp:

```matlab
clockOffset = posixtime(datetime('now', 'TimeZone', 'UTC')) - GetSecs();
```

Do not recompute it per trial: the cost of the clock call would land in the
reaction times. Do not report the raw `GetSecs` value either — PsychophysicsManager refuses
a timestamp that is not a plausible unix time, because a session measured by two
clocks is not repairable after the fact.

The response timestamp must be taken where the input device is read, which is
why it travels in the reply at all. Were PsychophysicsManager to stamp the reply's arrival,
every reaction time would carry that trial's inter-process latency.

## Octave

The reference worker uses MATLAB's `tcpserver`, which is R2021a and newer.
Octave has no `tcpserver` in core; the `instrument-control` package provides
sockets, and `jsonencode` / `jsondecode` have been built in since Octave 7. The
socket calls at the top of the loop are the only part that differs — the
protocol, the clock handling, and the Psychtoolbox calls are the same. Rather
than one file that runs on both, keep an Octave copy beside this one.

## Writing your own

A worker needs to do four things: answer `hello` with its name **and the
protocol version it speaks**, present on `present` and answer with a response
and two unix timestamps, acknowledge `feedback`, and stop on `close`. Everything
else — what the stimulus is, which keys mean what, whether there is any feedback
at all — is the worker's business. A hello reply that names no protocol version
is refused, so that a mismatch is found before a participant sits down.
Optional commands — `abandon` and `message` (above) — are sent only to a worker
whose hello reply lists them in `capabilities`, and the stimuli it declares are
optional too.

The hello reply may also name the worker's own `version`, and it should: the
session records it as the stimulus program that presented it, and a session is
not continued under another version unless the operator chooses to (PsychophysicsManager
cannot see inside another process, so this name is all it knows). Change it
whenever the stimulus code changes. A worker that names none is recorded as
`unknown`, and its sessions are not compared.

Two details that cost an afternoon each if nobody says them:

- **MATLAB renames `_type`.** `jsondecode` cannot make a field name out of a
  leading underscore, so `stimulus._type` arrives as `stimulus.x_type`. The
  `fields` structure itself is untouched, because Julia field names are already
  valid identifiers.
- **Over stdio, stdout is the protocol.** A worker driven through a spawned
  process's standard streams — `RemoteEngine(open(cmd, "r+"))` — must write
  protocol lines to stdout and nothing else; its own progress messages belong on
  stderr. A socket worker is free to print whatever it likes.

Two failures are worth being deliberate about:

- **Enforce `timeout_s` yourself.** It is the participant's response window, and
  only the process reading the device can end the wait. PsychophysicsManager cannot.
  Likewise `min_response_s`: a press made sooner than that after the presentation's
  onset is dropped, without a reply, and the wait goes on. It is non-zero only on a
  trial's first presentation, when the laboratory's settings ask for it, so that a
  double press or a key held from the previous trial does not answer the new one.
- **Answer every command.** A worker that goes silent while holding the
  connection open looks like a working session that never advances. PsychophysicsManager's
  `read_timeout_s` exists for exactly that case, but it is off by default,
  because a transport deadline must not cut a legitimate long response window.
