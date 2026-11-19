using Logging

# ── Fixtures for the optional presentation-reporting contract ────────────────

# Render-only engine: reports nothing at all
struct RenderOnlyEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::RenderOnlyEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) = nothing

# An engine that reads its own device: answers from a list, and notes the shortest
# response time the Core asks it for before each presentation
mutable struct GuardRecordingEngine <: PsychophysicsManager.AbstractStimulusEngine
    guards::Vector{Float64}
    replies::Vector{Int}
end
PsychophysicsManager.set_min_response_time!(engine::GuardRecordingEngine, min_s) =
    push!(engine.guards, min_s)
PsychophysicsManager.present_stimulus(engine::GuardRecordingEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) =
    PresentationResult(response = popfirst!(engine.replies))

# Fully reporting engine with fixed timestamps
struct FullReportEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::FullReportEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) =
    PresentationResult(response = 1, onset = 123.0, timestamp_response = 124.5)

# A two-interval task: which interval held the target is a variable of the
# design and has no stimulus field, so the answer that is correct for a
# presentation can only be read from the trial's variables
mutable struct TwoIntervalStimulus <: AbstractStimulusParameters end
PsychophysicsManager.correct_answer(::TwoIntervalStimulus, vars::NamedTuple) =
    vars.target_interval == 1 ? 1 : -1
register_stimulus_type!(TwoIntervalStimulus)

# A task that has a correct answer above its lowest level only
mutable struct PartlyScoredStimulus <: AbstractStimulusParameters end
PsychophysicsManager.correct_answer(::PartlyScoredStimulus, vars::NamedTuple) =
    vars.level > 1 ? 1 : nothing

# A programmatic two-interval participant: it names the interval the target was
# actually in with a probability that rises with the level, so a staircase run
# against it has a convergence point derivable from that probability alone.
# Its own stream keeps the observer's noise independent of the session's draws.
struct TwoIntervalObserver <: AbstractResponseSource
    threshold::Float64
    slope::Float64
    rng::Random.Xoshiro
end

# Chance is 0.5 with two intervals to guess between, so the curve rises from
# there rather than from zero
proportion_correct_at(observer::TwoIntervalObserver, level::Real) =
    0.5 + 0.5 / (1 + exp(-observer.slope * (level - observer.threshold)))

function PsychophysicsManager.request_response(observer::TwoIntervalObserver, context::TrialContext)
    # The design may declare more variables (a track, say); the observer answers
    # about the level and the interval the target was in
    level, target = context.indep_var_vals[1], context.indep_var_vals[2]
    correct = target == 1 ? 1 : -1
    hit = rand(observer.rng) < proportion_correct_at(observer, level)
    return (hit ? correct : -correct, time())
end

# Records what the Core asked it to tell the participant
struct FeedbackRecordingEngine <: PsychophysicsManager.AbstractStimulusEngine
    reported::Vector{Bool}
end
FeedbackRecordingEngine() = FeedbackRecordingEngine(Bool[])
PsychophysicsManager.present_stimulus(::FeedbackRecordingEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) = nothing
PsychophysicsManager.present_feedback(engine::FeedbackRecordingEngine, correct::Bool) =
    push!(engine.reported, correct)

# Engines that break the presentation contract, one check each
struct BadFormEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::BadFormEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) = "seen"

struct BadClockEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::BadClockEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) =
    PresentationResult(response = 1, onset = 12.5)

struct MutatingEngine <: PsychophysicsManager.AbstractStimulusEngine end
function PsychophysicsManager.present_stimulus(::MutatingEngine, stim_par::AbstractStimulusParameters,
                                    ::AbstractVector{<:Number})
    stim_par.duration_ms += 1.0
    return 1
end

# An engine that owns its input device: it answers with the sentinel and keeps
# every response window the Core handed it
mutable struct TimingOutEngine <: PsychophysicsManager.AbstractStimulusEngine
    windows::Vector{Any}
end
TimingOutEngine() = TimingOutEngine(Any[])
PsychophysicsManager.present_stimulus(::TimingOutEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) = :timeout
PsychophysicsManager.set_response_timeout!(engine::TimingOutEngine, timeout_s) =
    push!(engine.windows, timeout_s)

# Answers +1 until its `at`-th presentation, which throws `error` instead: Ctrl+C
# (an InterruptException) or a crash, arriving while a trial is under way
mutable struct FailingEngine <: PsychophysicsManager.AbstractStimulusEngine
    at::Int
    error::Exception
    presented::Int
end
FailingEngine(at::Int, error::Exception) = FailingEngine(at, error, 0)
function PsychophysicsManager.present_stimulus(engine::FailingEngine, ::AbstractStimulusParameters,
                                    ::AbstractVector{<:Number})
    engine.presented += 1
    engine.presented == engine.at && throw(engine.error)
    return 1
end

# Ctrl+C while the participant is being told how a trial went: the method has
# already consumed the answer, and the trial is not yet recorded
struct InterruptedFeedbackEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::InterruptedFeedbackEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) = 1
PsychophysicsManager.present_feedback(::InterruptedFeedbackEngine, ::Bool) = throw(InterruptException())

# A method with a timeout policy of its own: it runs constant stimuli and
# answers an expired window with whatever it was configured to make of one.
# `:abort` is this fixture's way of asking for a session that stops.
mutable struct PolicyMethod <: AbstractPsychoMethod
    inner::ConstantStimuli
    policy::Any

    PolicyMethod(policy) = new(ConstantStimuli(), policy)
end
PsychophysicsManager.initialize_method!(m::PolicyMethod, ex_par::ExperimentParameters;
                             rng = Random.default_rng()) =
    initialize_method!(m.inner, ex_par; rng)
PsychophysicsManager.get_next_trial_params(m::PolicyMethod, session::SessionContext) =
    get_next_trial_params(m.inner, session)
PsychophysicsManager.update_method_state!(m::PolicyMethod, response::Real) =
    update_method_state!(m.inner, response)
PsychophysicsManager.is_trial_finished(m::PolicyMethod) = is_trial_finished(m.inner)
PsychophysicsManager.is_experiment_finished(m::PolicyMethod) = is_experiment_finished(m.inner)
PsychophysicsManager.get_trial_result(m::PolicyMethod, last_response::Real) =
    get_trial_result(m.inner, last_response)
PsychophysicsManager.timeout_result(m::PolicyMethod, session::SessionContext) =
    m.policy === :abort ? (abort!(session); :timeout) : m.policy

# An operator's correction arriving while the participant looks at a stimulus: the
# engine plays a dashboard button pressed during the presentation
mutable struct CorrectingEngine <: PsychophysicsManager.AbstractStimulusEngine
    session::SessionContext
    outcomes::Vector{Any}
end
function PsychophysicsManager.present_stimulus(engine::CorrectingEngine, ::AbstractStimulusParameters,
                                    ::AbstractVector{<:Number})
    push!(engine.outcomes, (undo_last_trial!(engine.session),
                            repeat_trial!(engine.session, 1)))
    return 1
end

# A participant who has not answered yet: each presentation waits on a channel the
# test feeds, and the conditions presented are kept
struct WaitingEngine <: PsychophysicsManager.AbstractStimulusEngine
    replies::Channel{Int}
    seen::Vector{Vector{Float64}}
    abandonable::Bool
end
WaitingEngine(abandonable::Bool = true) =
    WaitingEngine(Channel{Int}(1), Vector{Float64}[], abandonable)
function PsychophysicsManager.present_stimulus(engine::WaitingEngine, ::AbstractStimulusParameters,
                                    vals::AbstractVector{<:Number})
    push!(engine.seen, collect(Float64, vals))
    return take!(engine.replies)
end
PsychophysicsManager.can_abandon_presentation(engine::WaitingEngine) = engine.abandonable

# Starts a trial in a task of its own and returns once it waits for its answer
function start_waiting_trial(s::SessionContext, engine::WaitingEngine)
    task = @async run_next_trial!(s, engine)
    timedwait(() -> s.trial_run !== nothing, 5.0) === :ok || error("The trial did not start.")
    return task
end

# A staircase that keeps what the operator's trials told it
mutable struct AbsorbingStaircase <: AbstractPsychoMethod
    inner::Staircase
    absorbed::Vector{Any}
end
AbsorbingStaircase() = AbsorbingStaircase(Staircase(2), Any[])
PsychophysicsManager.initialize_method!(m::AbsorbingStaircase, ex_par::ExperimentParameters; kwargs...) =
    initialize_method!(m.inner, ex_par; kwargs...)
PsychophysicsManager.get_next_trial_params(m::AbsorbingStaircase, session::SessionContext) =
    get_next_trial_params(m.inner, session)
PsychophysicsManager.update_method_state!(m::AbsorbingStaircase, response::Real, correct) =
    update_method_state!(m.inner, response, correct)
PsychophysicsManager.is_trial_finished(m::AbsorbingStaircase) = is_trial_finished(m.inner)
PsychophysicsManager.is_experiment_finished(m::AbsorbingStaircase) = is_experiment_finished(m.inner)
PsychophysicsManager.absorb_operator_trial!(m::AbsorbingStaircase, vals, response, correct) =
    push!(m.absorbed, (vals, response, correct))
PsychophysicsManager.forget_operator_trial!(m::AbsorbingStaircase, ::Trial) = (pop!(m.absorbed); true)
register_method_type!(AbsorbingStaircase)

# Deterministic input comes from the exported ScriptedResponseSource

# What a session presented and was answered, trial by trial
presented(session) = [(t.indep_var_vals, t.start_value, t.response) for t in session.history]

# Runs a session to its end the way one interrupted after every trial is: stopped once
# the trial is recorded, read from its file again, and continued
function run_reloading_after_each_trial(session, source)
    with_response_source(source) do
        while session.state != FINISHED
            run_experiment!(session, RenderOnlyEngine(); report = :silent,
                            on_trial_end = s -> s.state == RUNNING && throw(InterruptException()))
            session = load_session(session.save_path)
        end
    end
    return session
end

@testset "Core loop (end-to-end with EmulatorEngine)" begin

    # Run everything inside a sandbox directory with its own settings.toml
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

            @testset "Constant stimuli session" begin
                ex_par = ExperimentParameters("EmulatedCS", :duration_ms, [100.0, 200.0], 2)
                s = SessionContext("TestUser", ex_par, BaseStimulusParameters(100.0),
                                   ConstantStimuli())
                trials_seen = Ref(0)
                run_experiment!(s, EmulatorEngine(); on_trial_end = _ -> trials_seen[] += 1)

                @test s.state == FINISHED
                @test trials_seen[] == 4   # the callback fires for the FINAL trial too
                @test s.engine_name == "EmulatorEngine"
                @test length(s.history) == 4
                @test all(t.response in (0, 1) for t in s.history)  # recoded binary
                @test all(t.timestamp_response >= t.timestamp_onset for t in s.history)
                # EmulatorEngine reports its own onsets
                @test all(t.onset_source == :engine for t in s.history)
                # The indep var was bound into the stimulus parameters by name
                @test s.stim_par.duration_ms in (100.0, 200.0)

                # Checkpoint landed in the configured data_dir
                files = readdir(joinpath(dir, "out"))
                @test length(files) == 1

                # The finished state reached the checkpoint on disk
                @test load_session(s.save_path).state == FINISHED

                # Undo reopens the session, re-queues the trial, and names it
                @test undo_last_trial!(s) == 4
                @test s.state == RUNNING
                @test count(t -> t.is_valid, s.history) == 3

                # The undo itself is checkpointed (state + history in sync)
                ondisk = load_session(s.save_path)
                @test ondisk.state == RUNNING
                @test count(t -> t.is_valid, ondisk.history) == 3

                run_experiment!(s, EmulatorEngine())
                @test s.state == FINISHED
                @test length(s.history) == 5
                @test count(t -> t.is_valid, s.history) == 4
            end

            @testset "Adjustment session" begin
                ex_par = ExperimentParameters("EmulatedAdj", :contrast, [0.2, 0.8], 1)
                m = Adjustment(dep_var = :duration_ms,
                                     dep_range = 100.0:50.0:500.0,
                                     init_interval = (200.0, 400.0))
                s = SessionContext("TestUser2", ex_par, BaseStimulusParameters(300.0), m)
                run_experiment!(s, EmulatorEngine())

                @test s.state == FINISHED
                @test length(s.history) == 2
                # Recorded responses are confirmed values from the dependent range
                @test all(t.response in m.dep_range for t in s.history)
                # One recorded init value per trial, all within the init interval
                @test length(m.init_vals) == 2
                @test all(200.0 <= v <= 400.0 for v in m.init_vals)
                # Each trial records where its adjustment began
                @test [t.start_value for t in s.history] == m.init_vals
            end

            @testset "A press too soon after a trial's onset does not answer it" begin
                mktempdir() do dir
                    cd(dir) do
                        write("settings.toml",
                              "[storage]\ndata_dir = \"out\"\n[input]\nmin_response_s = 0.3\n")
                        ex_par = ExperimentParameters("Guarded", :duration_ms, [100.0], 1)
                        s = SessionContext("G", ex_par, BaseStimulusParameters(100.0),
                                           ConstantStimuli())
                        start_session!(s)
                        @test s.min_response_s == 0.3
                        keys = PsychophysicsManager.ChannelResponseSource(
                            Channel{Tuple{Int, Float64}}(1))
                        # The second press of a double press waits in the channel
                        put!(keys.channel, (1, time()))
                        @async (sleep(0.5); put!(keys.channel, (-1, time())))
                        with_response_source(keys) do
                            run_next_trial!(s, RenderOnlyEngine())
                        end
                        trial = only(s.history)
                        @test trial.timestamp_response - trial.timestamp_onset >= 0.3
                        @test load_session(s.save_path).min_response_s == 0.3

                        # An engine reading its own device is told for a trial's first
                        # presentation only: the adjustment's steps follow a held key
                        adjusted = SessionContext("G", ex_par, BaseStimulusParameters(100.0),
                                                  Adjustment(dep_var = :duration_ms,
                                                                   dep_range = 0.0:10.0:200.0))
                        start_session!(adjusted)
                        engine = GuardRecordingEngine(Float64[], [1, 1, -1, 0])
                        run_next_trial!(adjusted, engine)
                        @test engine.guards == [0.3, 0.0, 0.0, 0.0]

                        # Settings that ask for a negative time are refused at the start
                        write("settings.toml", "[input]\nmin_response_s = -1\n")
                        refused = SessionContext("G", ex_par, BaseStimulusParameters(100.0),
                                                 ConstantStimuli())
                        @test_throws ArgumentError start_session!(refused)
                        @test refused.state == READY
                    end
                end
            end

            @testset "Operator comments" begin
                ex_par = ExperimentParameters("Commented", :duration_ms, [100.0], 1)
                s = SessionContext("P1", ex_par, BaseStimulusParameters(100.0),
                                   ConstantStimuli())
                events = Symbol[]
                on_session_event!((_, event) -> push!(events, event), s)
                @test_throws ArgumentError add_comment!(s, "   ")
                @test_throws ArgumentError add_comment!(s, "About nothing"; trial = 1)
                # A session not yet saved keeps its comments until its first checkpoint
                comment = add_comment!(s, "  Lights dimmed \n")
                @test comment.text == "Lights dimmed" && comment.trial === nothing
                @test events == [:comment_added]
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test load_session(s.save_path).comments[1].text == "Lights dimmed"
                # After the session, at once, about a trial
                add_comment!(s, "Answered too fast"; trial = 1)
                @test [c.trial for c in load_session(s.save_path).comments] == [nothing, 1]
                # Mid-trial the trial's own checkpoint writes it, not the comment
                s.trial_under_way = true
                add_comment!(s, "Coughed")
                @test length(load_session(s.save_path).comments) == 2
                s.trial_under_way = false
                @test length(s.comments) == 3
                # A replication starts with none
                @test isempty(create_replicated_session(s, "P2").comments)
            end

            @testset "Interrupted session resumes from checkpoint" begin
                ex_par = ExperimentParameters("Resumable", :duration_ms, [100.0, 200.0], 2)
                s = SessionContext("Resumer", ex_par, BaseStimulusParameters(100.0),
                                   ConstantStimuli())
                start_session!(s)
                run_next_trial!(s, EmulatorEngine())
                run_next_trial!(s, EmulatorEngine())
                @test s.state == RUNNING
                @test length(s.history) == 2

                # "Crash": reload from the checkpoint written after trial 2
                path = s.save_path
                loaded = load_session(path)
                @test loaded.state == RUNNING
                @test length(loaded.history) == 2
                @test loaded.current_trial_idx == 3   # index of the NEXT trial
                @test loaded.method_instance.current_idx == s.method_instance.current_idx
                # Continuing must not re-randomize: the realized order is part
                # of the saved method state, and resuming does not re-run
                # start_session!
                @test loaded.method_instance.order == s.method_instance.order
                @test loaded.rng_seed == s.rng_seed

                # Continue to the end: no duplicated trial indices
                run_experiment!(loaded, EmulatorEngine())
                @test loaded.state == FINISHED
                @test length(loaded.history) == 4
                @test [t.trial_index for t in loaded.history] == [1, 2, 3, 4]
                @test loaded.save_path == abspath(path)   # same file kept updated

                # The final checkpoint carries FINISHED; loading and re-running
                # a finished session is a safe no-op
                refin = load_session(path)
                @test refin.state == FINISHED
                run_experiment!(refin, EmulatorEngine())
                @test length(refin.history) == 4
            end

            @testset "Ctrl+C leaves the session paused and continuable" begin
                ex_par = ExperimentParameters("Interrupted", :duration_ms,
                                              [100.0, 200.0], 2)
                s = SessionContext("Int", ex_par, BaseStimulusParameters(100.0),
                                   ConstantStimuli())
                out_path = joinpath(dir, "interrupted_out.txt")
                returned = open(out_path, "w") do io
                    redirect_stdout(io) do
                        run_experiment!(s, FailingEngine(3, InterruptException());
                                        report = :session)
                    end
                end
                # Ctrl+C is not an error the caller has to handle
                @test returned === s
                @test s.state == PAUSED
                @test length(s.history) == 2
                @test isempty(s.listeners)
                output = read(out_path, String)
                @test occursin("Interrupted ─ 2 trials", output)
                @test occursin("load_session(", output)

                on_disk = load_session(s.save_path)
                @test on_disk.state == PAUSED
                # The trial the interruption cut short is still to be presented
                @test on_disk.method_instance.current_idx == 3

                # Continued from the file: the banner says where, and no index
                # is used twice. (Another engine takes over from the failing one,
                # which is a change of stimulus program, accepted.)
                resumed_path = joinpath(dir, "resumed_out.txt")
                open(resumed_path, "w") do io
                    redirect_stdout(io) do
                        run_experiment!(on_disk, EmulatorEngine(); report = :session,
                                        accept_changed_stimulus = true)
                    end
                end
                @test occursin("resuming after trial 2", read(resumed_path, String))
                @test on_disk.state == FINISHED
                @test [t.trial_index for t in on_disk.history] == [1, 2, 3, 4]
                @test sort([t.indep_var_vals[1] for t in on_disk.history]) ==
                      [100.0, 100.0, 200.0, 200.0]
            end

            @testset "A crash leaves the session paused, and the error propagates" begin
                ex_par = ExperimentParameters("Crashed", :duration_ms, [100.0, 200.0], 2)
                s = SessionContext("Crash", ex_par, BaseStimulusParameters(100.0),
                                   ConstantStimuli())
                with_logger(NullLogger()) do
                    @test_throws ErrorException run_experiment!(
                        s, FailingEngine(2, ErrorException("worker gone")); report = :silent)
                end
                @test s.state == PAUSED
                @test load_session(s.save_path).state == PAUSED

                # Continued in the same process, from the paused object, by an engine
                # taking over from the failing one
                run_experiment!(s, EmulatorEngine(); report = :silent,
                                accept_changed_stimulus = true)
                @test s.state == FINISHED
                @test [t.trial_index for t in s.history] == [1, 2, 3, 4]
                @test load_session(s.save_path).state == FINISHED
            end

            @testset "A trial is recorded whole or not at all" begin
                # The method consumed the answer before the feedback was cut
                # short; the planned trial must not be lost with it
                ex_par = ExperimentParameters("Feedback cut", :target_interval,
                                              [1.0, 2.0], 1)
                s = SessionContext("FB", ex_par, TwoIntervalStimulus(),
                                   ConstantStimuli())
                set_feedback!(s, true)
                method = s.method_instance
                run_experiment!(s, InterruptedFeedbackEngine(); report = :silent)
                @test s.state == PAUSED
                @test isempty(s.history)
                @test method.current_idx == 1
                @test s.method_instance === method   # restored in place
                run_experiment!(s, FullReportEngine(); report = :silent,
                                accept_changed_stimulus = true)
                @test s.state == FINISHED
                @test sort([t.indep_var_vals[1] for t in s.history]) == [1.0, 2.0]

                # An adjustment cut short after two steps starts again from its
                # starting value, drawn again as it was the first time
                design = ExperimentParameters("Adj cut", :x, [1.0], 1)
                adjustment() = Adjustment(dep_var = :duration_ms,
                                                dep_range = 1.0:9.0,
                                                init_interval = (1.0, 9.0))
                m = adjustment()
                cut = SessionContext("A", design, BaseStimulusParameters(5.0), m;
                                     rng_seed = 7)
                with_logger(NullLogger()) do
                    # The script runs out after two steps: the source fails
                    @test_throws ErrorException with_response_source(
                        ScriptedResponseSource([1, 1])) do
                        run_experiment!(cut, RenderOnlyEngine(); report = :silent)
                    end
                end
                @test cut.state == PAUSED
                @test isempty(m.init_vals) && m.needs_init
                with_response_source(ScriptedResponseSource([0])) do
                    run_experiment!(cut, RenderOnlyEngine(); report = :silent)
                end

                twin = SessionContext("A", design, BaseStimulusParameters(5.0),
                                      adjustment(); rng_seed = 7)
                with_response_source(ScriptedResponseSource([0])) do
                    run_experiment!(twin, RenderOnlyEngine(); report = :silent)
                end
                @test length(m.init_vals) == length(cut.history) == 1
                @test only(cut.history).response == only(twin.history).response ==
                      only(m.init_vals)
            end

            @testset "Only abort! ends a session for good" begin
                ex_par = ExperimentParameters("Aborted", :x, [1.0, 2.0], 1)
                s = SessionContext(ex_par, BaseStimulusParameters(1.0),
                                   ConstantStimuli())
                start_session!(s)
                run_next_trial!(s, EmulatorEngine())
                abort!(s)
                loaded = load_session(s.save_path)
                @test loaded.state == ABORTED
                run_experiment!(loaded, EmulatorEngine(); report = :silent)
                @test loaded.state == ABORTED
                @test length(loaded.history) == 1
            end

            @testset "Default participant for rapid setup" begin
                ex_par = ExperimentParameters("Quick", :x, [1.0], 1)
                s = SessionContext(ex_par, BaseStimulusParameters(1.0),
                                   ConstantStimuli())
                @test s.participant_id == DEFAULT_PARTICIPANT_ID == "test_user"
                @test PEM === PsychophysicsManager
            end

            @testset "Environment snapshot" begin
                ex_par = ExperimentParameters("Machine", :x, [1.0], 1)
                s = SessionContext(ex_par, BaseStimulusParameters(1.0),
                                   ConstantStimuli())
                @test isempty(s.environment)   # taken at the start, not at setup

                start_session!(s)
                @test issubset(["julia_version", "os", "hostname", "psychophysics_manager_version"],
                               keys(s.environment))
                @test s.environment["julia_version"] == string(VERSION)
                @test s.environment["psychophysics_manager_version"] == s.program_version
                # Nothing was presented, so nothing describes the display
                @test !haskey(s.environment, "display_resolution")

                # An engine that knows its viewing conditions reports them
                shown = SessionContext(ex_par, MarkerLayout(),
                                       ConstantStimuli())
                start_session!(shown, OffscreenVisualEngine(640, 480))
                @test shown.environment["display_resolution"] == "640x480"
            end

            @testset "Console reporter" begin
                ex_par = ExperimentParameters("ReporterDemo", :x, [1.0, 2.0], 1)
                s = SessionContext(ex_par, BaseStimulusParameters(1.0),
                                   ConstantStimuli())
                out_path = joinpath(dir, "reporter_out.txt")
                open(out_path, "w") do io
                    redirect_stdout(io) do
                        run_experiment!(s, EmulatorEngine())
                    end
                end
                output = read(out_path, String)
                @test occursin("ReporterDemo ─ test_user ─ ConstantStimuli ─ planned 2 trials", output)
                # The seed is announced, or the run could not be repeated
                @test occursin("seed $(s.rng_seed)", output)
                @test occursin("[1/2]", output) && occursin("[2/2]", output)
                @test occursin("x=", output)          # variables named generically
                @test occursin("FINISHED ─ 2 trials", output)
                @test occursin("saved:", output)
                @test isempty(s.listeners)            # reporter detached after the run

                # :silent runs produce no console output at all
                s2 = SessionContext(ex_par, BaseStimulusParameters(1.0),
                                    ConstantStimuli())
                silent_path = joinpath(dir, "reporter_silent.txt")
                open(silent_path, "w") do io
                    redirect_stdout(io) do
                        run_experiment!(s2, EmulatorEngine(); report = :silent)
                    end
                end
                @test isempty(strip(read(silent_path, String)))

                # Unknown levels are rejected up front
                s3 = SessionContext(ex_par, BaseStimulusParameters(1.0),
                                    ConstantStimuli())
                @test_throws ArgumentError run_experiment!(s3, EmulatorEngine();
                                                           report = :loud)
            end

            @testset "Intra-trial :response_registered events" begin
                ex_par = ExperimentParameters("Steps", :c, [0.5], 1)
                m = Adjustment(dep_var = :duration_ms,
                                     dep_range = 1.0:5.0,
                                     init_interval = (3.0, 3.0))
                s = SessionContext(ex_par, BaseStimulusParameters(3.0), m)
                steps = Ref(0)
                on_session_event!(s) do sess, event
                    event == :response_registered && (steps[] += 1)
                end
                start_session!(s)

                with_response_source(ScriptedResponseSource([1, -1, 0])) do
                    run_next_trial!(s, RenderOnlyEngine())
                end
                # Two intra-trial steps (+1, -1); the confirming 0 is announced
                # by :trial_completed instead
                @test steps[] == 2
                @test length(s.history) == 1
                # The reporter's :steps level reads the current adjusted value
                @test occursin("duration_ms", describe_method_state(m))
            end

            @testset "Optional presentation reporting" begin
                # A fully reporting engine: its timestamps land in the Trial
                ex_par = ExperimentParameters("Full", :x, [1.0], 1)
                s = SessionContext("T", ex_par, BaseStimulusParameters(1.0),
                                   ConstantStimuli())
                start_session!(s)
                run_next_trial!(s, FullReportEngine())
                @test s.history[1].timestamp_onset == 123.0
                @test s.history[1].timestamp_response == 124.5
                @test s.history[1].onset_source == :engine

                # A render-only engine: the response comes from the active
                # response source, the onset is a core-side estimate
                with_response_source(ScriptedResponseSource([1, -1])) do
                    ex2 = ExperimentParameters("RO", :x, [1.0, 2.0], 1)
                    s2 = SessionContext("T2", ex2, BaseStimulusParameters(1.0),
                                        ConstantStimuli())
                    run_experiment!(s2, RenderOnlyEngine())
                    @test s2.state == FINISHED
                    @test length(s2.history) == 2
                    @test all(t.onset_source == :estimated for t in s2.history)
                    @test sort([t.response for t in s2.history]) == [0, 1]  # recoded 1/-1
                end
            end

            @testset "Correctness scoring" begin
                ex_par = ExperimentParameters("2IFC", :target_interval, [1.0, 2.0], 2)

                # Both codes must score: an observer always answering "first"
                # is right on the trials whose target was in the first
                # interval, one always answering "second" on the others
                for (answer, scored_target) in ((1, 1.0), (-1, 2.0))
                    s = SessionContext("Scored", ex_par, TwoIntervalStimulus(),
                                       ConstantStimuli())
                    with_response_source(ScriptedResponseSource(fill(answer, 4))) do
                        run_experiment!(s, RenderOnlyEngine(); report = :silent)
                    end
                    @test length(s.history) == 4
                    @test all(t.correct == (t.indep_var_vals[1] == scored_target)
                              for t in s.history)
                    @test count(t -> t.correct, s.history) == 2
                end

                # A stimulus that defines no correct answer is not scored, and
                # its session runs exactly as before
                plain_par = ExperimentParameters("Unscored", :duration_ms,
                                                 [100.0, 200.0], 2)
                plain = SessionContext("Unscored", plain_par,
                                       BaseStimulusParameters(100.0),
                                       ConstantStimuli())
                run_experiment!(plain, EmulatorEngine(); report = :silent)
                @test plain.state == FINISHED
                @test length(plain.history) == 4
                @test all(t.correct === nothing for t in plain.history)
                @test all(t.response in (0, 1) for t in plain.history)

                # A response that is not an answer is unscored rather than
                # wrong: the repeat request the participant made is a question,
                # not a mistake
                repeated = SessionContext("Repeat",
                                          ExperimentParameters("2IFC", :target_interval,
                                                               [1.0], 1),
                                          TwoIntervalStimulus(), ConstantStimuli())
                with_response_source(ScriptedResponseSource([0, 1])) do
                    run_experiment!(repeated, RenderOnlyEngine(); report = :silent)
                end
                @test only(repeated.history).correct === true
            end

            @testset "Feedback is a declared session setting" begin
                ex_par = ExperimentParameters("Feedback", :target_interval,
                                              [1.0, 2.0], 2)
                announced(session) = begin
                    engine = FeedbackRecordingEngine()
                    with_response_source(ScriptedResponseSource(fill(1, 4))) do
                        run_experiment!(session, engine; report = :silent)
                    end
                    return engine.reported
                end

                on = SessionContext("F", ex_par, TwoIntervalStimulus(),
                                    ConstantStimuli())
                set_feedback!(on, true)
                # Answering "first" every time is right on half the trials
                @test sort(announced(on)) == [false, false, true, true]

                off = SessionContext("F", ex_par, TwoIntervalStimulus(),
                                     ConstantStimuli())
                @test isempty(announced(off))

                # A trial the task did not score has no outcome to announce
                unscored = SessionContext("F",
                                          ExperimentParameters("Plain", :x, [1.0, 2.0], 2),
                                          BaseStimulusParameters(10.0),
                                          ConstantStimuli())
                set_feedback!(unscored, true)
                @test isempty(announced(unscored))
            end

            @testset "The trial line carries the scored outcome" begin
                marks(session, source, engine, filename) = begin
                    path = joinpath(dir, filename)
                    open(path, "w") do io
                        redirect_stdout(io) do
                            with_response_source(source) do
                                run_experiment!(session, engine)
                            end
                        end
                    end
                    return read(path, String)
                end

                scored = SessionContext("M",
                                        ExperimentParameters("Marks", :target_interval,
                                                             [1.0, 2.0], 1),
                                        TwoIntervalStimulus(), ConstantStimuli())
                output = marks(scored, ScriptedResponseSource([1, 1]), RenderOnlyEngine(),
                               "marks_scored.txt")
                @test occursin("✓", output) && occursin("✗", output)

                # An unscored trial gets no mark, so an operator never reads a
                # missing one as a wrong answer
                plain = SessionContext("M",
                                       ExperimentParameters("PlainMarks", :x, [1.0, 2.0], 1),
                                       BaseStimulusParameters(1.0), ConstantStimuli())
                plain_output = marks(plain, ScriptedResponseSource([1, -1]),
                                     RenderOnlyEngine(), "marks_plain.txt")
                @test !occursin("✓", plain_output) && !occursin("✗", plain_output)
            end

            @testset "A staircase on a task without a correct answer steps on its direction" begin
                ex_par = ExperimentParameters("Unscored", :level, [1.0, 2.0, 3.0], 5)
                s = SessionContext("S", ex_par, BaseStimulusParameters(100.0),
                                   Staircase())
                with_response_source(ScriptedResponseSource([1, 1, -1, 1, -1])) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end
                # An answer coded +1 steps down and the other up, one at a time, so
                # the run converges on the level answered +1 half the time
                @test [only(t.indep_var_vals) for t in s.history] == [3.0, 2.0, 1.0, 2.0, 1.0]
                # Recorded 1/0, so that a level's mean response is a proportion
                @test [t.response for t in s.history] == [1, 1, 0, 1, 0]
                @test all(t -> t.correct === nothing, s.history)
                @test s.method_instance.n_down === nothing

                # A trial the operator asks for is recorded in the same coding
                @test present_condition!(s, [2.0])
                with_response_source(ScriptedResponseSource([-1])) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end
                @test last(s.history).origin === :operator && last(s.history).response == 0

                # A task that scores some conditions only is neither, and refused
                partly = SessionContext("P", ex_par, PartlyScoredStimulus(),
                                        ConstantStimuli())
                @test_throws ArgumentError set_parameters!(partly,
                                                           Dict("method" => "Staircase"))
                @test partly.method_instance isa ConstantStimuli
                # A script that starts one is refused too
                @test task_scoring(partly.stim_par, ex_par) === :some
                scripted = SessionContext("P", ex_par, PartlyScoredStimulus(),
                                          Staircase())
                @test_throws ArgumentError start_session!(scripted)
                @test scripted.state == READY
            end

            @testset "A staircase repeat request costs no trial" begin
                ex_par = ExperimentParameters("Repeat", [:level, :target_interval],
                                              [[1.0, 2.0], [1.0, 2.0]], 1)
                s = SessionContext("R", ex_par, TwoIntervalStimulus(),
                                   Staircase(2; trial_limit = 2))
                with_response_source(ScriptedResponseSource([0, 0, 1, 1])) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end
                # Four presentations, two of them re-presentations of the same
                # stimulus, and two recorded trials
                @test length(s.history) == 2
                @test s.state == FINISHED
            end

            @testset "A staircase spends a trial on a missing response" begin
                # A model observer whose backend keeps failing must not be
                # re-presented the same trial forever: the run ends with the
                # trials recorded and invalidatable, not with an endless loop
                ex_par = ExperimentParameters("Missing", [:level, :target_interval],
                                              [[1.0, 2.0], [1.0, 2.0]], 1)
                s = SessionContext("N", ex_par, TwoIntervalStimulus(),
                                   Staircase(2; trial_limit = 3))
                with_response_source(ScriptedResponseSource(fill(MISSING_RESPONSE, 3))) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end
                @test s.state == FINISHED
                @test length(s.history) == 3
                @test all(isnan(t.response) for t in s.history)
                @test all(t.correct === nothing for t in s.history)
                # The level never moved: nothing was learned from any of them
                @test length(unique(t.indep_var_vals[1] for t in s.history)) == 1

                # A missing response reaches the checkpoint, and comes back
                @test all(isnan(t.response) for t in load_session(s.save_path).history)
                @test mark_outlier!(s, 1)
            end

            @testset "Interleaved tracks run side by side" begin
                fine = [0.2, 0.4, 0.6, 0.8, 1.0]
                coarse = [0.0, 0.5, 1.0, 1.5]
                ex_par = ExperimentParameters("Interleaved",
                                              [:level, :target_interval, :track],
                                              Any[fine, [1.0, 2.0], 1:2], 1)
                tracks = [Staircase(2; levels = fine, trial_limit = 12),
                          Staircase(2; levels = coarse, trial_limit = 8)]
                s = SessionContext("I", ex_par, TwoIntervalStimulus(),
                                   Interleaved(tracks); rng_seed = 7)
                observer = TwoIntervalObserver(0.5, 6.0, Random.Xoshiro(4))
                with_response_source(observer) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end

                @test s.state == FINISHED
                # Every track runs its own trials, and the run ends with the last
                @test length(s.history) == 20
                of_track(k) = [t for t in s.history if t.indep_var_vals[3] == k]
                @test length(of_track(1.0)) == 12
                @test length(of_track(2.0)) == 8

                # Each stayed on the levels it was given, which is what
                # interleaving two measurements is for
                @test all(t -> t.indep_var_vals[1] in fine, of_track(1.0))
                @test all(t -> t.indep_var_vals[1] in coarse, of_track(2.0))
                # Both were scored: a track measures the same task
                @test all(t -> t.correct !== nothing, s.history)

                # The track is a variable like any other, so the summary splits
                # on it without anything downstream knowing about tracks
                @test all(p -> length(p.vals) == 3, get_aggregated_data(s))
                mktemp() do path, io
                    close(io)
                    export_session(s, path)
                    @test occursin("track", first(
                        filter(l -> startswith(l, "trial_index"), readlines(path))))
                end
            end

            @testset "An interleaved run resumes where it stood" begin
                ex_par = ExperimentParameters("Resumable tracks",
                                              [:level, :target_interval, :track],
                                              Any[[1.0, 2.0], [1.0, 2.0], 1:2], 1)
                tracks = [Staircase(2; levels = [1.0, 2.0], trial_limit = 3),
                          Staircase(2; levels = [8.0, 9.0], trial_limit = 3)]
                s = SessionContext("R", ex_par, TwoIntervalStimulus(),
                                   Interleaved(tracks; order = :round_robin);
                                   rng_seed = 11)
                start_session!(s)
                with_response_source(ScriptedResponseSource([1, 1, 1])) do
                    for _ in 1:3
                        run_next_trial!(s, RenderOnlyEngine())
                    end
                end

                loaded = load_session(s.save_path)
                composite = loaded.method_instance
                # The tracks come back as themselves, with their own levels and
                # their own progress, and the run continues from that track
                @test length(composite.tracks) == 2
                @test composite.tracks[2].available_levels == [8.0, 9.0]
                @test [t.current_trial for t in composite.tracks] ==
                      [t.current_trial for t in tracks]
                @test composite.track_position == 3

                with_response_source(ScriptedResponseSource(fill(1, 5))) do
                    run_experiment!(loaded, RenderOnlyEngine(); report = :silent)
                end
                @test loaded.state == FINISHED
                @test length(loaded.history) == 6
                @test count(t -> t.indep_var_vals[3] == 2.0, loaded.history) == 3
            end

            @testset "A session continued from its file draws on from where it stopped" begin
                # Every random choice a core method makes during a run: the further
                # variable of a staircase, the order of interleaved tracks, the
                # starting values of an adjustment
                levels = collect(0.1:0.1:1.0)
                two_interval = ExperimentParameters("Stream", [:level, :target_interval],
                                                    Any[levels, [1.0, 2.0]], 1)
                with_tracks = ExperimentParameters("Stream tracks",
                                                   [:level, :target_interval, :track],
                                                   Any[levels, [1.0, 2.0], 1:2], 1)
                adjusted = ExperimentParameters("Stream adjustment", :contrast,
                                                [0.2, 0.5, 0.8], 4)
                observer() = TwoIntervalObserver(0.5, 6.0, Random.Xoshiro(4))
                cases = [
                    (() -> SessionContext("S", two_interval, TwoIntervalStimulus(),
                                          Staircase(2; trial_limit = 24); rng_seed = 5),
                     observer),
                    (() -> SessionContext("S", with_tracks, TwoIntervalStimulus(),
                                          Interleaved([Staircase(2; trial_limit = 12),
                                                             Staircase(1; trial_limit = 12)];
                                                            order = :random);
                                          rng_seed = 5),
                     observer),
                    (() -> SessionContext("S", adjusted, BaseStimulusParameters(300.0),
                                          Adjustment(dep_var = :duration_ms,
                                                           dep_range = 100.0:10.0:500.0,
                                                           init_interval = (150.0, 450.0));
                                          rng_seed = 5),
                     () -> ScriptedResponseSource(fill(0, 12))),
                ]
                for (build, source) in cases
                    whole = build()
                    with_response_source(source()) do
                        run_experiment!(whole, RenderOnlyEngine(); report = :silent)
                    end
                    continued = run_reloading_after_each_trial(build(), source())
                    @test whole.state == FINISHED
                    @test presented(continued) == presented(whole)
                    # The draws are not one value repeated, which would hide a
                    # stream that starts again
                    @test length(unique(presented(whole))) > length(whole.history) ÷ 2
                end
            end

            @testset "A closed response window is recorded, never guessed" begin
                ex_par = ExperimentParameters("Window", :level, [1.0, 2.0], 1)
                s = SessionContext("W", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                set_timeout!(s, 0.5)
                with_response_source(ScriptedResponseSource([:timeout, 1])) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end

                @test s.state == FINISHED
                @test length(s.history) == 2
                # The unanswered presentation keeps the sentinel: the method's
                # binary recoding never reaches it, and nothing is scored
                @test s.history[1].response === :timeout
                @test s.history[1].correct === nothing
                @test s.history[2].response == 1
                # The trial that spent the window checkpointed it, and it comes
                # back as the sentinel rather than as a number or a null
                ondisk = load_session(s.save_path)
                @test ondisk.history[1].response === :timeout
                @test ondisk.timeout_s == 0.5
            end

            @testset "An engine that captures input is told the window" begin
                ex_par = ExperimentParameters("EngineWindow", :level, [1.0, 2.0], 1)
                s = SessionContext("E", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                set_timeout!(s, 0.25)
                engine = TimingOutEngine()
                # A window the operator changes mid-session reaches the device
                # on the next trial, not on the next session
                run_experiment!(s, engine; report = :silent,
                                on_trial_end = session -> set_timeout!(session, 1.0))

                @test engine.windows == [0.25, 1.0]
                @test all(t.response === :timeout for t in s.history)
                @test all(t.correct === nothing for t in s.history)
            end

            @testset "The method decides what a closed window means" begin
                # Asking for the stimulus again: the trial is still ahead, and
                # the answer that finally arrives is the one recorded
                repeating = SessionContext("P1",
                                           ExperimentParameters("Policy", :level, [1.0], 1),
                                           BaseStimulusParameters(10.0), PolicyMethod(0))
                with_response_source(ScriptedResponseSource([:timeout, 1])) do
                    run_experiment!(repeating, RenderOnlyEngine(); report = :silent)
                end
                @test length(repeating.history) == 1
                @test repeating.history[1].response == 1

                # Counting it as a wrong answer: a method may say so, in its own
                # terms, and the Core then scores what the method returned
                scoring = SessionContext("P2",
                                         ExperimentParameters("2IFC", :target_interval,
                                                              [1.0], 1),
                                         TwoIntervalStimulus(), PolicyMethod(-1))
                with_response_source(ScriptedResponseSource([:timeout])) do
                    run_experiment!(scoring, RenderOnlyEngine(); report = :silent)
                end
                @test only(scoring.history).correct === false
                @test only(scoring.history).response == 0   # recoded, not a sentinel

                # A method that must stop the session aborts it and leaves the
                # sentinel standing; the trial it was in is still recorded
                stopping = SessionContext("P3",
                                          ExperimentParameters("Policy3", :level,
                                                               [1.0, 2.0], 1),
                                          BaseStimulusParameters(10.0),
                                          PolicyMethod(:abort))
                with_response_source(ScriptedResponseSource([:timeout])) do
                    run_experiment!(stopping, RenderOnlyEngine(); report = :silent)
                end
                @test stopping.state == ABORTED
                @test only(stopping.history).response === :timeout
            end

            @testset "An adjustment nobody confirms ends where it stands" begin
                # The trial must end, and must not record the value the
                # adjustment happened to reach as if it had been confirmed
                m = Adjustment(dep_var = :duration_ms,
                                     dep_range = 100.0:50.0:500.0,
                                     init_interval = (200.0, 400.0))
                s = SessionContext("A", ExperimentParameters("Adj", :x, [1.0], 1),
                                   BaseStimulusParameters(300.0), m)
                set_timeout!(s, 0.5)
                with_response_source(ScriptedResponseSource([1, 1, :timeout])) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end

                @test s.state == FINISHED
                @test only(s.history).response === :timeout
                @test length(m.init_vals) == 1
            end

            @testset "The response window is a declared session setting" begin
                s = SessionContext("S", ExperimentParameters("Win", :x, [1.0], 1),
                                   BaseStimulusParameters(10.0), ConstantStimuli())
                # A session waits for the participant until it is told not to
                @test s.timeout_s === nothing

                events = Symbol[]
                on_session_event!((_, event) -> push!(events, event), s)

                @test set_timeout!(s, 2).timeout_s === 2.0
                @test events == [:settings_changed]
                @test set_timeout!(s, nothing).timeout_s === nothing

                # A window that closes at or before the stimulus is not a window
                @test_throws ArgumentError set_timeout!(s, 0)
                @test_throws ArgumentError set_timeout!(s, -1.5)

                # It describes the measurement, so a replication inherits it
                set_timeout!(s, 1.5)
                @test create_replicated_session(s, "S2").timeout_s === 1.5
            end

            @testset "A staircase converges on a two-interval observer" begin
                levels = collect(0.0:0.1:1.0)
                ex_par = ExperimentParameters("Converge", [:level, :target_interval],
                                              [levels, [1.0, 2.0]], 1)
                s = SessionContext("Obs", ex_par, TwoIntervalStimulus(),
                                   Staircase(2; trial_limit = 60);
                                   rng_seed = UInt64(2718))
                observer = TwoIntervalObserver(0.5, 8.0, Random.Xoshiro(1234))
                with_response_source(observer) do
                    run_experiment!(s, RenderOnlyEngine(); report = :silent)
                end

                @test s.state == FINISHED
                @test length(s.history) == 60          # the declared limit, not repeats
                @test all(t.correct !== nothing for t in s.history)

                # A 2-down/1-up rule settles where two correct answers in a row
                # are as likely as one wrong one
                target = sqrt(0.5)
                expected = levels[argmin(abs.(proportion_correct_at.(Ref(observer), levels) .-
                                              target))]
                track = [t.indep_var_vals[1] for t in s.history]
                @test abs(sum(track[end-19:end]) / 20 - expected) <= 0.15

                # The target changed sides, and each side was scored on its own terms
                @test Set(t.indep_var_vals[2] for t in s.history) == Set([1.0, 2.0])
            end

            @testset "Undo is transactional (staircase refuses)" begin
                ex_par = ExperimentParameters("Stair", [:level, :target_interval],
                                              [[1.0, 2.0, 3.0], [1.0, 2.0]], 5)
                s = SessionContext("S", ex_par, TwoIntervalStimulus(),
                                   Staircase(2))
                start_session!(s)
                run_next_trial!(s, EmulatorEngine())
                @test length(s.history) == 1

                # Staircase cannot revert: the undo must be cancelled
                # and the trial must stay valid (no silent data loss). The
                # method explains the refusal; the command only reports that
                # nothing was undone.
                @test @test_logs((:warn, r"does not support reverting"),
                                 undo_last_trial!(s)) === nothing
                @test s.history[1].is_valid

                # Its next level follows from every answer so far, so a repeated trial
                # is presented past it: the staircase keeps its state, and the record
                # marks the trial as the operator's
                m = s.method_instance
                state() = (m.current_idx, m.correct_count, m.current_trial)
                before = state()
                @test repeat_trial!(s, 1)
                run_next_trial!(s, EmulatorEngine())
                @test length(s.history) == 2 && s.history[2].origin === :operator
                @test s.history[2].indep_var_vals == s.history[1].indep_var_vals
                @test !s.history[1].is_valid
                @test state() == before
                # An operator's trial the staircase never saw is undone without it,
                # and its condition is presented again next
                @test undo_last_trial!(s) == 2
                @test !s.history[2].is_valid
                @test [r.vals for r in s.operator_requests] == [s.history[2].indep_var_vals]
            end

            @testset "An operator's trial reaches the track it names" begin
                ex_par = ExperimentParameters("Tracks", [:level, :target_interval, :track],
                                              Any[[1.0, 2.0, 3.0], [1.0, 2.0], 1:2], 5)
                tracks = [AbsorbingStaircase(), AbsorbingStaircase()]
                s = SessionContext("T", ex_par, TwoIntervalStimulus(),
                                   Interleaved(tracks))
                start_session!(s)
                @test present_condition!(s, [2.0, 1.0, 2.0])
                with_response_source(ScriptedResponseSource([1])) do
                    run_next_trial!(s, RenderOnlyEngine())
                end
                @test s.history[1].origin === :operator
                @test isempty(tracks[1].absorbed)
                @test tracks[2].absorbed == [([2.0, 1.0], 1, true)]
                @test tracks[2].inner.current_trial == 1
                @test undo_last_trial!(s) == 1
                @test isempty(tracks[2].absorbed)

                # A run whose tracks set the stimulus during their trial can neither
                # pass a trial by nor take one into a plan
                adjusting = SessionContext("A",
                    ExperimentParameters("Adjusting", [:contrast, :track],
                                         Any[[0.2, 0.8], 1:2], 1),
                    BaseStimulusParameters(300.0),
                    Interleaved([Adjustment(dep_var = :duration_ms,
                                                        dep_range = 100.0:50.0:500.0)
                                       for _ in 1:2]))
                @test @test_logs((:warn, r"sets the stimulus during its trial"),
                                 present_condition!(adjusting, [0.2, 1.0])) == false
            end

            @testset "A selected trial is repeated next" begin
                ex_par = ExperimentParameters("Repeat", :level, [1.0, 2.0, 3.0], 1)
                s = SessionContext("R", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                start_session!(s)
                run_next_trial!(s, EmulatorEngine())
                run_next_trial!(s, EmulatorEngine())
                events = Symbol[]
                on_session_event!((_, event) -> push!(events, event), s)

                # Nothing is set aside until the new answer exists, the plan changes
                # when the trial is taken up, and the request is not saved
                @test repeat_trial!(s, 1)
                @test s.history[1].is_valid && isempty(events)
                @test planned_trial_count(s.method_instance) == 3
                @test isempty(load_session(s.save_path).operator_requests)
                @test @test_logs((:warn, r"already waiting"), repeat_trial!(s, 1)) == false
                run_next_trial!(s, EmulatorEngine())
                @test s.history[3].indep_var_vals == s.history[1].indep_var_vals
                @test s.history[3].origin === :operator && !s.history[1].is_valid
                @test planned_trial_count(s.method_instance) == 4
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test s.state == FINISHED
                @test length(s.history) == 4
                @test sort([t.indep_var_vals[1] for t in s.history if t.is_valid]) ==
                      [1.0, 2.0, 3.0]

                # After the session: it is reopened, and its file says FINISHED until
                # the repeated trial is recorded
                @test repeat_trial!(s, 2)
                @test s.state == RUNNING
                @test load_session(s.save_path).state == FINISHED
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test s.state == FINISHED
                @test length(s.history) == 5
                @test s.history[5].indep_var_vals == s.history[2].indep_var_vals
                @test !s.history[2].is_valid

                # An invalid trial has no answer to replace
                @test @test_logs((:warn, r"already invalid"), repeat_trial!(s, 1)) == false
                @test @test_logs((:warn, r"no such trial"), repeat_trial!(s, 99)) == false
                abort!(s)
                @test @test_logs((:warn, r"aborted"), repeat_trial!(s, 3)) == false
                @test s.history[3].is_valid
            end

            @testset "A stimulus is previewed once, with no answer awaited" begin
                engine = WaitingEngine()
                put!(engine.replies, 1)   # an answer it would otherwise wait for
                preview_stimulus(engine, Gabor(), [0.2, 1.0])
                @test engine.seen == [[0.2, 1.0]]
                # The engine-owning form opens an engine, presents, and closes it
                @test preview_stimulus(Gabor(); engine_type = EmulatorEngine,
                                       config = PsychophysicsManager.DisplayConfig()) === nothing
                # An engine with no window to close stays open
                @test isopen(EmulatorEngine())
            end

            @testset "A backend loaded on demand runs its engine" begin
                # A throwaway backend package: replicating a session whose engine it
                # provides loads it, in a world newer than the running code
                packages = mktempdir()
                mkpath(joinpath(packages, "LateBackend", "src"))
                write(joinpath(packages, "LateBackend", "src", "LateBackend.jl"), """
                    module LateBackend
                    import PsychophysicsManager
                    struct LateEngine <: PsychophysicsManager.AbstractStimulusEngine end
                    PsychophysicsManager.initialize_engine(::Type{LateEngine},
                                                ::PsychophysicsManager.AbstractStimulusParameters,
                                                ::PsychophysicsManager.DisplayConfig) = LateEngine()
                    PsychophysicsManager.present_stimulus(::LateEngine,
                                               ::PsychophysicsManager.AbstractStimulusParameters,
                                               ::AbstractVector{<:Number}) = nothing
                    __init__() = PsychophysicsManager.register_engine_type!(LateEngine)
                    end
                    """)
                push!(LOAD_PATH, packages)
                try
                    register_engine_backend!(:LateEngine, [:LateBackend])
                    template = SessionContext("L", ExperimentParameters("Late", :level, [1.0], 1),
                                              BaseStimulusParameters(10.0),
                                              ConstantStimuli())
                    template.engine_name = "LateEngine"
                    path = save_session_checkpoint(template, pwd(); filename = "late.json")
                    session = with_response_source(ScriptedResponseSource([1])) do
                        replicate_experiment(path; report = :silent)
                    end
                    @test session.state == FINISHED && length(session.history) == 1
                finally
                    filter!(!=(packages), LOAD_PATH)
                end
            end

            @testset "An operator's condition is added to the plan" begin
                ex_par = ExperimentParameters("Add", :level, [1.0, 2.0, 3.0], 2)
                s = SessionContext("Add", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                start_session!(s)
                run_next_trial!(s, EmulatorEngine())
                m = s.method_instance
                waiting() = [m.trial_table[i] for i in m.order[m.current_idx:end]]
                # A condition still waiting is moved forward, so the plan keeps its
                # length and presents it once less later
                target = last(waiting())
                copies = count(==(target), waiting())
                @test present_condition!(s, target)
                run_next_trial!(s, EmulatorEngine())
                @test s.history[2].indep_var_vals == target
                @test s.history[2].origin === :operator && s.history[1].is_valid
                @test planned_trial_count(m) == 6
                @test count(==(target), waiting()) == copies - 1

                # One with no copy left waiting is inserted, and the plan grows
                while !is_experiment_finished(m)
                    run_next_trial!(s, EmulatorEngine())
                end
                @test s.state == FINISHED
                @test present_condition!(s, [2.0])
                @test s.state == RUNNING
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test planned_trial_count(m) == 7 && length(s.history) == 7
                @test s.history[7].indep_var_vals == [2.0] && s.history[7].origin === :operator
                @test all(t -> t.is_valid, s.history)

                # A condition is one the design declares or the session presented
                @test_throws ArgumentError present_condition!(s, [4.0])
                @test_throws ArgumentError present_condition!(s, [1.0, 2.0])
                abort!(s)
                @test @test_logs((:warn, r"aborted"), present_condition!(s, [1.0])) == false
            end

            @testset "A trial is abandoned for the operator's condition" begin
                ex_par = ExperimentParameters("Now", :level, [1.0, 2.0, 3.0], 1)
                s = SessionContext("N", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                start_session!(s)
                m = s.method_instance
                events = Symbol[]
                on_session_event!((_, event) -> push!(events, event), s)
                engine = WaitingEngine()
                loop = start_waiting_trial(s, engine)
                waiting = only(engine.seen)
                chosen = first(filter(!=(waiting), [[1.0], [2.0], [3.0]]))
                # A key pressed for the abandoned trial waits in the active source;
                # it must not answer the stimulus presented in its place
                keys = PsychophysicsManager.ChannelResponseSource(Channel{Tuple{Int, Float64}}(1))
                PsychophysicsManager.offer_response!(keys.channel, -1)
                with_response_source(keys) do
                    @test present_condition!(s, chosen; when = :now)
                end
                @test !isready(keys.channel)
                @test fetch(loop) == true
                @test isempty(s.history) && events == [:trial_abandoned]
                @test !s.trial_under_way && s.trial_run === nothing

                # The chosen condition comes first, the abandoned one right after, and
                # the plan keeps its length
                put!(engine.replies, 1)
                run_next_trial!(s, engine)
                put!(engine.replies, 1)
                run_next_trial!(s, engine)
                @test [t.indep_var_vals for t in s.history] == [chosen, waiting]
                @test [t.origin for t in s.history] == [:operator, :method]
                @test planned_trial_count(m) == 3

                # An engine that cannot interrupt its presentation finishes the trial
                # first, and the request comes next
                stubborn = WaitingEngine(false)
                loop = start_waiting_trial(s, stubborn)
                last_waiting = only(stubborn.seen)
                @test @test_logs((:warn, r"cannot interrupt"),
                                 repeat_trial!(s, 1; when = :now))
                put!(stubborn.replies, 1)
                @test fetch(loop) == true
                @test s.history[3].indep_var_vals == last_waiting
                put!(stubborn.replies, 1)
                @test run_next_trial!(s, stubborn) == false
                @test s.history[4].origin === :operator && !s.history[1].is_valid
                @test s.state == FINISHED

                @test_throws ArgumentError present_condition!(s, [1.0]; when = :later)
            end

            @testset "Stop does not wait for a participant who has left" begin
                ex_par = ExperimentParameters("Stop", :level, [1.0, 2.0], 1)
                s = SessionContext("S", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                start_session!(s)
                controller = PsychophysicsManager.DashboardController(s)
                engine = WaitingEngine()
                loop = @async run_experiment!(s, engine; report = :silent)
                timedwait(() -> s.trial_run !== nothing, 5.0)
                @test PsychophysicsManager.stop_experiment!(controller) == false   # asks first
                @test PsychophysicsManager.stop_experiment!(controller)
                @test timedwait(() -> istaskdone(loop), 5.0) === :ok
                @test s.state == ABORTED && isempty(s.history)
            end

            @testset "An abandoned trial is presented again as it was" begin
                ex_par = ExperimentParameters("NowStair", [:level, :target_interval],
                                              [[1.0, 2.0, 3.0], [1.0, 2.0]], 5)
                s = SessionContext("NS", ex_par, TwoIntervalStimulus(), Staircase(2))
                start_session!(s)
                engine = WaitingEngine()
                loop = start_waiting_trial(s, engine)
                abandoned = only(engine.seen)
                @test present_condition!(s, [1.0, 2.0]; when = :now)
                @test fetch(loop)
                for _ in 1:2
                    put!(engine.replies, 1)
                    run_next_trial!(s, engine)
                end
                # The stream was restored with the method, so the target is drawn into
                # the same interval again
                @test engine.seen == [abandoned, [1.0, 2.0], abandoned]
                @test [t.origin for t in s.history] == [:operator, :method]
                @test s.method_instance.current_trial == 2
            end

            @testset "The progress total grows with trials the method does not count" begin
                ex_par = ExperimentParameters("Total", [:level, :target_interval],
                                              [[1.0, 2.0, 3.0], [1.0, 2.0]], 1)
                s = SessionContext("T", ex_par, TwoIntervalStimulus(),
                                   Staircase(2; trial_limit = 3))
                @test session_trial_total(s) === nothing
                start_session!(s)
                @test session_trial_total(s) == 3
                run_next_trial!(s, EmulatorEngine())
                # An operator's trial passes the staircase by, waiting and then presented
                @test present_condition!(s, [1.0, 2.0])
                @test session_trial_total(s) == 4
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test length(s.history) == 4 && session_trial_total(s) == 4

                # An undone trial of a plan is presented again
                c = SessionContext("C", ExperimentParameters("C", :level, [1.0, 2.0], 1),
                                   BaseStimulusParameters(10.0), ConstantStimuli())
                # Before the start, a plan not yet drawn is the design's trials
                @test session_trial_total(c) == 2
                start_session!(c)
                run_next_trial!(c, EmulatorEngine())
                @test undo_last_trial!(c) == 1
                @test session_trial_total(c) == 3
                run_experiment!(c, EmulatorEngine(); report = :silent)
                @test length(c.history) == 3 && session_trial_total(c) == 3
            end

            @testset "Planned valid trials follow corrections and operator trials" begin
                s = SessionContext("P", ExperimentParameters("Planned", :level, [1.0, 2.0, 3.0], 2),
                                   BaseStimulusParameters(10.0), ConstantStimuli())
                @test PsychophysicsManager.planned_valid_trials(s) == 6
                start_session!(s)
                @test PsychophysicsManager.planned_valid_trials(s) == 6
                for _ in 1:3
                    run_next_trial!(s, EmulatorEngine())
                end
                @test count(t -> t.is_valid, s.history) == 3
                @test PsychophysicsManager.planned_valid_trials(s) == 6
                @test undo_last_trial!(s) == 3
                @test count(t -> t.is_valid, s.history) == 2
                @test PsychophysicsManager.planned_valid_trials(s) == 6
                @test mark_outlier!(s, 1)
                @test PsychophysicsManager.planned_valid_trials(s) == 5
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test PsychophysicsManager.planned_valid_trials(s) == 5
                @test present_condition!(s, [1.0])
                run_next_trial!(s, EmulatorEngine())
                @test PsychophysicsManager.planned_valid_trials(s) == 6

                open_ended = SessionContext("S",
                                            ExperimentParameters("Open", [:level, :target_interval],
                                                                 [[1.0, 2.0, 3.0], [1.0, 2.0]], 1),
                                            TwoIntervalStimulus(), Staircase(2))
                @test PsychophysicsManager.planned_valid_trials(open_ended) === nothing
            end

            @testset "An adjustment trial is repeated with a start value of its own" begin
                ex_par = ExperimentParameters("RepeatAdj", :contrast, [0.2, 0.8], 1)
                m = Adjustment(dep_var = :duration_ms,
                                     dep_range = 100.0:50.0:500.0,
                                     init_interval = (200.0, 400.0))
                s = SessionContext("RA", ex_par, BaseStimulusParameters(300.0), m)
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test repeat_trial!(s, 1)
                run_experiment!(s, EmulatorEngine(); report = :silent)
                @test s.state == FINISHED
                @test length(s.history) == 3
                @test s.history[3].indep_var_vals == s.history[1].indep_var_vals
                @test length(m.init_vals) == 3
                # The operator's trial was an adjustment like the others: its answer is
                # the value confirmed
                @test s.history[3].origin === :operator && s.history[3].response in m.dep_range
            end

            @testset "The plan is not corrected while a trial is under way" begin
                ex_par = ExperimentParameters("Guard", :level, [1.0, 2.0, 3.0], 1)
                s = SessionContext("G", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                start_session!(s)
                run_next_trial!(s, EmulatorEngine())
                order = copy(s.method_instance.order)
                engine = CorrectingEngine(s, Any[])
                # Undo is refused; a repetition waits for the trial under way
                @test_logs((:warn, r"under way"), run_next_trial!(s, engine))
                @test engine.outcomes == [(nothing, true)]
                @test all(t -> t.is_valid, s.history)
                @test s.method_instance.order == order
                @test s.method_instance.current_idx == 3
                @test !s.trial_under_way
                run_next_trial!(s, EmulatorEngine())
                @test s.history[3].origin === :operator
                @test s.history[3].indep_var_vals == s.history[1].indep_var_vals
                @test !s.history[1].is_valid

                # A trial that ends in an error lowers the flag too, and a request it
                # was presenting still waits
                @test repeat_trial!(s, 2)
                @test_throws ErrorException run_next_trial!(s, FailingEngine(1,
                                                            ErrorException("gone")))
                @test !s.trial_under_way
                @test only(s.operator_requests).replaces == 2 && s.history[2].is_valid
            end

            @testset "Corrections report their outcome" begin
                ex_par = ExperimentParameters("Corrections", :level, [1.0, 2.0], 1)
                s = SessionContext("C", ex_par, BaseStimulusParameters(10.0),
                                   ConstantStimuli())
                run_experiment!(s, EmulatorEngine(); report = :silent)

                @test mark_outlier!(s, 1)
                @test !s.history[1].is_valid
                # Marking it again changes nothing and says so
                @test !mark_outlier!(s, 1)
                @test @test_logs((:warn, r"no such trial"),
                                 mark_outlier!(s, 99)) == false

                # Every remaining trial undone, then nothing is left to undo
                @test undo_last_trial!(s) == 2
                @test @test_logs((:warn, r"no valid trials"),
                                 undo_last_trial!(s)) === nothing
            end
        end
    end

end

# A Julia script exits on Ctrl+C unless it asks otherwise; the loop asks for as
# long as it runs, so a script's session is paused and saved, not cut off
@testset "Ctrl+C in a script pauses the session" begin
    if Sys.isunix()
        mktempdir() do dir
            script = joinpath(dir, "interrupted.jl")
            write(script, """
                using PsychophysicsManager
                struct SlowEngine <: PsychophysicsManager.AbstractStimulusEngine end
                PsychophysicsManager.present_stimulus(::SlowEngine, ::AbstractStimulusParameters,
                                           ::AbstractVector{<:Number}) = (sleep(0.1); 1)
                cd(ARGS[1])
                write("settings.toml", "[storage]\\ndata_dir = \\"out\\"\\n")
                s = SessionContext("Script", ExperimentParameters("Script", :x, 1:500, 1),
                                   BaseStimulusParameters(1.0), ConstantStimuli())
                run_experiment!(s, SlowEngine(); report = :session,
                                on_trial_end = s -> length(s.history) == 1 && touch("started"))
                write("saved_at", abspath(s.save_path))
                """)
            output = joinpath(dir, "output.txt")
            child = run(pipeline(`$(Base.julia_cmd()) --startup-file=no
                                  --project=$(Base.active_project()) $script $dir`;
                                 stdout = output, stderr = output); wait = false)
            started = joinpath(dir, "started")
            timedwait(() -> isfile(started) || process_exited(child), 300.0)
            @test isfile(started)
            kill(child, Base.SIGINT)
            timedwait(() -> process_exited(child), 60.0)
            process_running(child) && kill(child)

            # The script went on after the loop returned, and the file it left
            # says the session can be continued
            @test success(child)
            saved_at = joinpath(dir, "saved_at")
            @test isfile(saved_at) && load_session(read(saved_at, String)).state == PAUSED
            @test occursin("Interrupted", read(output, String))
        end
    end
end

# An engine whose code is a file of its own, in a git repository or outside any: the
# file defining its `present_stimulus` is what identifies the program presenting a session
function write_probe_engine(dir::String, name::String; stated = nothing)
    file = joinpath(dir, "$name.jl")
    write(file, """
        struct $name <: PsychophysicsManager.AbstractStimulusEngine end
        PsychophysicsManager.present_stimulus(::$name, ::PsychophysicsManager.AbstractStimulusParameters,
                                   ::AbstractVector{<:Number}) = nothing
        $(stated === nothing ? "" : "PsychophysicsManager.engine_version(::$name) = \"$stated\"")
        """)
    return file
end

function probe_engine_type(file::String, name::String)
    probe = Module(:IdentityProbe)
    Core.eval(probe, :(using PsychophysicsManager))
    Base.include(probe, file)
    # Defined by the include, in a world newer than this function's
    return Base.invokelatest(getfield, probe, Symbol(name))
end

# Defined here, at the top level, so the tests below run in a world that has them
const IDENTITY_DIR = mktempdir()
const LOOSE_ENGINE_FILE = write_probe_engine(mkpath(joinpath(IDENTITY_DIR, "loose")),
                                             "LooseEngine")
const LooseEngine = probe_engine_type(LOOSE_ENGINE_FILE, "LooseEngine")
const REPO_ENGINE_FILE = write_probe_engine(mkpath(joinpath(IDENTITY_DIR, "repo")),
                                            "RepoEngine"; stated = "probe 2")
const REPO_NOTES_FILE = joinpath(dirname(REPO_ENGINE_FILE), "notes.txt")
const REPO_ENGINE_COMMIT = let git = PsychophysicsManager.LibGit2
    write(REPO_NOTES_FILE, "notes\n")
    repo = git.init(dirname(REPO_ENGINE_FILE))
    git.add!(repo, "RepoEngine.jl", "notes.txt")
    signature = git.Signature("Test", "test@example.org")
    commit = string(git.commit(repo, "the engine"; author = signature, committer = signature))
    close(repo)
    commit
end
const RepoEngine = probe_engine_type(REPO_ENGINE_FILE, "RepoEngine")

@testset "The stimulus program that presented a session" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
            stim = BaseStimulusParameters(1.0)
            new_session() = SessionContext("P", ExperimentParameters("Identity", :x, [1.0, 2.0], 1),
                                           stim, ConstantStimuli())

            # Outside any repository, the file's content stands for the version
            @test stimulus_identity(LooseEngine(), stim) ==
                  ("LooseEngine (IdentityProbe)",
                   "sha256 $(bytes2hex(PsychophysicsManager.SHA.sha256(read(LOOSE_ENGINE_FILE)))) of LooseEngine.jl")

            # In a repository, its commit and the file's content do
            commit = REPO_ENGINE_COMMIT
            file = REPO_ENGINE_FILE
            file_hash() = bytes2hex(PsychophysicsManager.SHA.sha256(read(file)))
            original = "git $commit, RepoEngine.jl sha256 $(file_hash())"
            engine = RepoEngine()
            @test stimulus_identity(engine, stim) == ("RepoEngine (IdentityProbe)", original)

            # The session records it at its start, and the version its author states beside it
            session = new_session()
            with_logger(NullLogger()) do
                # One of the two trials is answered, then the presentation fails
                @test_throws ErrorException with_response_source(ScriptedResponseSource([1])) do
                    run_experiment!(session, engine; report = :silent)
                end
            end
            @test session.state == PAUSED && length(session.history) == 1
            @test session.environment["stimulus_program"] == "RepoEngine (IdentityProbe)"
            @test session.environment["stimulus_version"] == original
            @test session.environment["stimulus_version_stated"] == "probe 2"
            @test !haskey(session.environment, "stimulus_uncommitted_changes")

            # A change elsewhere in the repository is marked, and is no change of the program
            write(REPO_NOTES_FILE, "edited notes\n")
            @test stimulus_identity(engine, stim) == ("RepoEngine (IdentityProbe)", original)
            dirty = new_session()
            start_session!(dirty, engine)
            @test dirty.environment["stimulus_uncommitted_changes"] == "yes"

            # Resumed after the engine's file changed, it does not continue on its own
            write(file, read(file, String) * "# changed\n")
            changed = last(stimulus_identity(engine, stim))
            @test changed == "git $commit, RepoEngine.jl sha256 $(file_hash())" != original
            refusal = try
                run_experiment!(session, engine; report = :silent)
                nothing
            catch err
                err
            end
            @test refusal isa StimulusChangedError
            @test refusal.recorded == "RepoEngine (IdentityProbe), $original"
            @test refusal.current == "RepoEngine (IdentityProbe), $changed"
            @test occursin("accept_changed_stimulus = true", sprint(showerror, refusal))
            @test session.state == PAUSED && length(session.history) == 1

            # Continued deliberately, it records the change and the trial it took effect at
            with_response_source(ScriptedResponseSource([1])) do
                run_experiment!(session, engine; report = :silent, accept_changed_stimulus = true)
            end
            @test session.state == FINISHED && length(session.history) == 2
            @test session.environment["stimulus_version"] == original
            @test session.environment["stimulus_version_from_trial_2"] == changed
            @test session.environment["stimulus_program_from_trial_2"] == "RepoEngine (IdentityProbe)"
            # The record survives the file, and the changed program is the one in effect
            reloaded = load_session(session.save_path)
            @test reloaded.environment == session.environment
            @test PsychophysicsManager.presenting_stimulus(reloaded.environment) ==
                  ("RepoEngine (IdentityProbe)", changed)

            # A session started before any engine presented it records the first one that does
            unstarted = new_session()
            start_session!(unstarted)
            @test !haskey(unstarted.environment, "stimulus_version")
            with_response_source(ScriptedResponseSource([1, 1])) do
                run_experiment!(unstarted, LooseEngine(); report = :silent)
            end
            @test unstarted.environment["stimulus_program"] == "LooseEngine (IdentityProbe)"

            # An unknown version is never compared
            unknown = new_session()
            start_session!(unknown)
            unknown.environment["stimulus_program"] = "Something"
            unknown.environment["stimulus_version"] = UNKNOWN_STIMULUS_VERSION
            with_response_source(ScriptedResponseSource([1, 1])) do
                run_experiment!(unknown, engine; report = :silent)
            end
            @test unknown.state == FINISHED
            @test !any(startswith("stimulus_version_from_trial_"), keys(unknown.environment))
        end
    end
end

@testset "Experiment parameters refuse a plan with no trials" begin
    # Each of these runs to FINISHED with an empty or misaligned history if it
    # is allowed through, which no later stage can tell from a real measurement
    @test_throws ArgumentError ExperimentParameters("zero", :x, [1.0, 2.0], 0)
    @test_throws ArgumentError ExperimentParameters("empty", :x, Float64[], 2)
    @test_throws ArgumentError ExperimentParameters("mismatch", [:x, :y],
                                                    [[1.0, 2.0]], 2)

    # A single condition repeated is a design, not a mistake
    @test ExperimentParameters("one level", :x, [1.0], 1).repeats == 1
    # So is an experiment with no independent variable at all
    @test isempty(ExperimentParameters("no variables", Symbol[], Any[], 3).indep_var_ranges)
end

@testset "Trial constructors" begin
    # Scoring and engine-reported onsets are opt-in: the shorter forms a
    # caller wrote before either existed still build a trial
    @test Trial(1, 0.0, 0.1, [1.0], 1, true).correct === nothing
    @test Trial(1, 0.0, 0.1, [1.0], 1, true).onset_source === :estimated
    @test Trial(1, 0.0, 0.1, [1.0], 1, true, :engine).correct === nothing
    @test Trial(1, 0.0, 0.1, [1.0], 1, true, :engine, false).correct === false

    # A response is a number or the one sentinel that stands for no response
    @test Trial(1, 0.0, 0.1, [1.0], :timeout, true).response === :timeout
    @test_throws ArgumentError Trial(1, 0.0, 0.1, [1.0], :abandoned, true)
end

@testset "What counts as an answer" begin
    @test PsychophysicsManager.is_answer(1)
    @test PsychophysicsManager.is_answer(-0.5)
    # A repeat request, a missing reply and a closed window state nothing about
    # what was perceived, so none of them can be scored
    @test !PsychophysicsManager.is_answer(0)
    @test !PsychophysicsManager.is_answer(MISSING_RESPONSE)
    @test !PsychophysicsManager.is_answer(:timeout)

    # An engine reports the same sentinel, and nothing else symbolic
    @test PsychophysicsManager.normalize_presentation(:timeout).response === :timeout
    @test PsychophysicsManager.normalize_presentation((:timeout, 5.0)).timestamp_response == 5.0
    @test_throws ArgumentError PsychophysicsManager.normalize_presentation(:probably)
end

@testset "Engine conformance check" begin
    par = BaseStimulusParameters(100.0)
    report = verify_engine(EmulatorEngine(), par)
    @test report.probes == 3
    @test !report.render_only          # the emulator answers for the participant too
    @test report.reports_onset && report.reports_response_time
    @test par.duration_ms == 100.0     # the check leaves the parameters as it found them

    # A render-only engine is not a broken one: the report says a response
    # source has to supply the answers, and the Core will stamp the onset
    render_only = verify_engine(RenderOnlyEngine(), par)
    @test render_only.render_only
    @test !render_only.reports_onset
    @test occursin("render-only", repr(MIME("text/plain"), render_only))

    # Each check names the engine and what it did with it
    @test_throws "returned \"seen\"" verify_engine(BadFormEngine(), par)
    @test_throws "reported 12.5 as the onset" verify_engine(BadClockEngine(), par)
    @test_throws "changed BaseStimulusParameters.duration_ms" verify_engine(MutatingEngine(), par)
    @test_throws ArgumentError verify_engine(EmulatorEngine(), par; n_probes = 0)
end

@testset "The console prompt outlives a closed window" begin
    stim = BaseStimulusParameters(10.0)
    context(timeout_s) = TrialContext(stim, [:x], [1.0], 1, "console", nothing, timeout_s)

    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    source = ConsoleResponseSource()

    redirect_stdout(devnull) do
        redirect_stdin(pipe.out) do
            started = time()
            @test request_response(source, context(0.3))[1] === :timeout
            # The point of the deadline: the console does not hold the session
            @test time() - started < 3.0

            # The line typed too late answers the next presentation instead of
            # being swallowed by a reader nobody waits for any more
            write(pipe.in, "-1\n")
            flush(pipe.in)
            @test request_response(source, context(5.0))[1] == -1

            # A session that declares no window waits as it always did
            write(pipe.in, "1\n")
            flush(pipe.in)
            @test request_response(source)[1] == 1
        end
    end
    close(pipe)
end

@testset "The text-mode engine reads the console within the window" begin
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    engine = InteractiveEngine()
    PsychophysicsManager.set_response_timeout!(engine, 0.3)

    redirect_stdout(devnull) do
        redirect_stdin(pipe.out) do
            # An engine that captures its own input reports the sentinel itself,
            # rather than leaving the participant to answer a stimulus that is
            # no longer on screen
            @test present_stimulus(engine, BaseStimulusParameters(10.0), [1.0])[1] ===
                  :timeout

            write(pipe.in, "1\n")
            flush(pipe.in)
            PsychophysicsManager.set_response_timeout!(engine, nothing)
            @test present_stimulus(engine, BaseStimulusParameters(10.0), [1.0])[1] == 1
        end
    end
    close(pipe)
end

@testset "Console response parsing" begin
    @test PsychophysicsManager._parse_console_response("-1") == -1
    @test PsychophysicsManager._parse_console_response(" 0 ") == 0
    @test PsychophysicsManager._parse_console_response("1") == 1
    @test PsychophysicsManager._parse_console_response("confirm") === nothing
    @test PsychophysicsManager._parse_console_response("2") === nothing
end

@testset "Response sources" begin
    @testset "ScriptedResponseSource" begin
        source = ScriptedResponseSource([1, -1, 0])
        responses = [request_response(source)[1] for _ in 1:3]
        @test responses == [1, -1, 0]
        # Responses keep their natural numeric type
        @test all(r isa Int for r in responses)
        @test request_response(ScriptedResponseSource([0.5]))[1] === 0.5
        # Asking past the end of the script is an error, not a silent repeat
        @test_throws ErrorException request_response(source)

        # A script may write down a window that closed with nothing answered,
        # so a persistence or policy test needs no real waiting
        @test request_response(ScriptedResponseSource([:timeout]))[1] === :timeout
        @test_throws ArgumentError ScriptedResponseSource([1, :maybe])
    end

    @testset "Active source is restored" begin
        original = PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[]
        temporary = ScriptedResponseSource([1])

        previous = swap_response_source!(temporary)
        @test previous === original
        @test PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[] === temporary
        set_response_source!(original)

        inside = with_response_source(temporary) do
            PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[]
        end
        @test inside === temporary
        @test PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[] === original

        # A failed presentation must not leave a dead source behind: the next
        # session would block on input nothing feeds any more
        @test_throws ErrorException with_response_source(temporary) do
            error("presentation failed")
        end
        @test PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[] === original
    end
end

@testset "Saved-session launch API" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"data\"\n")
            source = SessionContext(
                "Template",
                ExperimentParameters("SavedEmulator", :duration_ms, [20.0], 1),
                BaseStimulusParameters(20.0),
                ConstantStimuli();
                tags=["template"],
            )
            source.engine_name = "EmulatorEngine"
            set_fit_gamma!(source, 0.5)
            templates = joinpath(dir, "templates")
            mkpath(templates)
            source_path = save_session_checkpoint(source, templates; filename="source.json")

            prepared = create_replicated_session(source_path, "PreparedParticipant")
            @test prepared.state == READY
            @test prepared.participant_id == "PreparedParticipant"
            @test prepared.engine_name == "EmulatorEngine"
            @test prepared.tags == ["template"]
            # The asymptote describes the kind of data the design collects, so
            # a replication measures it the same way
            @test prepared.fit_gamma == 0.5
            # ...but not the same random sequence: a replication that repeated
            # the trial order would confound the design with the order
            @test prepared.rng_seed != source.rng_seed
            @test prepared.ex_par !== source.ex_par
            @test prepared.stim_par !== source.stim_par
            prepared.ex_par.repeats = 3
            @test source.ex_par.repeats == 1

            completed = run_session_from_file(source_path; participant_id="RunParticipant")
            @test completed.state == FINISHED
            @test completed.participant_id == "RunParticipant"
            @test length(completed.history) == 1
            @test isfile(completed.save_path)
        end
    end
end

@testset "Stimulus registry and selection" begin
    # 1. selectable_stimuli listing
    choices = selectable_stimuli()
    @test issubset(["Gabor", "MarkerLayout", "TemporalOppelKundt"], choices)
    @test !("WorkerStimulus" in choices)
    @test !("BaseStimulusParameters" in choices) # Requires arguments

    # A worker's stimuli are listed and chosen with the defaults it declares, the
    # session then presented by the worker
    worker_stim = WorkerStimulus("remote_test"; x = 10, y = 20)
    @test "remote_test" in selectable_stimuli(; declared = [worker_stim])
    s_worker = SessionContext(ExperimentParameters("Worker", :Ref, [10.0], 1),
                              MarkerLayout(), ConstantStimuli())
    @test_throws ArgumentError set_parameters!(s_worker, Dict("stimulus" => "remote_test"))
    set_parameters!(s_worker, Dict("stimulus" => "remote_test"); declared = [worker_stim])
    @test PsychophysicsManager.stimulus_name(s_worker.stim_par) == "remote_test"
    @test s_worker.stim_par !== worker_stim
    @test parameter_value(s_worker.stim_par, :y) == 20
    @test s_worker.ex_par.indep_var_names == [:x] && s_worker.ex_par.indep_var_ranges == [[10]]
    @test s_worker.engine_name == "RemoteEngine"
    @test default_engine_type(worker_stim) === RemoteEngine

    # 2. Chosen by name with defaults, another key of the same call changing one; a
    # stimulus of the same type is changed in place, for whoever holds it
    session = SessionContext(
        ExperimentParameters("Test", :Ref, [10.0, 20.0], 1),
        MarkerLayout(DistrN = 7),
        Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0),
    )
    held = session.stim_par
    set_parameters!(session, Dict("stimulus" => "MarkerLayout", "stim_par.Ref" => 35.0))
    @test session.stim_par === held
    @test session.stim_par.Ref == 35.0
    @test session.stim_par.DistrN == MarkerLayout().DistrN
    @test session.engine_name == "GeometryVisualEngine"
    @test session.method_instance.dep_range == collect(-5.0:1.0:5.0)

    # 3. Variables kept and replaced
    # Session with [:Ref, :Diff] switching to MarkerLayout: both numeric parameters, so kept
    s_keep = SessionContext(
        ExperimentParameters("Keep", [:Ref, :Diff], [[10.0, 15.0], [0.0]], 1),
        MarkerLayout(),
        Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0),
    )
    set_parameters!(s_keep, Dict("stimulus" => "MarkerLayout"))
    @test s_keep.ex_par.indep_var_names == [:Ref, :Diff]
    @test s_keep.ex_par.indep_var_ranges == Any[[10.0, 15.0], [0.0]]

    # Variables not in new stimulus: replaced by new stimulus's first numeric parameter at default value
    s_replace = SessionContext(
        ExperimentParameters("Replace", [:contrast, :target_interval], [[0.1, 0.2], [1, 2]], 1),
        Gabor(),
        ConstantStimuli(),
    )
    # MarkerLayout does not have :contrast or :target_interval
    set_parameters!(s_replace, Dict("stimulus" => "MarkerLayout"))
    @test s_replace.ex_par.indep_var_names == [:Ref]
    @test s_replace.ex_par.indep_var_ranges == Any[[10.0]] # MarkerLayout default Ref is 10.0

    # A stimulus is given the variables its design cannot do without, after the others
    s_gabor = SessionContext(ExperimentParameters("To Gabor", :Ref, [10.0, 20.0], 1),
                             MarkerLayout(), ConstantStimuli())
    set_parameters!(s_gabor, Dict("stimulus" => "Gabor"))
    @test s_gabor.ex_par.indep_var_names == [:contrast, :target_interval]
    @test s_gabor.ex_par.indep_var_ranges == Any[[Gabor().contrast], [1, 2]]
    @test required_variables(MarkerLayout()) == []
    # and keeps the levels of one it has already
    set_parameters!(s_gabor, Dict("ex_par.indep_var_ranges" => Any[[0.1, 0.2], [2, 1]]))
    set_parameters!(s_gabor, Dict("stimulus" => "Gabor"))
    @test s_gabor.ex_par.indep_var_ranges == Any[[0.1, 0.2], [2, 1]]

    # One variable kept, the other replaced by the first numeric parameter that is free:
    # not the one the method goes on adjusting, whose range stays
    mutable struct TwoOfMarkerStimulus <: AbstractStimulusParameters
        Diff::Float64
        Ref::Float64
        gap::Float64
    end
    TwoOfMarkerStimulus() = TwoOfMarkerStimulus(0.0, 50.0, 3.0)
    register_stimulus!(TwoOfMarkerStimulus; engine = :EmulatorEngine)
    s_partial = SessionContext(
        ExperimentParameters("Partial", [:Ref, :DistrN], [[10.0, 20.0], [1, 2]], 1),
        MarkerLayout(),
        Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0),
    )
    set_parameters!(s_partial, Dict("stimulus" => "TwoOfMarkerStimulus"))
    @test s_partial.ex_par.indep_var_names == [:Ref, :gap]
    @test s_partial.ex_par.indep_var_ranges == Any[[10.0, 20.0], [3.0]]
    @test s_partial.method_instance.dep_var === :Diff
    @test s_partial.method_instance.dep_range == collect(-5.0:1.0:5.0)
    @test s_partial.engine_name == "EmulatorEngine"

    # 4. Incompatible stimulus refused, session unchanged
    mutable struct EmptyDummyStimulus <: AbstractStimulusParameters end
    register_stimulus!(EmptyDummyStimulus; engine = :EmulatorEngine, description = "Empty dummy")
    s_adj = SessionContext(
        ExperimentParameters("Adj", :Ref, [10.0], 1),
        MarkerLayout(),
        Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0),
    )
    # Adjustment cannot adjust a stimulus without numeric parameters
    @test_throws ArgumentError set_parameters!(s_adj, Dict("stimulus" => "EmptyDummyStimulus"))
    @test s_adj.stim_par isa MarkerLayout # Unchanged

    # A stimulus whose only number becomes the variable leaves the adjustment nothing
    mutable struct OneNumberStimulus <: AbstractStimulusParameters
        x::Float64
    end
    OneNumberStimulus() = OneNumberStimulus(1.0)
    register_stimulus!(OneNumberStimulus; engine = :EmulatorEngine)
    err = try set_parameters!(s_adj, Dict("stimulus" => "OneNumberStimulus")) catch e e end
    @test err isa ArgumentError && occursin("none it can adjust", err.msg)
    @test s_adj.stim_par isa MarkerLayout && s_adj.method_instance.dep_var === :Diff

    # An adjustment of a parameter the new stimulus lacks starts again: its range was in
    # the old parameter's units
    set_parameters!(s_adj, Dict("stimulus" => "TemporalOppelKundt"))
    @test s_adj.stim_par isa TemporalOppelKundt
    @test s_adj.method_instance.dep_var in numeric_parameters(s_adj.stim_par)
    @test !(s_adj.method_instance.dep_var in s_adj.ex_par.indep_var_names)
    @test :dep_range in unset_settings(s_adj.method_instance)
    @test s_adj.engine_name == "AudioStimulusEngine"

    # Scored method cannot run when scoring is invalid for conditions
    mutable struct PartlyScoredTestStimulus <: AbstractStimulusParameters
        level::Float64
    end
    PartlyScoredTestStimulus() = PartlyScoredTestStimulus(1.0)
    PsychophysicsManager.correct_answer(::PartlyScoredTestStimulus, vars::NamedTuple) =
        vars.level > 1 ? 1 : nothing
    register_stimulus!(PartlyScoredTestStimulus; engine = :EmulatorEngine)

    s_scored = SessionContext(
        ExperimentParameters("Scored", :level, [1.0, 2.0], 1),
        MarkerLayout(),
        Staircase(),
    )
    # PartlyScoredTestStimulus scores only level > 1, so Staircase (steps_on_answers) refuses it
    @test_throws ArgumentError set_parameters!(s_scored, Dict("stimulus" => "PartlyScoredTestStimulus"))
    @test s_scored.stim_par isa MarkerLayout # Unchanged

    # Stimulus whose correct_answer throws on a condition is refused
    mutable struct BrokenScoringStimulus <: AbstractStimulusParameters
        x::Float64
    end
    BrokenScoringStimulus() = BrokenScoringStimulus(1.0)
    PsychophysicsManager.correct_answer(::BrokenScoringStimulus, ::NamedTuple) =
        throw(ArgumentError("unscorable condition"))
    register_stimulus!(BrokenScoringStimulus; engine = :EmulatorEngine)
    s_broken = SessionContext(
        ExperimentParameters("Broken", :Ref, [10.0], 1),
        MarkerLayout(),
        ConstantStimuli(),
    )
    @test_throws ArgumentError set_parameters!(s_broken, Dict("stimulus" => "BrokenScoringStimulus"))
    @test s_broken.stim_par isa MarkerLayout # Unchanged

    # Unknown stimulus name refused
    @test_throws ArgumentError set_parameters!(s_scored, Dict("stimulus" => "NonExistentStimulus"))

    # 5. Engine query and default_engine_type before/after backend load
    mutable struct TestCoreEngineStimulus <: AbstractStimulusParameters end
    register_stimulus!(TestCoreEngineStimulus;
                       engine = :TestCoreUnloadedEngine,
                       backend = [:TestCoreFakeBackend],
                       description = "Engine query test")
    err = try default_engine_type(TestCoreEngineStimulus()) catch e e end
    @test err isa ErrorException
    @test occursin("TestCoreUnloadedEngine", err.msg)
    @test occursin("TestCoreFakeBackend", err.msg)

    # Choosing it names the engine and loads nothing
    s_unloaded = SessionContext(ExperimentParameters("Unloaded", :Ref, [10.0], 1),
                                MarkerLayout(), ConstantStimuli())
    mutable struct UnloadedEngineStimulus <: AbstractStimulusParameters
        x::Float64
    end
    UnloadedEngineStimulus() = UnloadedEngineStimulus(1.0)
    register_stimulus!(UnloadedEngineStimulus; engine = :TestCoreUnloadedEngine)
    set_parameters!(s_unloaded, Dict("stimulus" => "UnloadedEngineStimulus"))
    @test s_unloaded.engine_name == "TestCoreUnloadedEngine"
    @test !haskey(PsychophysicsManager.ENGINE_REGISTRY, :TestCoreUnloadedEngine)

    # Register the engine type now
    struct TestCoreUnloadedEngine <: AbstractStimulusEngine end
    register_engine_type!(TestCoreUnloadedEngine)
    @test default_engine_type(TestCoreEngineStimulus()) === TestCoreUnloadedEngine

    # 6. The older registration calls still work: the engine of a stimulus chosen by
    # name is then the one its `default_engine_type` method names, and a stimulus with
    # no engine known is refused
    mutable struct OldStyleStimulus <: AbstractStimulusParameters
        x::Float64
    end
    OldStyleStimulus() = OldStyleStimulus(1.0)
    register_stimulus_type!(OldStyleStimulus)
    s_old = SessionContext(ExperimentParameters("Old", :Ref, [10.0], 1),
                           MarkerLayout(), ConstantStimuli())
    s_old.engine_name = "GeometryVisualEngine"
    err = try set_parameters!(s_old, Dict("stimulus" => "OldStyleStimulus")) catch e e end
    @test err isa ArgumentError && occursin("No engine is known", err.msg)
    @test s_old.stim_par isa MarkerLayout && s_old.engine_name == "GeometryVisualEngine"

    struct HandWrittenEngine <: AbstractStimulusEngine end
    PsychophysicsManager.default_engine_type(::OldStyleStimulus) = HandWrittenEngine
    @test default_engine_type(OldStyleStimulus()) === HandWrittenEngine
    set_parameters!(s_old, Dict("stimulus" => "OldStyleStimulus"))
    @test s_old.stim_par isa OldStyleStimulus && s_old.engine_name == "HandWrittenEngine"
end
