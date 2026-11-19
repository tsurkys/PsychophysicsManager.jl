# Contrast detection threshold. A Gabor patch appears in one of two intervals,
# the participant names the interval, and a staircase lowers the contrast until
# the answers are right about 71 % of the time. The contrast is digital, not
# calibrated luminance contrast: read docs/STIMULI.md before reporting it.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie

# ── EXPERIMENT PARAMETERS ────────────────────────────────────────────────────

# Michelson contrast as a proportion, log-spaced as thresholds are; the
# staircase moves one step along this list at a time
CONTRASTS = exp10.(range(-2.0, 0.0; length = 21))
TRIALS = 60

STIMULUS = Gabor(
    cycles_per_px = 1 / 32,
    orientation_deg = 0.0,
    sigma_px = 16.0,
    size_px = 128,
    mean_luminance = 0.5,
    interval_ms = 200.0,
    isi_ms = 500.0,
    leading_blank_ms = 500.0,
)

INSTRUCTIONS = """
Two intervals follow each other, each framed by four small marks, and one of \
them holds a faint striped patch. Press ← if it was in the first interval and → \
if it was in the second. Guess when you are not sure. Enter or Space shows the \
pair again."""
BREAK = "Take a short rest. Press any response key when you are ready to go on."
CLOSING = "Thank you, that is all."

# ── RUN ──────────────────────────────────────────────────────────────────────

design = ExperimentParameters("Contrast_Threshold_2IFC",
                              [:contrast, :target_interval], [CONTRASTS, [1, 2]], 1)
# Two correct answers step down, one wrong steps up.
# `Psi(pf = :weibull, trial_limit = TRIALS)` takes the same design.
session = SessionContext(get(ARGS, 1, DEFAULT_PARTICIPANT_ID), design, STIMULUS,
                         Staircase(2; trial_limit = TRIALS))
set_task!(session, ObserverTask(INSTRUCTIONS, ("first", "second"), "second"))
set_fit_gamma!(session, 0.5)   # with two intervals, guessing already scores half
# Shown in the stimulus window: the instructions first, a break every 20 trials, the
# closing text after the last
set_messages!(session; instructions = true, break_every = 20, break_text = BREAK,
              closing_text = CLOSING)

run_experiment!(session)

# Which interval held the target only balances the task: the threshold is per contrast
print_psychometric_summary(session; collapse = :target_interval)
visualize_results(session; title = "Contrast threshold (2IFC)", collapse = :target_interval)

wait_for_enter()
