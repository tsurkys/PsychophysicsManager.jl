# The dashboard window: one GLFW window drawn by Dear ImGui, its views docked in
# it as tabs or dragged out into windows of their own.

# A buffer swap that waits for the display blocks the main thread, which the
# GLMakie stimulus window's `sleep`-timed intervals share; the frame rate is capped
# with a sleep instead. The cap also bounds how late a
# response key is stamped: keys are read once per frame, right after the events
# are polled.
const FRAMES_PER_SECOND = 30

# Bundled with CImGui, so the same on every system, and it draws every letter of
# the interface languages and the arrows of the key guide
const FONT_FILE = "Recursive Sans Linear-Regular.ttf"
const FONT_SIZE = 16

# Where Dear ImGui keeps the operator's arrangement of the views, the same for every
# working directory. The string must outlive the context that points at it.
const LAYOUT_FILE = Ref("")

# Raised when the views or their default arrangement change: a layout saved for other
# views would leave a new one floating, so the dashboard starts from the default again
const LAYOUT_VERSION = 3

# One window per process: Dear ImGui's backend keeps a single main window
const OPEN_DASHBOARD = Ref{Any}(nothing)

"""
    DashboardWindow

An open operator dashboard. `isopen(dashboard)` tells whether its window is still
open, `close(dashboard)` closes it, and `wait(dashboard)` returns once it has been
closed. Its controller is `dashboard.controller`.
"""
mutable struct DashboardWindow
    controller::DashboardController
    channel::Channel{Tuple{Int, Float64}}
    task::Union{Nothing, Task}
    close_requested::Bool
    frames::Int
    scale::Float32
    build_layout::Bool
    # Reread from the session when a session event marks the view out of date
    stale::Bool
    series::DashboardPlotSeries
    headers::Vector{String}
    rows::Vector{DashboardTrialRow}
    key_guide::Vector{Pair{String, String}}
    scroll_to_end::Bool
    # Operator input that lives between frames
    typing::Bool
    # A point right-clicked, or :design for the plot itself
    menu_target::Union{Nothing, AggregatePoint, DashboardTrialPoint, Symbol}
    # Set by the right-click, for the one frame that opens the menu
    menu_requested::Bool
    plot_options::PlotOptions
    plot_options_stale::Bool
    show_earlier::Ref{Bool}
    session_cache::SessionCache
    data_plot::DashboardDataPlot
    data_rows::Vector{DataViewRow}
    live_rows::Vector{DataViewRow}
    earlier_line::Union{Nothing, DashboardPlotLine}
    data_view_key::Any
    earlier_key::Any
    entries_version::Int
    show_control::Ref{Bool}
    show_plot::Ref{Bool}
    show_trials::Ref{Bool}
    show_messages::Ref{Bool}
    messages_shown::Int
    show_not_counted::Ref{Bool}
    participant_buffer::Vector{UInt8}
    comment_buffer::Vector{UInt8}
    # The Start view: its lists are read from disk only when `controller.lists_stale`
    show_browse::Ref{Bool}
    show_parameters::Ref{Bool}
    templates::Vector{DashboardEntryRow}
    entries::Vector{LibraryEntry}
    plans::Vector{DashboardPlanRow}
    plan_runs::Vector{DashboardRunRow}   # of the plan chosen
    filters::DashboardFilters
    filter_tags_buffer::Vector{UInt8}
    filter_text_buffer::Vector{UInt8}
    filter_from_buffer::Vector{UInt8}
    filter_to_buffer::Vector{UInt8}
    filter_parameter_buffer::Vector{UInt8}
    template_buffer::Vector{UInt8}
    last_state::Union{Nothing, SessionState}
    discard_path::Union{Nothing, String}   # a file awaiting the operator's confirmation
    pending_choice::Union{Nothing, Function}   # a Browse choice awaiting it (`choose_in_browse!`)
    # The Parameters view's edit fields, by the key of their line
    edit_buffers::Dict{String, Vector{UInt8}}
    refused_edits::Set{String}
    editing_key::Union{Nothing, String}
    edit_session::Union{Nothing, Base.UUID}
    edit_stimulus::Union{Nothing, String}
    edit_ticked::Union{Nothing, Vector{String}}
    typed_previews::Set{String}   # preview values the operator typed, kept as typed
    # The control Enter or Space presses, and since when (`press_control_on_key!`)
    key_control::Union{Nothing, Symbol}
    key_control_since::Float64
    # Save as Dataset popup state
    dataset_buffer::Vector{UInt8}
    save_dataset_popup::Bool
    save_dataset_error::Union{Nothing, String}
    # A session that starts brings its file forward on the Sessions tab
    show_sessions::Bool
    # The Settings view: its sections, read from the files when it opens and after a
    # change, the files a section no file defines may go to and the one chosen for
    # each, its edit fields, and the outcome of the last change
    show_settings::Ref{Bool}
    settings_open::Bool
    settings_stale::Bool
    settings::Vector{SettingsSectionRows}
    settings_targets::Vector{String}
    settings_target::Dict{String, String}
    setting_buffers::Dict{String, Vector{UInt8}}
    refused_settings::Set{String}
    editing_setting::Union{Nothing, String}
    settings_outcome::Union{Nothing, Tuple{Bool, String}}
    settings_unread::Union{Nothing, String}
    # The control channel for scripts and AI agents, while the settings turn it on
    control::Union{Nothing, ControlChannel}
    source::Union{Nothing, ChannelResponseSource}
    # Single-screen mode: whether the dashboard window is currently yielded (hidden,
    # polling-only, no input) to the stimulus window, and when a RUNNING session last
    # left a trial/message so consecutive trials do not flash the dashboard between them
    single_screen_yielded::Bool
    single_screen_release_at::Union{Nothing, Float64}
end

function DashboardWindow(controller::DashboardController)
    controller.lists_stale = true
    opts = settings_plot_options()
    return DashboardWindow(
        controller, Channel{Tuple{Int, Float64}}(1), nothing, false, 0, 1.0f0, false,
        true, dashboard_plot_series(nothing, opts), String[], DashboardTrialRow[],
        Pair{String, String}[], false, false, nothing, false,
        opts, false, Ref(false), SessionCache(), DashboardDataPlot(),
        DataViewRow[], DataViewRow[], nothing, nothing, nothing, 0,
        Ref(true), Ref(true), Ref(true), Ref(true), 0, Ref(false),
        text_buffer(DEFAULT_PARTICIPANT_ID), text_buffer(""),
        Ref(controller.owns_engine), Ref(true), DashboardEntryRow[], LibraryEntry[],
        DashboardPlanRow[], DashboardRunRow[], DashboardFilters(),
        text_buffer(""), text_buffer(""), text_buffer(""), text_buffer(""), text_buffer(""),
        text_buffer(""), nothing, nothing, nothing,
        Dict{String, Vector{UInt8}}(), Set{String}(), nothing, nothing, nothing, nothing,
        Set{String}(), nothing, 0.0,
        text_buffer(""), false, nothing, false,
        Ref(false), false, true, SettingsSectionRows[], String[], Dict{String, String}(),
        Dict{String, Vector{UInt8}}(), Set{String}(), nothing, nothing, nothing, nothing, nothing,
        false, nothing)
end

Base.isopen(dashboard::DashboardWindow) =
    dashboard.task !== nothing && !istaskdone(dashboard.task)
Base.close(dashboard::DashboardWindow) = (dashboard.close_requested = true; nothing)

# The operator's close — the window's button or the menu — which asks first while a
# session's loop runs (`close_dashboard!`); `close` closes without asking
request_close!(dashboard::DashboardWindow) =
    close_dashboard!(() -> close(dashboard), dashboard.controller)
Base.wait(dashboard::DashboardWindow) = (dashboard.task === nothing || wait(dashboard.task); nothing)

"""
    open_operator_dashboard(session::SessionContext; update_policy = :continuous, presentation_mode = nothing)

Opens the operator dashboard on a session the calling script has already set up,
and returns at once with the window, which keeps running beside the script. The
script keeps the engine and the trial loop: Start only moves the session into
`RUNNING`, and [`run_when_started!`](@ref) runs the loop from there.

The window shows the session's state and progress, the controls of the session
(Start, Pause, Resume, Undo, Stop, Discard), a live plot of the results with every
single trial beside the averages, and the table of trials; right-clicking a point of
the plot or a row of the table marks a trial an outlier or presents it again. Its keyboard is the response source of
render-only engines (the audio stimulus) while it has focus and no text field is
being typed in.

`update_policy` decides which session events redraw the plot and the table:
`:continuous` every one, `:between_trials` none while a trial is under way,
`:minimal` only state changes and the operator's corrections. It can be changed
from the View menu.

`presentation_mode` (`:dual_screen` or `:single_screen`, defaulting to `[display]
presentation_mode` in `settings.toml`, `:dual_screen` when unset) controls whether
the dashboard yields focus and skips redraws during each trial for single-monitor setups.

With `[control] enabled = true` in the settings, scripts and AI agents on this machine
work with the dashboard through its control channel while it is open
(`docs/CONTROL_CHANNEL.md`).

Returns the dashboard: `isopen(dashboard)` tells whether its window is still open,
`close(dashboard)` closes it and `wait(dashboard)` waits until it is closed. A window
still open when Julia exits is closed first.
"""
open_operator_dashboard(session::SessionContext; update_policy::Symbol = :continuous,
                        presentation_mode::Union{Nothing, Symbol} = nothing) =
    open_operator_dashboard(DashboardController(session; update_policy, presentation_mode))

"""
    open_operator_dashboard(; update_policy = :continuous, presentation_mode = nothing)

Opens the operator dashboard with no session. A saved session is loaded from the
window as a fresh replication for the participant entered there, and runs from the
window: the dashboard restores the session's engine, runs the trial loop in a task
of its own, and closes the engine when the session ends.
A scenario plan in the templates directory runs from the window too, one run after
another, each for the participant the plan names ([`choose_scenario!`](@ref)).
"""
open_operator_dashboard(; update_policy::Symbol = :continuous,
                        presentation_mode::Union{Nothing, Symbol} = nothing) =
    open_operator_dashboard(DashboardController(; update_policy, presentation_mode))

function open_operator_dashboard(controller::DashboardController)
    previous = OPEN_DASHBOARD[]
    previous !== nothing && isopen(previous) && throw(ArgumentError(
        "An operator dashboard is already open in this process; close it first."))

    dashboard = DashboardWindow(controller)
    source = ChannelResponseSource(dashboard.channel)
    dashboard.source = source
    install_response_source!(controller, source)
    # A session event only marks the view out of date: the frame rereads the
    # session, and nothing outside the frame touches what it draws
    controller.on_update = () -> (dashboard.stale = true; nothing)
    controller.session === nothing || bind_session!(controller, controller.session)

    ig.set_backend(:GlfwOpenGL3)
    context = ig.CreateContext()
    plot_context = ImPlot.CreateContext()
    dashboard.build_layout = configure_context!()
    OPEN_DASHBOARD[] = dashboard
    # Its connections are served in tasks beside the window's, on the same thread
    dashboard.control = start_control_channel_from_settings(controller)
    unread = unread_settings_text()
    unread === nothing || set_message!(controller, unread)

    name_window_class()
    dashboard.task = ig.render(context;
                               window_title = ui_label(:dashboard_title),
                               window_size = initial_window_size(),
                               vsync = false, fps_limit = FRAMES_PER_SECOND,
                               wait = false,
                               on_exit = () -> window_closed!(dashboard, plot_context)) do
        draw_frame!(dashboard)
    end
    return dashboard
end

# Docking, the font, the colours and where the layout is kept. Returns whether the
# views still have to be arranged, which they do until a layout has been saved.
function configure_context!()
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.lib.ImGuiConfigFlags_DockingEnable |
                     ig.lib.ImGuiConfigFlags_ViewportsEnable
    LAYOUT_FILE[] = joinpath(first(DEPOT_PATH), "scratchspaces",
                             string(Base.PkgId(PsychophysicsManager).uuid),
                             "dashboard_layout-$LAYOUT_VERSION.ini")
    mkpath(dirname(LAYOUT_FILE[]))
    io.IniFilename = pointer(LAYOUT_FILE[])
    ig.AddFontFromFileTTF(unsafe_load(io.Fonts), joinpath(pkgdir(ig), "fonts", FONT_FILE),
                          FONT_SIZE)
    apply_style!()
    return !isfile(LAYOUT_FILE[])
end

# Window coordinates are pixels on Windows and X11 and points on macOS, where the
# system scales the window itself
function initial_window_size()
    scale = Sys.isapple() ? 1.0 : first(GLFW.GetMonitorContentScale(GLFW.GetPrimaryMonitor()))
    return round.(Int, (1280, 800) .* scale)
end

function window_closed!(dashboard::DashboardWindow, plot_context)
    stop_control_channel!(dashboard.control)
    dashboard.control = nothing
    close_controller!(dashboard.controller)
    ImPlot.DestroyContext(plot_context)
    OPEN_DASHBOARD[] === dashboard && (OPEN_DASHBOARD[] = nothing)
    return nothing
end

# GLFW.jl terminates the library in an exit hook of its own; one registered later
# runs earlier, so this one ends a window still open while its library is alive
# (a script that returns beside an open dashboard would otherwise log a failed loop)
function close_dashboard_at_exit()
    dashboard = OPEN_DASHBOARD[]
    dashboard === nothing && return nothing
    close(dashboard)
    timedwait(() -> !isopen(dashboard), 5.0)
    return nothing
end

# Brief delay before showing the dashboard again while a session is still RUNNING
# between trials: prevents a 1-frame flash between consecutive trials of `run_experiment!`
# while restoring controls immediately on any state change (PAUSED, ABORTED, FINISHED, READY).
const SINGLE_SCREEN_SHOW_DELAY_S = 0.1

function focus_glfw_window!(window::GLFW.Window)
    window.handle == C_NULL && return nothing
    try
        GLFW.GetWindowAttrib(window, GLFW.ICONIFIED) != 0 && GLFW.RestoreWindow(window)
        ccall((:glfwFocusWindow, GLFW.libglfw), Cvoid, (Ptr{Cvoid},), window.handle)
    catch err
        # Native Wayland forbids focusing a window without user interaction
        @warn "Could not focus dashboard window" exception = err
    end
    return nothing
end

# Single-screen window transitions in one place: hides the dashboard and focuses the
# stimulus window during a trial (or stimulus-side message), and restores the dashboard
# between trials or on a state change. Returns whether this frame must yield (poll only).
function apply_presentation_mode!(dashboard::DashboardWindow, window::GLFW.Window)
    controller = dashboard.controller
    pres = dashboard_presentation_state(controller; source = dashboard.source)
    if pres.stimulus_focused
        dashboard.single_screen_release_at = nothing
        dashboard.typing = false
        if !dashboard.single_screen_yielded
            dashboard.single_screen_yielded = true
            GLFW.HideWindow(window)
            Base.invokelatest(focus_stimulus_window!)
        end
        return true
    end

    if dashboard.single_screen_yielded
        session = controller.session
        if session !== nothing && session.state == RUNNING
            now = time()
            if dashboard.single_screen_release_at === nothing
                dashboard.single_screen_release_at = now
                return true
            elseif now - dashboard.single_screen_release_at < SINGLE_SCREEN_SHOW_DELAY_S
                return true
            end
        end
        dashboard.single_screen_yielded = false
        dashboard.single_screen_release_at = nothing
        GLFW.ShowWindow(window)
        focus_glfw_window!(window)
        dashboard.stale = true
    end
    return false
end

function draw_frame!(dashboard::DashboardWindow)
    dashboard.frames += 1
    dashboard.frames == 1 && (place_on_monitor!(); set_window_icon!(); scale_to_display!(dashboard))
    dashboard.close_requested && return :imgui_exit_loop
    # The window's close button sets this flag before the frame; the loop exits on it
    # after the frame, unless the frame clears it. The current context is not asked: a
    # stimulus window made its own current between frames, or none once it closed.
    window = ig.current_window()
    if GLFW.WindowShouldClose(window)
        GLFW.SetWindowShouldClose(window, false)
        request_close!(dashboard)
    end

    apply_presentation_mode!(dashboard, window) && return nothing

    forward_response_keys!(dashboard)
    ig.IsKeyPressed(ig.lib.ImGuiKey_F5, false) && refresh!(dashboard)
    if dashboard.plot_options_stale
        dashboard.plot_options = settings_plot_options()
        dashboard.plot_options_stale = false
        dashboard.stale = true
    end
    dashboard.stale && reread_session!(dashboard)

    draw_menu_bar!(dashboard)
    dock_views!(dashboard)
    draw_control_view!(dashboard)
    draw_parameters_view!(dashboard)
    draw_plot_view!(dashboard)
    # Of two views sharing a dock, the one drawn last is the tab shown first
    draw_settings_view!(dashboard)
    draw_messages_view!(dashboard)
    draw_trials_view!(dashboard)
    draw_browse_view!(dashboard)
    draw_discard_confirmation!(dashboard)
    draw_choice_confirmation!(dashboard)
    draw_save_dataset_popup!(dashboard)
    undo_on_key!(dashboard)
    press_control_on_key!(dashboard)
    follow_session_start!(dashboard)
    return nothing
end

# Refresh rereads the session, the lists and the settings from the disk
refresh!(dashboard::DashboardWindow) =
    (dashboard.stale = dashboard.controller.lists_stale = dashboard.settings_stale =
     dashboard.plot_options_stale = true; nothing)

# When a session starts running, its trials come to the front of the Browse view, and
# its file joins the previous sessions, built from the session rather than read from
# the disk during the run
function follow_session_start!(dashboard::DashboardWindow)
    session = dashboard.controller.session
    state = session === nothing ? nothing : session.state
    if state == RUNNING && dashboard.last_state != RUNNING
        dashboard.show_trials[] && ig.SetWindowFocus(view_title(:trials))
        path = session.save_path
        if path !== nothing && !any(entry -> entry.path == path, dashboard.entries)
            push!(dashboard.entries, session_library_entry(session))
            dashboard.entries_version += 1
        end
        dashboard.show_sessions = true
    end
    dashboard.last_state = state
    return nothing
end

# Ctrl+Z takes back the last answered trial, as Session › Undo Last Trial does, unless
# a text field has the keyboard: there it undoes the typing
function undo_on_key!(dashboard::DashboardWindow)
    io = ig.GetIO()
    (dashboard.typing || !unsafe_load(io.KeyCtrl)) && return nothing
    ig.IsKeyPressed(ig.lib.ImGuiKey_Z, false) && undo_dashboard_trial!(dashboard.controller)
    return nothing
end

# Enter and Space, the keys that confirm an answer during a trial, press between
# sessions the control `keyboard_control` names — Start, or Prepare Next Run of a
# scenario — so a participant at this keyboard can go on by themselves. A press that
# comes within KEY_CONTROL_DELAY_S of the control becoming available is not taken: it
# may be the answer to the session's last trial, pressed twice.
const CONTROL_KEYS = (ig.lib.ImGuiKey_Enter, ig.lib.ImGuiKey_KeypadEnter, ig.lib.ImGuiKey_Space)
const KEY_CONTROL_DELAY_S = 1.0

function press_control_on_key!(dashboard::DashboardWindow)
    control = keyboard_control(dashboard.controller)
    if control !== dashboard.key_control
        dashboard.key_control = control
        dashboard.key_control_since = time()
    end
    (control === nothing || dashboard.typing ||
     time() - dashboard.key_control_since < KEY_CONTROL_DELAY_S ||
     ig.IsPopupOpen("", ig.lib.ImGuiPopupFlags_AnyPopupId | ig.lib.ImGuiPopupFlags_AnyPopupLevel)) &&
        return nothing
    any(key -> ig.IsKeyPressed(key, false), CONTROL_KEYS) &&
        last(CONTROL_BUTTONS[control])(dashboard.controller)
    return nothing
end

# On the monitor the settings name (`[display] dashboard_screen_idx` or
# `dashboard_screen_name`); with neither, where the window system put it
function place_on_monitor!()
    monitors = GLFW.GetMonitors()
    index = dashboard_monitor_index(String[GLFW.GetMonitorName(m) for m in monitors],
                                    load_display_config())
    index === nothing && return nothing
    position = GLFW.GetMonitorPos(monitors[index])
    try
        GLFW.SetWindowPos(ig.current_window(), position.x + 40, position.y + 40)
    catch err
        # Native Wayland lets no program place its windows
        @warn "The dashboard window could not be placed on monitor $index" exception = err
    end
    return nothing
end

# GLFW would name the window's class after its title, which follows the interface
# language. The names hold for the next window GLFW makes, the dashboard's, and are
# reset once it exists (`set_window_icon!`), so a stimulus window keeps its own.
function name_window_class()
    GLFW.WindowHintString(GLFW.X11_CLASS_NAME, DESKTOP_WINDOW_CLASS)
    GLFW.WindowHintString(GLFW.X11_INSTANCE_NAME, DESKTOP_APP_ID)
    GLFW.WindowHintString(GLFW.WAYLAND_APP_ID, DESKTOP_APP_ID)
    return nothing
end

# The icon the window carries is shown by X11 desktops such as KDE and by Windows;
# GLFW.jl leaves it out on macOS and native Wayland. GNOME shows only the icon of the
# desktop entry `install_desktop_icon()` writes.
function set_window_icon!()
    GLFW.DefaultWindowHints()
    GLFW.SetWindowIcon(ig.current_window(), window_icon_images())
    return nothing
end

# Dear ImGui does not follow the desktop's scale factor. Where the framebuffer is
# already denser than the window (macOS) it draws sharp at its own size; elsewhere
# the sizes and the font are scaled by the window's content scale.
function scale_to_display!(dashboard::DashboardWindow)
    window = ig.current_window()
    content = first(GLFW.GetWindowContentScale(window))
    density = first(GLFW.GetFramebufferSize(window)) / max(first(GLFW.GetWindowSize(window)), 1)
    dashboard.scale = Float32(max(content / density, 1.0))
    style = ig.GetStyle()
    ig.ScaleAllSizes(style, dashboard.scale)
    style.FontScaleDpi = dashboard.scale
    return nothing
end

function reread_session!(dashboard::DashboardWindow)
    session = dashboard.controller.session
    dashboard.series = dashboard_plot_series(session, dashboard.plot_options)
    dashboard.live_rows = data_view_rows(session)
    rows = dashboard_trial_rows(session)
    dashboard.scroll_to_end = length(rows) > length(dashboard.rows)
    dashboard.rows = rows
    dashboard.headers = dashboard_trial_headers(session)
    dashboard.key_guide = response_key_guide(session)
    # A session that is not running may have been saved, finished or set aside: the
    # Start view's lists read the disk again, which is not done during a run
    session === nothing || session.state == RUNNING || (dashboard.controller.lists_stale = true)
    dashboard.stale = false
    return nothing
end

# ── Response keys ────────────────────────────────────────────────────────────

const RESPONSE_KEYS = ((ig.lib.ImGuiKey_LeftArrow, -1), (ig.lib.ImGuiKey_RightArrow, 1),
                       (ig.lib.ImGuiKey_Enter, 0), (ig.lib.ImGuiKey_KeypadEnter, 0),
                       (ig.lib.ImGuiKey_Space, 0))

"""
    forward_response_keys!(dashboard)

Passes the response keys pressed since the last frame to the session as answers.
Read in the frame, right after the events were polled, they carry the poll's time
as a key callback would, and they are caught in every window of the dashboard, a
view dragged out of it included. Nothing is passed while a text field has the
keyboard, nor while no trial is under way unless the dashboard is presenting a
message: a key pressed between trials would otherwise wait in the channel and
answer the next trial before it was presented.
"""
function forward_response_keys!(dashboard::DashboardWindow)
    dashboard.typing = unsafe_load(ig.GetIO().WantTextInput)
    session = dashboard.controller.session
    (dashboard.typing || session === nothing) && return nothing
    source_message = dashboard.source !== nothing && shown_message(dashboard.source) !== nothing
    (session.trial_under_way || source_message) || return nothing
    for (key, response) in RESPONSE_KEYS
        ig.IsKeyPressed(key, true) && offer_response!(dashboard.channel, response)
    end
    return nothing
end

# ── Layout and menus ─────────────────────────────────────────────────────────

# Window names carry a fixed ID after ###, so a saved layout survives a change of
# interface language
view_title(view::Symbol) = ui_label(Symbol("view_", view)) * "###" * string(view)

function split_node(node, direction, ratio::Float32)
    first, second = Ref{ig.lib.ImGuiID}(0), Ref{ig.lib.ImGuiID}(0)
    ig.DockBuilderSplitNode(node, direction, ratio, first, second)
    return first[], second[]
end

function dock_views!(dashboard::DashboardWindow)
    dockspace = ig.GetID("PsychophysicsManagerDockSpace")
    if dashboard.build_layout
        # On the left the controls above the parameters; on the right the live plot
        # above Browse, the trial table and the messages
        ig.DockBuilderRemoveNode(dockspace)
        ig.DockBuilderAddNode(dockspace, Int(ig.lib.ImGuiDockNodeFlags_DockSpace))
        ig.DockBuilderSetNodeSize(dockspace, unsafe_load(ig.GetMainViewport()).WorkSize)
        left, right = split_node(dockspace, ig.lib.ImGuiDir_Left, 0.32f0)
        control, parameters = split_node(left, ig.lib.ImGuiDir_Up, 0.34f0)
        plot, bottom = split_node(right, ig.lib.ImGuiDir_Up, 0.58f0)
        ig.DockBuilderDockWindow(view_title(:control), control)
        ig.DockBuilderDockWindow(view_title(:parameters), parameters)
        ig.DockBuilderDockWindow(view_title(:plot), plot)
        ig.DockBuilderDockWindow(view_title(:browse), bottom)
        ig.DockBuilderDockWindow(view_title(:trials), bottom)
        ig.DockBuilderDockWindow(view_title(:messages), bottom)
        # Hidden until the View menu shows it, and then a tab beside them
        ig.DockBuilderDockWindow(view_title(:settings), bottom)
        ig.DockBuilderFinish(dockspace)
        dashboard.show_control[] = dashboard.show_parameters[] = dashboard.show_plot[] =
            dashboard.show_trials[] = dashboard.show_messages[] = true
        # Only a dashboard that runs its own sessions chooses them
        dashboard.show_browse[] = dashboard.controller.owns_engine
        dashboard.build_layout = false
    end
    # A view alone in its place shows no tab: its content names it
    ig.DockSpaceOverViewport(dockspace, ig.GetMainViewport(),
                             ig.lib.ImGuiDockNodeFlags_AutoHideTabBar)
    return nothing
end

# The logo at the menu bar's left end, drawn from the shapes of `assets/icon.svg` (a
# 64-unit square) on the bar, whose colour is the logo's tile: 46 units span the bar's
# height, centred on the curve's middle, with a quarter of the height free on the left.
function draw_logo()
    height = ig.GetFrameHeight()
    k = height / 46f0
    margin = height / 4
    origin = ig.GetCursorScreenPos()
    at(x, y) = (origin.x + margin + (x - 7f0) * k, origin.y + (y - 9f0) * k)
    list = ig.GetWindowDrawList()
    curve = ig.ColorConvertFloat4ToU32(ACCENT)
    thickness = 4.5f0 * k
    # One path, so the straight ends join the curve without a seam; the round caps
    # are circles, which a path stroke does not draw
    ig.PathLineTo(list, at(10, 47))
    ig.PathLineTo(list, at(15, 47))
    ig.PathBezierCubicCurveTo(list, at(30, 47), at(34, 17), at(49, 17))
    ig.PathLineTo(list, at(54, 17))
    ig.PathStroke(list, curve, thickness)
    ig.AddCircleFilled(list, at(10, 47), thickness / 2, curve)
    ig.AddCircleFilled(list, at(54, 17), thickness / 2, curve)
    ring = ig.ColorConvertFloat4ToU32(LOGO_TILE)
    for ((x, y), color) in zip(((22.85f0, 43.9f0), (32f0, 32f0), (41.15f0, 20.1f0)), LOGO_POINTS)
        ig.AddCircleFilled(list, at(x, y), 5.8f0 * k, ring)
        ig.AddCircleFilled(list, at(x, y), 3.8f0 * k, ig.ColorConvertFloat4ToU32(color))
    end
    ig.Dummy(ig.ImVec2(margin + 50f0 * k, height))
    return nothing
end

function draw_menu_bar!(dashboard::DashboardWindow)
    ig.BeginMainMenuBar() || return nothing
    draw_logo()
    controller = dashboard.controller
    if ig.BeginMenu(ui_label(:menu_session))
        available = action_state(controller)
        ig.MenuItem(ui_label(:undo_last_trial), "Ctrl+Z", false, available.can_undo) &&
            undo_dashboard_trial!(controller)
        tooltip(:tip_undo)
        if ig.MenuItem(ui_label(:discard_session), C_NULL, false,
                       available.can_discard && controller.session.save_path !== nothing)
            dashboard.discard_path = controller.session.save_path
        end
        tooltip(:tip_discard)
        ig.Separator()
        ig.MenuItem(ui_label(:close_dashboard)) && request_close!(dashboard)
        ig.EndMenu()
    end
    if ig.BeginMenu(ui_label(:menu_view))
        ig.MenuItem(ui_label(:view_control), C_NULL, dashboard.show_control)
        ig.MenuItem(ui_label(:view_parameters), C_NULL, dashboard.show_parameters)
        ig.MenuItem(ui_label(:view_plot), C_NULL, dashboard.show_plot)
        controller.owns_engine &&
            ig.MenuItem(ui_label(:view_browse), C_NULL, dashboard.show_browse)
        ig.MenuItem(ui_label(:view_trials), C_NULL, dashboard.show_trials)
        ig.MenuItem(ui_label(:view_messages), C_NULL, dashboard.show_messages)
        ig.MenuItem(ui_label(:view_settings), C_NULL, dashboard.show_settings)
        tooltip(:tip_view_settings)
        ig.Separator()
        if ig.BeginMenu(ui_label(:menu_updates))
            for policy in UPDATE_POLICIES
                ig.MenuItem(update_policy_label(policy), C_NULL,
                            policy === controller.update_policy) &&
                    set_update_policy!(controller, policy)
            end
            ig.EndMenu()
        end
        ig.MenuItem(ui_label(:refresh), "F5") && refresh!(dashboard)
        tooltip(:tip_refresh)
        ig.MenuItem(ui_label(:reset_layout)) && (dashboard.build_layout = true)
        ig.EndMenu()
    end
    ig.EndMainMenuBar()
    return nothing
end
