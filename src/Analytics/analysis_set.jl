# Combined datasets: sessions kept whole in one set,
# analysed together and saved as a dataset of their own.

"""
    COMBINING_CHECKS

The optional checks of an [`AnalysisSet`](@ref): facts sessions must also share to be
combined while the check is on. All of them are on unless the `[combining]` section of
`settings.toml` switches one off ([`load_combining_checks`](@ref)).

- `:instructions` — the verbatim wording of the task;
- `:observer` — the program that answered and the settings it was queried with;
- `:feedback` — whether answers were followed by feedback;
- `:timeout` — the response window;
- `:stimulus` — the stimulus fields that are neither an independent variable nor set
  by the method during the run ([`adjusted_fields`](@ref)).

Whatever the checks, sessions are combined only when they share the stimulus type, the
method (an interleaved run together with its tracks), the independent variables in
their order, the task's response coding (its options and the one coded `+1`),
`fit_gamma`, whether a person or a program answered, and the units their values are
reported in — the label of each [`UnitConversion`](@ref). A conversion's scale may
differ, since sessions measured on two displays convert the same recorded value to
different units.
"""
const COMBINING_CHECKS = (:instructions, :observer, :feedback, :timeout, :stimulus)

"""
    AnalysisSet(sessions = SessionContext[]; checks = load_combining_checks())

Sessions combined into one dataset, for analysing them together and for saving them as
a dataset of their own ([`save_analysis_set`](@ref)). Every member stays whole — its
id, its parameters, its full history — and trials are pooled only by an analysis:
[`get_aggregated_data`](@ref), the summaries, the plots and the export take a set
wherever they take a session.

Sessions are added in order through [`add_session!`](@ref), which refuses, with a
warning, a session already in the set and one that does not share every fact the set
compares; `checks` names the optional ones ([`COMBINING_CHECKS`](@ref)). The last
member is the design a new experiment set up from the set starts from
([`create_replicated_session`](@ref)).
"""
struct AnalysisSet
    sessions::Vector{SessionContext}
    checks::Vector{Symbol}

    function AnalysisSet(sessions::AbstractVector{SessionContext} = SessionContext[];
                         checks = load_combining_checks())
        unknown = [check for check in checks if !(check in COMBINING_CHECKS)]
        isempty(unknown) || throw(ArgumentError(
            "$(join(repr.(unknown), ", ")) is not a combining check; the checks are " *
            "$(join(repr.(COMBINING_CHECKS), ", "))."))
        set = new(SessionContext[], [check for check in COMBINING_CHECKS if check in checks])
        foreach(session -> add_session!(set, session), sessions)
        return set
    end
end

count_sessions(set::AnalysisSet) =
    length(set.sessions) == 1 ? "1 session" : "$(length(set.sessions)) sessions"

Base.show(io::IO, set::AnalysisSet) = print(io, "AnalysisSet(", count_sessions(set), ")")

function Base.show(io::IO, ::MIME"text/plain", set::AnalysisSet)
    print(io, "AnalysisSet of ", count_sessions(set), "; optional checks: ",
          isempty(set.checks) ? "none" : join(set.checks, ", "))
    for member in set.sessions
        print(io, "\n  ", string(member.id)[1:8], "  ", member.participant_id, "  ",
              member.state, "  ", count(trial -> trial.is_valid, member.history),
              " valid trials")
    end
end

# What an analysis accepts
const SessionOrSet = Union{SessionContext, AnalysisSet}

# The session an analysis reads the design from — the variable names, the stimulus
# type, the method, fit_gamma. The members of a set share all of them, and the last
# member is the one a new experiment starts from.
design_session(session::SessionContext) = session
function design_session(set::AnalysisSet)
    isempty(set.sessions) && throw(ArgumentError(
        "The analysis set is empty; add a session before analysing it."))
    return last(set.sessions)
end

"""
    add_session!(set::AnalysisSet, session::SessionContext) -> Symbol

Adds `session` to the end of `set` and returns what happened: `:added`; `:discarded`
when it was loaded from a discarded file ([`discard_session`](@ref)); `:duplicate`
when a member already has its id, so that no session is counted twice; or
`:incompatible` when it differs from the members in a fact the set compares
([`COMBINING_CHECKS`](@ref)). A refused session leaves the set unchanged, and the
warning names the reason.
"""
function add_session!(set::AnalysisSet, session::SessionContext)
    outcome, differing = admit_session!(set, session)
    outcome === :added ||
        @warn "Session $(session.id) of participant $(session.participant_id) is not " *
              "added to the set: $(refusal_reason(session, outcome, differing))."
    return outcome
end

# `add_session!` without the warning, for a caller that reports the outcome itself:
# the outcome, and the facts that differ — each with the stimulus fields that do, for
# `:stimulus` — when it is `:incompatible`
function admit_session!(set::AnalysisSet, session::SessionContext)
    outcome, differing = admission(set, session)
    outcome === :added && push!(set.sessions, session)
    return outcome, differing
end

function admission(set::AnalysisSet, session::SessionContext)
    none = Pair{Symbol, Vector{String}}[]
    is_discarded(session.save_path) && return :discarded, none
    any(member -> member.id == session.id, set.sessions) && return :duplicate, none
    isempty(set.sessions) && return :added, none
    differing = combining_differences(first(set.sessions), session, set.checks)
    return isempty(differing) ? :added : :incompatible, differing
end

refusal_reason(session::SessionContext, outcome::Symbol, differing) =
    outcome === :discarded ? "it was discarded ($(session.save_path))" :
    outcome === :duplicate ? "it is already in the set" :
    "it differs from the set in " *
    join((name === :stimulus ? "stimulus fields " * join(fields, ", ") : string(name)
          for (name, fields) in differing), ", ")

# The facts two sessions must share to be combined, always-compared ones first
function combining_facts(session::SessionContext, checks)
    task = session.task
    facts = Pair{Symbol, Any}[
        :stimulus_type => (type_name(session.stim_par), stimulus_name(session.stim_par)),
        :method => method_kind(session.method_instance),
        :independent_variables => session.ex_par.indep_var_names,
        :response_coding => task === nothing ? nothing : (task.options, task.positive_option),
        :fit_gamma => session.fit_gamma,
        :observer_kind => answered_by_program(session) ? :program : :person,
        # Each member is converted by its own conversion before its trials pool, so
        # the members must agree on the units, not on the arithmetic
        :units => Dict(variable => conversion.label
                       for (variable, conversion) in session.unit_conversions),
    ]
    :instructions in checks &&
        push!(facts, :instructions => task === nothing ? nothing : task.instructions)
    :observer in checks && push!(facts, :observer => observer_settings(session))
    :feedback in checks && push!(facts, :feedback => session.feedback)
    :timeout in checks && push!(facts, :timeout => session.timeout_s)
    :stimulus in checks && push!(facts, :stimulus => design_stimulus_fields(session))
    return facts
end

# The facts in which `b` differs from `a`, each with the stimulus fields that differ
# for `:stimulus`. Compared by value, not by type: a session read back from its file
# holds 0 where the same session in memory held 0.0
function combining_differences(a::SessionContext, b::SessionContext, checks)
    differing = Pair{Symbol, Vector{String}}[]
    for ((name, value_a), (_, value_b)) in zip(combining_facts(a, checks),
                                               combining_facts(b, checks))
        value_a == value_b && continue
        fields = name === :stimulus ?
            sort([string(field) for field in union(keys(value_a), keys(value_b))
                  if get(value_a, field, nothing) != get(value_b, field, nothing)]) :
            String[]
        push!(differing, name => fields)
    end
    return differing
end

# An interleaved run is named with its tracks in order, because the trials recorded
# under `:track` = k pool as one condition
method_kind(method::AbstractPsychoMethod) = type_name(method)
method_kind(method::Interleaved) =
    (type_name(method), map(method_kind, method.tracks)...)

# A run that was killed never stored its provenance, but its tags were stamped before
# its first trial (run_observer_experiment!)
answered_by_program(session::SessionContext) =
    !isempty(session.observer_metadata) || MODEL_OBSERVER_TAG in session.tags

# The request counts observer_provenance adds describe how a run went, not whom it asked
observer_settings(session::SessionContext) =
    filter(entry -> !(first(entry) in ("requests", "failed_requests")),
           session.observer_metadata)

function design_stimulus_fields(session::SessionContext)
    stim_par = session.stim_par
    set_during_run = union(session.ex_par.indep_var_names,
                           adjusted_fields(session.method_instance))
    return Dict{Symbol, Any}(field => parameter_value(stim_par, field)
                             for field in parameter_names(stim_par)
                             if !(field in set_during_run))
end

# ── Saved sets ───────────────────────────────────────────────────────────────

const ANALYSIS_SET_SCHEMA_VERSION = 1

# A set file is told from a session file by what it holds: a list of sessions
is_analysis_set_document(document) =
    document isa AbstractDict && haskey(document, "sessions")

"""
    save_analysis_set(set::AnalysisSet, path) -> String

Writes `set` to one JSON file: every member whole, in the form of its own checkpoint,
with the checks the set was combined under. The write is
atomic, and the absolute path is returned.

A saved set only grows. A file holding a set is replaced only by a set that still
holds all of its sessions — load it, add to it, save it back — and a file holding
anything else is never written over.
"""
function save_analysis_set(set::AnalysisSet, path::AbstractString)
    isempty(set.sessions) && throw(ArgumentError("An empty analysis set is not saved."))
    if isfile(path)
        existing = try
            read_json_document(path)
        catch
            nothing
        end
        is_analysis_set_document(existing) || throw(ArgumentError(
            "$path exists and does not hold an analysis set, and a set is never " *
            "written over another file. Save the set under another name."))
        members = Set(string(member.id) for member in set.sessions)
        dropped = [String(stored["id"]) for stored in existing["sessions"]
                   if !(String(stored["id"]) in members)]
        isempty(dropped) || throw(ArgumentError(
            "$path holds sessions this set does not ($(join(dropped, ", "))), and a " *
            "saved set only grows. Save the set under another name."))
    end
    document = Dict{String, Any}(
        "schema_version" => ANALYSIS_SET_SCHEMA_VERSION,
        "program_version" => program_version(),
        "saved" => Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"),
        "checks" => string.(set.checks),
        "sessions" => [session_to_dict(member) for member in set.sessions],
    )
    return atomic_write(abspath(path)) do io
        JSON3.write(io, document)
    end
end

"""
    load_analysis_set(path) -> AnalysisSet

Reads a set written by [`save_analysis_set`](@ref). Its members are admitted again,
under the checks the set was saved with rather than the local settings, and a file
whose sessions repeat or do not combine is refused.

A member read from a set is not tied to the set's file: correcting it or continuing
its run writes that session's own checkpoint, never the set.
"""
function load_analysis_set(path::AbstractString)
    document = read_json_document(path)
    is_analysis_set_document(document) || throw(ArgumentError(
        "$path holds a single session, not an analysis set; load it with load_session."))
    return analysis_set_from_document(document, path)
end

function analysis_set_from_document(document::AbstractDict, path::AbstractString)
    version = get(document, "schema_version", 1)
    version <= ANALYSIS_SET_SCHEMA_VERSION || error(
        "$path uses analysis-set schema version $version, but this PsychophysicsManager " *
        "understands up to $ANALYSIS_SET_SCHEMA_VERSION — upgrade the package to load it.")
    set = AnalysisSet(; checks = Symbol.(document["checks"]))
    for stored in document["sessions"]
        session = dict_to_session(stored)
        outcome, differing = admit_session!(set, session)
        outcome === :added || throw(ArgumentError(
            "$path does not hold a valid analysis set: session $(session.id) is " *
            "refused because $(refusal_reason(session, outcome, differing))."))
    end
    isempty(set.sessions) && throw(ArgumentError("$path holds an analysis set with no sessions."))
    return set
end
