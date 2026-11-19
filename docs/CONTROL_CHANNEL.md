# The control channel

The **control channel** lets a program — a Python or MATLAB script, an AI agent — work
with a running operator dashboard while the operator watches the same session. It
reads the session, its trials and the dashboard's messages, and sends the commands the
dashboard's own controls send: start, pause, resume, undo, stop, the corrections of a
trial, a new session from a template. Nothing in it is Julia-specific: any language
that can open a TCP connection, write a line and decode JSON can use it.

Every command calls the same function the dashboard's control calls, so every rule
holds for a program as for the operator: what a greyed-out button would refuse is
refused, with the words the operator would read. No command supplies an answer: the
participant's answers come from the participant alone.

## Turning it on

The channel is off unless the settings turn it on — in the `[control]` section of the
`settings.toml` the dashboard finds (`View › Settings` shows and changes it):

```toml
[control]
enabled = true
port = 5556
```

The dashboard opens the channel when its window opens, says so in its messages
(`The control channel listens on 127.0.0.1:5556.`), and closes it with the window. It
listens on this computer's loopback address only: no other machine can reach it, and
any program on this computer can. A port another program holds is reported in the
messages, and the dashboard works on without the channel.

## The protocol

A request is one JSON object on one line, naming its `command`; every request is
answered by one JSON object on one line. An `id` in a request comes back in its reply.

- A **reading** answers `{"ok": true, …}` with what was asked. It is not shown to the
  operator: a program polling the status would otherwise bury the messages.
- A **command** is noted among the operator's messages with who sent it
  (`analysis.py via the control channel: start`), then done, and answers
  `{"ok": true|false, "message": "…"}` — whether it was done, and the message the
  dashboard shows for it. A refusal's message says why.
- A request the channel cannot carry out — not JSON, an unknown command, an argument
  missing or of the wrong kind — answers `{"ok": false, "error": "…"}` and does
  nothing.

The messages are in the dashboard's interface language, which `hello` names.

### Readings

| Request | Reply |
| --- | --- |
| `{"command":"hello","client":"analysis.py"}` | `program`, `version`, `protocol` (1), `language`, `commands`; `client` names the program in the operator's messages |
| `{"command":"status"}` | `session` (experiment, participant, method, stimulus, variables, state, trials, counted_trials, planned_trials, trial_under_way, file — or `null`), `actions` (which controls are available now), `running`, `message` |
| `{"command":"trials","after":0}` | `trials`: each trial's number, `values` by variable, `response` (a number, `"timeout"`, or `null` when none came), `correct`, `counted`, `origin`, `onset` and `answered_at` (unix times); `after` skips that many already read |
| `{"command":"messages","since":0}` | `messages`: the dashboard's recent messages, each with its unix `time`; `since` keeps the later ones |
| `{"command":"comments"}` | `comments`: the operator's comments on the session in hand, each with its unix `time`, the `trial` it is about (or `null`) and its `text` |
| `{"command":"templates"}`, `{"command":"plans"}` | the templates and scenario plans Browse shows, each entry with its `path` |
| `{"command":"sessions","participant":"P01","state":"continuable"}` | saved sessions and datasets, newest first; optional filters: `participant`, `experiment`, `tags` (string or list), `state` (`"continuable"` or a `SessionState` name), `text`, `method`, `stimulus`, `from`/`to` (`yyyy-mm-dd`), `parameter` (`"name = value"`) |
| `{"command":"series","experiment":"Oppel"}` | sessions grouped into series under the dashboard's active combining checks, newest last run first (`key`, `participant`, `experiment`, `variables`, `repetitions`, `trials`, `last_run`, `state`, `continuable`, `sessions` as paths); takes the same optional filters as `sessions` |

### Commands

| Request | What it does |
| --- | --- |
| `{"command":"new_session","template":"contrast","participant":"P01","parameters":{"ex_par.repeats":5}}` | prepares a session from a template (its path, or its name in the templates directory) for a participant, with parameters changed; refused parameters leave it as the template has it |
| `{"command":"set_parameters","parameters":{"stim_par.Ref":12}}` | changes the parameters of a session not yet started, all of them or none; the keys are a scenario's: `ex_par.<field>`, `stim_par.<field>`, `method`, `method.<setting>`; after a session ends, those of the session `start_new` will run |
| `{"command":"set_participant","participant":"P02"}` | who the next session is for |
| `{"command":"start"}` | starts the session in hand |
| `{"command":"pause"}`, `{"command":"resume"}` | pause and resume; a trial under way still takes its answer |
| `{"command":"undo"}` | takes back the last answered trial, which is presented again |
| `{"command":"stop"}` | ends the session for good — **sent twice within 5 s**, as the button is pressed twice: the first reply asks for confirmation |
| `{"command":"mark_outlier","trial":7}` | trial 7 no longer counts |
| `{"command":"add_comment","text":"Glasses off","trial":7}` | adds a comment to the session in hand, at any state; `trial` is optional |
| `{"command":"repeat_trial","trial":7,"when":"after"}` | presents trial 7's condition again, its new answer replacing the old; `"when":"now"` abandons the trial under way |
| `{"command":"add_trial","trial":7,"when":"after"}` | the same, the new answer added to the old |
| `{"command":"present_condition","values":[0.2],"when":"after"}` | presents a condition of the design, one value per variable |
| `{"command":"start_new"}` | after a session ends: starts a new one of the same experiment — the one `set_parameters` prepared, if any |
| `{"command":"open_session","path":"…"}` | opens a saved session as it is, to look at or continue. A paused session in hand is set aside first (so do `new_session`, `choose_plan`); the reply then precedes the choice — read `status` |
| `{"command":"choose_plan","path":"…"}`, `{"command":"prepare_next_run"}` | prepares a scenario plan's next run |
| `{"command":"continue_changed"}` | continues a session under a stimulus program that has changed since it began |

## An example in Python

```python
import json
import socket
import time

connection = socket.create_connection(("127.0.0.1", 5556))
stream = connection.makefile("rw", encoding="utf-8", newline="\n")

def send(command, **arguments):
    stream.write(json.dumps({"command": command, **arguments}) + "\n")
    stream.flush()
    return json.loads(stream.readline())

print(send("hello", client="example.py")["commands"])
print([entry["name"] for entry in send("templates")["templates"]])
print([(s["participant"], s["experiment"], s["repetitions"])
       for s in send("series", state="FINISHED")["series"]])

reply = send("new_session", template="base", participant="P01",
             parameters={"ex_par.repeats": 2})
print(reply["ok"], reply["message"])
print(send("start")["message"])

while send("status")["session"]["state"] in ("READY", "RUNNING", "PAUSED"):
    time.sleep(0.5)

for trial in send("trials")["trials"]:
    print(trial["trial"], trial["values"], trial["response"])
connection.close()
```

In MATLAB, a `tcpclient("127.0.0.1", 5556)` with `writeline`, `readline`, `jsonencode` and
`jsondecode` speaks the same protocol; no MATLAB client has been run against it yet.
