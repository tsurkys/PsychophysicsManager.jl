# Scenario plans: sessions run back to back from one human-authored TOML file.
# The plan belongs to the operator and is never
# written to. What has been run is recorded beside it, in a state file only this
# code writes, and a plan is resumed from that file and the sessions it names.

"""
    ScenarioRow

One run of a scenario plan: the saved session it replicates (`source`), the file
the new session is written to (`destination`), the participant, the tags the
session gains beyond its template's, and the parameters that differ from the
template (`overrides`, keyed `"ex_par.<field>"` or `"stim_par.<field>"`). Paths
are absolute, resolved against the plan's directory when the plan is read.
"""
struct ScenarioRow
    id::String
    source::String
    destination::String
    participant_id::String
    tags::Vector{String}
    overrides::Dict{String, Any}
end

const SCENARIO_ROW_KEYS = ("id", "source", "destination", "participant_id", "tags",
                           "overrides")

"""
    load_scenario(plan_path) -> Vector{ScenarioRow}

Reads a scenario plan: a TOML file whose `[[run]]` tables are its runs, in the
order they are run.

```toml
# Oppel-Kundt for one participant: the plain figure, then the filled one
[[run]]
id = "p01-plain"
source = "templates/ok.json"             # relative to this file
destination = "sessions/P01_plain.json"
participant_id = "P01"
tags = ["plain"]

[run.overrides]
stim_par.StimConfig = "r t"
ex_par.repeats = 2

[[run]]
id = "p01-filled"
source = "templates/ok.json"
destination = "sessions/P01_filled.json"
participant_id = "P01"
tags = ["filled"]
```

`participant_id` defaults to `DEFAULT_PARTICIPANT_ID`, `tags` and `overrides` to
none. An override is a value, never an expression, and names a field of the
template's `ex_par` or `stim_par`; `"ex_par.repeats" = 2` means the same as the
dotted form above.

A plan that cannot mean what it says is refused: an unknown key (a misspelt
`participant_id` would otherwise measure the default participant), a blank or
repeated id, two runs writing one file, or a run writing over a template.
"""
function load_scenario(plan_path::AbstractString)
    isfile(plan_path) || throw(ArgumentError("Scenario plan not found: $plan_path"))
    plan = TOML.parsefile(plan_path)
    extra = sort(collect(setdiff(keys(plan), ["run"])))
    isempty(extra) || throw(ArgumentError(
        "The scenario plan $plan_path has unknown top-level keys $(join(extra, ", ")); " *
        "a plan lists its runs as [[run]] tables and nothing else."))
    runs = get(plan, "run", Any[])
    (runs isa AbstractVector && !isempty(runs) && all(run -> run isa AbstractDict, runs)) ||
        throw(ArgumentError("The scenario plan $plan_path lists no [[run]] tables."))

    base = dirname(abspath(plan_path))
    rows = [scenario_row(run, base, position) for (position, run) in enumerate(runs)]

    for (what, values) in (("id", [row.id for row in rows]),
                           ("destination", [row.destination for row in rows]))
        repeated = sort(unique(filter(value -> count(==(value), values) > 1, values)))
        isempty(repeated) || throw(ArgumentError(
            "The scenario plan $plan_path gives more than one run the $what " *
            "$(join(repr.(repeated), ", ")); every run needs its own."))
    end
    sources = Set(row.source for row in rows)
    for row in rows
        row.destination in sources && throw(ArgumentError(
            "Run \"$(row.id)\" would write its session over $(row.destination), which " *
            "the plan replicates."))
    end
    return rows
end

function scenario_row(run::AbstractDict, base::String, position::Int)
    extra = sort(collect(setdiff(keys(run), SCENARIO_ROW_KEYS)))
    isempty(extra) || throw(ArgumentError(
        "Run $position of the plan has unknown keys $(join(extra, ", ")); a run takes " *
        "$(join(SCENARIO_ROW_KEYS, ", "))."))
    id = plan_text(run, "id", "Run $position of the plan")
    context = "Run \"$id\""
    source = plan_path_value(run, "source", base, context)
    destination = plan_path_value(run, "destination", base, context)
    participant_id = haskey(run, "participant_id") ?
                     plan_text(run, "participant_id", context) : DEFAULT_PARTICIPANT_ID

    tags = get(run, "tags", String[])
    (tags isa AbstractVector && all(tag -> tag isa AbstractString, tags)) ||
        throw(ArgumentError("$context gives tags as $(repr(tags)); tags are a list of strings."))
    raw_overrides = get(run, "overrides", Dict{String, Any}())
    raw_overrides isa AbstractDict || throw(ArgumentError(
        "$context gives overrides as $(repr(raw_overrides)); overrides are a table."))
    overrides = flatten_overrides!(Dict{String, Any}(), raw_overrides, "", context)

    return ScenarioRow(id, source, destination, participant_id, String.(tags), overrides)
end

function plan_text(run::AbstractDict, key::String, context::String)
    value = get(run, key, nothing)
    (value isa AbstractString && !isempty(strip(value))) ||
        throw(ArgumentError("$context needs a non-empty `$key`."))
    return String(value)
end

plan_path_value(run::AbstractDict, key::String, base::String, context::String) =
    normpath(joinpath(base, expanduser(plan_text(run, key, context))))

# TOML reads `ex_par.repeats = 2` as a table inside a table and `"ex_par.repeats"
# = 2` as one key; both spellings arrive here as the same dotted key
function flatten_overrides!(out::Dict{String, Any}, table::AbstractDict, prefix::String,
                            context::String)
    for (key, value) in table
        name = isempty(prefix) ? String(key) : "$prefix.$key"
        if value isa AbstractDict
            flatten_overrides!(out, value, name, context)
            continue
        end
        parts = split(name, '.')
        (length(parts) == 2 && parts[1] in ("ex_par", "stim_par")) || throw(ArgumentError(
            "$context overrides `$name`; an override names a field of ex_par or stim_par, " *
            "as in `ex_par.repeats` or `stim_par.Ref`."))
        haskey(out, name) && throw(ArgumentError("$context overrides `$name` twice."))
        out[name] = value
    end
    return out
end

"""
    scenario_state_path(plan_path) -> String

The file beside a plan that records what has been run of it: `plan.toml` is
recorded in `plan.state.toml`. Only the steps of a run write it
([`prepare_next_run`](@ref), [`begin_scenario_run!`](@ref),
[`complete_scenario_run!`](@ref)), from [`run_scenario!`](@ref) or the dashboard.
"""
scenario_state_path(plan_path::AbstractString) =
    first(splitext(abspath(plan_path))) * ".state.toml"

const SCENARIO_ATTEMPT_KEYS = ("id", "session_id", "destination", "started")

function read_scenario_state(state_path::String, rows::Vector{ScenarioRow})
    isfile(state_path) || return Dict{String, Any}[]
    attempts = get(TOML.parsefile(state_path), "attempt", Any[])
    ids = Set(row.id for row in rows)
    for attempt in attempts
        (attempt isa AbstractDict && all(key -> haskey(attempt, key), SCENARIO_ATTEMPT_KEYS)) ||
            throw(ArgumentError(
                "The scenario state file $state_path is malformed: every attempt records " *
                "$(join(SCENARIO_ATTEMPT_KEYS, ", "))."))
        attempt["id"] in ids || throw(ArgumentError(
            "The scenario state file $state_path records run \"$(attempt["id"])\", which " *
            "the plan no longer has. A run renamed or removed after it started cannot be " *
            "matched to its session: restore the run, or move the state file and the " *
            "sessions it names away to start the plan again."))
    end
    return Vector{Dict{String, Any}}(attempts)
end

function latest_attempt(attempts::AbstractVector, id::String)
    index = findlast(attempt -> attempt["id"] == id, attempts)
    return index === nothing ? nothing : attempts[index]
end

function write_scenario_state(state_path::String, plan_path::AbstractString,
                              attempts::AbstractVector)
    return atomic_write(state_path) do io
        println(io, "# What has been run of the scenario plan $(basename(plan_path)), written by")
        println(io, "# PsychophysicsManager; the plan itself is never modified. Each attempt is one session")
        println(io, "# started for a run, and a run's last attempt says whether it is complete.")
        println(io)
        TOML.print(io, Dict("attempt" => attempts); sorted = true)
    end
end

# Where a run of the plan stands (the states `scenario_run_states` names), from its
# last attempt and its destination, read without loading the session
function run_state(row::ScenarioRow, attempt)
    if attempt !== nothing && haskey(attempt, "completed")
        return destination_discarded(row, attempt) ? :to_run : :complete
    end
    if attempt === nothing || attempt["destination"] != row.destination ||
       !isfile(row.destination)
        return isfile(row.destination) ? :occupied : :to_run
    end
    stored = read_json_document(row.destination)
    get(stored, "id", nothing) == attempt["session_id"] || return :occupied
    state = get(stored, "state", "")
    return state == string(FINISHED) ? :complete :
           state == string(ABORTED) ? :aborted : :to_continue
end

"""
    scenario_run_states(plan_path) -> Vector{Pair{ScenarioRow, Symbol}}

Where each run of a scenario plan stands, in the plan's order: `:complete`; `:to_run`
— never started, sent by the plan to another destination, or its session discarded
and so measured again; `:to_continue` — its session waits in its destination,
unfinished; `:aborted` — its session was stopped, and the run is measured again only
under another destination; `:occupied` — its destination holds a file the plan did not
start for it. Nothing is written.
"""
function scenario_run_states(plan_path::AbstractString)
    rows = load_scenario(plan_path)
    attempts = read_scenario_state(scenario_state_path(plan_path), rows)
    return [row => run_state(row, latest_attempt(attempts, row.id)) for row in rows]
end

# The measurement a run that is not complete needs: a new session (`:start`), or the
# one its destination holds (`:resume`). What prevents it is refused, naming the run.
function prepare_run(row::ScenarioRow, attempt, state::Symbol)
    state === :to_run && return (:start, replicate_for_run(row))
    state === :aborted && throw(ArgumentError(
        "Run \"$(row.id)\" was aborted, and its session stays in $(row.destination). " *
        "To measure the run again, give it another destination."))
    if state === :occupied
        attempt === nothing || attempt["destination"] != row.destination ?
            throw(ArgumentError(
                "Run \"$(row.id)\" would write $(row.destination), which already exists " *
                "and was not started by this scenario. Move the file away or give the run " *
                "another destination: a scenario never overwrites a session.")) :
            throw(ArgumentError(
                "$(row.destination) holds another session than the session " *
                "$(attempt["session_id"]) this scenario started for run \"$(row.id)\"."))
    end
    return (:resume, load_session(row.destination))
end

# The operator discarded the session a completed run measured: its destination
# is gone, and the discarded directory beside it holds that very session. Such a run
# is measured again; a destination merely moved away by hand is not.
function destination_discarded(row::ScenarioRow, attempt::AbstractDict)
    isfile(row.destination) && return false
    set_aside = joinpath(dirname(row.destination), DISCARDED_DIRECTORY,
                         basename(row.destination))
    isfile(set_aside) || return false
    stored = try
        read_json_document(set_aside)
    catch
        return false
    end
    return get(stored, "id", nothing) == attempt["session_id"]
end

# The stimulus program's backend is not loaded here: the run loads it when it starts,
# so a window can prepare a run without stopping for a graphics or audio package
function replicate_for_run(row::ScenarioRow)
    isfile(row.source) || throw(ArgumentError(
        "Run \"$(row.id)\" replicates $(row.source), which does not exist."))
    session = create_replicated_session(read_replicable_session(row.source),
                                        row.participant_id)
    apply_overrides!(session, row)
    foreach(tag -> tag in session.tags || push!(session.tags, tag), row.tags)
    return session
end

# The same path the dashboard's Parameters view takes (`set_parameters!`), so a run
# refuses what the view refuses; the refusal names the run
function apply_overrides!(session::SessionContext, row::ScenarioRow)
    try
        set_parameters!(session, row.overrides)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("Run \"$(row.id)\": $(err.msg)"))
    end
    return session
end

"""
    ScenarioRun

The next run of a scenario plan, prepared to be measured ([`prepare_next_run`](@ref)):
the plan, the run's row and its `position` among the plan's `total` runs, and its
`session` — a new one when `kind` is `:start`, its destination not yet written, or the
one its destination holds when `kind` is `:resume`.
"""
struct ScenarioRun
    plan::String
    row::ScenarioRow
    position::Int
    total::Int
    kind::Symbol
    session::SessionContext
end

"""
    prepare_next_run(plan_path) -> Union{ScenarioRun, Nothing}

Prepares the first run of a scenario plan that is not complete, or returns `nothing`
when every run is. Every run still to do is checked first, so a mistake in the last
run is found before anyone is measured: a refusal is an `ArgumentError` naming the
run. A run whose session finished without the state file being told (a crash between
its last checkpoint and that write) is recorded as complete here. The run's session
is not started, and nothing of it is written; [`begin_scenario_run!`](@ref) does that.
"""
function prepare_next_run(plan_path::AbstractString)
    rows = load_scenario(plan_path)
    state_path = scenario_state_path(plan_path)
    attempts = read_scenario_state(state_path, rows)
    next = nothing
    for (position, row) in enumerate(rows)
        attempt = latest_attempt(attempts, row.id)
        state = run_state(row, attempt)
        if state === :complete
            if !haskey(attempt, "completed")
                attempt["completed"] = now(UTC)
                write_scenario_state(state_path, plan_path, attempts)
            end
            continue
        end
        kind, session = prepare_run(row, attempt, state)
        next === nothing &&
            (next = ScenarioRun(abspath(plan_path), row, position, length(rows), kind, session))
    end
    return next
end

"""
    begin_scenario_run!(run::ScenarioRun) -> run

Gives a new run's session its place before its first trial: the attempt is recorded in
the plan's state file, then the session is written to the run's destination, where
every checkpoint of it lands. A run that continues its session needs neither. A
destination that has appeared since the run was prepared is refused.
"""
function begin_scenario_run!(run::ScenarioRun)
    run.kind === :start || return run
    row, session = run.row, run.session
    isfile(row.destination) && throw(ArgumentError(
        "Run \"$(row.id)\" would write $(row.destination), which already exists and was " *
        "not started by this scenario: a scenario never overwrites a session."))
    state_path = scenario_state_path(run.plan)
    attempts = read_scenario_state(state_path, load_scenario(run.plan))
    push!(attempts, Dict{String, Any}("id" => row.id, "session_id" => string(session.id),
                                      "destination" => row.destination,
                                      "started" => now(UTC)))
    write_scenario_state(state_path, run.plan, attempts)
    mkpath(dirname(row.destination))
    save_session_checkpoint(session, dirname(row.destination);
                            filename = basename(row.destination))
    return run
end

"""
    complete_scenario_run!(run::ScenarioRun) -> Bool

Records in the plan's state file that the run's session has finished. Returns whether
it was recorded: a session that has not finished is not.
"""
function complete_scenario_run!(run::ScenarioRun)
    run.session.state == FINISHED || return false
    state_path = scenario_state_path(run.plan)
    attempts = read_scenario_state(state_path, load_scenario(run.plan))
    attempt = latest_attempt(attempts, run.row.id)
    (attempt !== nothing && attempt["session_id"] == string(run.session.id)) || return false
    attempt["completed"] = now(UTC)
    write_scenario_state(state_path, run.plan, attempts)
    return true
end

"""
    run_scenario!(plan_path; pause_between = false, report = :trials,
                  accept_changed_stimulus = false) -> Vector{SessionContext}

Runs the runs of a scenario plan ([`load_scenario`](@ref)) that are not complete,
in the plan's order, and returns the sessions it ran.

Each run replicates its `source` for its participant, applies its overrides and
tags, and is written to its `destination` from before its first trial, so every
checkpoint of the run lands in that file and an interrupted run is continued from
it the next time the plan is run. What has been run is recorded in the state
file beside the plan ([`scenario_state_path`](@ref)); the plan is never written
to.

Every run still to do is checked before each run starts, so a mistake in the last
run is found before anyone is measured. The plan stops, leaving the remaining runs
for the next call, when a run ends without finishing (Ctrl+C, an error, `abort!`)
or when `pause_between` asks the operator before each further run and they answer
`q`. A scenario never overwrites a file: a destination that exists and was not
started by this plan is refused, and a run that was aborted is measured again only
under a new destination. A run whose session was discarded
([`discard_session`](@ref)) is measured again, finished or not, under the same
destination. `report` is the console level of each run
([`attach_console_reporter!`](@ref)). A run continued under a stimulus program other
than the one that presented it stops the plan ([`StimulusChangedError`](@ref)) unless
`accept_changed_stimulus` continues it deliberately.

The dashboard runs a plan from its Browse view, through the same steps:
[`prepare_next_run`](@ref), [`begin_scenario_run!`](@ref) and
[`complete_scenario_run!`](@ref).
"""
function run_scenario!(plan_path::AbstractString; pause_between::Bool = false,
                       report::Symbol = :trials, accept_changed_stimulus::Bool = false)
    ran = SessionContext[]
    while (run = prepare_next_run(plan_path)) !== nothing
        row, session = run.row, run.session
        isempty(ran) || !pause_between || confirm_next_run(row, run.position, run.total) ||
            break
        # A backend that cannot be loaded stops the plan before the run is recorded
        activate_engine_backend!(session.engine_name)
        begin_scenario_run!(run)

        report === :silent || println(
            "── Scenario $(basename(plan_path)) ─ run $(run.position) of $(run.total) ─ " *
            "$(row.id)$(run.kind === :resume ? " ─ resuming" : "") ─ $(row.destination)")
        run_restored!(session; report, accept_changed_stimulus)
        push!(ran, session)

        if session.state != FINISHED
            report === :silent || println(
                "── Scenario $(basename(plan_path)) stopped at run $(run.position), $(row.id): ",
                session.state == ABORTED ?
                "it was aborted; give it another destination to measure it again." :
                "running the plan again continues it.")
            break
        end
        complete_scenario_run!(run)
    end
    return ran
end

# The operator's confirmation between two runs: Enter starts the next
# run, and q or closed input stops the plan
function confirm_next_run(row::ScenarioRow, position::Int, total::Int)
    print("Next: run $position of $total, $(row.id). Press Enter to start it, or q to stop: ")
    eof(stdin) && return false
    return lowercase(strip(readline(stdin))) != "q"
end
