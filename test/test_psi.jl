# Tests for the Psi method (`src/Methods/psi.jl`), and its agreement with the Palamedes
# toolbox run under Octave (`test/reference/palamedes_psi.m`).

using Statistics

# ── Fixtures ─────────────────────────────────────────────────────────────────

struct QuietEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::QuietEngine, ::AbstractStimulusParameters,
                                      ::AbstractVector{<:Number}) = nothing

# A two-interval task: which interval held the target is a variable of the design, so
# the answer that is correct is read from the trial's variables
mutable struct IntervalTask <: AbstractStimulusParameters end
PsychophysicsManager.correct_answer(::IntervalTask, vars::NamedTuple) =
    vars.target_interval == 1 ? 1 : -1
register_stimulus_type!(IntervalTask)

# A two-interval participant whose accuracy rises with the level; its 75 % point is
# exactly `threshold`
struct IntervalObserver <: AbstractResponseSource
    threshold::Float64
    slope::Float64
    rng::Random.Xoshiro
end

function PsychophysicsManager.request_response(observer::IntervalObserver,
                                               context::TrialContext)
    level, target = context.indep_var_vals
    correct = target == 1 ? 1 : -1
    p = 0.5 + 0.5 / (1 + exp(-observer.slope * (level - observer.threshold)))
    return (rand(observer.rng) < p ? correct : -correct, time())
end

# Answers right or wrong, trial by trial, as `pattern` says
struct AnswerPattern <: AbstractResponseSource
    pattern::Vector{Bool}
end

function PsychophysicsManager.request_response(observer::AnswerPattern,
                                               context::TrialContext)
    correct = context.indep_var_vals[2] == 1 ? 1 : -1
    return (popfirst!(observer.pattern) ? correct : -correct, time())
end

# A comparison with no correct answer, such as "is the test longer than the
# reference": the observer answers +1 with a probability that rises with the level and
# is one half at `pse`
struct ComparisonObserver <: AbstractResponseSource
    pse::Float64
    slope::Float64
    rng::Random.Xoshiro
end

function PsychophysicsManager.request_response(observer::ComparisonObserver,
                                               context::TrialContext)
    level = first(context.indep_var_vals)
    p = 1 / (1 + exp(-observer.slope * (level - observer.pse)))
    return (rand(observer.rng) < p ? 1 : -1, time())
end

psi_session(method, levels; seed = 20260908) =
    SessionContext("Adaptive",
                   ExperimentParameters("2IFC", [:level, :target_interval],
                                        Any[levels, [1.0, 2.0]], 1),
                   IntervalTask(), method; rng_seed = seed)

# Runs a session to its end the way one interrupted after every trial is: stopped once
# the trial is recorded, read from its file again, and continued
function run_reloading(session, source)
    with_response_source(source) do
        while session.state != FINISHED
            run_experiment!(session, QuietEngine(); report = :silent,
                            on_trial_end = s -> s.state == RUNNING && throw(InterruptException()))
            session = load_session(session.save_path)
        end
    end
    return session
end

const PM = PsychophysicsManager

# ── Tests ────────────────────────────────────────────────────────────────────

@testset "Psi" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
            levels = collect(-1.0:0.1:1.0)

            @testset "Psi agrees with the Palamedes toolbox" begin
                # Seven runs of PAL_AMPM_setupPM / PAL_AMPM_updatePM under Octave, one per
                # psychometric function (`test/reference/palamedes_psi.m`, which names the
                # columns), each replayed level by level: the posterior has to come out
                # the same after every answer, and the level chosen next has to be the
                # toolbox's
                reference = joinpath(@__DIR__, "reference")
                runs = [split(line, ',') for line in
                        eachline(joinpath(reference, "palamedes_psi_runs.csv"))]
                trials = [parse.(Float64, split(line, ',')) for line in
                          eachline(joinpath(reference, "palamedes_psi_trials.csv"))]
                grid(v) = collect(range(v[1], v[2]; length = Int(v[3])))
                replayed = 0
                for (r, run) in enumerate(runs)
                    v = parse.(Float64, run[2:end])
                    stim = grid(v[3:5])
                    method = Psi(; trial_limit = Int(v[12]), stim_range = stim,
                                   alpha_range = grid(v[6:8]), beta_range = grid(v[9:11]),
                                   gamma = v[1], lambda = v[2], pf = Symbol(run[1]))
                    posterior = PM.prior_posterior(method)
                    @test stim[PM.most_informative(posterior)] ≈ v[13]
                    for (_, _, level, answer, threshold, slope, sd, next) in
                        filter(row -> row[1] == r, trials)
                        PM.take_answer!(posterior, PM.grid_index(stim, level), answer == 1)
                        centre = PM.posterior_mean(posterior, posterior.alphas)
                        @test centre ≈ threshold atol = 1e-12
                        @test PM.posterior_mean(posterior, posterior.log_slopes) ≈ slope atol = 1e-12
                        @test sqrt(PM.posterior_mean(posterior, (posterior.alphas .- centre) .^ 2)) ≈
                              sd atol = 1e-12
                        @test stim[PM.most_informative(posterior)] ≈ next
                        replayed += 1
                    end
                end
                @test length(runs) == length(PSYCHOMETRIC_FUNCTIONS) && replayed == 305
            end

            @testset "Psi converges on a simulated observer" begin
                # A threshold estimate is a random variable, so one seeded run says
                # little: five observers differing only in their stream are asked, and
                # the median one has to land near the threshold. What would fail here is
                # a method that does not converge at all.
                true_threshold = 0.2
                estimates = Float64[]
                for seed in 11:15
                    session = psi_session(Psi(trial_limit = 60, pf = :logistic), levels)
                    with_response_source(IntervalObserver(true_threshold, 5.0,
                                                          Random.Xoshiro(seed))) do
                        run_experiment!(session, QuietEngine(); report = :silent)
                    end
                    @test session.state == FINISHED
                    @test length(session.history) == 60
                    push!(estimates, method_threshold(session.method_instance))
                end
                errors = abs.(estimates .- true_threshold)
                @test median(errors) < 0.15
                @test maximum(errors) < 0.35
            end

            @testset "A Psi run continued from its file draws on from where it stopped" begin
                # What it draws during a run: the interval of the target, and which side
                # of the estimate the level is presented on
                make() = Psi(trial_limit = 20, pf = :logistic, symmetric = true)
                whole = psi_session(make(), levels)
                with_response_source(IntervalObserver(0.0, 5.0, Random.Xoshiro(7))) do
                    run_experiment!(whole, QuietEngine(); report = :silent)
                end
                continued = run_reloading(psi_session(make(), levels),
                                          IntervalObserver(0.0, 5.0, Random.Xoshiro(7)))
                presented(session) = [(t.indep_var_vals, t.response) for t in session.history]
                @test whole.state == FINISHED
                @test presented(continued) == presented(whole)
                @test length(unique(presented(whole))) > 4
            end

            @testset "A Psi run comes back from its file by replay" begin
                session = psi_session(Psi(trial_limit = 12, pf = :logistic), levels)
                with_response_source(IntervalObserver(0.0, 5.0, Random.Xoshiro(7))) do
                    run_experiment!(session, QuietEngine(); report = :silent)
                end
                @test session.state == FINISHED

                live = session.method_instance
                rebuilt = load_session(session.save_path).method_instance
                # The posterior is not in the file; what is in the file rebuilds it
                @test rebuilt.posterior.probability ≈ live.posterior.probability
                @test method_threshold(rebuilt) ≈ method_threshold(live)
                @test PM.suggested_level(rebuilt) == PM.suggested_level(live)
                @test rebuilt.scores == live.scores

                # An undo drops the last answer and rebuilds from the rest
                @test undo_last_trial!(session) == 12
                @test length(live.scores) == 11
                @test live.trials_spent == 11
            end

            @testset "Psi answers to the trial rules" begin
                method = Psi(trial_limit = 3, pf = :logistic)
                session = psi_session(method, levels)
                # A repeat request costs no trial; a missing response spends one
                # without touching the posterior, and neither is scored
                with_response_source(ScriptedResponseSource(
                        [0, 1, MISSING_RESPONSE, :timeout, 1])) do
                    run_experiment!(session, QuietEngine(); report = :silent)
                end
                @test session.state == FINISHED
                @test length(session.history) == 3
                @test isnan(session.history[2].response)
                @test session.history[3].response === :timeout
                @test count(t -> t.correct !== nothing, session.history) == 1
            end

            @testset "Undo unwinds only what the posterior took in" begin
                # A trial nobody answered spent a trial and nothing else, so undoing it
                # must not drop the answer recorded before it
                method = Psi(trial_limit = 2, pf = :logistic)
                session = psi_session(method, levels)
                with_response_source(ScriptedResponseSource([1, :timeout])) do
                    run_experiment!(session, QuietEngine(); report = :silent)
                end
                @test length(method.scores) == 1
                @test method.trials_spent == 2

                @test undo_last_trial!(session) == 2
                @test length(method.scores) == 1
                @test method.trials_spent == 1

                @test undo_last_trial!(session) == 1
                @test isempty(method.scores)
                @test method.trials_spent == 0
                @test isnan(method_threshold(method))
            end

            @testset "Undo past an outlier" begin
                # Psi takes the undone trial's own answer out
                method = Psi(trial_limit = 3, pf = :logistic)
                session = psi_session(method, levels)
                with_response_source(AnswerPattern([true, true, false])) do
                    run_experiment!(session, QuietEngine(); report = :silent)
                end
                kept = [(method.levels[i], method.scores[i]) for i in (1, 3)]
                @test mark_outlier!(session, 3)
                @test undo_last_trial!(session) == 2
                @test collect(zip(method.levels, method.scores)) == kept
            end

            @testset "An operator's trial enters the Psi posterior" begin
                method = Psi(trial_limit = 4, pf = :logistic)
                session = psi_session(method, levels)
                observer = IntervalObserver(0.0, 5.0, Random.Xoshiro(3))
                start_session!(session)
                with_response_source(observer) do
                    run_next_trial!(session, QuietEngine())
                end
                after_first = method_threshold(method)

                # The operator presents a level of the grid, with the target first
                level = levels[16]
                @test present_condition!(session, [level, 1.0])
                with_response_source(ScriptedResponseSource([1])) do
                    run_next_trial!(session, QuietEngine())
                end
                @test session.history[2].origin === :operator
                @test session.history[2].correct === true
                @test method.levels[end] == level && method.scores[end] == 1
                @test method.trials_spent == 1          # not one of Psi's own
                @test session_trial_total(session) ==
                      2 + remaining_trial_count(method) == 1 + method.trial_limit

                # A posterior rebuilt from the file includes it
                rebuilt = load_session(session.save_path).method_instance
                @test rebuilt.levels == method.levels
                @test method_threshold(rebuilt) ≈ method_threshold(method)
                @test PM.suggested_level(rebuilt) == PM.suggested_level(method)

                # Undoing it takes it out again, and it is presented again next
                @test undo_last_trial!(session) == 2
                @test length(method.scores) == 1 && method.trials_spent == 1
                @test method_threshold(method) ≈ after_first
                @test only(session.operator_requests).vals == [level, 1.0]

                # Psi's own sequence keeps its length
                with_response_source(observer) do
                    run_experiment!(session, QuietEngine(); report = :silent)
                end
                @test session.state == FINISHED
                @test count(t -> t.is_valid && t.origin === :method, session.history) == 4
                @test count(t -> t.is_valid && t.origin === :operator, session.history) == 1

                # A level of the design off Psi's grid is recorded but not taken in
                coarse = Psi(trial_limit = 2, pf = :logistic, stim_range = levels[1:2:end])
                session = psi_session(coarse, levels)
                start_session!(session)
                @test present_condition!(session, [levels[2], 1.0])
                @test_logs (:warn, r"not on this Psi run's stimulus grid") begin
                    with_response_source(ScriptedResponseSource([1])) do
                        run_next_trial!(session, QuietEngine())
                    end
                end
                @test session.history[1].origin === :operator && isempty(coarse.scores)
            end

            @testset "Psi is chosen and set as parameters" begin
                session = psi_session(Staircase(2), levels)
                @test "Psi" in selectable_methods()
                set_parameters!(session, Dict("method" => "Psi",
                                              "method.trial_limit" => 30,
                                              "method.pf" => "logistic"))
                @test nameof(typeof(session.method_instance)) == :Psi
                @test session.method_instance.trial_limit == 30
                @test session.method_instance.pf === :logistic
                @test_throws ArgumentError set_parameters!(session,
                                                           Dict("method.pf" => "nonsense"))
                @test_throws ArgumentError Psi(beta_range = Float64[])
                # A Weibull's threshold is positive, so a grid reaching 0 is refused
                # when the run starts, naming the function
                weibull = psi_session(Psi(pf = :weibull), collect(0.0:0.1:1.0))
                @test_throws r":weibull" start_session!(weibull)
            end

            @testset "A Psi and a staircase interleave" begin
                # The composite hands each track the design without the column that
                # names the track, so neither draws a track index of its own
                design = ExperimentParameters("mixed", [:level, :target_interval, :track],
                                              Any[levels, [1.0, 2.0], 1:2], 1)
                tracks = [Psi(trial_limit = 8, pf = :logistic),
                          Staircase(2; trial_limit = 6)]
                session = SessionContext("Mixed", design, IntervalTask(),
                                         Interleaved(tracks); rng_seed = 3)
                with_response_source(IntervalObserver(0.0, 6.0, Random.Xoshiro(8))) do
                    run_experiment!(session, QuietEngine(); report = :silent)
                end
                @test session.state == FINISHED
                @test length(session.history) == 14
                @test count(t -> t.indep_var_vals[3] == 1.0, session.history) == 8

                # Psi's posterior came back from the file, rebuilt inside the composite
                rebuilt = load_session(session.save_path).method_instance
                @test method_threshold(rebuilt.tracks[1]) ≈ method_threshold(tracks[1])
                @test PM.suggested_level(rebuilt.tracks[1]) == PM.suggested_level(tracks[1])
            end

            @testset "Psi on a task without a correct answer finds the PSE" begin
                design = ExperimentParameters("PSE", :level, collect(-10.0:1.0:10.0), 1)
                for symmetric in (nothing, false)
                    session = SessionContext("PSE", design, BaseStimulusParameters(10.0),
                                             Psi(trial_limit = 80, symmetric = symmetric);
                                             rng_seed = 11)
                    with_response_source(ComparisonObserver(2.5, 0.6, Random.Xoshiro(3))) do
                        run_experiment!(session, QuietEngine(); report = :silent)
                    end
                    method = session.method_instance
                    # What a task without a correct answer takes by default
                    @test method.scored == false
                    @test PM.guess_rate(method) == method.lambda == 0.02
                    @test PM.function_name(method) === :logistic
                    @test PM.mirrors(method) == (symmetric === nothing)
                    estimate = method_threshold(method)
                    @test abs(estimate - 2.5) < 1.5
                    # Recorded 1/0, so a level's mean response is a proportion
                    @test all(t -> t.response in (0, 1) && t.correct === nothing,
                              session.history)

                    # The file holds the levels presented, mirrored ones among them
                    rebuilt = load_session(session.save_path).method_instance
                    @test method_threshold(rebuilt) ≈ estimate
                    @test rebuilt.levels == method.levels
                    # An undo takes the answer out by its recorded direction
                    @test undo_last_trial!(session) == 80
                    @test length(method.scores) == 79
                end

                # A symmetric run presents levels Psi did not choose, their mirror
                # images about the estimate
                mirrored = Psi(trial_limit = 1, symmetric = true)
                session = SessionContext("PSE", design, BaseStimulusParameters(10.0), mirrored;
                                         rng_seed = 11)
                start_session!(session)
                with_response_source(ScriptedResponseSource([1])) do
                    run_next_trial!(session, QuietEngine())
                end
                chosen = PM.suggested_level(mirrored)
                estimate = method_threshold(mirrored)
                drawn = [PM.next_level(mirrored, Random.Xoshiro(seed)) for seed in 1:20]
                @test chosen in drawn
                @test any(level -> level != chosen &&
                                   abs(level - (2estimate - chosen)) <= 0.5, drawn)

                # A task with a correct answer keeps the defaults it had
                scored = psi_session(Psi(trial_limit = 2), levels)
                with_response_source(IntervalObserver(0.0, 5.0, Random.Xoshiro(2))) do
                    run_experiment!(scored, QuietEngine(); report = :silent)
                end
                method = scored.method_instance
                @test method.scored == true && PM.guess_rate(method) == 0.5
                @test PM.function_name(method) === :gumbel && !PM.mirrors(method)
            end

            @testset "A replication repeats the configuration, not the run" begin
                session = psi_session(Psi(trial_limit = 5, pf = :logistic), levels)
                with_response_source(IntervalObserver(0.0, 6.0, Random.Xoshiro(9))) do
                    run_experiment!(session, QuietEngine(); report = :silent)
                end
                replica = create_replicated_session(session, "Second")
                @test replica.method_instance.trial_limit == 5
                @test replica.method_instance.stim_range == levels
                @test isempty(replica.method_instance.scores)
                @test replica.state == READY
            end
        end
    end
end
