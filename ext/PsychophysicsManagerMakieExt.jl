# Plotting extension: loads automatically when any Makie backend is present
# (GLMakie and CairoMakie both load Makie). Uses only the backend-agnostic
# Makie API; window management specifics live in PsychophysicsManagerGLMakieExt.

module PsychophysicsManagerMakieExt

using PsychophysicsManager
using Makie
using Statistics
import PsychophysicsManager: plot_psychometric_curve, plot_adjustment_results,
                  plot_psychometric_curve!, plot_adjustment_results!,
                  plot_adaptive_sequence, save_summary_plot, save_adjustment_plot,
                  visualize_results
using PsychophysicsManager: SessionOrSet, design_session, converted_observations, Adjustment,
                 kept_variables, kept_positions,
                 variable_label, response_label,
                 get_aggregated_data, smoothed_means, CI_LEVEL,
                 fit_psychometric_curve, psychometric_proportions,
                 CurveFit, curve_value, has_interval, close_all_windows,
                 TemporalOppelKundt, AnalysisSet

# The 2D plots draw against the FIRST independent variable. Aggregation keys
# on the full condition vector, so multi-variable sessions are not averaged
# together — but they do appear as separate points sharing an x value, which
# deserves an explicit heads-up instead of a silently confusing figure.
function warn_if_multivariable(data::SessionOrSet, collapse)
    names = kept_variables(data, collapse)
    if length(names) > 1
        @warn "The data has $(length(names)) independent variables; plotting against '$(names[1])' only. Conditions differing in the other variables appear as separate points at the same x; `collapse` pools the trials over a variable that is only counterbalanced."
    end
    return nothing
end

"""
    plot_psychometric_curve(data; title="Psychometric Curve",
                            gamma=design_session(data).fit_gamma, lambda=0.0, on=:auto,
                            fit=nothing, smooth=false, spread=:sem, collapse=())

Generates a psychometric plot with aggregated data points, error bars, and a fitted
curve, for one session or for the sessions of an `AnalysisSet` pooled together.

The points and the curve show the proportion correct for a session whose task
scores every condition, and the mean response otherwise; `on` overrides the
choice as it does for `fit_psychometric_curve`.

Without `fit` the core's logistic is fitted and drawn. The lower asymptote defaults to
the data's own `fit_gamma`, so a session reopened later is fitted the way its operator
declared it; pass `gamma` explicitly to fit the same data differently without changing
the session.

A `fit` made beforehand — the library's maximum-likelihood fit of any of its models,
for example — is drawn as it was estimated: its own model, and, when it carries one
([`has_interval`](@ref)), the confidence interval of its threshold as a band. Pass the
`on` it was fitted with, so that the points show what the curve describes.

```julia
fit = fit_psychometric_curve(get_aggregated_data(session), :weibull; gamma = 0.5)
plot_psychometric_curve(session; fit)
```

`spread` chooses the error bars on the points: `:sem` the standard error of the mean
(binomial for proportion correct), `:ci` the confidence interval at `CI_LEVEL` of what
is plotted (the Wilson score interval for a proportion, Student's t otherwise), `:none`
no bars. `smooth = true` adds a curve through the mean responses that assumes no model
(`smoothed_means`). `collapse` pools the trials over a counterbalancing variable, such as
the interval that held the target, so that each level is one point
(`get_aggregated_data`).
"""
function plot_psychometric_curve(data::SessionOrSet; title="Psychometric Curve",
                                 gamma=design_session(data).fit_gamma, lambda=0.0,
                                 on::Symbol=:auto, fit::Union{Nothing, CurveFit}=nothing,
                                 smooth::Bool=false, spread::Symbol=:sem, collapse=())
    check_spread(spread, (:sem, :ci, :none))
    if isempty(get_aggregated_data(data; collapse))
        @warn "No valid data to plot."
        return nothing
    end
    fig = Figure(size = (800, 600))
    ax = Axis(fig[1, 1], title = title)
    plot_psychometric_curve!(ax, data; gamma, lambda, on, fit, smooth, spread, collapse)
    axislegend(ax, position = :rb)
    return fig
end

"""
    plot_psychometric_curve!(ax, data; label=nothing, color=nothing, gamma, lambda=0.0,
                             on=:auto, fit=nothing, smooth=false, spread=:sem,
                             collapse=()) -> CurveFit

Draws what [`plot_psychometric_curve`](@ref) draws into the Makie axis `ax`, beside
what the axis already holds, and returns the fit. Given `color`, the points, the curve
and the threshold are drawn in it, and `label` names them in the legend, so that
several sessions or datasets share one axis:

```julia
fig = Figure(); ax = Axis(fig[1, 1])
for (session, color) in zip(sessions, Makie.wong_colors())
    plot_psychometric_curve!(ax, session; label = session.participant_id, color)
end
axislegend(ax)
```

`spread` selects `:sem`, `:ci`, or `:none` error bars as in
[`plot_psychometric_curve`](@ref). The axis is labelled from the data unless it has
labels of its own.
"""
function plot_psychometric_curve!(ax, data::SessionOrSet; label=nothing, color=nothing,
                                  gamma=design_session(data).fit_gamma, lambda=0.0,
                                  on::Symbol=:auto, fit::Union{Nothing, CurveFit}=nothing,
                                  smooth::Bool=false, spread::Symbol=:sem, collapse=())
    check_spread(spread, (:sem, :ci, :none))
    agg = get_aggregated_data(data; collapse)
    if isempty(agg)
        @warn "No valid data to plot."
        return fit
    end
    warn_if_multivariable(data, collapse)

    # The curve is fitted unless one is given (gamma/lambda fixed during the fit; the
    # asymptote comes from the session — see DEFAULT_FIT_GAMMA for why it is declared
    # there)
    fit === nothing && (fit = fit_psychometric_curve(agg; gamma=gamma, lambda=lambda, on=on))
    source, proportions = psychometric_proportions(agg, on)

    session = design_session(data)
    names = kept_variables(data, collapse)
    label_axis!(ax, isempty(names) ? "Stimulus Level" : variable_label(session, first(names)),
                source === :correct ? "Proportion correct" :
                session.stim_par isa TemporalOppelKundt ?
                "Proportion: second interval longer" : "Proportion 'Yes'")
    ylims!(ax, -0.05, 1.05)

    # Alone in its axis the data is black, the fit red and the threshold blue
    point_color = something(color, :black)
    curve_color = something(color, :red)
    alpha_color = something(color, :blue)
    named(entry) = label === nothing ? entry : "$label: $entry"

    levels = [p.level for p in agg]
    scatter!(ax, levels, proportions, color = point_color, markersize = 12,
             label = label === nothing ? "Data" : string(label))
    if spread === :sem
        # The recorded SEM is the mean response's; a proportion correct spreads binomially
        sems = source === :correct ?
            [sqrt(q * (1 - q) / point.n) for (q, point) in zip(proportions, agg)] :
            [p.sem for p in agg]
        errorbars!(ax, levels, proportions, sems, color = point_color, whiskerwidth = 10)
    elseif spread === :ci
        intervals = source === :correct ?
            [(p.correct_ci_lo, p.correct_ci_hi) for p in agg] :
            [(p.ci_lo, p.ci_hi) for p in agg]
        below = [y - (isnan(lo) ? y : lo) for (y, (lo, _)) in zip(proportions, intervals)]
        above = [(isnan(hi) ? y : hi) - y for (y, (_, hi)) in zip(proportions, intervals)]
        errorbars!(ax, levels, proportions, below, above, color = point_color, whiskerwidth = 10)
    end
    smooth && draw_smoothed!(ax, agg, proportions; color = point_color)

    # The fit if it converged, with its threshold's interval when it has one
    if fit.converged
        if has_interval(fit)
            vspan!(ax, fit.ci_alpha..., color = (alpha_color, 0.12),
                   label = named("α interval ($(fit.n_bootstrap) bootstrap samples)"))
        end
        x_range = range(minimum(levels), maximum(levels), length=100)
        lines!(ax, x_range, [curve_value(fit, x) for x in x_range], color = curve_color,
               linewidth = 2, label = named(fit_label(fit)))
        vlines!(ax, [fit.alpha], color = alpha_color, linestyle = :dash, alpha = 0.5)
        text!(ax, fit.alpha, 0.5, text = " α = $(round(fit.alpha, digits=3))",
              color = alpha_color)
    end
    return fit
end

# An axis keeps the labels it was given; one without takes the data's
function label_axis!(ax, x_label::AbstractString, y_label::AbstractString)
    isempty(ax.xlabel[]) && (ax.xlabel = x_label)
    isempty(ax.ylabel[]) && (ax.ylabel = y_label)
    return nothing
end

# "Logistic fit", "Cumulative normal fit"
fit_label(fit::CurveFit) = uppercasefirst(replace(string(fit.model), "_" => " ")) * " fit"

"""
    plot_adaptive_sequence(session; title="Adaptive Sequence", fit=nothing,
                           gamma=session.fit_gamma, lambda=0.0, on=:auto)

The levels an adaptive method presented, trial by trial ([`adaptive_sequence`](@ref)),
one line per track: a filled point for a correct answer, a hollow one for a wrong or
missing one, a cross over a trial that no longer counts, and a ring around each
reversal. The method's own threshold is drawn beside the threshold fitted to the same
trials — the core's logistic with the session's `gamma`, or the `fit` given — as two
horizontal lines.
"""
function plot_adaptive_sequence(session::SessionContext; title = "Adaptive Sequence",
                                fit::Union{Nothing, CurveFit} = nothing,
                                gamma = session.fit_gamma, lambda = 0.0, on::Symbol = :auto)
    tracks = adaptive_sequence(session)
    variable = first(tracks).variable
    fig = Figure(size = (800, 500))
    ax = Axis(fig[1, 1], title = title, xlabel = "Trial",
              ylabel = variable_label(session, variable))
    colors = Makie.wong_colors()
    for (k, track) in enumerate(tracks)
        isempty(track.trials) && continue
        color = colors[mod1(k, length(colors))]
        first_track = k == 1
        lines!(ax, track.trials, track.levels, color = color,
               label = isempty(track.name) ? "Presented level" : track.name)
        right = [answer === true for answer in track.correct]
        scatter!(ax, track.trials[right], track.levels[right], color = color, markersize = 9,
                 label = first_track ? "Correct" : nothing)
        scatter!(ax, track.trials[.!right], track.levels[.!right], color = :white,
                 strokecolor = color, strokewidth = 1.5, markersize = 9,
                 label = first_track ? "Wrong or unanswered" : nothing)
        scatter!(ax, track.trials[track.reversal], track.levels[track.reversal],
                 color = (:white, 0.0), strokecolor = :orange, strokewidth = 2,
                 markersize = 18, label = first_track ? "Reversal" : nothing)
        dropped = .!track.counted
        any(dropped) && scatter!(ax, track.trials[dropped], track.levels[dropped],
                                 marker = :xcross, color = :gray, markersize = 12,
                                 label = first_track ? "Not counted" : nothing)
        estimate = track.estimate
        if estimate !== nothing && !isnan(estimate)
            hlines!(ax, [estimate], color = color, linestyle = :dash,
                    label = "Method's threshold$(isempty(track.name) ? "" : ", " * track.name)" *
                            " = $(round(estimate, digits = 3))")
        end
    end
    # The fit reads the first variable of the design, which is the presented one
    # unless an interleaved design names its track first
    if first(session.ex_par.indep_var_names) == variable
        aggregated = get_aggregated_data(session)
        fit === nothing && length(aggregated) >= 2 &&
            (fit = fit_psychometric_curve(aggregated; gamma = gamma, lambda = lambda, on = on))
        fit !== nothing && fit.converged &&
            hlines!(ax, [fit.alpha], color = :red, linestyle = :dot,
                    label = "Fitted threshold = $(round(fit.alpha, digits = 3))")
    end
    axislegend(ax, position = :rt)
    return fig
end

# A curve through the condition means — or the values given for them — that assumes
# no model, along the first variable; a multi-variable design gets one per
# combination of the others
function draw_smoothed!(ax, agg, values = [point.mean_response for point in agg];
                       color = :black)
    smoothed = smoothed_means(agg; values)
    first_group = true
    for others in unique(point.vals[2:end] for point in agg)
        members = sort!(findall(point -> point.vals[2:end] == others, agg);
                        by = index -> agg[index].level)
        lines!(ax, [agg[index].level for index in members], smoothed[members],
               color = color, linewidth = 2,
               label = first_group ? "Smoothed (moving average of 3 levels)" : nothing)
        first_group = false
    end
    return nothing
end

"""
    save_summary_plot(data, filename::String)

Convenience function to generate and save a plot to disk.
"""
function save_summary_plot(data::SessionOrSet, filename::String)
    fig = plot_psychometric_curve(data)
    if fig !== nothing
        save(filename, fig)
        println("Plot saved to: $filename")
    end
end

"""
    plot_adjustment_results(data; title="Adjustment Results", spread=:sem, smooth=false,
                            collapse=())

Plots the adjusted values (e.g. Diff) for each level of the independent variable (e.g. DistrN),
for one session or for the sessions of an `AnalysisSet` pooled together.
Shows individual trials as dots and the mean with error bars.

`spread` chooses the bars: `:sem` the standard error of the mean, `:sd` the standard
deviation of the settings (the variable error), `:ci` the mean's confidence interval
(Student's t for an adjustment, Wilson for a proportion, at `CI_LEVEL`), `:none` no
bars. `smooth = true` adds a curve through the
means that assumes no model (`smoothed_means`). `collapse` pools the settings over a
counterbalancing variable (`get_aggregated_data`).
"""
function plot_adjustment_results(data::SessionOrSet; title="Adjustment Results",
                                 spread::Symbol=:sem, smooth::Bool=false, collapse=())
    check_spread(spread)
    agg = get_aggregated_data(data; collapse)
    if isempty(agg)
        @warn "No valid adjustment data to plot."
        return nothing
    end
    fig = Figure(size = (600, 440))
    ax = Axis(fig[1, 1], title = design_session(data).ex_par.experiment_name * " Results",
              xticks = [p.level for p in agg])
    plot_adjustment_results!(ax, data; spread, smooth, collapse)
    # Below the axis, where it covers no point however the settings lie
    Legend(fig[2, 1], ax, orientation = :horizontal, framevisible = false)
    return fig
end

check_spread(spread::Symbol, allowed = (:sem, :sd, :ci, :none)) =
    spread in allowed || throw(ArgumentError(
        "spread is $(join(":" .* string.(allowed[1:end-1]), ", ")) or :$(allowed[end]), " *
        "got :$spread."))

"""
    plot_adjustment_results!(ax, data; label=nothing, color=nothing, spread=:sem,
                             smooth=false, collapse=())

Draws what [`plot_adjustment_results`](@ref) draws into the Makie axis `ax`, beside what
the axis already holds. Given `color`, the trials and the means are drawn in it, and
`label` names the means in the legend, so that several sessions or datasets share one
axis (see [`plot_psychometric_curve!`](@ref)). The axis is labelled from the data unless
it has labels of its own.
"""
function plot_adjustment_results!(ax, data::SessionOrSet; label=nothing, color=nothing,
                                  spread::Symbol=:sem, smooth::Bool=false, collapse=())
    check_spread(spread)
    agg = get_aggregated_data(data; collapse)
    if isempty(agg)
        @warn "No valid adjustment data to plot."
        return nothing
    end
    warn_if_multivariable(data, collapse)

    unique_levels = [p.level for p in agg]
    means = [p.mean_response for p in agg]
    # The bars below and above each mean; a single trial gives no interval
    below, above = spread === :ci ?
        ([p.mean_response - (isnan(p.ci_lo) ? p.mean_response : p.ci_lo) for p in agg],
         [(isnan(p.ci_hi) ? p.mean_response : p.ci_hi) - p.mean_response for p in agg]) :
        spread === :sd ? ([p.sd for p in agg], [p.sd for p in agg]) :
        ([p.sem for p in agg], [p.sem for p in agg])

    # Individual trial points for the scatter overlay, the trials the means were
    # computed from, in the same units
    observations = converted_observations(data)
    level_position = first(kept_positions(data, collapse))
    all_x = [vals[level_position] for (vals, _, _) in observations]
    all_y = [response for (_, response, _) in observations]

    session = design_session(data)
    names = kept_variables(data, collapse)
    label_axis!(ax, isempty(names) ? "Independent Variable" : variable_label(session, first(names)),
                something(response_label(session), "Adjusted Value"))

    # Alone in its axis the trials are grey and the means red
    trial_color = something(color, :black)
    mean_color = something(color, :red)
    bars = spread === :sem ? "Mean ± SEM" : spread === :sd ? "Mean ± SD" :
           spread === :ci ? "Mean, $(round(Int, 100 * CI_LEVEL))% CI" : "Mean"

    # Individual trials, jittered
    jitter = (rand(length(all_x)) .- 0.5) .* 0.1
    scatter!(ax, all_x .+ jitter, all_y, color = (trial_color, 0.2), markersize = 6,
             label = label === nothing ? "Trials" : nothing)

    spread === :none ||
        errorbars!(ax, unique_levels, means, below, above, color = mean_color, whiskerwidth = 10)
    scatter!(ax, unique_levels, means, color = mean_color, markersize = 10, marker = :circle,
             label = label === nothing ? bars : "$label: $bars")
    lines!(ax, unique_levels, means, color = mean_color, linestyle = :dash, alpha = 0.4)
    smooth && draw_smoothed!(ax, agg; color = something(color, :black))
    return nothing
end

"""
    save_adjustment_plot(data, filename::String)

Convenience function to generate and save adjustment results plot to disk.
"""
function save_adjustment_plot(data::SessionOrSet, filename::String)
    fig = plot_adjustment_results(data)
    if fig !== nothing
        save(filename, fig)
        println("Adjustment plot saved to: $filename")
    end
end

"""
    visualize_results(data; title="Experiment Results", collapse=(), split=false)

High-level function to display experiment results of a session or an `AnalysisSet`.
Closes any stimulus windows first (via the active display backend) and selects the
plot type appropriate for the method. `collapse` pools the trials over a counterbalancing
variable, as `get_aggregated_data` does. `split = true` draws each session of a set in a
panel of its own, titled by its participant and short id, instead of pooling them.
"""
function visualize_results(data::SessionOrSet; title="Experiment Results", collapse=(),
                           split::Bool=false)
    println("\nOpening results plot...")

    # Let the display backend (e.g. GLMakie) release fullscreen stimulus windows
    close_all_windows()

    adjustment = design_session(data).method_instance isa Adjustment
    fig = if split && data isa AnalysisSet
        plot_members(data; title, collapse, adjustment)
    elseif adjustment
        plot_adjustment_results(data; title, collapse)
    else
        plot_psychometric_curve(data; title, collapse)
    end

    if fig !== nothing
        display(fig)
    end

    return fig
end

# A panel per member of a set, in a near-square grid under one title
function plot_members(set::AnalysisSet; title, collapse, adjustment::Bool)
    members = set.sessions
    isempty(members) && (@warn "No valid data to plot."; return nothing)
    columns = ceil(Int, sqrt(length(members)))
    rows = cld(length(members), columns)
    fig = Figure(size = (420 * columns, 340 * rows + 40))
    Label(fig[0, 1:columns], title, fontsize = 18, font = :bold)
    for (index, member) in enumerate(members)
        ax = Axis(fig[cld(index, columns), mod1(index, columns)],
                  title = member.participant_id * " · " * string(member.id)[1:8])
        adjustment ? plot_adjustment_results!(ax, member; collapse) :
                     plot_psychometric_curve!(ax, member; collapse)
    end
    return fig
end

end # module
