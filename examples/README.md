# PsychophysicsManager Test Examples

This directory contains manual integration, persistence, and display tests for
the package under development. It is deliberately a test workbench rather than
a step-by-step tutorial.

Run commands from the `PsychophysicsManager.jl` package directory:

```sh
julia examples/run_example.jl
```

The scripts activate the examples environment themselves (so the
`--project=examples` flag is optional) and use `PsychophysicsManager.jl/data/` for
checkpoints regardless of the launch directory. Every `[PARTICIPANT_ID]`
argument is optional: when omitted, the reserved default participant
`test_user` (`DEFAULT_PARTICIPANT_ID`) is used — name the participant
explicitly for real data collection.

## Interactive (REPL) Use

Scripts are the unattended/batch form; for Matlab-style interactive work,
start a REPL once from the `PsychophysicsManager.jl` directory (`julia
--project=examples`), pay the package-load cost a single time, and drive
sessions directly:

```julia
using PsychophysicsManager, GLMakie

session = SessionContext(
    ExperimentParameters("OK_Geometry_Study", :DistrN, 0:5, 2),
    MarkerLayout(StimConfig = "d r t", Ref = 240.0, Anchor = :middle),
    Adjustment(dep_var = :Diff, dep_range = -120:120))

run_experiment!(session)        # the console reporter shows progress
visualize_results(session)
```

Windows stay open between commands, checkpoints are written as usual, and
repeated runs need no recompilation. Omitting the participant argument uses
`test_user`; sessions for real participants get the id as the first argument
of `SessionContext`.
Set `PEM_EXAMPLE_WORKDIR` to an alternate directory when test data should
be isolated, for example:

```sh
PEM_EXAMPLE_WORKDIR=/tmp/pem-example \
  julia --project=examples examples/run_example.jl
```

## The Operator Dashboard

`run_dashboard.jl` opens the dashboard on its own: choose an experiment in Browse,
among the templates or the previous sessions (a previous session shows its data),
the participant in Control, and start. `save_templates.jl` writes the example experiments (the Oppel-Kundt
adjustment, the two-interval contrast threshold, the auditory filled-time
experiment) into the templates directory, `[storage] templates_dir` of
`settings.toml` (`templates` by default); a session prepared in the dashboard is
saved there with Save as Template. The stimulus backend loads when a session starts.

```sh
julia examples/save_templates.jl    # once
julia examples/run_dashboard.jl
```

## Main Visual Test

Both primary visual tests retain the OK4 geometric configuration and
adjustment range while using neutral experiment and file names:

- `run_ok_experiment.jl [PARTICIPANT_ID]`: direct stimulus-window workflow.
- `run_ok_dashboard.jl [PARTICIPANT_ID]`: two-window operator-dashboard
  workflow with live progress, live adjustment results, and session controls.

Display selection, stimulus window size, and fullscreen behavior come from
`settings.toml`. The stimulus engine prints every monitor GLFW detects with
its index; if the index order does not match your OS's, set
`[display] screen_name` to a fragment of the desired monitor's printed name
(e.g. `"HDMI"`) — a name match overrides `screen_idx`.

Controls for geometry adjustment tests:

- Left/Right: decrease or increase the adjustment value.
- Enter/Space: confirm the current value.

For the dashboard test, click `Start Session` in the operator window and then
focus the stimulus window before entering participant responses. The dashboard
(Dear ImGui: `using CImGui, ImPlot, GLFW, ModernGL`) provides Start, Pause,
Resume, Undo, Stop and Discard, a live plot and the table of trials; a right-click
on a plotted point or a table row marks a trial an outlier or presents it again.
The geometry engine captures responses in its own stimulus window. Two monitors
are recommended: `[display] dashboard_screen_idx` (or `dashboard_screen_name`)
puts the dashboard on the operator's.

## Main Audio Test

`run_temporal_oppel_kundt.jl [PARTICIPANT_ID] [REPEATS]` runs the auditory
filled-time (temporal Oppel-Kundt) experiment with Constant Stimuli and the
operator dashboard:

```sh
julia --project=examples examples/run_temporal_oppel_kundt.jl Audio_Test 4
```

The first, filled reference interval is 1000 ms and contains six equally spaced
filler bursts. The empty comparison interval ranges from 800 to 2000 ms in
200 ms steps. All markers are 1000 Hz, 30 ms bursts with 3.4 ms linear ramps.
The default two repeats produce 14 randomized trials (pass a REPEATS argument
for more). The 2.6 s leading
silence gives the response-to-next-onset delay of the reference protocol.

The experiment uses a 48 kHz sample rate. Set `[audio] output_device` in your
`settings.toml` to the exact PortAudio device name, or leave it blank to use the
operating-system default; `using PortAudio; devices()` lists available names.

Keep the dashboard focused while responding:

- Left: first interval sounded longer (`-1`, stored as binary `0`).
- Right: second interval sounded longer (`+1`, stored as binary `1`).
- Enter/Space: replay the same stimulus without recording a trial.

This example uses `peak_amplitude = 0.5`, half of the available digital peak
range (approximately -6.02 dBFS). It is not a dB SPL specification or a
hearing-safety guarantee. Begin setup at low hardware gain. Before participant
data collection, select the intended audio device, calibrate the complete
playback chain, verify the waveform at the headphones, and record that hardware
configuration. Device latency is not yet measured by PsychophysicsManager.

## Contrast Threshold Test

`run_contrast_threshold.jl [PARTICIPANT_ID]` measures a contrast detection
threshold with the two-interval Gabor stimulus and the built-in 2-down/1-up
staircase: 60 trials over log-spaced contrasts, then the proportion correct per
contrast and interval, a logistic fit whose threshold is read at 75 % correct,
and its plot. `Psi(pf = :weibull)` replaces the staircase without changing the
design.

In the stimulus window:

- Left: the patch was in the first interval (`-1`).
- Right: the patch was in the second interval (`+1`).
- Enter/Space: show the pair again without recording a trial.

Read the calibration and timing notes in `docs/STIMULI.md` §6 before reporting
the threshold: the contrast is digital, the window has 8 bits per channel, and
the intervals are timed only to within a frame of GLMakie's render loop.

## Headless And Console Tests

- `run_example.jl`: deterministic emulator smoke test; no input or display.
- `run_interactive.jl`: console response test for Constant Stimuli.
- `run_interactive_adjustment.jl`: console adjustment test.

These are useful for checking the session loop, checkpointing, response
handling, and analysis without depending on laboratory display hardware.

## Persistence And Inspection

- `run_from_file.jl SESSION.json [PARTICIPANT_ID]`: creates and runs a fresh
  participant session from an explicitly selected checkpoint. The source file
  must contain a known engine name. Geometry and audio engine checkpoints are
  supported by the examples environment.
- `inspect_session.jl [SESSION.json]`: prints session metadata, parameters, and
  trial history without opening a GUI. With no argument, it uses the newest
  checkpoint in the configured example data directory.
- `inspect_results.jl [SESSION.json]`: prints and plots stored results. With no
  argument, it opens a terminal file-selection menu.

`run_from_file.jl` intentionally requires an explicit file: silently running
whichever checkpoint happens to be newest is unsafe during laboratory testing.

## Scenario Plans

`run_scenario.jl PLAN.toml` runs the sessions a scenario plan lists, back to
back. Each run replicates a saved session — any session file can be the
template, for example one written by `run_ok_experiment.jl` — for its
participant, with the parameters it overrides, and writes the new session to a
destination of its own:

```toml
[[run]]
id = "p01-plain"
source = "templates/ok.json"             # relative to the plan
destination = "sessions/P01_plain.json"
participant_id = "P01"
tags = ["plain"]

[run.overrides]
stim_par.StimConfig = "r t"
```

`?load_scenario` describes the format in full. The plan itself is never
modified: what has been run is recorded beside it, in `PLAN.state.toml`, so
running the same plan again continues with the first run not yet complete, and a
run cut off by a crash continues from its own file. The script waits for Enter
before each further run, and `q` stops the plan until the next time. A plan never
overwrites a session: a run that was stopped is measured again only under a new
destination.

The dashboard runs a plan as well: a plan kept in the templates directory is listed
in Browse › Scenarios with its runs, and choosing it prepares the next run — the
participant and the parameters the plan gives, which Parameters can still change —
for Start. Once a run has finished, Prepare Next Run in Control prepares the next.
Between sessions Enter or Space presses Start or Prepare Next Run, so the participant
can go on alone. Paths in the plan are relative to the plan, so `source = "ok.json"`
names a template beside it.

## Display Diagnostics

- `ruler_test.jl`: interactive 1-pixel gap and marker-width check.
- `debug_display.jl [MONITOR_INDEX]`: borderless bitmap, placement, and scaling
  check. Without an argument, it uses `screen_idx` from `settings.toml` and
  clamps unavailable indices to the detected monitor range.

These scripts are manual diagnostics, not automated calibration. Record and
verify the actual laboratory display configuration before collecting data.

## Model Observer (AI participant)

Three self-contained scripts run the visual Oppel-Kundt experiment with a model
instead of a person as the participant, plus one script to pool completed runs:

| Script | Figure | Observer |
|---|---|---|
| `run_ok_simulated_observer.jl` | filled | simulated psychometric rule (offline, free) |
| `run_ok_ai_observer.jl` | filled (the illusion) | model named by `OBSERVER` |
| `run_ok_ai_observer_plain.jl` | three segments, no filling | the same model |
| `plot_pooled_ai_sessions.jl` | — | pools completed AI sessions via `AnalysisSet` |

```sh
export OPENROUTER_API_KEY="sk-or-..."   # or ANTHROPIC_API_KEY for the Claude API

julia --project=examples examples/run_ok_simulated_observer.jl
julia --project=examples examples/run_ok_ai_observer.jl
julia --project=examples examples/run_ok_ai_observer_plain.jl
```

See [`docs/AI_OBSERVER.md`](../docs/AI_OBSERVER.md) for API key setup, `OBSERVER`
and `DELIBERATION` options, model screening (`LEVELS`, `"screening"` tag), and
pooling rules.
