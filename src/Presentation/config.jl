"""
    PRESENTATION_MODES

How the stimulus window and the operator dashboard share displays (`[display]
presentation_mode` in `settings.toml`):

- `:dual_screen` (default) — both windows stay active side by side;
- `:single_screen` — during a trial the stimulus window holds exclusive focus and
  input while the dashboard yields (hidden, polling-only), returning controls
  between trials or on a session state change.
"""
const PRESENTATION_MODES = (:dual_screen, :single_screen)

function check_presentation_mode(mode::Symbol)
    mode in PRESENTATION_MODES && return mode
    throw(ArgumentError(
        "Unknown presentation mode $(repr(mode)); the modes are " *
        join(repr.(PRESENTATION_MODES), ", ") * "."))
end

"""
    DisplayConfig

Hardware and window configuration for stimulus presentation. It describes the
*presentation environment* (which monitor, which window), never the stimulus
itself — stimulus parameters live in `src/Stimuli/`.

The values are loaded from the `[display]` section of a `settings.toml`
by `load_display_config` (`src/IO/settings.jl`).
"""
mutable struct DisplayConfig
    screen_idx::Int
    screen_name::String           # non-empty: pick the monitor whose name contains
                                  # this fragment (case-insensitive) — more robust
                                  # than an index, whose order the driver may change
    fullscreen::Bool
    window_size::Tuple{Int, Int}
    title::String
    # The operator dashboard's monitor, chosen the same way; with neither set the
    # window system places the dashboard
    dashboard_screen_idx::Union{Nothing, Int}
    dashboard_screen_name::String
    presentation_mode::Symbol

    function DisplayConfig(screen_idx::Integer, screen_name::AbstractString,
                           fullscreen::Bool, window_size::Tuple{Int, Int},
                           title::AbstractString,
                           dashboard_screen_idx::Union{Nothing, Int},
                           dashboard_screen_name::AbstractString,
                           presentation_mode::Symbol = :dual_screen)
        return new(Int(screen_idx), String(screen_name), fullscreen, window_size,
                   String(title), dashboard_screen_idx, String(dashboard_screen_name),
                   check_presentation_mode(presentation_mode))
    end
end

function DisplayConfig(; screen_idx=1, screen_name="", fullscreen=false,
                       window_size=(1200, 800), title="PsychophysicsManager Stimulus",
                       dashboard_screen_idx=nothing, dashboard_screen_name="",
                       presentation_mode::Symbol=:dual_screen)
    return DisplayConfig(screen_idx, screen_name, fullscreen, window_size, title,
                         dashboard_screen_idx, dashboard_screen_name, presentation_mode)
end

"""
    focus_stimulus_window!()

Raises and focuses the active stimulus window on the current display backend without
moving, recreating, or reinitializing it. No-op when headless or no visual window is
open; the visual-engine extension adds the backend method.
"""
focus_stimulus_window!() = focus_stimulus_window!(ACTIVE_DISPLAY_BACKEND[])
focus_stimulus_window!(::DisplayBackend) = nothing

"""
    select_monitor_index(monitor_names, screen_idx, screen_name) -> Int

Chooses which monitor to use from the configured index and name fragment. A
non-empty `screen_name` matched case-insensitively against a monitor name wins
over `screen_idx`, because the driver may reorder indices between sessions; an
unmatched fragment falls back to the index with a warning. The index is clamped
into range.

Pure function over the monitor names, so the selection rules are testable
without a display; the stimulus window and the dashboard both choose through it.
"""
function select_monitor_index(monitor_names::AbstractVector{<:AbstractString},
                              screen_idx::Integer, screen_name::AbstractString)
    target_idx = clamp(screen_idx, 1, length(monitor_names))
    isempty(screen_name) && return target_idx

    found = findfirst(name -> occursin(lowercase(screen_name), lowercase(name)),
                      monitor_names)
    if found === nothing
        @warn "No monitor name contains \"$screen_name\"; falling back to screen_idx=$target_idx"
        return target_idx
    end
    return found
end

"""
    dashboard_monitor_index(monitor_names, config::DisplayConfig) -> Union{Nothing, Int}

The monitor the operator dashboard is placed on, or `nothing` when the settings name
none and the window system places it.
"""
function dashboard_monitor_index(monitor_names::AbstractVector{<:AbstractString},
                                 config::DisplayConfig)
    config.dashboard_screen_idx === nothing && isempty(config.dashboard_screen_name) &&
        return nothing
    isempty(monitor_names) && return nothing
    return select_monitor_index(monitor_names, something(config.dashboard_screen_idx, 1),
                                config.dashboard_screen_name)
end
