include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager

filepath = isempty(ARGS) ? "" : resolve_example_path(ARGS[1])
participant_id = get(ARGS, 2, DEFAULT_PARTICIPANT_ID)

run_session_from_file(filepath; participant_id=participant_id)
