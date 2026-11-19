using Random

# Filled-space layout used throughout: distractors fill the reference interval,
# `Diff` extends the test interval, so the point of subjective equality sits at
# `Diff = bias_per_distractor * DistrN`.
function ok_stim_params(; DistrN = 4, Diff = 0.0)
    return MarkerLayout(
        StimConfig = "d r t",
        Ref = 240.0,
        DistrN = DistrN,
        Diff = Diff,
        MarkerSize = (2, 30),
        Anchor = :middle,
    )
end

function ok_observer_session(; participant = "sim_observer", levels = -40.0:10.0:40.0,
                             repeats = 12, DistrN = 4)
    ex_par = ExperimentParameters("OK_Model_Observer", :Diff, collect(levels), repeats)
    return SessionContext(participant, ex_par, ok_stim_params(DistrN = DistrN),
                          ConstantStimuli(); tags = ["test"])
end

@testset "Trial context and the render-only engine" begin
    engine = OffscreenVisualEngine(400, 120)
    @test canvas_size(engine) == (400, 120)
    # Nothing presented yet: the engine reports no frame rather than an empty one
    @test last_frame(engine) === nothing
    @test last_frame(EmulatorEngine()) === nothing

    params = ok_stim_params(DistrN = 3, Diff = 20.0)
    result = present_stimulus(engine, params, [20.0])
    @test result.response === nothing          # render-only: the source answers
    @test result.onset !== nothing

    frame = last_frame(engine)
    @test frame isa AbstractMatrix{Bool}
    @test size(frame) == (400, 120)
    @test any(frame)                            # markers actually drawn

    # The buffer holds exactly what the headless rasterizer produces, which is
    # what the on-screen engine draws too
    reference = fill(false, 400, 120)
    render_stimulus!(reference, params)
    @test frame == reference

    @test_throws ArgumentError OffscreenVisualEngine(0, 100)
    @test_throws ErrorException present_stimulus(engine, BaseStimulusParameters(0.0), [0.0])
end

@testset "Response-source contract stays backward compatible" begin
    context = TrialContext(ok_stim_params(), [:Diff], [0.0], 1, "Test", nothing)
    # A source written against the original one-argument contract still works
    scripted = ScriptedResponseSource([1, -1])
    @test request_response(scripted, context)[1] == 1
    @test request_response(scripted)[1] == -1

    session = ok_observer_session(repeats = 1)
    session.current_trial_idx = 7
    built = TrialContext(session, [12.0], nothing)
    @test built.trial_index == 7
    @test built.indep_var_names == [:Diff]
    @test built.indep_var_vals == [12.0]
    @test built.experiment_name == "OK_Model_Observer"
    @test built.stim_par === session.stim_par
end

@testset "Observer task and response coding" begin
    task = length_comparison_task()
    @test task.options == ("left", "right")
    @test task.positive_option == "right"
    @test occursin("left", task.instructions) && occursin("right", task.instructions)
    # The wording must not hand the observer the measurement it is asked to make
    @test !occursin("Diff", task.instructions)
    @test !occursin("illusion", lowercase(task.instructions))

    @test response_code(task, "right") == 1
    @test response_code(task, "left") == -1
    @test_throws ArgumentError response_code(task, "maybe")

    @test_throws ArgumentError ObserverTask("q", ("a", "a"), "a")
    @test_throws ArgumentError ObserverTask("q", ("a", "b"), "c")
    @test_throws ArgumentError ObserverTask("   ", ("a", "b"), "a")
end

@testset "Simulated observer decides from the layout geometry" begin
    # "d r t": reference interval, then the test interval extended by Diff
    lengths = segment_lengths(ok_stim_params(DistrN = 4, Diff = 30.0))
    @test length(lengths) == 2
    @test lengths[1] ≈ 240.0
    @test lengths[2] ≈ 270.0

    task = length_comparison_task()
    noiseless = SimulatedObserver(noise_sd = 1e-9, bias_per_distractor = 0.0,
                                  rng = Xoshiro(1))
    ask(observer, params) = query_observer(
        observer, ObserverQuestion(task, TrialContext(params, [:Diff], [params.Diff], 1, "T", nothing))
    ).choice

    @test ask(noiseless, ok_stim_params(Diff = 40.0)) == "right"
    @test ask(noiseless, ok_stim_params(Diff = -40.0)) == "left"

    # With a bias the test interval must be physically longer to be called longer
    biased = SimulatedObserver(noise_sd = 1e-9, bias_per_distractor = 5.0,
                               positive_interval = 2, rng = Xoshiro(2))
    @test ask(biased, ok_stim_params(DistrN = 4, Diff = 10.0)) == "left"   # 10 < 5*4
    @test ask(biased, ok_stim_params(DistrN = 4, Diff = 30.0)) == "right"  # 30 > 5*4

    @test_throws ArgumentError SimulatedObserver(noise_sd = 0.0)
    @test_throws ArgumentError SimulatedObserver(lapse_rate = 1.5)
    @test_throws ArgumentError SimulatedObserver(positive_interval = 3)
end

@testset "A simulated observer runs a full session and its threshold is recovered" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
            bias, distractors = 5.0, 4
            observer = SimulatedObserver(bias_per_distractor = bias, noise_sd = 12.0,
                                         rng = Xoshiro(20260812))
            source = ModelObserverSource(observer, length_comparison_task())
            session = ok_observer_session(levels = -20.0:10.0:60.0, repeats = 40,
                                          DistrN = distractors)
            engine = OffscreenVisualEngine(600, 160)

            with_response_source(source) do
                run_experiment!(session, engine; report = :silent)
            end

            @test session.state == FINISHED
            @test length(session.history) == 9 * 40
            @test all(t -> t.is_valid, session.history)
            @test all(t -> t.response in (0, 1), session.history)
            @test length(source.records) == length(session.history)
            @test all(r -> r.response !== nothing, source.records)

            # Ground truth: PSE sits at Diff = bias * DistrN
            fit = fit_psychometric_curve(get_aggregated_data(session);
                                         gamma = session.fit_gamma)
            @test fit.converged
            @test isapprox(fit.alpha, bias * distractors, atol = 4.0)

            provenance = observer_provenance(source)
            @test provenance["backend"] == "SimulatedObserver"
            @test provenance["bias_per_distractor"] == bias
            @test provenance["failed_requests"] == 0
            # What was asked belongs to the session, not to who answered it
            @test !haskey(provenance, "instructions")
            @test !haskey(provenance, "positive_option")
        end
    end
end

# A backend that never answers, to exercise the failure policy without a network
struct SilentObserver <: PsychophysicsManager.AbstractObserverBackend end
PsychophysicsManager.query_observer(::SilentObserver, ::ObserverQuestion) =
    ObserverAnswer(choice = nothing, raw = "I cannot determine this.")

@testset "Unusable answers are retried, never invented" begin
    context = TrialContext(ok_stim_params(), [:Diff], [0.0], 3, "T", nothing)

    erroring = ModelObserverSource(SilentObserver(), length_comparison_task();
                                   max_attempts = 2)
    @test_throws ErrorException request_response(erroring, context)
    @test length(erroring.records) == 2                  # every attempt is recorded
    @test all(r -> r.response === nothing, erroring.records)
    @test erroring.records[end].choice === nothing
    # The reply survives in the record: a failure that says only "no answer"
    # cannot be diagnosed afterwards
    @test erroring.records[end].raw == "I cannot determine this."

    invalidating = ModelObserverSource(SilentObserver(), length_comparison_task();
                                       max_attempts = 1, on_failure = :invalidate)
    response, _ = (@test_logs (:warn,) request_response(invalidating, context))
    @test isnan(response)                                # cannot pass for a decision
    @test invalidating.pending_invalid == [3]
    @test observer_provenance(invalidating)["failed_requests"] == 1

    @test_throws ArgumentError ModelObserverSource(SilentObserver(); max_attempts = 0)
    @test_throws ArgumentError ModelObserverSource(SilentObserver(); on_failure = :ignore)
end

@testset "Failed trials are marked invalid as they are recorded" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
            source = ModelObserverSource(SilentObserver(), length_comparison_task();
                                         max_attempts = 1, on_failure = :invalidate)
            session = ok_observer_session(levels = [0.0, 10.0], repeats = 1)
            engine = OffscreenVisualEngine(300, 100)

            with_response_source(source) do
                run_experiment!(session, engine; report = :silent,
                                on_trial_end = s -> invalidate_failed_trials!(source, s))
            end

            @test length(session.history) == 2
            @test !any(t -> t.is_valid, session.history)   # no invented data survives
            @test isempty(source.pending_invalid)
            @test isempty(get_aggregated_data(session))
            @test invalidate_failed_trials!(source, session) == 0   # idempotent
        end
    end
end

@testset "Observer provenance travels with the data" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
            observer = SimulatedObserver(bias_per_distractor = 3.0, noise_sd = 10.0,
                                         rng = Xoshiro(7))
            source = ModelObserverSource(observer, length_comparison_task())
            session = ok_observer_session(levels = [0.0, 20.0], repeats = 2)

            with_response_source(source) do
                run_experiment!(session, OffscreenVisualEngine(400, 120); report = :silent)
            end
            set_observer_metadata!(session, observer_provenance(source))

            set_task!(session, source.task)

            reloaded = load_session(session.save_path)
            @test reloaded.observer_metadata["backend"] == "SimulatedObserver"
            @test reloaded.observer_metadata["bias_per_distractor"] == 3.0
            @test reloaded.observer_metadata["failed_requests"] == 0
            @test !haskey(reloaded.observer_metadata, "instructions")

            # The question and the response coding survive the round trip on
            # their own field, whoever answered
            @test reloaded.task.instructions == source.task.instructions
            @test reloaded.task.options == source.task.options
            @test reloaded.task.positive_option == source.task.positive_option

            # A session answered by a person carries no observer metadata, and
            # one that declared no task stores none
            human = ok_observer_session(participant = "S01", levels = [0.0], repeats = 1)
            @test isempty(human.observer_metadata)
            @test human.task === nothing
            save_session_checkpoint(human)
            @test load_session(human.save_path).task === nothing

            # …but a person is asked a question too, and it is recorded the same way
            set_task!(human, length_comparison_task())
            @test load_session(human.save_path).task.positive_option == "right"
        end
    end
end

@testset "Naming an observer" begin
    @test PsychophysicsManager.parse_observer_spec("simulated") == (:simulated, "simulated_observer")
    @test PsychophysicsManager.parse_observer_spec("  simulated  ") == (:simulated, "simulated_observer")
    @test PsychophysicsManager.parse_observer_spec("anthropic/claude-opus-5") ==
          (:openrouter, "anthropic/claude-opus-5")
    @test PsychophysicsManager.parse_observer_spec("openrouter:openai/gpt-5") ==
          (:openrouter, "openai/gpt-5")
    # A slug and a channel prefix name different instruments, one character apart
    @test PsychophysicsManager.parse_observer_spec("anthropic:claude-opus-5") ==
          (:anthropic, "claude-opus-5")

    # A bare model name is refused rather than assigned to a channel
    @test_throws ArgumentError PsychophysicsManager.parse_observer_spec("claude-opus-5")
    @test_throws ArgumentError PsychophysicsManager.parse_observer_spec("")
    @test_throws ArgumentError PsychophysicsManager.parse_observer_spec("bedrock:some-model")
    @test_throws ArgumentError PsychophysicsManager.parse_observer_spec("anthropic:")

    backend = model_observer("simulated"; bias_per_distractor = 5.0, noise_sd = 12.0,
                             positive_interval = 1)
    @test backend isa SimulatedObserver
    @test backend.bias_per_distractor == 5.0
    @test backend.positive_interval == 1

    # The networked channels live in an extension; without it the error names the fix
    if Base.get_extension(PsychophysicsManager, :PsychophysicsManagerModelObserverExt) === nothing
        @test_throws ErrorException model_observer("anthropic/claude-opus-5")
    end

    withenv("PEM_TEST_KEY" => nothing) do
        @test_throws ErrorException PsychophysicsManager.require_api_key("PEM_TEST_KEY")
    end
    withenv("PEM_TEST_KEY" => "secret") do
        @test PsychophysicsManager.require_api_key("PEM_TEST_KEY") == "secret"
    end
end

# A backend that always answers, with a per-request price to summarize
struct CostedObserver <: PsychophysicsManager.AbstractObserverBackend end
PsychophysicsManager.query_observer(::CostedObserver, question::ObserverQuestion) =
    ObserverAnswer(choice = question.task.positive_option, raw = "{}", latency_s = 0.5,
                   metadata = Dict{String, Any}("cost" => 0.01))

@testset "run_observer_experiment! wires a whole run" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

            # Unanswered trials: invalidated as they are recorded, and the caller's
            # own on_trial_end still runs
            source = ModelObserverSource(SilentObserver(), length_comparison_task();
                                         max_attempts = 1, on_failure = :invalidate)
            session = ok_observer_session(levels = [0.0, 10.0], repeats = 1)
            seen = Ref(0)
            returned = run_observer_experiment!(session, source,
                                                OffscreenVisualEngine(300, 100);
                                                report = :silent,
                                                on_trial_end = _ -> (seen[] += 1))

            @test returned === source
            @test seen[] == 2
            @test !any(t -> t.is_valid, session.history)
            @test isempty(get_aggregated_data(session))
            # Provenance is stored by the run itself, not by the caller
            @test session.observer_metadata["backend"] == "SilentObserver"
            @test session.observer_metadata["failed_requests"] == 2
            # So are the question and the tags that mark a model session; the
            # operator's own tags are left alone, and a backend that names no
            # model contributes no `model:` tag
            @test session.task === source.task
            @test "ai-observer" in session.tags
            @test "test" in session.tags
            @test !any(startswith("model:"), session.tags)

            # A backend that names one is tagged with it, and rerunning adds
            # nothing a second time
            named = ModelObserverSource(SimulatedObserver(rng = Xoshiro(3)),
                                        length_comparison_task())
            tagged = ok_observer_session(levels = [0.0], repeats = 1)
            run_observer_experiment!(tagged, named, OffscreenVisualEngine(300, 100);
                                     report = :silent)
            @test "model:simulated" in tagged.tags
            PsychophysicsManager.stamp_observer_tags!(tagged, named.backend)
            @test count(==("model:simulated"), tagged.tags) == 1

            # A run that raises still records who answered (the `finally` branch)
            aborting = ModelObserverSource(SilentObserver(), length_comparison_task();
                                           max_attempts = 1)
            interrupted = ok_observer_session(levels = [0.0], repeats = 1)
            @test_throws ErrorException run_observer_experiment!(
                interrupted, aborting, OffscreenVisualEngine(200, 80); report = :silent)
            @test interrupted.observer_metadata["backend"] == "SilentObserver"
        end
    end
end

@testset "An observer whose answers hardly vary is named as such" begin
    sweep = [-120.0, -60.0, 60.0, 120.0]

    # A session answered exactly as given, cycling through the level set
    function answered(responses, validity = trues(length(responses)))
        session = ok_observer_session(levels = sweep, repeats = 1)
        set_task!(session, length_comparison_task())
        for (i, response) in enumerate(responses)
            push!(session.history,
                  Trial(i, 0.0, 0.1, [sweep[mod1(i, length(sweep))]], response, validity[i]))
        end
        return session
    end

    # Without a task there is no name for the option, so nothing is claimed
    @test constant_response(ok_observer_session()) === nothing

    # "right" on all but two trials: correct at positive Diff, wrong at negative,
    # so accuracy lands near 50% and looks like random responding
    @test constant_response(answered([fill(1, 19); 0; 0])) == ("right", 19, 21)

    # Exactly 90% is inside the rule and 80% is outside it
    @test constant_response(answered([fill(1, 18); 0; 0])) == ("right", 18, 20)
    @test constant_response(answered([fill(1, 8); 0; 0])) === nothing

    # Below ten valid trials the share would demand unanimity, so nothing is read
    # into a short session either way
    @test constant_response(answered(fill(1, 9))) === nothing
    @test constant_response(answered(fill(1, 10))) == ("right", 10, 10)

    # The other direction is caught the same way, by the option's own name
    @test constant_response(answered([fill(0, 11); 1])) == ("left", 11, 12)

    # Invalid trials count for neither side
    @test constant_response(answered([fill(1, 9); fill(0, 4)],
                                     [trues(9); falses(4)])) === nothing
    @test constant_response(answered([fill(1, 10); fill(0, 4)],
                                     [trues(10); falses(4)])) == ("right", 10, 10)
end

@testset "A run's requests are summarized" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
            source = ModelObserverSource(CostedObserver(), length_comparison_task())
            session = ok_observer_session(levels = [0.0, 10.0], repeats = 2)
            run_observer_experiment!(session, source, OffscreenVisualEngine(300, 100);
                                     report = :silent)

            summary = observer_summary(source)
            @test summary.requests == 4
            @test summary.failed == 0
            @test isempty(summary.failures)
            @test summary.median_latency_s == 0.5
            @test summary.cost ≈ 0.04
            @test redirect_stdout(() -> print_observer_summary(session, source),
                                  devnull) === nothing

            # Failures are tallied by reason; a backend that names none is "unknown"
            silent = ModelObserverSource(SilentObserver(), length_comparison_task();
                                         max_attempts = 2, on_failure = :invalidate)
            quiet = ok_observer_session(levels = [0.0], repeats = 1)
            run_observer_experiment!(quiet, silent, OffscreenVisualEngine(200, 80);
                                     report = :silent)
            failed = observer_summary(silent)
            @test failed.requests == 2          # both attempts, not just the trial
            @test failed.failures == ["unknown" => 2]
            @test failed.cost == 0.0
        end
    end
end
