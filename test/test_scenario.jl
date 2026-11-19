using Dates, Logging, TOML

# A render-only engine a saved session can name: a scenario restores its engines
# from the registry, and these tests script the participant's answers
struct ScenarioProbeEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.initialize_engine(::Type{ScenarioProbeEngine}, ::AbstractStimulusParameters,
                            ::DisplayConfig) = ScenarioProbeEngine()
PsychophysicsManager.present_stimulus(::ScenarioProbeEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) = nothing
register_engine_type!(ScenarioProbeEngine)

# A saved, never started session to replicate: two conditions, one repeat
function write_scenario_template(path::String, engine_name::String)
    template = SessionContext("template",
                              ExperimentParameters("Scenario", :Diff, [-10.0, 10.0], 1),
                              MarkerLayout(Ref = 10.0), ConstantStimuli())
    template.engine_name = engine_name
    mkpath(dirname(path))
    return save_session_checkpoint(template, dirname(path); filename = basename(path))
end

scenario_plan_text(folder::String) = """
# Three runs of one template; this comment must survive every run
[[run]]
id = "first"
source = "templates/emulated.json"
destination = "$folder/first.json"
participant_id = "P01"

[[run]]
id = "second"
source = "templates/emulated.json"
destination = "$folder/second.json"
participant_id = "P02"
tags = ["practice"]

[run.overrides]
ex_par.repeats = 2
stim_par.Anchor = "center"
"stim_par.MarkerSize" = [2, 30]

[[run]]
id = "third"
source = "templates/emulated.json"
destination = "$folder/third.json"
"""

scenario_attempts(plan::String) =
    get(TOML.parsefile(scenario_state_path(plan)), "attempt", Any[])

@testset "Scenario plans" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"data\"\n")
            write_scenario_template(joinpath(dir, "templates", "emulated.json"),
                                    "EmulatorEngine")
            write_scenario_template(joinpath(dir, "templates", "scripted.json"),
                                    "ScenarioProbeEngine")

            @testset "A plan is read as written" begin
                plan = joinpath(dir, "plan.toml")
                write(plan, scenario_plan_text("sessions"))
                rows = load_scenario(plan)
                @test [row.id for row in rows] == ["first", "second", "third"]
                # Paths belong to the plan, not to the directory it is run from
                @test rows[1].source == joinpath(dir, "templates", "emulated.json")
                @test rows[1].destination == joinpath(dir, "sessions", "first.json")
                @test rows[3].participant_id == DEFAULT_PARTICIPANT_ID
                @test rows[2].tags == ["practice"]
                # Both TOML spellings of an override arrive as the same key
                @test rows[2].overrides == Dict("ex_par.repeats" => 2,
                                                "stim_par.Anchor" => "center",
                                                "stim_par.MarkerSize" => [2, 30])
                @test scenario_state_path(plan) == joinpath(dir, "plan.state.toml")
            end

            @testset "A plan that cannot mean what it says is refused" begin
                run_table(fields) = "[[run]]\n" * fields
                good = "source = \"templates/emulated.json\"\ndestination = \"bad/x.json\"\n"
                path = joinpath(dir, "bad.toml")
                for text in (
                        "",                                                     # no runs
                        "title = \"x\"\n" * run_table("id = \"a\"\n" * good),   # unknown top-level key
                        run_table("id = \" \"\n" * good),                       # blank id
                        run_table("id = \"a\"\npartcipant_id = \"P01\"\n" * good),
                        run_table("id = \"a\"\n" * good) *                      # repeated id
                            run_table("id = \"a\"\nsource = \"templates/emulated.json\"\n" *
                                      "destination = \"bad/y.json\"\n"),
                        run_table("id = \"a\"\n" * good) * run_table("id = \"b\"\n" * good),
                        run_table("id = \"a\"\nsource = \"templates/emulated.json\"\n" *
                                  "destination = \"templates/emulated.json\"\n"),
                        run_table("id = \"a\"\n" * good * "[run.overrides]\nmethod.trial_limit = 3\n"),
                    )
                    write(path, text)
                    @test_throws ArgumentError load_scenario(path)
                end
            end

            @testset "Every run is written to its destination, and the plan is left as it was" begin
                plan = joinpath(dir, "plan.toml")
                original = read(plan)
                sessions = run_scenario!(plan; report = :silent)
                @test length(sessions) == 3
                @test all(session -> session.state == FINISHED, sessions)

                saved = [load_session(joinpath(dir, "sessions", "$name.json"))
                         for name in ("first", "second", "third")]
                @test [session.id for session in saved] == [session.id for session in sessions]
                @test [session.participant_id for session in saved] ==
                      ["P01", "P02", DEFAULT_PARTICIPANT_ID]
                @test [length(session.history) for session in saved] == [2, 4, 2]
                @test saved[2].ex_par.repeats == 2
                @test saved[2].stim_par.Anchor === :center
                @test saved[2].stim_par.MarkerSize == (2, 30)
                @test "practice" in saved[2].tags && !("practice" in saved[1].tags)

                @test read(plan) == original
                @test [attempt["id"] for attempt in scenario_attempts(plan)] ==
                      ["first", "second", "third"]
                @test all(attempt -> haskey(attempt, "completed"), scenario_attempts(plan))
                # The destination was pinned before the run, so no checkpoint went
                # anywhere else, and no half-written file was left behind
                data = joinpath(dir, "data")
                @test !any(endswith(".json"), isdir(data) ? readdir(data) : String[])
                @test !any(endswith(".tmp"), readdir(dir))

                # A complete plan has nothing left to run
                @test isempty(run_scenario!(plan; report = :silent))
            end

            @testset "Stopped between runs, a plan continues with the runs not yet run" begin
                plan = joinpath(dir, "paused.toml")
                write(plan, scenario_plan_text("paused"))
                answers = joinpath(dir, "answers.txt")
                write(answers, "q\n")
                sessions = open(answers) do io
                    redirect_stdin(io) do
                        redirect_stdout(devnull) do
                            run_scenario!(plan; pause_between = true, report = :silent)
                        end
                    end
                end
                @test length(sessions) == 1
                @test [attempt["id"] for attempt in scenario_attempts(plan)] == ["first"]
                @test !isfile(joinpath(dir, "paused", "second.json"))

                first_id = load_session(joinpath(dir, "paused", "first.json")).id
                @test length(run_scenario!(plan; report = :silent)) == 2
                @test load_session(joinpath(dir, "paused", "first.json")).id == first_id
                @test all(attempt -> haskey(attempt, "completed"), scenario_attempts(plan))
            end

            @testset "A run that finished before its state was written is not measured again" begin
                plan = joinpath(dir, "crash.toml")
                write(plan, scenario_plan_text("crash"))
                run_scenario!(plan; report = :silent)
                # The state file as a crash after the run's last checkpoint leaves it
                attempts = scenario_attempts(plan)
                delete!(attempts[end], "completed")
                PsychophysicsManager.write_scenario_state(scenario_state_path(plan), plan, attempts)

                third = joinpath(dir, "crash", "third.json")
                before = read(third)
                @test isempty(run_scenario!(plan; report = :silent))
                @test read(third) == before
                @test haskey(scenario_attempts(plan)[end], "completed")
            end

            @testset "An interrupted run is continued from its checkpoint" begin
                plan = joinpath(dir, "interrupted.toml")
                write(plan, """
                    [[run]]
                    id = "only"
                    source = "templates/scripted.json"
                    destination = "interrupted/only.json"
                    """)
                destination = joinpath(dir, "interrupted", "only.json")

                # One of the two trials is answered, then the run fails
                failing_run() = with_response_source(ScriptedResponseSource([1])) do
                    run_scenario!(plan; report = :silent)
                end
                with_logger(NullLogger()) do
                    @test_throws ErrorException failing_run()
                end
                stopped = load_session(destination)
                @test stopped.state == PAUSED
                @test length(stopped.history) == 1
                paused_file = read(destination, String)

                # An aborted run is not continued: measuring it again is the
                # operator's decision, under another destination
                write(destination, replace(paused_file, "\"PAUSED\"" => "\"ABORTED\""))
                @test_throws "aborted" run_scenario!(plan; report = :silent)

                write(destination, paused_file)
                resumed = only(with_response_source(ScriptedResponseSource([1])) do
                    run_scenario!(plan; report = :silent)
                end)
                @test resumed.id == stopped.id
                @test resumed.state == FINISHED
                @test [trial.trial_index for trial in resumed.history] == [1, 2]
                @test haskey(only(scenario_attempts(plan)), "completed")
            end

            @testset "A run saved but never started is started from its file" begin
                plan = joinpath(dir, "ready.toml")
                write(plan, """
                    [[run]]
                    id = "only"
                    source = "templates/emulated.json"
                    destination = "ready/only.json"
                    """)
                row = only(load_scenario(plan))
                # As a crash right after the destination was pinned leaves it
                session = PsychophysicsManager.replicate_for_run(row)
                PsychophysicsManager.write_scenario_state(scenario_state_path(plan), plan,
                    [Dict{String, Any}("id" => "only", "session_id" => string(session.id),
                                       "destination" => row.destination,
                                       "started" => now(UTC))])
                mkpath(dirname(row.destination))
                save_session_checkpoint(session, dirname(row.destination);
                                        filename = basename(row.destination))

                ran = only(run_scenario!(plan; report = :silent))
                @test ran.id == session.id
                @test ran.state == FINISHED
            end

            @testset "A run whose session was discarded is measured again" begin
                plan = joinpath(dir, "discarded.toml")
                write(plan, """
                    [[run]]
                    id = "only"
                    source = "templates/emulated.json"
                    destination = "discarded_runs/only.json"
                    """)
                destination = joinpath(dir, "discarded_runs", "only.json")
                first_run = only(run_scenario!(plan; report = :silent))

                set_aside = discard_session(destination)
                again = only(run_scenario!(plan; report = :silent))
                @test again.id != first_run.id
                @test load_session(destination).id == again.id
                @test load_session(set_aside).id == first_run.id
                @test length(scenario_attempts(plan)) == 2

                # A destination moved away by hand is not a reason to measure again
                mv(destination, joinpath(dir, "discarded_runs", "archived.json"))
                @test isempty(run_scenario!(plan; report = :silent))
            end

            @testset "A scenario never overwrites a file it did not start" begin
                plan = joinpath(dir, "occupied.toml")
                write(plan, scenario_plan_text("occupied"))
                mkpath(joinpath(dir, "occupied"))
                write(joinpath(dir, "occupied", "third.json"), "{}")
                @test_throws ArgumentError run_scenario!(plan; report = :silent)
                # Refused before the first run started
                @test !isfile(joinpath(dir, "occupied", "first.json"))
                @test !isfile(scenario_state_path(plan))
            end

            @testset "An override the template cannot take is refused before anything runs" begin
                plan = joinpath(dir, "override.toml")
                for override in ("stim_par.NoSuchField = 1",   # no such field
                                 "ex_par.repeats = 2.5",       # not an integer
                                 "ex_par.repeats = 0")         # a design the type refuses
                    write(plan, scenario_plan_text("override") *
                                "\n[run.overrides]\n$override\n")
                    @test_throws ArgumentError run_scenario!(plan; report = :silent)
                    @test !isfile(joinpath(dir, "override", "first.json"))
                end
            end

            @testset "A state file that does not describe the plan is refused" begin
                plan = joinpath(dir, "ghost.toml")
                write(plan, scenario_plan_text("ghost"))
                write(scenario_state_path(plan), """
                    [[attempt]]
                    id = "renamed"
                    session_id = "00000000-0000-0000-0000-000000000000"
                    destination = '$(joinpath(dir, "ghost", "renamed.json"))'
                    started = 2026-09-14T12:00:00Z
                    """)
                @test_throws ArgumentError run_scenario!(plan; report = :silent)
                write(scenario_state_path(plan), "[[attempt]]\nid = \"first\"\n")
                @test_throws ArgumentError run_scenario!(plan; report = :silent)
            end
        end
    end
end
