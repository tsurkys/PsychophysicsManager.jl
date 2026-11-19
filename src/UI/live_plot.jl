# What the dashboard's live plot draws, decided without a window:
# the view only hands these numbers to its plotting library. The rule for the
# values is the one `plot_psychometric_curve` and the fit follow, so the live plot,
# the results plot and the printed summary describe the same measurement.

"""
    DashboardTrialPoint

One recorded trial on the live plot: its number, the level it was presented at and
the place `x` it is drawn at beside that level, the value `y` it adds to its
condition's point, its answer as the trial table writes it, and whether it still
counts.
"""
struct DashboardTrialPoint
    trial::Int
    level::Float64
    x::Float64
    y::Float64
    answer::String
    counted::Bool
end

"""
    DashboardPlotSeries

What the live plot draws for a session: its labels, the ranges of the axes (`nothing`
where the axis follows the data), the places the x axis is marked at (empty where its
plotting library chooses them), the aggregated conditions, the value plotted at
each level with its error bars (`err_lo`, `err_hi`: non-negative extents below and above
`y`, empty for `:none`; `err` holds the symmetric half-width), the optional smoothed
curve (`smooth_y`), every recorded trial, and the fitted psychometric curve when there
is one (empty otherwise).
"""
Base.@kwdef struct DashboardPlotSeries
    spec::DashboardPlotSpec
    x_limits::Union{Nothing, Tuple{Float64, Float64}} = nothing
    y_limits::Union{Nothing, Tuple{Float64, Float64}} = nothing
    x_ticks::Vector{Float64} = Float64[]
    points::Vector{AggregatePoint} = AggregatePoint[]
    x::Vector{Float64} = Float64[]
    y::Vector{Float64} = Float64[]
    err::Vector{Float64} = Float64[]
    err_lo::Vector{Float64} = Float64[]
    err_hi::Vector{Float64} = Float64[]
    smooth_y::Vector{Float64} = Float64[]
    trials::Vector{DashboardTrialPoint} = DashboardTrialPoint[]
    curve_x::Vector{Float64} = Float64[]
    curve_y::Vector{Float64} = Float64[]
end

# Up to this many levels the x axis is marked at each of them and nowhere else, so a
# count such as a number of distractors is not marked at halves; more would crowd it
const MAX_LEVEL_TICKS = 12

# The fit has two free parameters; fewer levels than this only draw a line through them
const MIN_LEVELS_TO_FIT = 3

# While every value plotted, a single trial's included, is a proportion, the y axis
# holds still, with a margin for the points at 0 and 1
const PROPORTION_LIMITS = (-0.05, 1.05)

# Downward and upward error-bar extents for each point under `spread` (`:none`, `:sd`,
# `:sem`, `:ci`). Single-trial undefined intervals give 0.0 so ImPlot never receives NaN.
function spread_bars(points::Vector{AggregatePoint}, y::Vector{Float64},
                     source::Symbol, spread::Symbol)
    (spread === :none || isempty(points)) && return Float64[], Float64[]
    if spread === :sd
        # For a proportion correct, use the Bernoulli sample SD of the scored proportion
        # rather than `point.sd`, which is the spread of raw choice codes.
        vals = source === :correct ?
            Float64[point.n > 1 ? sqrt(q * (1 - q) * point.n / (point.n - 1)) : 0.0
                    for (q, point) in zip(y, points)] :
            Float64[point.sd for point in points]
        return vals, copy(vals)
    elseif spread === :sem
        # The recorded SEM is the mean response's; a proportion correct spreads binomially
        vals = source === :correct ?
            Float64[sqrt(q * (1 - q) / point.n) for (q, point) in zip(y, points)] :
            Float64[point.sem for point in points]
        return vals, copy(vals)
    elseif spread === :ci
        lo = Float64[]
        hi = Float64[]
        for (val, point) in zip(y, points)
            ci_lo, ci_hi = source === :correct ?
                (point.correct_ci_lo, point.correct_ci_hi) : (point.ci_lo, point.ci_hi)
            push!(lo, isnan(ci_lo) ? 0.0 : max(0.0, val - ci_lo))
            push!(hi, isnan(ci_hi) ? 0.0 : max(0.0, ci_hi - val))
        end
        return lo, hi
    end
    throw(ArgumentError("Unknown plot spread $(repr(spread))."))
end

# Before any trial is recorded, read from the design; once recorded, from the history.
# A saved session whose stimulus refuses its design still opens, unscored.
function group_scored(sessions::AbstractVector{SessionContext})
    if all(s -> isempty(s.history), sessions)
        return try
            answers_scored(last(sessions))
        catch err
            err isa ArgumentError || rethrow()
            false
        end
    end
    return all(t -> t.correct !== nothing, t for s in sessions for t in s.history)
end

# Shared per-group plot calculation used by both `dashboard_plot_series` (live plot)
# and `dashboard_data_plot` (Data view).
function compute_plot_group(data::SessionOrSet, options::PlotOptions;
                            x_limits_override::Union{Nothing, Tuple{Float64, Float64}} = nothing)
    session = design_session(data)
    sessions = data isa AnalysisSet ? data.sessions : SessionContext[data]
    converted = options.converted
    spec = dashboard_plot_spec(session; converted)
    levels = group_design_levels(sessions; converted)
    x_limits = x_limits_override === nothing ? axis_limits(levels) : x_limits_override
    x_ticks = length(levels) <= MAX_LEVEL_TICKS ? levels : Float64[]
    points = get_aggregated_data(data; converted)
    x = Float64[point.level for point in points]
    n = Int[point.n for point in points]

    if session.method_instance isa Adjustment
        y = Float64[point.mean_response for point in points]
        err_lo, err_hi = spread_bars(points, y, :response, options.spread)
        smooth_y = options.smooth && !isempty(points) ?
                   smoothed_means(points; values = y) : Float64[]
        trials = options.raw ? group_trial_points(sessions, :response, levels; converted) :
                               DashboardTrialPoint[]
        return (spec = spec, x_limits = x_limits, y_limits = nothing, x_ticks = x_ticks,
                points = points, x = x, y = y, n = n, err_lo = err_lo, err_hi = err_hi,
                smooth_y = smooth_y, trials = trials,
                curve_x = Float64[], curve_y = Float64[])
    end

    scored = group_scored(sessions)
    source, y = isempty(points) ? (scored ? :correct : :response, Float64[]) :
                psychometric_proportions(points, :auto)
    trials = options.raw ? group_trial_points(sessions, source, levels; converted) :
                           DashboardTrialPoint[]
    y_limits = all(v -> 0 <= v <= 1, y) && all(t -> 0 <= t.y <= 1, trials) ?
               PROPORTION_LIMITS : nothing
    err_lo, err_hi = spread_bars(points, y, source, options.spread)
    source === :correct &&
        (spec = DashboardPlotSpec(title = spec.title, x_label = spec.x_label,
                                  y_label = ui_label(:plot_proportion_correct_y)))
    smooth_y = options.smooth && !isempty(points) ?
               smoothed_means(points; values = y) : Float64[]

    curve_x, curve_y = Float64[], Float64[]
    if options.fit && length(points) >= MIN_LEVELS_TO_FIT
        # A live plot must not stop the session over a fit that did not work out
        fit = try
            fit_psychometric_curve(points; gamma = session.fit_gamma, on = source)
        catch
            nothing
        end
        if fit !== nothing && fit.converged
            low, high = something(x_limits, extrema(x))
            curve_x = collect(range(low, high; length = 100))
            curve_y = Float64[curve_value(fit, level) for level in curve_x]
        end
    end
    return (spec = spec, x_limits = x_limits, y_limits = y_limits, x_ticks = x_ticks,
            points = points, x = x, y = y, n = n, err_lo = err_lo, err_hi = err_hi,
            smooth_y = smooth_y, trials = trials, curve_x = curve_x, curve_y = curve_y)
end

"""
    dashboard_plot_series(session, options = PlotOptions()) -> DashboardPlotSeries

The live plot of `session` under `options`. An adjustment plots the mean adjusted value;
any other method plots, per level, the proportion correct when every condition was scored
and the mean response otherwise (`psychometric_proportions`), and the logistic fitted from
the session's lower asymptote (`fit_gamma`) when `options.fit` is true, once there are
enough levels and the fit converges. Error bars follow `options.spread`, smoothing follows
`options.smooth`, unit conversions follow `options.converted`, and single trials follow
`options.raw`.
"""
dashboard_plot_series(::Nothing, options::PlotOptions = PlotOptions()) =
    DashboardPlotSeries(spec = dashboard_plot_spec(nothing; converted = options.converted),
                        y_limits = PROPORTION_LIMITS)

function dashboard_plot_series(session::SessionContext,
                               options::PlotOptions = PlotOptions())
    g = compute_plot_group(session, options)
    err = options.spread === :ci ? 0.5 .* (g.err_lo .+ g.err_hi) : g.err_lo
    return DashboardPlotSeries(
        spec = g.spec, x_limits = g.x_limits, y_limits = g.y_limits,
        x_ticks = g.x_ticks, points = g.points, x = g.x, y = g.y,
        err = err, err_lo = g.err_lo, err_hi = g.err_hi,
        smooth_y = g.smooth_y, trials = g.trials,
        curve_x = g.curve_x, curve_y = g.curve_y,
    )
end

# Every finite level of the design's first variable, in the declared (or raw) units, sorted
function design_levels(session::SessionContext; converted::Bool = true)
    isempty(session.ex_par.indep_var_names) && return Float64[]
    levels = try
        [converted ? converted_values(session, [Float64(level)])[1] : Float64(level)
         for level in session.ex_par.indep_var_ranges[1]]
    catch
        return Float64[]
    end
    return sort(unique(filter(isfinite, levels)))
end

function group_design_levels(sessions::AbstractVector{SessionContext}; converted::Bool = true)
    all_levels = Float64[]
    for session in sessions
        append!(all_levels, design_levels(session; converted))
    end
    return sort!(unique!(all_levels))
end

# The x axis spans every level the design presents, so it does not jump as levels are
# reached, with room for the trials spread beside the outer levels; `nothing` when the
# design gives no finite level
function axis_limits(levels::Vector{Float64})
    isempty(levels) && return nothing
    low, high = extrema(levels)
    margin = max((high - low) * 0.06, 0.6 * spread_width(levels))
    return (low - margin, high + margin)
end

# The trials of one level are spread sideways in the order presented, so that each
# can be pointed at and the order of the answers can be read
function group_trial_points(sessions::AbstractVector{SessionContext}, source::Symbol,
                            levels::Vector{Float64}; converted::Bool = true)
    placed = Tuple{Trial, Float64, Float64}[]
    for session in sessions
        convert_response = converted ? response_conversion(session) : identity
        for trial in session.history
            # The rule `converted_observations` keeps a trial by, validity aside
            trial.response isa Real && !isnan(trial.response) || continue
            isempty(trial.indep_var_vals) && continue
            y = source === :correct ? trial.correct : convert_response(trial.response)
            y === nothing && continue
            level = converted ? converted_values(session, trial.indep_var_vals)[1] :
                                Float64(trial.indep_var_vals[1])
            push!(placed, (trial, level, Float64(y)))
        end
    end

    spread_levels = isempty(levels) && !isempty(placed) ?
                    sort(unique(Float64[p[2] for p in placed])) : levels
    width = spread_width(spread_levels)
    sharing = Dict{Float64, Int}()
    for (_, level, _) in placed
        sharing[level] = get(sharing, level, 0) + 1
    end
    slots = Dict{Float64, Int}()
    return map(placed) do (trial, level, y)
        slot = slots[level] = get(slots, level, 0) + 1
        x = level + width * ((slot - 0.5) / sharing[level] - 0.5)
        DashboardTrialPoint(trial.trial_index, level, x, y, trial_response_text(trial),
                            trial.is_valid)
    end
end

trial_points(session::SessionContext, source::Symbol, levels::Vector{Float64};
             converted::Bool = true) =
    group_trial_points(SessionContext[session], source, levels; converted)

# A third of the narrowest gap between the design's levels, so that no trial reaches a
# neighbouring level, and at least a sixtieth of their span, which a fine adaptive grid
# needs; a tenth of the level's size when there is a single level
function spread_width(levels::Vector{Float64})
    length(levels) > 1 || return 0.1 * max(abs(isempty(levels) ? 0.0 : only(levels)), 1.0)
    return max(minimum(diff(levels)) / 3, (last(levels) - first(levels)) / 60)
end

"""
    dashboard_point_trials(session, point; converted = true) -> Vector{Trial}

The recorded trials behind one point of the live plot — every trial presented at
that condition, counted or not — so that a correction can be made from the point.
"""
dashboard_point_trials(session::SessionContext, point::AggregatePoint;
                       converted::Bool = true) =
    [trial for trial in session.history
     if (converted ? converted_values(session, trial.indep_var_vals) :
                     trial.indep_var_vals) == point.vals]

"""
    dashboard_point_condition(session, point; converted = true) -> Vector{Float64}

The condition behind a point of the live plot as the session recorded it, the
values `present_condition!` takes: the plot shows them in the declared units when
`converted` is true.
"""
dashboard_point_condition(session::SessionContext, point::AggregatePoint;
                          converted::Bool = true) =
    copy(first(dashboard_point_trials(session, point; converted)).indep_var_vals)

"""
    dashboard_design_conditions(session) -> Vector{Pair{String, Vector{Float64}}}

Every condition the design declares — each combination of the declared levels,
sorted by the first variable — as the label the plot's menu shows and the recorded
values `present_condition!` takes. This is how a stimulus still to come is chosen.
"""
function dashboard_design_conditions(session::SessionContext)
    names = session.ex_par.indep_var_names
    ranges = [Float64[x for x in range if x isa Real] for range in session.ex_par.indep_var_ranges]
    conditions = sort(vec([collect(vals) for vals in Iterators.product(ranges...)]))
    return [join(("$name $(format_level(value))" for (name, value) in zip(names, vals)),
                 " · ") => vals
            for vals in conditions]
end
