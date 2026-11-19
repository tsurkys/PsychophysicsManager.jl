# Auditory filled-time (temporal Oppel-Kundt) Constant Stimuli experiment.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie                          # the results plot
using CImGui, ImPlot, GLFW, ModernGL   # the operator dashboard
using PortAudio, SampledSignals        # the sound

include(joinpath(@__DIR__, "_temporal_oppel_kundt_setup.jl"))

participant_id = get(ARGS, 1, DEFAULT_PARTICIPANT_ID)
# 7 levels × 2 = 14 trials — enough for a listening test without fatiguing the ear
repeats = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 2
session = create_temporal_oppel_kundt_session(
    participant_id;
    repeats = repeats,
    extra_tags = ["dashboard-test"],
)

display_config = load_display_config()
display_config.title = "Temporal Oppel-Kundt Dashboard"
engine = initialize_engine(
    default_engine_type(session.stim_par),
    session.stim_par,
    display_config,
)

try
    dashboard = open_operator_dashboard(session)

    # Participant/progress lines come from the console reporter; what stays
    # here is experiment-specific: the stimulus summary, the level-safety
    # note, and the semantic meaning of the response keys.
    println("\n── Temporal Oppel-Kundt audio experiment ──")
    println("Reference: 1000 ms, first interval, six filler bursts")
    println("Signal: 1000 Hz, 30 ms, 3.4 ms ramps")
    println("Digital peak amplitude: $(session.stim_par.peak_amplitude) (not dB SPL)")
    println("1. Set the system output to the calibrated laboratory device.")
    println("2. Click Start Session and keep the dashboard window focused.")
    println("3. Left = first interval longer; Right = second interval longer.")
    println("4. Enter/Space = replay the same stimulus.")

    # This experiment phrases each answer in its own terms, so the built-in
    # reporter is dialed down to session-level lines and the per-trial line
    # stays custom (report = :session).
    run_when_started!(session, engine, dashboard; report = :session,
                      on_trial_end = s -> begin
        trial = s.history[end]
        answer = trial.response == 1 ? "second interval" : "first interval"
        println("  [Trial $(trial.trial_index)] " *
                "comparison=$(only(trial.indep_var_vals)) ms, response=$answer")
    end)

    if session.state == READY
        println("Dashboard closed before the session was started.")
    else
        print_adjustment_summary(session)
        wait_for_enter()

        visualize_results(session; title = "Temporal Oppel-Kundt Results")
        wait_for_enter()
    end
finally
    close_engine!(engine)
    GLMakie.closeall()
end
