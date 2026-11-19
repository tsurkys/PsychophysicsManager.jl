# The sequence an adaptive method presented: the
# level of each trial, the reversals, and the method's own threshold estimate, which a
# report shows beside the threshold fitted to the same trials.

"""
    AdaptiveTrack

The levels one adaptive track presented, in the order presented: `name` (empty for a
session with one track, `"track 2"` for a track of an interleaved run), the `variable`
the levels are values of, the trials' numbers, their `levels` in the units the session
declares, whether each was answered `correct`ly (`nothing` when unscored or
unanswered), whether each still `counted`, whether each was a `reversal`, and
`estimate`, the method's own threshold in the same units, or `nothing` when the method
gives none (`NaN` when it gives one but has too little to go on yet).
"""
struct AdaptiveTrack
    name::String
    variable::Symbol
    trials::Vector{Int}
    levels::Vector{Float64}
    correct::Vector{Union{Nothing, Bool}}
    counted::Vector{Bool}
    reversal::Vector{Bool}
    estimate::Union{Nothing, Float64}
end

"""
    is_adaptive(method) -> Bool

Whether `method` chooses each trial's level from the answers before it: it neither
plans its conditions ([`plans_conditions`](@ref)) nor has a value adjusted.
"""
is_adaptive(method::AbstractPsychoMethod) =
    !plans_conditions(method) && isempty(adjusted_fields(method))

"""
    method_estimate(method) -> Union{Nothing, Float64}

The threshold `method` estimates itself, in the units it presents — [`Psi`](@ref)
gives its posterior mean ([`method_threshold`](@ref)) — or `nothing` for a method
that gives none.
"""
method_estimate(::AbstractPsychoMethod) = nothing

"""
    adaptive_sequence(session) -> Vector{AdaptiveTrack}

The levels the session's adaptive method presented, one track per staircase — each
track of an interleaved run on its own — in the units the session declares
([`set_unit_conversion!`](@ref)). Trials the operator chose are left out, since the
method did not choose them.

A reversal is the trial after which the level moved the other way than it last moved:
the trial whose answer turned the track. A trial presented again at the same level — an
undone or unanswered one — makes no step, and the last trial of a track, with no step
after it, is never marked.

A method that is not adaptive ([`is_adaptive`](@ref)) is refused.
"""
function adaptive_sequence(session::SessionContext)
    method = session.method_instance
    is_adaptive(method) || throw(ArgumentError(
        "$(type_name(method)) presents no adaptive sequence: it plans its conditions or " *
        "adjusts a value, and its levels do not follow the answers."))
    names = session.ex_par.indep_var_names
    column = findfirst(!=(TRACK_VARIABLE), names)
    column === nothing && throw(ArgumentError("The design declares no variable to present."))
    variable = names[column]
    convert = get(session.unit_conversions, variable, identity)
    chosen = filter(trial -> trial.origin === :method, session.history)
    track_column = findfirst(==(TRACK_VARIABLE), names)
    if method isa Interleaved && track_column !== nothing
        return [adaptive_track("track $k", variable, convert, column,
                               filter(trial -> round(Int, trial.indep_var_vals[track_column]) == k,
                                      chosen),
                               method_estimate(track))
                for (k, track) in enumerate(method.tracks)]
    end
    return [adaptive_track("", variable, convert, column, chosen, method_estimate(method))]
end

function adaptive_track(name::String, variable::Symbol, convert, column::Int,
                        trials::Vector{Trial}, estimate::Union{Nothing, Real})
    levels = Float64[convert(trial.indep_var_vals[column]) for trial in trials]
    reversal = falses(length(levels))
    previous = 0.0
    for (index, step) in enumerate(sign.(diff(levels)))
        step == 0 && continue
        previous != 0 && step != previous && (reversal[index] = true)
        previous = step
    end
    return AdaptiveTrack(name, variable, [trial.trial_index for trial in trials], levels,
                         Union{Nothing, Bool}[trial.correct for trial in trials],
                         [trial.is_valid for trial in trials], collect(reversal),
                         estimate === nothing ? nothing : Float64(convert(estimate)))
end

# The method's own estimate beside the fitted threshold, in the summary
function print_method_estimates(session::SessionContext)
    for track in adaptive_sequence(session)
        track.estimate === nothing && continue
        whose = isempty(track.name) ? "The method's own threshold" :
                "The method's own threshold, $(track.name)"
        println(whose, ": ", isnan(track.estimate) ? "not estimated yet (too few reversals)" :
                             round(track.estimate, digits = 2),
                "   ($(count(track.reversal)) reversal(s))")
    end
    return nothing
end
