# GLMakie extension: the visual stimulus engine and its window management.
# Loads automatically on `using GLMakie`. The operator dashboard is the Dear
# ImGui extension's (PsychophysicsManagerImGuiExt).
#
# This file is only the loader. The implementation is split by responsibility.
# Everything that can be computed without a window lives in the headless core,
# so what remains here is genuinely backend-bound:
#
#   windows.jl           monitors, window placement, the stimulus screen, the
#                        current-context check, the display backend
#   input.jl             key → response mapping
#   engine_geometry.jl   GeometryVisualEngine (buffer, window, timing) for the
#                        marker layouts and the two-interval Gabor
#
# All files share this single module; no submodules, so nothing needs
# qualifying between them.

module PsychophysicsManagerGLMakieExt

using PsychophysicsManager
using GLMakie
using GLMakie: ShaderAbstractions
using GLFW
import PsychophysicsManager: initialize_engine, present_stimulus,
                  display_info, set_response_timeout!, set_min_response_time!, close_all_windows, close_engine!,
                  preview_stimulus, reads_response_keys, present_message
using PsychophysicsManager: AbstractStimulusEngine, MarkerLayout, Gabor, validate_gabor,
                 DisplayConfig, render_stimulus!, PresentationResult,
                 await_channel_response, await_message_key, offer_response!, select_monitor_index,
                 ParticipantMessage

include("windows.jl")
include("input.jl")
include("engine_geometry.jl")

function __init__()
    PsychophysicsManager.register_engine_type!(GeometryVisualEngine)
    PsychophysicsManager.ACTIVE_DISPLAY_BACKEND[] = GLMakieDisplayBackend()
end

end # module
