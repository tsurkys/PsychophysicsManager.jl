# Headless model for the dashboard's Data view: multi-session grouping, pooling through
# in-memory AnalysisSets, session caching by path and mtime, the dimmed earlier-sessions
# line under a live plot, and the table of shown sessions below the plot.

"""
    DashboardPlotLine

One series or single-session curve drawn in the Data view: its legend `label`, the
aggregated `points`, plotted `x`/`y`/`n` values, non-negative error-bar extents
`err_lo` and `err_hi` below and above `y` (empty when `spread === :none`), optional
`smooth_y`, fitted logistic `curve_x`/`curve_y`, individual `trials` (empty when
`raw === false` or for dimmed reference lines), and whether the line is `dimmed`.
"""
Base.@kwdef struct DashboardPlotLine
    label::String = ""
    points::Vector{AggregatePoint} = AggregatePoint[]
    x::Vector{Float64} = Float64[]
    y::Vector{Float64} = Float64[]
    n::Vector{Int} = Int[]
    err_lo::Vector{Float64} = Float64[]
    err_hi::Vector{Float64} = Float64[]
    smooth_y::Vector{Float64} = Float64[]
    curve_x::Vector{Float64} = Float64[]
    curve_y::Vector{Float64} = Float64[]
    trials::Vector{DashboardTrialPoint} = DashboardTrialPoint[]
    dimmed::Bool = false
end

"""
    DashboardDataPlot

What the Data view draws for ticked sessions: one or more `panels` (each a vector of
[`DashboardPlotLine`](@ref)s), per-panel axis specs/limits/ticks (with the first panel's
repeated on the top-level fields), and a `note` explaining series differences, failed
loads, or sessions that could not be pooled.
"""
Base.@kwdef struct DashboardDataPlot
    spec::DashboardPlotSpec = dashboard_plot_spec(nothing)
    x_limits::Union{Nothing, Tuple{Float64, Float64}} = nothing
    y_limits::Union{Nothing, Tuple{Float64, Float64}} = nothing
    x_ticks::Vector{Float64} = Float64[]
    panels::Vector{Vector{DashboardPlotLine}} = Vector{DashboardPlotLine}[]
    panel_specs::Vector{DashboardPlotSpec} = DashboardPlotSpec[]
    panel_x_limits::Vector{Union{Nothing, Tuple{Float64, Float64}}} = Union{Nothing, Tuple{Float64, Float64}}[]
    panel_y_limits::Vector{Union{Nothing, Tuple{Float64, Float64}}} = Union{Nothing, Tuple{Float64, Float64}}[]
    panel_x_ticks::Vector{Vector{Float64}} = Vector{Float64}[]
    note::String = ""
end

"""
    DataViewRow

One row of the session table under the Data view's plot: file `path`, start `date`,
valid/planned `trials`, lifecycle `state`, the last operator `comment`, and whether the
row has a tick checkbox (`false` for the session in hand alone).
"""
Base.@kwdef struct DataViewRow
    path::String = ""
    date::String = ""
    trials::String = ""
    state::String = ""
    comment::String = ""
    tickable::Bool = true
end

# ── Plot options and mode ────────────────────────────────────────────────────

# Reads `[plot]` safely for the dashboard: an invalid hand-edited setting warns and
# falls back to defaults instead of stopping the window from opening.
function settings_plot_options(directory::AbstractString = ".")
    try
        return load_plot_options(directory)
    catch err
        err isa ArgumentError || rethrow()
        @warn "Using default [plot] options: $(err.msg)"
        return PlotOptions()
    end
end

"""
    set_dashboard_plot_option!(controller, key, value; directory = ".") -> Bool

Persists one `[plot]` option via [`set_plot_option!`](@ref). On an `ArgumentError`,
reports the refusal in `controller` and returns `false`.
"""
function set_dashboard_plot_option!(controller::DashboardController,
                                    key::Union{Symbol, AbstractString}, value;
                                    directory::AbstractString = ".")
    try
        set_plot_option!(key, value; directory)
        return true
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_setting_refused; error = err.msg))
        return false
    end
end

"""
    is_live_plot_mode(controller) -> Bool

Whether the Data view shows the live plot of the session in hand (with context menus)
rather than the ticked sessions: whenever a session's loop is running or nothing is
ticked.
"""
function is_live_plot_mode(controller::DashboardController)
    isempty(controller.ticked) && return true
    is_running(controller) && return true
    session = controller.session
    return !controller.owns_engine && session !== nothing &&
           session.state in (RUNNING, PAUSED)
end

# ── Session cache ────────────────────────────────────────────────────────────

struct CachedSession
    mtime::Float64
    size::Int64
    session::Union{Nothing, SessionContext}
    error::Union{Nothing, String}
end

"""
    SessionCache()

In-memory cache of loaded session files keyed by absolute path, modification time, and
file size so the Data view avoids reloading unchanged files.
"""
struct SessionCache
    entries::Dict{String, CachedSession}
end

SessionCache() = SessionCache(Dict{String, CachedSession}())

"""
    load_cached_session!(cache, path) -> (Union{Nothing, SessionContext}, Union{Nothing, String})

Loads `path` with `load_session` when absent from `cache` or modified on disk, returning
`(session, nothing)` on success or `(nothing, error_text)` on failure.
"""
function load_cached_session!(cache::SessionCache, path::AbstractString)
    key = abspath(String(path))
    st = try
        stat(key)
    catch err
        return (nothing, sprint(showerror, err))
    end
    mtime = Float64(st.mtime)
    size = Int64(st.size)
    cached = get(cache.entries, key, nothing)
    if cached !== nothing && cached.mtime == mtime && cached.size == size
        return (cached.session, cached.error)
    end
    try
        session = load_session(key)
        cache.entries[key] = CachedSession(mtime, size, session, nothing)
        return (session, nothing)
    catch err
        msg = err isa ArgumentError ? err.msg : sprint(showerror, err)
        cache.entries[key] = CachedSession(mtime, size, nothing, msg)
        return (nothing, msg)
    end
end

"""
    prune_session_cache!(cache, paths) -> cache

Drops cached entries whose paths are no longer present in `paths`.
"""
function prune_session_cache!(cache::SessionCache, paths::AbstractVector{<:AbstractString})
    keep = Set(abspath.(paths))
    for key in collect(keys(cache.entries))
        key in keep || delete!(cache.entries, key)
    end
    return cache
end

# ── Labels, notes, and per-group construction ────────────────────────────────

function session_line_label(session::SessionContext)
    date = started_text(session.start_time)
    return isempty(date) ? session.participant_id : "$date · $(session.participant_id)"
end

function session_short_name(session::SessionContext)
    session.save_path !== nothing && return splitext(basename(session.save_path))[1]
    return session_line_label(session)
end

function series_line_label(series::SessionSeries, vars,
                           multiple_groups::Bool, multiple_experiments::Bool)
    if !multiple_groups && length(series.entries) == 1
        entry = only(series.entries)
        date = started_text(entry.start_time)
        return isempty(date) ? series.participant : "$date · $(series.participant)"
    end
    parts = String[series.participant]
    if multiple_groups
        multiple_experiments && !isempty(series.experiment_name) &&
            push!(parts, series.experiment_name)
        vtext = series_variables_text(series, vars)
        isempty(vtext) || push!(parts, vtext)
    end
    return join(parts, " · ")
end

function series_difference_note(grouped::AbstractVector{SessionSeries})
    length(grouped) < 2 && return ""
    vars = session_variables(grouped)
    diffs = String[]
    length(unique(s.participant for s in grouped)) > 1 &&
        push!(diffs, ui_label(:data_diff_participant))
    length(unique(s.experiment_name for s in grouped)) > 1 &&
        push!(diffs, ui_label(:data_diff_experiment))
    for param in vars.parameters
        push!(diffs, string(param))
    end
    for tag_key in vars.tags
        push!(diffs, tag_key)
    end
    for fact in vars.other
        push!(diffs, ui_label(Symbol("fact_", fact)))
    end
    isempty(diffs) && return ""
    return ui_label(:data_note_series_differ; count = length(grouped),
                    differences = join(diffs, ", "))
end

function make_plot_line(data::SessionOrSet, label::AbstractString, options::PlotOptions;
                        dimmed::Bool = false)
    line_opts = dimmed ? PlotOptions(raw = false, mean = options.mean,
                                     spread = options.spread, smooth = options.smooth,
                                     fit = options.fit, converted = options.converted,
                                     split = options.split) : options
    g = compute_plot_group(data, line_opts)
    sessions = data isa AnalysisSet ? data.sessions : SessionContext[data]
    levels = group_design_levels(sessions; converted = options.converted)
    line = DashboardPlotLine(
        label = String(label),
        points = g.points,
        x = g.x,
        y = g.y,
        n = g.n,
        err_lo = g.err_lo,
        err_hi = g.err_hi,
        smooth_y = g.smooth_y,
        curve_x = g.curve_x,
        curve_y = g.curve_y,
        trials = g.trials,
        dimmed = dimmed,
    )
    return (line = line, spec = g.spec, x_limits = g.x_limits, y_limits = g.y_limits,
            x_ticks = g.x_ticks, levels = levels)
end

function build_panel_geometry(built_lines)
    isempty(built_lines) && return (spec = dashboard_plot_spec(nothing),
                                    x_limits = nothing, y_limits = nothing,
                                    x_ticks = Float64[])
    all_levels = Float64[]
    for item in built_lines
        if !isempty(item.levels)
            append!(all_levels, item.levels)
        elseif !isempty(item.line.x)
            append!(all_levels, item.line.x)
        end
    end
    sort!(unique!(all_levels))
    x_limits = axis_limits(all_levels)
    x_ticks = length(all_levels) <= MAX_LEVEL_TICKS ? all_levels : Float64[]
    y_limits = all(item -> item.y_limits == PROPORTION_LIMITS, built_lines) ?
               PROPORTION_LIMITS : nothing
    return (spec = first(built_lines).spec, x_limits = x_limits, y_limits = y_limits,
            x_ticks = x_ticks)
end

function build_data_plot(labeled_groups::AbstractVector{<:Pair{<:AbstractString, <:AbstractVector{SessionContext}}},
                         options::PlotOptions;
                         checks = COMBINING_CHECKS,
                         note::AbstractString = "")
    note_parts = String[]
    isempty(note) || push!(note_parts, String(note))

    if options.split === :pooled
        built_lines = Any[]
        refused_notes = String[]
        for (label, group_sessions) in labeled_groups
            isempty(group_sessions) && continue
            if length(group_sessions) == 1
                push!(built_lines, make_plot_line(only(group_sessions), label, options))
            else
                set = AnalysisSet(; checks)
                refused = Tuple{SessionContext, Symbol, Any}[]
                for session in group_sessions
                    outcome, differing = admit_session!(set, session)
                    outcome === :added || push!(refused, (session, outcome, differing))
                end
                if !isempty(set.sessions)
                    data = length(set.sessions) == 1 ? only(set.sessions) : set
                    push!(built_lines, make_plot_line(data, label, options))
                end
                for (session, outcome, differing) in refused
                    push!(built_lines,
                          make_plot_line(session, session_line_label(session), options))
                    push!(refused_notes,
                          "$(session_short_name(session)) ($(admission_reason_text(outcome, differing)))")
                end
            end
        end
        isempty(refused_notes) ||
            push!(note_parts, ui_label(:data_note_not_pooled; files = join(refused_notes, "; ")))
        full_note = join(note_parts, " · ")
        isempty(built_lines) && return DashboardDataPlot(note = full_note)

        geom = build_panel_geometry(built_lines)
        panel = DashboardPlotLine[item.line for item in built_lines]
        return DashboardDataPlot(
            spec = geom.spec,
            x_limits = geom.x_limits,
            y_limits = geom.y_limits,
            x_ticks = geom.x_ticks,
            panels = Vector{DashboardPlotLine}[panel],
            panel_specs = DashboardPlotSpec[geom.spec],
            panel_x_limits = Union{Nothing, Tuple{Float64, Float64}}[geom.x_limits],
            panel_y_limits = Union{Nothing, Tuple{Float64, Float64}}[geom.y_limits],
            panel_x_ticks = Vector{Float64}[geom.x_ticks],
            note = full_note,
        )
    end

    all_sessions = SessionContext[s for (_, grp) in labeled_groups for s in grp]
    full_note = join(note_parts, " · ")
    isempty(all_sessions) && return DashboardDataPlot(note = full_note)

    built_lines = [make_plot_line(s, session_line_label(s), options) for s in all_sessions]
    if options.split === :overlaid
        geom = build_panel_geometry(built_lines)
        panel = DashboardPlotLine[item.line for item in built_lines]
        return DashboardDataPlot(
            spec = geom.spec,
            x_limits = geom.x_limits,
            y_limits = geom.y_limits,
            x_ticks = geom.x_ticks,
            panels = Vector{DashboardPlotLine}[panel],
            panel_specs = DashboardPlotSpec[geom.spec],
            panel_x_limits = Union{Nothing, Tuple{Float64, Float64}}[geom.x_limits],
            panel_y_limits = Union{Nothing, Tuple{Float64, Float64}}[geom.y_limits],
            panel_x_ticks = Vector{Float64}[geom.x_ticks],
            note = full_note,
        )
    end

    # :panels — one panel per session, titled with the session's label
    panels = Vector{DashboardPlotLine}[]
    panel_specs = DashboardPlotSpec[]
    panel_x_limits = Union{Nothing, Tuple{Float64, Float64}}[]
    panel_y_limits = Union{Nothing, Tuple{Float64, Float64}}[]
    panel_x_ticks = Vector{Float64}[]
    for item in built_lines
        titled = DashboardPlotSpec(title = item.line.label, x_label = item.spec.x_label,
                                   y_label = item.spec.y_label)
        push!(panels, DashboardPlotLine[item.line])
        push!(panel_specs, titled)
        push!(panel_x_limits, item.x_limits)
        push!(panel_y_limits, item.y_limits)
        push!(panel_x_ticks, item.x_ticks)
    end
    first_spec = first(built_lines).spec
    return DashboardDataPlot(
        spec = first_spec,
        x_limits = first(panel_x_limits),
        y_limits = first(panel_y_limits),
        x_ticks = first(panel_x_ticks),
        panels = panels,
        panel_specs = panel_specs,
        panel_x_limits = panel_x_limits,
        panel_y_limits = panel_y_limits,
        panel_x_ticks = panel_x_ticks,
        note = full_note,
    )
end

# Synthetic LibraryEntry for an in-memory session with a unique path key so unsaved
# sessions keep their input order in `group_series` and never collide on `""`.
function synthetic_session_entry(session::SessionContext, fallback_key::String)
    entry = session_library_entry(session)
    isempty(entry.path) || return entry
    return LibraryEntry(
        fallback_key, entry.kind, entry.ids, entry.participants, entry.tags,
        entry.experiment_name, entry.method, entry.stimulus, entry.indep_var_names,
        entry.state, entry.start_time, entry.trials, entry.valid_trials,
        entry.planned_trials, entry.comments, entry.parameters, entry.levels, entry.facts,
    )
end

"""
    dashboard_data_plot(entries, sessions_by_path, options = PlotOptions();
                        checks = COMBINING_CHECKS, failed = Pair{String, String}[])
        -> DashboardDataPlot
    dashboard_data_plot(sessions::AbstractVector{SessionContext}, options = PlotOptions();
                        checks = COMBINING_CHECKS) -> DashboardDataPlot
    dashboard_data_plot(sessions_by_group::AbstractVector{<:AbstractVector{SessionContext}},
                        options = PlotOptions(); checks = COMBINING_CHECKS, note = "")
        -> DashboardDataPlot

Pure headless model for the Data view's plots. Groups session library entries into
series under `checks` (`group_series`), pools each series via an in-memory `AnalysisSet`
when `options.split === :pooled`, overlays one line per session when `:overlaid`, or
puts each session in its own panel when `:panels`. Never mutates or saves sessions.
"""
function dashboard_data_plot(entries::AbstractVector{LibraryEntry},
                             sessions_by_path::AbstractDict{String, SessionContext},
                             options::PlotOptions = PlotOptions();
                             checks = COMBINING_CHECKS,
                             failed::AbstractVector{<:Pair{String, String}} = Pair{String, String}[])
    note_parts = String[]
    if !isempty(failed)
        failed_text = join(("$(basename(p)) ($err)" for (p, err) in failed), "; ")
        push!(note_parts, ui_label(:data_note_load_failed; files = failed_text))
    end

    loaded_entries = LibraryEntry[e for e in entries
                                  if e.kind === :session && haskey(sessions_by_path, e.path)]
    if isempty(loaded_entries)
        return DashboardDataPlot(note = join(note_parts, " · "))
    end

    grouped = group_series(loaded_entries; checks)
    diff_note = series_difference_note(grouped)
    isempty(diff_note) || push!(note_parts, diff_note)

    vars = session_variables(grouped)
    multiple_groups = length(grouped) > 1
    multiple_experiments = length(unique(s.experiment_name for s in grouped)) > 1
    labeled_groups = Pair{String, Vector{SessionContext}}[]
    for series in grouped
        label = series_line_label(series, vars, multiple_groups, multiple_experiments)
        group_sessions = SessionContext[sessions_by_path[e.path] for e in series.entries]
        push!(labeled_groups, label => group_sessions)
    end
    return build_data_plot(labeled_groups, options; checks, note = join(note_parts, " · "))
end

function dashboard_data_plot(sessions::AbstractVector{SessionContext},
                             options::PlotOptions = PlotOptions();
                             checks = COMBINING_CHECKS)
    isempty(sessions) && return DashboardDataPlot()
    entries = LibraryEntry[]
    sessions_by_path = Dict{String, SessionContext}()
    for (index, session) in enumerate(sessions)
        fallback = "session_" * lpad(index, 6, '0')
        entry = synthetic_session_entry(session, fallback)
        key = haskey(sessions_by_path, entry.path) ? "$(entry.path)#$index" : entry.path
        if key != entry.path
            entry = LibraryEntry(
                key, entry.kind, entry.ids, entry.participants, entry.tags,
                entry.experiment_name, entry.method, entry.stimulus, entry.indep_var_names,
                entry.state, entry.start_time, entry.trials, entry.valid_trials,
                entry.planned_trials, entry.comments, entry.parameters, entry.levels,
                entry.facts,
            )
        end
        push!(entries, entry)
        sessions_by_path[key] = session
    end
    return dashboard_data_plot(entries, sessions_by_path, options; checks)
end

function dashboard_data_plot(sessions_by_group::AbstractVector{<:AbstractVector{SessionContext}},
                             options::PlotOptions = PlotOptions();
                             checks = COMBINING_CHECKS,
                             note::AbstractString = "")
    nonempty = [collect(SessionContext, grp) for grp in sessions_by_group if !isempty(grp)]
    isempty(nonempty) && return DashboardDataPlot(note = String(note))
    labeled = Pair{String, Vector{SessionContext}}[
        (length(grp) == 1 ? session_line_label(only(grp)) : last(grp).participant_id) => grp
        for grp in nonempty
    ]
    return build_data_plot(labeled, options; checks, note)
end

function dashboard_data_plot(labeled_groups::AbstractVector{<:Pair{<:AbstractString, <:AbstractVector{SessionContext}}},
                             options::PlotOptions = PlotOptions();
                             checks = COMBINING_CHECKS,
                             note::AbstractString = "")
    return build_data_plot(labeled_groups, options; checks, note)
end

"""
    load_ticked_data_view(paths, entries, cache, options = PlotOptions();
                          checks = COMBINING_CHECKS)
        -> (plot = DashboardDataPlot, rows = Vector{DataViewRow})

Loads `paths` through `cache`, builds the Data view's [`DashboardDataPlot`](@ref) by
grouping their library entries under `checks`, and returns the matching
[`DataViewRow`](@ref)s for the table below the plot.
"""
function load_ticked_data_view(paths::AbstractVector{<:AbstractString},
                               entries::AbstractVector{LibraryEntry},
                               cache::SessionCache,
                               options::PlotOptions = PlotOptions();
                               checks = COMBINING_CHECKS)
    entry_by_path = Dict{String, LibraryEntry}(
        abspath(e.path) => e for e in entries if e.kind === :session)
    selected_entries = LibraryEntry[]
    sessions_by_path = Dict{String, SessionContext}()
    raw_by_entry = Dict{String, String}()
    failed = Pair{String, String}[]

    for raw_path in paths
        raw_str = String(raw_path)
        abs_path = abspath(raw_str)
        haskey(sessions_by_path, abs_path) && continue
        session, err = load_cached_session!(cache, abs_path)
        if session === nothing
            push!(failed, abs_path => something(err, "unreadable"))
            continue
        end
        entry = get(entry_by_path, abs_path, nothing)
        if entry === nothing
            entry = session_library_entry(session)
        end
        sessions_by_path[entry.path] = session
        raw_by_entry[entry.path] = raw_str
        push!(selected_entries, entry)
    end

    plot = dashboard_data_plot(selected_entries, sessions_by_path, options; checks, failed)
    grouped = group_series(selected_entries; checks)
    rows = DataViewRow[
        data_view_row(sessions_by_path[e.path]; path = raw_by_entry[e.path], tickable = true)
        for s in grouped for e in s.entries
    ]
    return (plot = plot, rows = rows)
end

# ── Earlier sessions of the active session's series ──────────────────────────

"""
    earlier_series_entries(session, entries; checks = COMBINING_CHECKS) -> Vector{LibraryEntry}

Finds the other sessions of `session`'s series among the kept library `entries` using
[`group_series`](@ref) under `checks`, excluding `session` itself.
"""
function earlier_series_entries(session::SessionContext,
                                entries::AbstractVector{LibraryEntry};
                                checks = COMBINING_CHECKS)
    session_entries = LibraryEntry[e for e in entries if e.kind === :session]
    self_id = string(session.id)
    self_path = session.save_path === nothing ? nothing : abspath(session.save_path)
    is_self(e::LibraryEntry) =
        (self_path !== nothing && abspath(e.path) == self_path) || (self_id in e.ids)

    candidates = copy(session_entries)
    if !any(is_self, candidates)
        push!(candidates, synthetic_session_entry(session, self_id))
    end

    for series in group_series(candidates; checks)
        any(is_self, series.entries) || continue
        return LibraryEntry[e for e in series.entries if !is_self(e)]
    end
    return LibraryEntry[]
end

"""
    earlier_sessions_line(sessions, options = PlotOptions(); checks = COMBINING_CHECKS)
        -> Union{Nothing, DashboardPlotLine}
    earlier_sessions_line(session, entries, cache, options = PlotOptions();
                          checks = COMBINING_CHECKS)
        -> Union{Nothing, DashboardPlotLine}

Builds the single dimmed pooled [`DashboardPlotLine`](@ref) drawn under the live plot
for the other sessions of the active session's series. Returns `nothing` when there are
none.
"""
function earlier_sessions_line(sessions::AbstractVector{SessionContext},
                               options::PlotOptions = PlotOptions();
                               checks = COMBINING_CHECKS)
    isempty(sessions) && return nothing
    data = if length(sessions) == 1
        only(sessions)
    else
        set = AnalysisSet(; checks)
        for s in sessions
            admit_session!(set, s)
        end
        isempty(set.sessions) && return nothing
        length(set.sessions) == 1 ? only(set.sessions) : set
    end
    return make_plot_line(data, ui_label(:plot_earlier_sessions), options; dimmed = true).line
end

function earlier_sessions_line(session::SessionContext,
                               entries::AbstractVector{LibraryEntry},
                               cache::SessionCache,
                               options::PlotOptions = PlotOptions();
                               checks = COMBINING_CHECKS)
    others = earlier_series_entries(session, entries; checks)
    isempty(others) && return nothing
    loaded = SessionContext[]
    for entry in others
        s, _ = load_cached_session!(cache, entry.path)
        s === nothing || push!(loaded, s)
    end
    return earlier_sessions_line(loaded, options; checks)
end

# ── Table under the plot ─────────────────────────────────────────────────────

function data_view_row(session::SessionContext;
                       path::AbstractString = something(session.save_path, ""),
                       tickable::Bool = true)
    valid = count(t -> t.is_valid, session.history)
    planned = planned_valid_trials(session)
    comment = isempty(session.comments) ? "" : last(session.comments).text
    return DataViewRow(
        path = String(path),
        date = started_text(session.start_time),
        trials = trials_text(valid, planned),
        state = state_label(session.state),
        comment = comment,
        tickable = tickable,
    )
end

"""
    data_view_rows(sessions; tickable = true) -> Vector{DataViewRow}
    data_view_rows(session::SessionContext) -> Vector{DataViewRow}
    data_view_rows(::Nothing) -> Vector{DataViewRow}

Builds the session rows shown in the table under the Data view's plot: date, valid and
planned trials, state, and the last comment. A single session in hand defaults to
`tickable = false`.
"""
data_view_rows(::Nothing) = DataViewRow[]
data_view_rows(session::SessionContext) = DataViewRow[data_view_row(session; tickable = false)]
data_view_rows(sessions::AbstractVector{SessionContext}; tickable::Bool = true) =
    DataViewRow[data_view_row(s; tickable) for s in sessions]
