# Whether a presentation has a right answer, and what it is. Scoring is a
# property of the task being presented, so the hook dispatches on the stimulus
# parameters; the Core loop compares
# the participant's raw response against it and records the outcome.

"""
    trial_variables(ex_par::ExperimentParameters, vals::AbstractVector{<:Real}) -> NamedTuple

The trial's independent variables by name, pairing `ex_par.indep_var_names`
with the value vector a method produced for this presentation.

It is the read-side counterpart of [`apply_variables!`](@ref): a variable
reaches the stimulus fields through binding, and reaches everyone who needs its
value — [`correct_answer`](@ref) above all — through this.
"""
function trial_variables(ex_par::ExperimentParameters, vals::AbstractVector{<:Real})
    return NamedTuple{Tuple(ex_par.indep_var_names)}(Tuple(Float64.(vals)))
end

"""
    validate_stimulus(stim_par::AbstractStimulusParameters) -> stim_par

Checks that a stimulus can be presented as it is described, and throws an
`ArgumentError` saying what is wrong otherwise. Parameters are checked when they are
set ([`set_parameters!`](@ref)), so a value is refused when it is typed rather than at
the first trial. The default accepts; a stimulus type with rules of its own extends
it.
"""
validate_stimulus(stim_par::AbstractStimulusParameters) = stim_par

"""
    correct_answer(stim_par::AbstractStimulusParameters, vars::NamedTuple) -> Union{Nothing, Int}

The raw response code (`+1` or `-1`) that is correct for the presentation
described by `stim_par` and this trial's independent variables `vars`. A
response that is not an answer ([`is_answer`](@ref)) is never scored against it.

The default returns `nothing`: a task need not have a right answer. A point of
subjective equality is measured as the proportion of trials answered one way,
and inventing a correct response for it would describe a measurement that was
never made.

An implementation reads every per-trial quantity from `vars`, not from
`stim_par`: a variable that has no same-named stimulus field — a target
position such as `target_interval`, say — is skipped by `apply_variables!` and
would not be in `stim_par` at all, and one that does have a field is written
there by the same binding step that fills `vars`, so reading the bound value
can only ever return the same number or a stale one.

```julia
PsychophysicsManager.correct_answer(::TwoIntervalStimulus, vars::NamedTuple) =
    vars.target_interval == 1 ? 1 : -1
```
"""
correct_answer(::AbstractStimulusParameters, ::NamedTuple) = nothing

"""
    physical_equality(stim_par::AbstractStimulusParameters, field::Symbol, vars::NamedTuple) -> Union{Nothing, Real}

The value of the stimulus field `field` — the one an adjustment method adjusts — at
which the presentation is physically equal: the reference and the test the same, for
this trial's independent variables `vars`. An adjustment's constant error is the mean
setting's deviation from it ([`constant_errors`](@ref)).

The default returns `nothing`: a stimulus need not have such a point, and one not
declared here is never assumed. A stimulus type declares it as it declares its
correct answer, so that nothing has to be typed per session.

```julia
PsychophysicsManager.physical_equality(::LineBisection, field::Symbol, vars::NamedTuple) =
    field === :offset ? 0.0 : nothing
```
"""
physical_equality(::AbstractStimulusParameters, ::Symbol, ::NamedTuple) = nothing

"""
    is_answer(response) -> Bool

Whether a raw response states what the participant perceived, and can therefore
be scored.

Three codes do not: `0` asks for the presentation to be repeated,
[`MISSING_RESPONSE`](@ref) records that no reply arrived at all, and `:timeout`
that the response window closed first. Scoring any of them would turn a
question the participant never answered into a wrong answer, and an adaptive
method reading that would step its level on a repeat request or on a model
observer's silence.
"""
is_answer(response::Real) = response != 0 && !isnan(response)
is_answer(::Symbol) = false

"""
    task_scoring(stim_par, ex_par) -> Symbol

For how many conditions of the design the stimulus declares a correct answer
([`correct_answer`](@ref)): `:all` for a scored task, such as a threshold measured in
two intervals, `:none` for one that has none — a point of subjective equality — and
`:some`.
"""
task_scoring(stim_par::AbstractStimulusParameters, ex_par::ExperimentParameters) =
    scoring_kind([correct_answer(stim_par, trial_variables(ex_par, Float64[condition...]))
                  for condition in Iterators.product(ex_par.indep_var_ranges...)])

# The same, of the correct answers of the conditions
function scoring_kind(answers)
    unscored = count(isnothing, answers)
    return unscored == 0 ? :all : unscored == length(answers) ? :none : :some
end
