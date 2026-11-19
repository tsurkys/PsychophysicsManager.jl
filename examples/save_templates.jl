# Writes the example experiments into the templates directory (`[storage]
# templates_dir` of settings.toml, `templates` by default), where the operator
# dashboard offers them: the Oppel-Kundt adjustment, the two-interval contrast
# threshold and the auditory filled-time experiment. A template that is already
# there is kept.

include(joinpath(@__DIR__, "_example_setup.jl"))
include(joinpath(@__DIR__, "_ok_experiment_setup.jl"))
include(joinpath(@__DIR__, "_temporal_oppel_kundt_setup.jl"))

using PsychophysicsManager

oppel_kundt = create_ok_session()
oppel_kundt.engine_name = "GeometryVisualEngine"

contrast = SessionContext(
    ExperimentParameters("Contrast_Threshold_2IFC", [:contrast, :target_interval],
                         [exp10.(range(-2.0, 0.0; length = 21)), [1, 2]], 1),
    Gabor(cycles_per_px = 1 / 32, sigma_px = 16.0, size_px = 128,
                interval_ms = 200.0, isi_ms = 500.0, leading_blank_ms = 500.0),
    Staircase(2; trial_limit = 60))
set_fit_gamma!(contrast, 0.5)
contrast.engine_name = "GeometryVisualEngine"

audio = create_temporal_oppel_kundt_session(; repeats = 2)
audio.engine_name = "AudioStimulusEngine"

directory = resolve_templates_dir()
for (name, session) in ("Oppel-Kundt adjustment" => oppel_kundt,
                        "Contrast threshold 2IFC" => contrast,
                        "Temporal Oppel-Kundt" => audio)
    filename = name * ".json"
    if isfile(joinpath(directory, filename))
        println("Kept:  ", joinpath(directory, filename))
    else
        println("Saved: ", save_session_checkpoint(session, directory; filename))
    end
end
