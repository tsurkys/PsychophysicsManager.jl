# The chain check for `run_ok_ai_observer.jl`: the same design answered by the
# simulated observer, which has a known threshold and costs nothing.
#
#   julia --project=examples examples/run_ok_simulated_observer.jl
#
# The fit has to recover BIAS_PER_DISTRACTOR × DISTRACTORS. Run it before
# spending requests; keep the block below equal to the measuring script's. The
# simulated observer answers from the stimulus description rather than from the
# rendered pixels, so it checks the chain, not perception (docs/AI_OBSERVER.md).

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager

# ═══════════════════ EXPERIMENT PARAMETERS ═══════════════════

REPEATS     = 10                      # presentations per level
REFERENCE   = 240.0                   # px, the interval held constant
DISTRACTORS = 4                       # markers filling the reference interval
LEVELS      = -20.0:10.0:60.0         # px added to the test interval (Diff)
MIRRORED    = false                   # true = test interval on the left
CANVAS      = (900, 200)              # px; keep the long edge ≤ 2576

BIAS_PER_DISTRACTOR = 5.0             # px of illusion built in
NOISE_SD            = 12.0            # px of internal noise, which sets the slope

# ═════════════════════════════════════════════════════════════

backend = model_observer("simulated"; bias_per_distractor = BIAS_PER_DISTRACTOR,
                         noise_sd = NOISE_SD, positive_interval = 2)

stim_par = MarkerLayout(StimConfig = "d r t", StimMirror = MIRRORED,
                              Ref = REFERENCE, DistrN = DISTRACTORS, Anchor = :center)
ex_par = ExperimentParameters("OK_AI_Filled", :Diff, LEVELS, REPEATS)
session = SessionContext("simulated", ex_par, stim_par, ConstantStimuli();
                         tags = ["condition:filled",
                                 MIRRORED ? "layout:mirrored" : "layout:standard"])

# This observer reads the segment lengths, never the wording, so the package's
# default question stands in for the measuring script's instruction sheet
task = length_comparison_task(positive_option = MIRRORED ? "left" : "right")
source = ModelObserverSource(backend, task)

run_observer_experiment!(session, source, OffscreenVisualEngine(CANVAS...); report = :trials)

print_observer_summary(session, source)
fit = print_psychometric_summary(session)
fit.converged && println("PSE: $(round(fit.alpha, digits = 2)) px, against the " *
                         "$(BIAS_PER_DISTRACTOR * DISTRACTORS) px built in — a deviation " *
                         "of several px at this trial count is sampling noise.")
