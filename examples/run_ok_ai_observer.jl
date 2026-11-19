# Oppel-Kundt experiment measuring a model observer on the filled figure.
#
#   julia --project=examples examples/run_ok_ai_observer.jl
#
# Edit the block below and run the file. `run_ok_simulated_observer.jl` repeats
# that block to check the chain without spending a request, and
# `run_ok_ai_observer_plain.jl` measures the same figure without the filling, on
# a range of its own.
# Read docs/AI_OBSERVER.md before reading anything into the result.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using HTTP, PNGFiles          # activates the networked observer backends

# ═══════════════════ EXPERIMENT PARAMETERS ═══════════════════

OBSERVER    = "openai/gpt-5.6-terra"   # broker slug; "anthropic:model" = Claude API
REPEATS     = 3                      # presentations per level
REFERENCE   = 240.0                   # px, the interval held constant
DISTRACTORS = 4                       # markers filling the reference interval
LEVELS      = -100:50:200       # px added to the test interval (Diff)
MIRRORED    = false                   # true = test interval on the left
CANVAS      = (900, 200)              # px; keep the long edge ≤ 2576
DELIBERATION = :low                  # :none = judge immediately; :low…:max = think first

INSTRUCTIONS = """
The image shows a row of short vertical segments on a dark background. The \
leftmost, middle and rightmost segments mark two adjoining intervals; any \
segments in between are filling, not endpoints.

Which interval looks longer, the left one or the right one? Judge by how the \
image looks, not by counting pixels.

Answer with one word: "left" or "right". Choose one even if they look equal. \
Do not explain.
"""

# ═════════════════════════════════════════════════════════════

startswith(OBSERVER, "simulated") && error("The simulated observer has its own script.")

stim_par = MarkerLayout(StimConfig = "d r t", StimMirror = MIRRORED,
                              Ref = REFERENCE, DistrN = DISTRACTORS, Anchor = :center)
ex_par = ExperimentParameters("OK_AI_Filled", :Diff, LEVELS, REPEATS)
session = SessionContext(replace(OBSERVER, r"[/:]" => "_"), ex_par, stim_par,
                         ConstantStimuli();
                         tags = ["condition:filled",
                                 MIRRORED ? "layout:mirrored" : "layout:standard"])

# `"d r t"` draws the test interval second — on the right until the figure is
# mirrored — and that side is the one coded +1
task = ObserverTask(INSTRUCTIONS, ("left", "right"), MIRRORED ? "left" : "right")
source = ModelObserverSource(model_observer(OBSERVER; deliberation = DELIBERATION), task;
                             max_attempts = 3, on_failure = :invalidate)

run_observer_experiment!(session, source, OffscreenVisualEngine(CANVAS...); report = :trials)

print_observer_summary(session, source)
fit = print_psychometric_summary(session)
fit.converged && println("PSE: $(round(fit.alpha, digits = 2)) px = " *
                         "$(round(100 * fit.alpha / REFERENCE, digits = 2))% of the reference")
# Proportion of "test interval longer" per level, with the fitted curve and its α
visualize_results(session; title = "OK figure — $(OBSERVER)")
wait_for_enter()
