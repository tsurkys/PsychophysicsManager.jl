# Running an experiment with a model observer

A *model observer* is a participant that is a program. PsychophysicsManager ships three:

| Backend | Answers from | Use it to |
|---|---|---|
| `SimulatedObserver` | the stimulus *description*, with a known psychometric rule | check that the method, the loop, the aggregation and the fit recover a threshold you put in |
| `OpenRouterObserver` | the *rendered pixels*, via one broker key | measure many models — Claude, GPT, Gemini, open-weight — through one request shape |
| `ClaudeObserver` | the *rendered pixels*, via the Claude Messages API | measure Claude through the vendor's own API |

All three are `AbstractObserverBackend`s driven by the same `ModelObserverSource`,
so the session, the method and the analytics cannot tell them apart. Run the
simulated observer first: it costs nothing and proves the chain is intact.

> **A model observer is not a proxy for a human participant.** These data
> describe a model, and must never be pooled with human data — see *Keeping the
> data apart*.

## Quick start

```bash
export OPENROUTER_API_KEY="sk-or-..."     # or ANTHROPIC_API_KEY for the Claude API

# No network, no cost: a known threshold, recovered end to end
julia --project=examples examples/run_ok_simulated_observer.jl

# The measurement, and the control that says what its PSE is worth
julia --project=examples examples/run_ok_ai_observer.jl
julia --project=examples examples/run_ok_ai_observer_plain.jl
```

One condition per script, and none of them takes an argument: what is measured
is the `EXPERIMENT PARAMETERS` block at the top of the file, so a changed design
leaves a trace in the file that records it. `run_ok_ai_observer.jl` measures the
filled figure, `run_ok_ai_observer_plain.jl` the same figure without the filling,
and `run_ok_simulated_observer.jl` checks the chain for free. Each holds its own
copy of the block, so they are comparable only while the copies agree — nothing
enforces that.

`OBSERVER` in that block is the **observer spec**, the one place the backend is
chosen:

| Spec | Observer | Needs |
|---|---|---|
| `provider/model`, e.g. `openai/gpt-5.6-terra` | `OpenRouterObserver` | `OPENROUTER_API_KEY` |
| `anthropic:model`, e.g. `anthropic:claude-opus-5` | `ClaudeObserver` | `ANTHROPIC_API_KEY` |

A bare model name — neither a slash nor a prefix — is rejected rather than
guessed: `anthropic/…` and `anthropic:…` are different instruments. So is
`simulated`, which the measuring scripts refuse and refer to
`run_ok_simulated_observer.jl`, the one that knows the built-in ground truth.

Start at `REPEATS = 1` as a smoke test: only a live run shows whether a model
honours the forced-choice schema.

API keys are read from the environment, and checked when the observer is built:
export them in `~/.bashrc`, which the shell and the VS Code Julia terminal both read.

## Writing your own run

```julia
using PsychophysicsManager, HTTP, PNGFiles      # HTTP + PNGFiles activate the networked backends

backend = model_observer("openai/gpt-5.6-terra"; deliberation = :none)  # judge at once
session = SessionContext("gpt-5.6-terra", ex_par, stim_par, ConstantStimuli();
                         tags = ["ai-observer"])
source  = ModelObserverSource(backend, length_comparison_task();
                              max_attempts = 3, on_failure = :invalidate)

run_observer_experiment!(session, source, OffscreenVisualEngine(900, 200))

print_observer_summary(session, source)   # answered, dominant answer, failures, latency, cost
fit = print_psychometric_summary(session) # proportions per level and the threshold
```

`run_observer_experiment!` installs the source, records the task and the
identifying tags, invalidates every unanswered trial the moment it is recorded,
and stores the observer provenance even if the run is interrupted.
`observer_summary(source)` returns the printed numbers for scripting, and
`constant_response(session)` the option that dominated the session — its name,
the number of valid trials that chose it and the number there were — if one did.

A session run by a person is given its task by hand — `set_task!(session,
task)` — so that what was asked, and what `+1` meant, is in the file rather than
in the script.

## Screening

A model near chance on a difference a human could not miss cannot produce a
psychometric function. Screening is the same experiment at unmistakable levels:
set `LEVELS = [-120.0, -60.0, 60.0, 120.0]` (±25 % and ±50 % of the reference)
and `REPEATS = 3`, and add `"screening"` to the session's `tags` — the only thing
keeping the control out of a measured run, since the two share participant,
stimulus type, method and independent variable.

Read the per-level proportions, not a single accuracy figure:

- negative levels make the *reference* interval physically longer, so a model
  that sees the picture answers near 0 there and near 1 at the positive levels;
  0.5 everywhere means it cannot do the task;
- the signs are read separately: with distractors the illusion opposes
  correctness at positive `Diff` and assists it at negative `Diff`, so an
  asymmetry between them is a finding, not a fault;
- run `run_ok_ai_observer_plain.jl` too — a model that passes plain and fails
  filled is telling you about the figure rather than about its eyesight.

Below roughly 90 % correct, widen the measured `Diff` range before spending a
session; at chance, do not measure at all. Expect model capability rather than
rendering to be the binding constraint. `print_observer_summary` separately
flags a model that gave *one option on at least 90 % of the valid trials*, naming
the count and the total: that scores about 50 % on a balanced level set, which
accuracy alone cannot distinguish from random responding, and a handful of
departures from the one option does not change that reading. A session of fewer
than 10 valid trials is not judged, since there the share would mean unanimity.

Two endpoint constraints show up as a keyword in the measuring script. Both
change what is measured, and both are recorded in `observer_metadata`:

- `DELIBERATION = :low` — some endpoints mandate deliberation and reject
  `:none`, so such a model cannot be measured in the immediate-judgement
  condition at all;
- `require_parameters = false` on the `model_observer` call — reaches endpoints
  that do not declare support for everything sent, which makes the forced-choice
  schema a request rather than a guarantee.

## How a trial reaches the model

`OffscreenVisualEngine` rasterizes the stimulus into a fixed `Bool` canvas with
the same `render_stimulus!` the on-screen engine uses, so the model is shown the
pixels a participant would see. The Core loop hands that buffer to the response
source in a `TrialContext`; the backend encodes it as a PNG and sends one
stateless request — a single user turn with the image and the instructions —
whose answer is constrained by a JSON schema admitting only the task's two
options, then mapped to the abstract coding (`+1` / `-1`).

## What is controlled, and what is not

- **One request per trial, no history.** History would let the model see earlier
  stimuli and its own earlier answers, producing sequential dependencies.
- **The answer is forced.** A refusal, an unparseable reply or a transport
  failure is missing data: retried, then raised or marked invalid, never turned
  into a response.
- **Sampling variability is mostly not yours to set.** Current Claude models
  reject `temperature`, `top_p` and `top_k`; `OpenRouterObserver` exposes
  `temperature` but leaves it unset. A near-deterministic observer turns the
  curve into a step — the threshold is still estimable, the slope and any JND
  are not. Pilot about 5 levels × 10 repeats and look at the proportions before
  fixing a level spacing.
- **A threshold without a spread is not a comparison.** The headless fit
  (`fit_psychometric_curve(data; gamma)`) reports `alpha` and `beta` and nothing
  about their uncertainty; `fit_psychometric_curve(data, :logistic; gamma)` adds a
  parametric bootstrap and returns its interval in `ci_alpha`; judge a difference
  between models by overlapping intervals, or by re-running, not by two bare
  numbers.
- **Latency is not reaction time.** `ObserverRecord.latency_s` is transport plus
  inference, and trials keep `onset_source = :estimated`.
- **The canvas is the viewing conditions.** Fixed for the session and recorded
  with the data. Keep the long edge at or below 2576 px: above that the Claude
  API downscales server-side, which for a figure of 2-pixel markers changes the
  stimulus rather than its quality. Through a broker the real limit belongs to
  the upstream provider and is not knowable from this side. Nothing here is
  calibrated to visual angle.

## Experimental factors

- **Deliberation** — `DELIBERATION` in the block, `deliberation` on the
  `model_observer` call: `:none` asks for an immediate judgement, `:minimal` …
  `:max` let the model think first. Different conditions, not a performance
  setting, and a model can be at chance in one and accurate in the other.
  Each channel spells it its own way — `reasoning` through the broker,
  `thinking` plus `effort` on the Claude API — so the experiment names the
  condition and the channel translates it, refusing a level it cannot express
  (the Claude API has no `:minimal`) rather than serving the nearest one.
  (OpenRouter's `exclude: true` would only hide reasoning that still happens;
  the backend sends `effort: "none"`.)
- **Model** — one broker key makes this a one-line change (`OBSERVER`). Comparing models
  through different agent CLIs compares harnesses instead: each adds its own
  system prompt, tools and context.
- **Stimulus side** — `MIRRORED = true` separates the illusion from a constant
  left/right bias: a genuine percept gives the same PSE in both layouts, while a
  side preference displaces them in opposite directions. The same flag sets the
  layout and the side coded `+1`, so the two cannot disagree. The `layout:` tag
  is the only thing keeping the pair from being averaged into one another, since
  they share everything else a session is matched on.
- **Reference length** — `REFERENCE` is held constant while `Diff` sweeps, so it
  sets what a given `Diff` means: the same 135 px is a 1.56× length ratio
  against a 240 px reference and a 1.75× ratio against a 180 px one. Vary it to
  find out whether a model follows the ratio or the pixel count — they are the
  same thing until the reference moves.
- **The instructions** — the exact wording is part of the method, like a written
  instruction sheet handed to a participant, and is stored verbatim with the
  session. Two wordings are two conditions, not two attempts at the same one.
  Each script holds the sheet for its own figure in `INSTRUCTIONS`: the filled
  one names the filling between the endpoints, the plain one describes three
  segments and nothing else. The price is one more difference between the two
  conditions — describing filling that is not on screen would be the other one,
  and copying one sheet into both scripts removes it. `length_comparison_task`
  is the package default: the simulated control uses it, since it answers from
  the segment lengths and never reads a word.

## Reading the result

The example sweeps `Diff` at a fixed `DistrN` with Constant Stimuli, so the
aggregated means are the proportion of "test interval longer" answers and the
fitted `alpha` is the PSE in pixels. `fit_gamma` stays at `0`: this is a
proportion-of-choice paradigm, not accuracy scoring. The illusion
magnitude is the PSE as a fraction of the reference length; repeat over several
`DistrN` values, in separate sessions, for the form comparable with human data.

## Keeping the data apart

Sessions record `observer_metadata` (backend, settings, failed requests) and
carry the `ai-observer` and `model:<id>` tags, with the model id as the
participant id. `run_observer_experiment!` writes all of that, tags included:
they are derived from the backend that answered, so a script cannot name one
model and query another.

Recorded settings keep the vocabulary of the channel that answered, since they are
its request fields — with one shared key: both networked channels also report
`"deliberation"`, the level as the experiment named it (`reasoning` through the
broker, `thinking` plus `effort` on the Claude API), so their sessions can be
selected on the condition without knowing which channel served them. A simulated
observer has no such condition and reports no such key.

What the observer was *asked* is elsewhere — `session.task`, the verbatim
instructions with the two options and the one coded `+1`. It is not observer
metadata because a human session carries the same three facts, and it is set
with `set_task!` when a person is the participant.

Combining sessions into one dataset (`AnalysisSet`) reads the same record: it
never pools a model session with a human one, whatever the settings, and by
default it also refuses to pool model sessions queried with different settings
or given different instructions (`COMBINING_CHECKS`).

## Cost

A cropped canvas is a few hundred input tokens and the answer a few dozen output
tokens, so a 90-trial session with thinking disabled costs on the order of a US
dollar at Opus-tier pricing, roughly five times less on Haiku; adaptive thinking
multiplies the output side. The tokens and the cost each request reports are the
ground truth and are totalled by `observer_summary`; they live on the source, so
read them before the run ends. The Batch API halves the price of a Constant
Stimuli run whose trial list is known in advance.

## Routing through a broker

The same slug can be served by different upstream providers — a variable you did
not intend to manipulate. `OpenRouterObserver` pins routing by construction:
`allow_fallbacks = false` (run where pinned, or fail), `require_parameters = true`
(only endpoints honouring every parameter sent, schema included), and
`provider_order = ["Anthropic"]` to fix the provider outright. Pin an exact model
version rather than a floating alias, since a slug that moves to a new release
makes two sessions incomparable. The provider and model that served each request
are recorded on the source's `records` during the run, and a reroute stops the
run outright; the session file keeps the aggregate, not the per-request detail.
