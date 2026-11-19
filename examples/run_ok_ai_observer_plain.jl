# The plain control of `run_ok_ai_observer.jl`: the same measurement on a figure
# with nothing between its endpoints, so there is no illusion to find.
#
#   julia --project=examples examples/run_ok_ai_observer_plain.jl
#

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using HTTP, PNGFiles          # activates the networked observer backends
using GLMakie                 # the psychometric plot at the end

# ═══════════════════ EXPERIMENT PARAMETERS ═══════════════════

#OBSERVER  = "openai/gpt-5.6-luna"   # broker slug; "anthropic:model" = Claude API
OBSERVER  = "google/gemini-3.5-flash-lite"
REPEATS   = 3                     # presentations per level
REFERENCE = 240.0                   # px, the interval held constant
LEVELS    = -4:2:10         # px added to the test interval (Diff)
MIRRORED  = false                   # true = test interval on the left
CANVAS    = (900, 200)              # px; keep the long edge ≤ 2576
DELIBERATION = :medium                # :none = judge immediately; :low…:max = think first
INSTRUCTIONS = """
The image shows three short vertical segments in a row on a dark background, \
marking two adjoining intervals: leftmost to middle, and middle to rightmost.

Which interval looks longer, the left one or the right one? Judge by how the \
image looks, not by counting pixels.

Answer with one word: "left" or "right". Choose one even if they look equal. \
Do not explain.
"""

# ═════════════════════════════════════════════════════════════

startswith(OBSERVER, "simulated") && error("The simulated observer has its own script.")

stim_par = MarkerLayout(StimConfig = "d r t", StimMirror = MIRRORED,
                              Ref = REFERENCE, DistrN = 0, Anchor = :center)
ex_par = ExperimentParameters("OK_AI_Plain", :Diff, LEVELS, REPEATS)
session = SessionContext(replace(OBSERVER, r"[/:]" => "_"), ex_par, stim_par,
                         ConstantStimuli();
                         tags = ["condition:plain",
                                 MIRRORED ? "layout:mirrored" : "layout:standard"])

task = ObserverTask(INSTRUCTIONS, ("left", "right"), MIRRORED ? "left" : "right")
source = ModelObserverSource(model_observer(OBSERVER; deliberation = DELIBERATION), task;
                             max_attempts = 3, on_failure = :invalidate)

run_observer_experiment!(session, source, OffscreenVisualEngine(CANVAS...); report = :trials)

print_observer_summary(session, source)
fit = print_psychometric_summary(session)
fit.converged && println("Bias: $(round(fit.alpha, digits = 2)) px = " *
                         "$(round(100 * fit.alpha / REFERENCE, digits = 2))% of the " *
                         "reference; an unbiased observer would put it at 0.")

# Proportion of "test interval longer" per level, with the fitted curve and its α
visualize_results(session; title = "Plain figure — $(OBSERVER)")
wait_for_enter()
