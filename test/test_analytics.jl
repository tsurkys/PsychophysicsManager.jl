@testset "Analytics" begin

    @testset "Aggregation groups by the full condition vector" begin
        ex_par = ExperimentParameters("agg", [:a, :b], [[1.0, 2.0], [10.0, 20.0]], 1)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        # Conditions sharing a == 1.0 differ in b and must NOT be merged
        push!(s.history, Trial(1, 0.0, 0.1, [1.0, 10.0], 0, true))
        push!(s.history, Trial(2, 0.0, 0.1, [1.0, 10.0], 0, true))
        push!(s.history, Trial(3, 0.0, 0.1, [1.0, 20.0], 1, true))
        push!(s.history, Trial(4, 0.0, 0.1, [2.0, 10.0], 1, true))
        push!(s.history, Trial(5, 0.0, 0.1, [2.0, 10.0], 1, false))  # invalid: excluded

        agg = get_aggregated_data(s)
        @test length(agg) == 3
        @test [p.vals for p in agg] == [[1.0, 10.0], [1.0, 20.0], [2.0, 10.0]]
        @test [p.n for p in agg] == [2, 1, 1]
        @test [p.mean_response for p in agg] == [0.0, 1.0, 1.0]
        # `level` is the convenience alias for the first variable
        @test [p.level for p in agg] == [1.0, 1.0, 2.0]
    end

    @testset "A trial with no response is left out of the summary" begin
        ex_par = ExperimentParameters("unanswered", :x, [1.0, 2.0], 2)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        push!(s.history, Trial(1, 0.0, 0.1, [1.0], 1, true))
        push!(s.history, Trial(2, 0.0, 0.1, [1.0], 0, true))
        push!(s.history, Trial(3, 0.0, 0.1, [1.0], :timeout, true))
        push!(s.history, Trial(4, 0.0, 0.1, [2.0], MISSING_RESPONSE, true))

        agg = get_aggregated_data(s)
        # One condition averaged from the two trials that were answered; the
        # condition nobody answered has nothing to report at all
        @test [p.vals for p in agg] == [[1.0]]
        @test only(agg).n == 2
        @test only(agg).mean_response == 0.5
    end

    @testset "Reaction times per condition" begin
        ex_par = ExperimentParameters("rt", :x, [1.0, 2.0], 3)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        @test isempty(reaction_times(s))
        push!(s.history, Trial(1, 10.0, 10.4, [1.0], 1, true, :engine, nothing),
              Trial(2, 20.0, 20.6, [1.0], 0, true, :estimated, nothing),
              Trial(3, 30.0, 31.1, [1.0], 1, true, :engine, nothing),
              Trial(4, 40.0, 40.5, [2.0], 1, true, :engine, nothing),
              Trial(5, 50.0, 59.0, [2.0], 1, false, :engine, nothing),       # not counted
              Trial(6, 60.0, 62.0, [2.0], :timeout, true, :engine, nothing))  # not answered
        points = reaction_times(s)
        @test [p.vals for p in points] == [[1.0], [2.0]]
        @test [p.n for p in points] == [3, 1]
        @test points[1].median_s ≈ 0.6 && points[1].mean_s ≈ 0.7
        @test points[2].median_s ≈ 0.5
        @test [p.estimated for p in points] == [1, 0]

        output = mktemp() do path, io
            redirect_stdout(io) do
                print_reaction_times(s)
            end
            close(io)
            read(path, String)
        end
        @test occursin("REACTION TIMES (ms)", output)
        @test occursin("600.0", output) && occursin("onset the core estimated", output)

        # The latency of a program's answer is not a reaction time
        push!(s.tags, "ai-observer")
        @test_throws ArgumentError reaction_times(s)
    end

    @testset "Constant error of an adjustment" begin
        ex_par = ExperimentParameters("ce", :DistrN, [1, 3], 2)
        s = SessionContext("p", ex_par, MarkerLayout(),
                           Adjustment(dep_var = :Diff, dep_range = -10:10))
        push!(s.history, Trial(1, 0.0, 0.1, [1.0], 2.0, true), Trial(2, 0.0, 0.1, [1.0], 4.0, true),
              Trial(3, 0.0, 0.1, [3.0], -1.0, true), Trial(4, 0.0, 0.1, [3.0], -3.0, true))
        # Physical equality of a marker layout is Diff = 0
        @test physical_equality(MarkerLayout(), :Diff, (DistrN = 1.0,)) == 0.0
        @test physical_equality(MarkerLayout(), :Ref, (DistrN = 1.0,)) === nothing
        @test constant_errors(s) == [3.0, -2.0]
        output = mktemp() do path, io
            redirect_stdout(() -> print_adjustment_summary(s), io)
            close(io)
            read(path, String)
        end
        @test occursin("CE", output) && occursin("-2.0", output)

        # In the declared units of the adjusted value
        set_unit_conversion!(s, :Diff, UnitConversion("Offset (arcmin)"; scale = 0.5))
        @test constant_errors(s) == [1.5, -1.0]

        # A stimulus that declares no point of equality has no constant error
        plain = SessionContext("p", ExperimentParameters("ce", :x, [1.0], 1),
                               BaseStimulusParameters(100.0),
                               Adjustment(dep_var = :x, dep_range = 0:5))
        push!(plain.history, Trial(1, 0.0, 0.1, [1.0], 2.0, true))
        @test constant_errors(plain) == [nothing]
    end

    @testset "Yes/no detection" begin
        # The quantile the d′ is built on, against tabled values
        @test PsychophysicsManager.normal_quantile(0.5) == 0.0
        @test PsychophysicsManager.normal_quantile(0.975) ≈ 1.959963985 atol = 1e-8
        @test PsychophysicsManager.normal_quantile(0.025) ≈ -1.959963985 atol = 1e-8
        @test PsychophysicsManager.normal_quantile(0.001) ≈ -3.090232306 atol = 1e-8
        @test_throws DomainError PsychophysicsManager.normal_quantile(1.0)

        ex_par = ExperimentParameters("yesno", :present, [0, 1], 10)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
        @test_throws ArgumentError detection_summary(s)   # nothing scored
        outcomes = vcat(fill((1, true), 8), fill((-1, false), 2),    # present: hits, misses
                        fill((1, false), 3), fill((-1, true), 7))    # absent: FAs, rejections
        for (index, (response, correct)) in enumerate(outcomes)
            push!(s.history, Trial(index, 0.0, 0.1, [1.0], response, true, :engine, correct))
        end
        push!(s.history, Trial(21, 0.0, 0.1, [1.0], 1, false, :engine, true))   # not counted
        push!(s.history, Trial(22, 0.0, 0.1, [1.0], 0, true, :engine, nothing)) # a repeat request
        summary = detection_summary(s)
        @test (summary.hits, summary.misses, summary.false_alarms, summary.correct_rejections) ==
              (8, 2, 3, 7)
        @test summary.hit_rate == 0.8 && summary.false_alarm_rate == 0.3
        z_hit = PsychophysicsManager.normal_quantile(8.5 / 11)
        z_fa = PsychophysicsManager.normal_quantile(3.5 / 11)
        @test summary.d_prime ≈ z_hit - z_fa
        @test summary.criterion ≈ -(z_hit + z_fa) / 2
        @test summary.correction === :loglinear

        # A perfect observer still gets a finite d′
        perfect = SessionContext("p", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
        for (index, (response, correct)) in enumerate(vcat(fill((1, true), 5), fill((-1, true), 5)))
            push!(perfect.history, Trial(index, 0.0, 0.1, [1.0], response, true, :engine, correct))
        end
        @test isfinite(detection_summary(perfect).d_prime)
        @test detection_summary(perfect).hit_rate == 1.0

        # Only one kind of trial: no false-alarm rate to compare with
        only_present = SessionContext("p", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
        push!(only_present.history, Trial(1, 0.0, 0.1, [1.0], 1, true, :engine, true))
        @test_throws ArgumentError detection_summary(only_present)
    end

    @testset "Single-variable behaviour" begin
        ex_par = ExperimentParameters("agg1", :x, [1.0, 2.0], 2)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        push!(s.history, Trial(1, 0.0, 0.1, [2.0], 1, true))
        push!(s.history, Trial(2, 0.0, 0.1, [1.0], 0, true))
        push!(s.history, Trial(3, 0.0, 0.1, [2.0], 0, true))

        agg = get_aggregated_data(s)
        @test [p.level for p in agg] == [1.0, 2.0]          # sorted
        @test [p.mean_response for p in agg] == [0.0, 0.5]
        @test [p.n for p in agg] == [1, 2]
    end

    @testset "Proportion correct per condition" begin
        ex_par = ExperimentParameters("scored", :x, [1.0, 2.0], 3)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        push!(s.history, Trial(1, 0.0, 0.1, [1.0], 1, true, :estimated, true))
        push!(s.history, Trial(2, 0.0, 0.1, [1.0], 0, true, :estimated, false))
        push!(s.history, Trial(3, 0.0, 0.1, [1.0], 1, true, :estimated, nothing))
        push!(s.history, Trial(4, 0.0, 0.1, [2.0], 1, true, :estimated, true))
        push!(s.history, Trial(5, 0.0, 0.1, [2.0], 0, false, :estimated, false))

        agg = get_aggregated_data(s)
        # The share is taken over the scored trials; `n` still counts every
        # valid one, and an invalidated trial is outside both
        @test [p.n for p in agg] == [3, 1]
        @test [p.proportion_correct for p in agg] == [0.5, 1.0]

        # A task that defines no correct answer reports none rather than zero
        unscored = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                                  ConstantStimuli())
        push!(unscored.history, Trial(1, 0.0, 0.1, [1.0], 1, true))
        @test only(get_aggregated_data(unscored)).proportion_correct === nothing
    end

    @testset "Psychometric summary prints the run and returns its fit" begin
        ex_par = ExperimentParameters("summary", :x, collect(-4.0:1.0:4.0), 1)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        # Four answers at each level, more of them positive as the level rises
        for (level, positive) in zip(ex_par.indep_var_ranges[1], [0, 0, 0, 1, 1, 2, 3, 4, 4]),
            k in 1:4
            push!(s.history, Trial(length(s.history) + 1, 0.0, 0.1, [level],
                                   k <= positive ? 1 : 0, true))
        end

        fit = redirect_stdout(() -> print_psychometric_summary(s), devnull)
        @test fit.converged
        @test fit.gamma == s.fit_gamma          # the session's own asymptote
        @test isapprox(fit.alpha, 1.0, atol = 0.5)

        # No valid trials: a non-converged result rather than an error
        empty!(s.history)
        @test !redirect_stdout(() -> print_psychometric_summary(s), devnull).converged
    end

    @testset "The summary reports correctness only when the task scores it" begin
        summary_lines(session) = mktemp() do path, io
            redirect_stdout(() -> print_psychometric_summary(session), io)
            flush(io)
            return readlines(path)
        end
        header_of(lines) = only(filter(line -> occursin("Proportion", line), lines))

        ex_par = ExperimentParameters("summary", :x, collect(-4.0:1.0:4.0), 1)
        scored = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                                ConstantStimuli())
        unscored = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                                  ConstantStimuli())
        for (i, level) in enumerate(ex_par.indep_var_ranges[1])
            answered = level > 1.0
            push!(scored.history, Trial(i, 0.0, 0.1, [level], answered ? 1 : 0, true,
                                        :estimated, answered))
            push!(unscored.history, Trial(i, 0.0, 0.1, [level], answered ? 1 : 0, true))
        end

        scored_header = header_of(summary_lines(scored))
        @test occursin("Correct", scored_header)
        # The condition column plus three value columns
        @test count(==('|'), scored_header) == 3

        unscored_header = header_of(summary_lines(unscored))
        @test !occursin("Correct", unscored_header)
        @test count(==('|'), unscored_header) == 2
    end

    @testset "A scored session is fitted on its proportion correct" begin
        # Two-interval answers: the response codes say which interval was named,
        # so their mean is the bias, while the accuracy rises with the level
        ex_par = ExperimentParameters("scored fit", :x, collect(1.0:6.0), 1)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        accuracy = [0.5, 0.5, 0.625, 0.875, 1.0, 1.0]
        for (level, share) in zip(ex_par.indep_var_ranges[1], accuracy), k in 1:8
            push!(s.history, Trial(length(s.history) + 1, 0.0, 0.1, [level],
                                   isodd(k) ? 1 : 0, true, :estimated,
                                   k <= round(Int, 8 * share)))
        end

        agg = get_aggregated_data(s)
        @test PsychophysicsManager.psychometric_proportions(agg, :auto) == (:correct, accuracy)
        @test PsychophysicsManager.psychometric_proportions(agg, :response) == (:response, fill(0.5, 6))
        fit = fit_psychometric_curve(agg; gamma = 0.5)
        @test fit.converged
        @test 2.0 < fit.alpha < 5.0
        # The curve is drawn by the fit's own model
        @test curve_value(fit, fit.alpha) ≈ 0.5 + 0.5 / 2
        weibull = CurveFit(:weibull, 3.0, 2.0, 0.5, 0.0, true)
        @test curve_value(weibull, 3.0) ≈ 0.5 + 0.5 * (1 - exp(-1))
        @test curve_value(weibull, 0.0) == curve_value(weibull, -1.0) == 0.5

        # One condition nobody scored: accuracy is no longer what the data holds
        push!(s.history, Trial(length(s.history) + 1, 0.0, 0.1, [7.0], 1, true))
        partly_scored = get_aggregated_data(s)
        @test first(PsychophysicsManager.psychometric_proportions(partly_scored, :auto)) === :response
        @test_throws ArgumentError fit_psychometric_curve(partly_scored; on = :correct)
        @test_throws ArgumentError fit_psychometric_curve(agg; on = :accuracy)
    end

    @testset "The fit recovers a known curve at any scale of the levels" begin
        # Proportions that lie exactly on a curve are most probable under that curve,
        # so its threshold and slope have to come back as they went in
        on_curve(levels, alpha, beta; gamma = 0.0) =
            [AggregatePoint([x], x, 40, p, 0.0, 0.0, p, p, nothing, NaN, NaN)
             for x in levels for p in (gamma + (1 - gamma) / (1 + exp(-beta * (x - alpha))),)]
        recovers(fit, alpha, beta) = fit.converged && isapprox(fit.alpha, alpha; rtol = 1e-5) &&
                                     isapprox(fit.beta, beta; rtol = 1e-5)

        for scale in (0.01, 1.0, 100.0)
            fit = fit_psychometric_curve(on_curve(scale .* (1.0:9.0), 4.3 * scale, 1.5 / scale))
            @test recovers(fit, 4.3 * scale, 1.5 / scale)
        end
        # Durations in milliseconds, a shallow slope and a threshold off the levels' mean
        @test recovers(fit_psychometric_curve(on_curve(800.0:200.0:2000.0, 1300.0, 0.006)),
                       1300.0, 0.006)
        # A curve that falls, one that covers a part of its rise, and a guessing floor
        @test recovers(fit_psychometric_curve(on_curve(1.0:9.0, 5.5, -0.8)), 5.5, -0.8)
        @test recovers(fit_psychometric_curve(on_curve(1.0:5.0, 5.6, 0.7)), 5.6, 0.7)
        @test recovers(fit_psychometric_curve(on_curve(1.0:9.0, 4.0, 1.2; gamma = 0.5);
                                              gamma = 0.5), 4.0, 1.2)
    end

    @testset "The fit says when the data do not determine a curve" begin
        points(proportions; levels = 1.0:length(proportions)) =
            [AggregatePoint([x], x, 20, p, 0.0, 0.0, p, p, nothing, NaN, NaN)
             for (x, p) in zip(levels, proportions)]
        fitted(proportions; kwargs...) = fit_psychometric_curve(points(proportions; kwargs...))

        @test fitted([0.0, 0.1, 0.5, 0.9, 1.0]).converged
        # A step between two levels, and one with a single level on it
        @test !fitted([0.0, 0.0, 1.0, 1.0]).converged
        @test !fitted([0.0, 0.5, 1.0]).converged
        # No change over the levels
        @test !fitted([0.5, 0.5, 0.5, 0.5]).converged
        # A threshold far outside what was measured
        @test !fitted([0.02, 0.03, 0.05]).converged
        # One level, however many conditions share it
        @test !fitted([0.2, 0.8]; levels = [3.0, 3.0]).converged
        # What is not the proportion of a choice is refused, naming it
        @test_throws ArgumentError fitted([0.2, 1.5, 0.9])
    end

    @testset "The seven functions are the toolbox's" begin
        # Each at a level, against the formula the Palamedes toolbox gives it
        α, β, γ, λ, x = 0.4, 3.0, 0.25, 0.03, 0.55
        z = β * (x - α)
        formulas = Dict(:logistic => 1 / (1 + exp(-z)),
                        :cumulative_normal => 0.67364477971207992,   # Φ(0.45), by Octave
                        :hyperbolic_secant => 2 / π * atan(exp(π / 2 * z)),
                        :gumbel => 1 - exp(-10^z),
                        :log_quick => 1 - 2^(-10^z),
                        :weibull => 1 - exp(-(x / α)^β),
                        :quick => 1 - 2^(-(x / α)^β))
        @test Set(keys(formulas)) == Set(PSYCHOMETRIC_FUNCTIONS)
        for (model, F) in formulas
            @test psychometric_value(model, x, α, β, γ, λ) ≈ γ + (1 - γ - λ) * F
        end
        @test_throws ArgumentError psychometric_value(:sigmoid, x, α, β, γ, λ)
    end

    @testset "The fit agrees with the Palamedes toolbox" begin
        # 200 simulated datasets, each fitted by all seven functions with the lapse rate
        # held at 0 and free, by the original MATLAB toolbox under Octave
        # (`test/reference/palamedes_fit.m`, which names the columns): levels from
        # hundredths to thousands, 8 to 40 answers a level, a guess rate of 0 or 0.5
        rows = [split(line, ',') for line in
                eachline(joinpath(@__DIR__, "reference", "palamedes_fit.csv"))]
        tally = Dict{Tuple{Bool, Symbol}, Int}()
        for row in rows
            model, free = Symbol(row[1]), row[2] == "1"
            v = parse.(Float64, row[3:end])
            gamma, k, alpha, beta, lambda, log_likelihood, scenario = v[1], Int(v[2]), v[3:7]...
            levels, positive, answers = v[8:7 + k], v[17:16 + k], Int.(v[26:25 + k])
            points = [AggregatePoint([x], x, n, yes / n, 0.0, 0.0, NaN, NaN, nothing, NaN, NaN)
                      for (x, yes, n) in zip(levels, positive, answers)]
            fit = fit_psychometric_curve(points, model; gamma, lapse_free = free, bootstrap = 0)
            shape = PsychophysicsManager.psychometric_shape(model)
            axis = [PsychophysicsManager.axis_value(shape, x) for x in levels]
            location(a) = PsychophysicsManager.axis_location(shape, a)
            ours = -PsychophysicsManager.negative_log_likelihood(
                shape, location(fit.alpha), fit.beta, gamma, fit.lambda, axis, positive, answers)
            # The toolbox's scenario is 1 for a fit, negative for a step or a constant
            outcome = if fit.converged != (scenario == 1)
                # The toolbox fits no falling curve, and a fit can stop short of a curve
                # more likely than the step it settles on; neither may PEM
                fit.beta < 0 ? :falling : ours > log_likelihood + 1e-6 ? :beyond_step : :differs
            elseif scenario != 1
                :limit
            elseif ours > log_likelihood + 1e-6
                # The toolbox's simplex stopped short of the maximum PEM reached
                :higher
            else
                span = maximum(axis) - minimum(axis)
                tolerance = free ? 1e-3 : 1e-5
                isapprox(location(fit.alpha), location(alpha); atol = tolerance * span) &&
                    isapprox(fit.beta, beta; rtol = tolerance) &&
                    isapprox(fit.lambda, lambda; atol = tolerance) &&
                    ours >= log_likelihood - 1e-8 ? :same : :differs
            end
            tally[(free, outcome)] = get(tally, (free, outcome), 0) + 1
        end
        @test !haskey(tally, (false, :differs)) && !haskey(tally, (true, :differs))
        # With the lapse rate held, every fit is the toolbox's but for the falling curves
        @test tally[(false, :same)] == 1225 && tally[(false, :limit)] == 168
        @test tally[(false, :falling)] == 7 && !haskey(tally, (false, :higher))
        @test tally[(true, :same)] + tally[(true, :higher)] == 1038
        @test sum(values(tally)) == 2800
    end

    @testset "The bootstrap agrees with the Palamedes toolbox" begin
        # Four datasets bootstrapped 4000 times by the original toolbox under Octave
        # (`test/reference/palamedes_bootstrap.m`, which names the columns). Two
        # simulations differ, so the standard errors agree as far as their numbers can
        # tell: a few per cent at 1000 to 2000 simulations. The toolbox's slope has no
        # standard error where a simulation ended in a step (an infinite slope).
        for line in eachline(joinpath(@__DIR__, "reference", "palamedes_bootstrap.csv"))
            row = split(line, ',')
            model, free = Symbol(row[1]), row[2] == "1"
            v = parse.(Float64, row[3:end])
            gamma, se_alpha, se_beta, k = v[1], v[3], v[4], Int(v[6])
            levels, positive, answers = v[7:6 + k], v[7 + k:6 + 2k], Int.(v[7 + 2k:6 + 3k])
            points = [AggregatePoint([x], x, n, yes / n, 0.0, 0.0, NaN, NaN, nothing, NaN, NaN)
                      for (x, yes, n) in zip(levels, positive, answers)]
            fit = fit_psychometric_curve(points, model; gamma, lapse_free = free,
                                         bootstrap = free ? 1000 : 2000,
                                         rng = Random.Xoshiro(1))
            @test fit.se_alpha ≈ se_alpha rtol = 0.1
            isnan(se_beta) || @test fit.se_beta ≈ se_beta rtol = 0.1
        end
    end

    @testset "A fitted threshold comes with its uncertainty" begin
        # A two-interval observer whose 75 % point is 0.2
        levels = collect(-1.0:0.25:1.0)
        rng = Random.Xoshiro(21)
        points = map(levels) do x
            correct = count(_ -> rand(rng) < 0.5 + 0.5 / (1 + exp(-5 * (x - 0.2))), 1:20)
            AggregatePoint([x], x, 20, 0.5, 0.0, 0.0, 0.5, 0.5, correct / 20, NaN, NaN)
        end

        fit = fit_psychometric_curve(points, :logistic; gamma = 0.5, bootstrap = 200,
                                     rng = Random.Xoshiro(2))
        @test fit.converged && fit.model === :logistic
        @test has_interval(fit) && fit.n_bootstrap == 200
        # The interval is the point of the exercise: it has to contain the threshold
        # the observer was built with
        @test first(fit.ci_alpha) < 0.2 < last(fit.ci_alpha)
        @test fit.se_alpha > 0
        @test first(fit.ci_beta) < fit.beta < last(fit.ci_beta)
        # The same stream draws the same interval
        again = fit_psychometric_curve(points, :logistic; gamma = 0.5, bootstrap = 200,
                                       rng = Random.Xoshiro(2))
        @test again.ci_alpha == fit.ci_alpha && again.se_beta == fit.se_beta

        # Without simulations it is a point estimate, and says so; without a model it
        # is the same logistic
        quick = fit_psychometric_curve(points, :logistic; gamma = 0.5, bootstrap = 0)
        @test quick.converged && !has_interval(quick) && quick.alpha == fit.alpha
        @test fit_psychometric_curve(points; gamma = 0.5).alpha == fit.alpha

        # A free lapse rate stays within its range
        lapsing = fit_psychometric_curve(points, :gumbel; gamma = 0.5, lapse_free = true,
                                         bootstrap = 0)
        @test 0 <= lapsing.lambda <= 0.06

        # A summary can be printed from either fit
        printed = redirect_stdout(devnull) do
            design = ExperimentParameters("Fit", :level, levels, 1)
            session = SessionContext("Fit", design, BaseStimulusParameters(1.0),
                                     ConstantStimuli())
            for (i, point) in enumerate(points), k in 1:point.n
                push!(session.history,
                      Trial(length(session.history) + 1, 0.0, 0.1, [point.level], 1, true,
                            :estimated, k <= round(Int, point.proportion_correct * point.n)))
            end
            print_psychometric_summary(session; gamma = 0.5, model = :cumulative_normal,
                                       bootstrap = 50, rng = Random.Xoshiro(3))
        end
        @test printed.model === :cumulative_normal && has_interval(printed)

        @test_throws ArgumentError fit_psychometric_curve(points, :sigmoid)
        @test_throws ArgumentError fit_psychometric_curve(points, :logistic; level = 1.5)
        @test_throws ArgumentError fit_psychometric_curve(points, :logistic; bootstrap = -1)
        # A Weibull is a function of levels of 0 and above
        @test_throws r":weibull" fit_psychometric_curve(points, :weibull; gamma = 0.5)
    end

    @testset "The adaptive sequence marks where a track turned" begin
        staircase = SessionContext("A", ExperimentParameters("Stairs", :level, collect(1.0:5.0), 10),
                                   BaseStimulusParameters(1.0), Staircase(2))
        # Down, down, up, down, (again), down, up: the answers that turned the track are
        # the 3rd, the 4th and the 7th; the 5th was undone and its level presented again
        path = [(5.0, true), (4.0, true), (3.0, false), (4.0, true), (3.0, true),
                (3.0, true), (2.0, false), (3.0, true)]
        for (i, (level, right)) in enumerate(path)
            push!(staircase.history, Trial(i, 0.0, 0.1, [level], right ? 1 : -1, i != 5,
                                           :estimated, right))
        end
        # A condition the operator chose is not the method's step
        push!(staircase.history, Trial(9, 0.0, 0.1, [1.0], 1, true, :estimated, true, :operator))
        track = only(adaptive_sequence(staircase))
        @test track.name == "" && track.variable === :level
        @test track.trials == 1:8
        @test track.levels == first.(path)
        @test track.reversal == [false, false, true, true, false, false, true, false]
        @test track.counted == [true, true, true, true, false, true, true, true]
        @test track.correct == last.(path)
        # The core's staircase gives no threshold of its own
        @test track.estimate === nothing

        # In the units the session declares; a turn is a turn in either
        set_unit_conversion!(staircase, :level, UnitConversion("Level (dB)"; scale = 10.0))
        converted = only(adaptive_sequence(staircase))
        @test converted.levels == 10 .* first.(path)
        @test converted.reversal == track.reversal

        # An interleaved run has a track per staircase, told apart by :track
        interleaved = SessionContext("B", ExperimentParameters("Two", [:level, :track],
                                                               Any[collect(1.0:5.0), [1, 2]], 4),
                                     BaseStimulusParameters(1.0),
                                     Interleaved([Staircase(2), Staircase(2)]))
        for (i, (level, which)) in enumerate([(5.0, 1), (1.0, 2), (4.0, 1), (2.0, 2), (5.0, 1)])
            push!(interleaved.history, Trial(i, 0.0, 0.1, [level, which], 1, true, :estimated,
                                             true))
        end
        tracks = adaptive_sequence(interleaved)
        @test [t.name for t in tracks] == ["track 1", "track 2"]
        @test tracks[1].trials == [1, 3, 5] && tracks[1].reversal == [false, true, false]
        @test tracks[2].levels == [1.0, 2.0]

        # A planned design has no sequence to follow
        planned = SessionContext("C", ExperimentParameters("Planned", :level, [1.0], 1),
                                 BaseStimulusParameters(1.0), ConstantStimuli())
        @test !PsychophysicsManager.is_adaptive(planned.method_instance)
        @test_throws ArgumentError adaptive_sequence(planned)
    end

    @testset "Trials are pooled over a counterbalancing variable" begin
        s = SessionContext("C", ExperimentParameters("2IFC", [:contrast, :target_interval],
                                                     Any[[0.1, 0.2], [1, 2]], 2),
                           Gabor(), ConstantStimuli())
        answers = [(0.1, 1, true), (0.1, 2, false), (0.1, 1, false), (0.1, 2, false),
                   (0.2, 1, true), (0.2, 2, true), (0.2, 1, true), (0.2, 2, false)]
        for (i, (contrast, interval, right)) in enumerate(answers)
            push!(s.history, Trial(i, 0.0, 0.1, [contrast, Float64(interval)], right ? 1 : -1,
                                   true, :estimated, right))
        end
        @test length(get_aggregated_data(s)) == 4
        pooled = get_aggregated_data(s; collapse = :target_interval)
        @test [point.vals for point in pooled] == [[0.1], [0.2]]
        @test [point.n for point in pooled] == [4, 4]
        @test [point.proportion_correct for point in pooled] == [0.25, 0.75]
        @test [point.vals for point in get_aggregated_data(s; collapse = [:target_interval])] ==
              [[0.1], [0.2]]
        @test PsychophysicsManager.condition_header(s; collapse = :target_interval) == "contrast"
        @test_throws ArgumentError get_aggregated_data(s; collapse = :side)
        @test_throws ArgumentError get_aggregated_data(s; collapse = [:contrast, :target_interval])
        output = mktemp() do path, io
            redirect_stdout(() -> print_psychometric_summary(s; gamma = 0.5,
                                                             collapse = :target_interval), io)
            close(io)
            read(path, String)
        end
        @test occursin("contrast    | Proportion", output)
        @test !occursin("(0.1, 1.0)", output)

        # A constant error pools the deviations, each from its own point of equality
        ce = SessionContext("E", ExperimentParameters("ce", [:DistrN, :side], Any[[1, 3], [1, 2]], 1),
                            MarkerLayout(), Adjustment(dep_var = :Diff, dep_range = -10:10))
        push!(ce.history, Trial(1, 0.0, 0.1, [1.0, 1.0], 2.0, true),
              Trial(2, 0.0, 0.1, [1.0, 2.0], -4.0, true), Trial(3, 0.0, 0.1, [3.0, 1.0], 1.0, true))
        @test constant_errors(ce; collapse = :side) == [-1.0, 1.0]
    end

    @testset "Report table labels" begin
        ex_par = ExperimentParameters("labels", [:contrast, :frequency],
                                      [[0.1, 0.2], [1.0, 2.0]], 1)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           ConstantStimuli())
        push!(s.history, Trial(1, 0.0, 0.1, [0.1, 1.0], 1, true))
        push!(s.history, Trial(2, 0.0, 0.1, [0.2, 2.0], 0, true))

        @test PsychophysicsManager.condition_header(s) == "contrast, frequency"
        # A multi-variable design names the whole condition, never one dimension
        @test PsychophysicsManager.condition_label.(get_aggregated_data(s)) ==
              ["(0.1, 1.0)", "(0.2, 2.0)"]

        single = SessionContext("p", ExperimentParameters("one", :x, [1.0], 1),
                                BaseStimulusParameters(100.0), ConstantStimuli())
        push!(single.history, Trial(1, 0.0, 0.1, [1.0], 1, true))
        @test PsychophysicsManager.condition_header(single) == "x"
        @test PsychophysicsManager.condition_label(only(get_aggregated_data(single))) == "1.0"
    end

    @testset "Unit conversion: the declared forms" begin
        @test UnitConversion("x")(3.0) == 3.0                          # identity
        @test UnitConversion("x"; scale = 2.0)(3.0) == 6.0             # scale only
        @test UnitConversion("x"; offset = -1.0)(3.0) == 2.0           # offset only
        @test UnitConversion("x"; scale = 2.0, offset = 1.0)(3.0) == 7.0
        @test UnitConversion("x"; form = :log10)(100.0) == 2.0
        @test UnitConversion("x"; form = :log10, scale = 20.0, offset = 1.0)(10.0) == 21.0
        # A formula such as `x * 0.5 / 60` is a scale and no offset
        legacy = UnitConversion("Offset (deg)"; scale = 0.5 / 60)
        @test legacy.scale == 0.5 / 60 && legacy.offset == 0.0
        @test legacy(120.0) ≈ 120.0 * 0.5 / 60
        @test PsychophysicsManager.conversion_formula(:Diff, UnitConversion("Diff (arcmin)"; scale = 0.5)) ==
              "Diff (arcmin) = 0.5 * Diff"
        @test PsychophysicsManager.conversion_formula(:c, UnitConversion("log c"; form = :log10)) ==
              "log c = log10(c)"
        shifted = UnitConversion("t (s)"; scale = 0.001, offset = -0.5)
        @test PsychophysicsManager.conversion_formula(:t, shifted) == "t (s) = 0.001 * t - 0.5"
        reparsed = PsychophysicsManager.parse_unit_conversion(
            :t, PsychophysicsManager.conversion_formula(:t, shifted))
        @test reparsed.label == shifted.label && reparsed.form === shifted.form
        @test reparsed.scale ≈ shifted.scale && reparsed.offset ≈ shifted.offset
        @test reparsed.formula == "0.001 * t - 0.5"

        @test_throws ArgumentError UnitConversion(" ")
        @test_throws ArgumentError UnitConversion("x"; form = :ln)
        @test_throws ArgumentError UnitConversion("x"; scale = Inf)
        @test_throws ArgumentError UnitConversion("x"; offset = NaN)
        # A zero scale would merge every level into one condition
        @test_throws ArgumentError UnitConversion("x"; scale = 0.0)
        @test_throws DomainError UnitConversion("x"; form = :log10)(0.0)
    end

    @testset "Unit conversion: formula language" begin
        parse_uc = PsychophysicsManager.parse_unit_conversion
        refused_msg(f) = try
            f()
            nothing
        catch err
            @test err isa ArgumentError
            err.msg
        end

        # Empty text removes the conversion; a label alone is an identity without a formula
        @test parse_uc(:Diff, "") === nothing
        @test parse_uc(:Diff, "   ") === nothing
        label_only = parse_uc(:DistrN, "Number of distractors")
        @test label_only == UnitConversion("Number of distractors")
        @test label_only.form === :affine && label_only.scale == 1.0 &&
              label_only.offset == 0.0 && label_only.formula == ""

        # Legacy forms resolve to the expected form, scale, and offset
        c1 = parse_uc(:Diff, "Illusion strength, arc min = Diff * pixel_arcmin";
                      constants = Dict(:pixel_arcmin => 0.933))
        @test c1.label == "Illusion strength, arc min" && c1.form === :affine
        @test c1.scale ≈ 0.933
        @test c1.offset ≈ 0.0 atol = 1e-12
        @test c1.formula == "Diff * pixel_arcmin"

        c2 = parse_uc(:Test, "Illusion = (Ref - Test) * 1.21";
                      constants = Dict(:Ref => 10))
        @test c2.form === :affine && c2.scale ≈ -1.21 && c2.offset ≈ 12.1
        @test c2.formula == "(Ref - Test) * 1.21"

        c3 = parse_uc(:Test, "Diff = Test - Ref"; constants = Dict(:Ref => 10))
        @test c3.form === :affine && c3.scale ≈ 1.0 && c3.offset ≈ -10.0

        c4 = parse_uc(:KAtkp, "Angle = 0.367 * KAtkp * PagN / 60";
                      constants = Dict(:PagN => 5))
        @test c4.form === :affine && c4.scale ≈ 0.367 * 5 / 60
        @test c4.offset ≈ 0.0 atol = 1e-12

        c5 = parse_uc(:Frame12, "Duration (ms) = Frame12 * frame_ms";
                      constants = Dict(:frame_ms => 16.667))
        @test c5.form === :affine && c5.scale ≈ 16.667
        @test c5.offset ≈ 0.0 atol = 1e-12

        c6 = parse_uc(:contrast, "log10 contrast = log10(contrast)")
        @test c6.form === :log10 && c6.scale ≈ 1.0
        @test c6.offset ≈ 0.0 atol = 1e-12
        @test c6.formula == "log10(contrast)"

        # x stands for the parameter, and the legacy field format keeps working
        c7 = parse_uc(:contrast, "log10 contrast = log10(x)")
        @test c7.form === :log10 && c7.scale ≈ 1.0
        @test c7.offset ≈ 0.0 atol = 1e-12
        c8 = parse_uc(:Diff, "Diff (arcmin) = 0.5 * Diff + 0")
        @test c8.form === :affine && c8.scale ≈ 0.5
        @test c8.offset ≈ 0.0 atol = 1e-12
        c9 = parse_uc(:Diff, "Scaled = -x / 2 + 1e-2")
        @test c9.form === :affine && c9.scale ≈ -0.5 && c9.offset ≈ 0.01
        c10 = parse_uc(:Diff, "A = B = 2 * x")
        @test c10.label == "A = B" && c10.scale ≈ 2.0

        # conversion_formula keeps the formula text and round-trips to an equal conversion
        @test PsychophysicsManager.conversion_formula(:Diff, c1) ==
              "Illusion strength, arc min = Diff * pixel_arcmin"
        @test parse_uc(:Diff, PsychophysicsManager.conversion_formula(:Diff, c1);
                       constants = Dict(:pixel_arcmin => 0.933)) == c1
        @test parse_uc(:Test, PsychophysicsManager.conversion_formula(:Test, c2);
                       constants = Dict(:Ref => 10)) == c2
        @test parse_uc(:contrast, PsychophysicsManager.conversion_formula(:contrast, c6)) == c6

        # Refused forms: each names the offending function, name, or parameter
        @test occursin("abs", refused_msg(() -> parse_uc(:Diff, "Bad = abs(x)")))
        @test occursin("linear", lowercase(refused_msg(() -> parse_uc(:Diff, "Bad = x * x"))))
        @test occursin("linear", lowercase(refused_msg(() -> parse_uc(:Diff, "Bad = 1 / x"))))
        @test occursin("mystery", refused_msg(() -> parse_uc(:Diff, "Bad = Diff * mystery")))
        indep_msg = refused_msg(() -> parse_uc(:Diff, "Bad = Diff * DistrN";
                                               unavailable = [:DistrN]))
        @test occursin("DistrN", indep_msg) && occursin("no single value", indep_msg)
        ambig_msg = refused_msg(() -> parse_uc(:Diff, "Bad = Diff * Ref";
                                               ambiguous = [:Ref]))
        @test occursin("Ref", ambig_msg) && occursin("ambiguous", lowercase(ambig_msg))
        log_const_msg = refused_msg(() -> parse_uc(:contrast, "Bad = log10(pixel_arcmin)";
                                                   constants = Dict(:pixel_arcmin => 0.933)))
        @test occursin("log10", log_const_msg) && occursin("pixel_arcmin", log_const_msg)
        mix_msg = refused_msg(() -> parse_uc(:contrast, "Bad = x + log10(x)"))
        @test occursin("log10", mix_msg) && occursin("contrast", mix_msg)
        no_param_msg = refused_msg(() -> parse_uc(:Diff, "Bad = 2 * pixel_arcmin";
                                                  constants = Dict(:pixel_arcmin => 0.933)))
        @test occursin("Diff", no_param_msg)
        @test refused_msg(() -> parse_uc(:Diff, "Bad = x - x + 1")) !== nothing
        @test refused_msg(() -> parse_uc(:Diff, "Bad = x / 0")) !== nothing
        @test refused_msg(() -> parse_uc(:Diff, "= 2 * x")) !== nothing
        @test refused_msg(() -> parse_uc(:Diff, "Bad = ")) !== nothing
    end

    @testset "Unit conversion: what a session may convert" begin
        ex_par = ExperimentParameters("units", :level, [0.0, 1.0, 2.0], 1)
        adjustment = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                                    Adjustment(dep_var = :duration_ms,
                                                     dep_range = -5.0:5.0))
        events = Symbol[]
        on_session_event!((_, event) -> push!(events, event), adjustment)

        # An independent variable, and the adjusted field whose value is the response
        set_unit_conversion!(adjustment, :level, UnitConversion("Level (dB)"))
        set_unit_conversion!(adjustment, :duration_ms, UnitConversion("Duration (s)";
                                                                      scale = 1e-3))
        @test sort(collect(keys(adjustment.unit_conversions))) == [:duration_ms, :level]
        @test events == [:settings_changed, :settings_changed]
        # Declaring the same conversion again changes nothing and reports nothing
        set_unit_conversion!(adjustment, :level, UnitConversion("Level (dB)"))
        @test length(events) == 2
        set_unit_conversion!(adjustment, :level, nothing)
        @test !haskey(adjustment.unit_conversions, :level)

        # Any other field reports no value, and a choice has no unit
        @test_throws ArgumentError set_unit_conversion!(adjustment, :Ref, UnitConversion("x"))
        choice = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                                ConstantStimuli())
        @test_throws ArgumentError set_unit_conversion!(choice, :duration_ms,
                                                        UnitConversion("x"))

        # A logarithm is refused for a level the design presents...
        @test_throws ArgumentError set_unit_conversion!(adjustment, :level,
                                                        UnitConversion("log"; form = :log10))
        positive = SessionContext("p", ExperimentParameters("units", :level, [1.0, 2.0], 1),
                                  BaseStimulusParameters(100.0),
                                  Adjustment(dep_var = :duration_ms,
                                                   dep_range = -5.0:5.0))
        set_unit_conversion!(positive, :level, UnitConversion("log"; form = :log10))
        # ...and for a response the session has recorded
        push!(positive.history, Trial(1, 0.0, 0.1, [1.0], -2.0, true))
        @test_throws ArgumentError set_unit_conversion!(positive, :duration_ms,
                                                        UnitConversion("log"; form = :log10))
        @test !haskey(positive.unit_conversions, :duration_ms)

        # A conversion is declared after the run too: the record does not change
        positive.state = FINISHED
        set_unit_conversion!(positive, :duration_ms, UnitConversion("Duration (s)";
                                                                    scale = 1e-3))
        @test only(positive.history).response == -2.0
    end

    @testset "Unit conversion: analysis is in the declared units" begin
        ex_par = ExperimentParameters("units", :level, [1.0, 10.0], 2)
        s = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                           Adjustment(dep_var = :duration_ms, dep_range = 1.0:100.0))
        for (i, (level, value)) in enumerate([(1.0, 10.0), (1.0, 1000.0), (10.0, 4.0),
                                              (10.0, 6.0)])
            push!(s.history, Trial(i, 0.0, 0.1, [level], value, true))
        end
        push!(s.history, Trial(5, 0.0, 0.1, [10.0], :timeout, true))

        set_unit_conversion!(s, :level, UnitConversion("log level"; form = :log10))
        set_unit_conversion!(s, :duration_ms, UnitConversion("Duration (s)"; scale = 1e-3))
        agg = get_aggregated_data(s)
        @test [p.level for p in agg] == [0.0, 1.0]
        @test [p.mean_response for p in agg] ≈ [0.505, 0.005]
        @test agg[2].sem ≈ 0.001

        # converted = false skips the conversions and aggregates the recorded values
        raw_agg = get_aggregated_data(s; converted = false)
        @test [p.level for p in raw_agg] == [1.0, 10.0]
        @test [p.mean_response for p in raw_agg] ≈ [505.0, 5.0]
        @test raw_agg[2].sem ≈ 1.0
        raw_obs = PsychophysicsManager.converted_observations(s; converted = false)
        @test [obs[1] for obs in raw_obs] == [[1.0], [1.0], [10.0], [10.0]]
        @test [obs[2] for obs in raw_obs] == [10.0, 1000.0, 4.0, 6.0]
        raw_set = get_aggregated_data(AnalysisSet([s]); converted = false)
        @test [p.level for p in raw_set] == [1.0, 10.0]
        @test [p.mean_response for p in raw_set] ≈ [505.0, 5.0]

        # Each trial is converted before it is averaged: under a logarithm the mean
        # is the mean of the logarithms, not the logarithm of the mean
        set_unit_conversion!(s, :duration_ms, UnitConversion("log duration"; form = :log10))
        @test first(get_aggregated_data(s)).mean_response ≈ 2.0

        @test PsychophysicsManager.condition_header(s) == "log level"
        output = mktemp() do path, io
            redirect_stdout(() -> print_adjustment_summary(s), io)
            close(io)
            read(path, String)
        end
        @test occursin("log level", output)
        @test occursin("Values in: log duration", output)
    end

    @testset "The spread of a condition and a curve that assumes no model" begin
        s = SessionContext("Spread", ExperimentParameters("Spread", :level, [1.0, 2.0, 3.0, 4.0], 1),
                           BaseStimulusParameters(1.0), ConstantStimuli())
        settings = [(1.0, 2.0), (1.0, 4.0), (1.0, 6.0), (2.0, 5.0), (3.0, 9.0), (4.0, 1.0),
                    (4.0, 3.0)]
        for (i, (level, value)) in enumerate(settings)
            push!(s.history, Trial(i, 0.0, 0.1, [level], value, true))
        end
        points = get_aggregated_data(s)
        first_level = points[1]
        @test first_level.mean_response == 4.0 && first_level.sd ≈ 2.0
        @test first_level.sem ≈ 2.0 / sqrt(3)
        # Student's t with two degrees of freedom: 4.303 standard errors either way
        @test first_level.ci_hi - 4.0 ≈ 4.302652729911275 * 2.0 / sqrt(3)
        @test first_level.ci_lo ≈ 8.0 - first_level.ci_hi
        # A single trial spreads nowhere and gives no interval
        @test points[2].sd == 0.0 && points[2].sem == 0.0
        @test isnan(points[2].ci_lo) && isnan(points[2].ci_hi)

        # The moving average over three levels, narrower at the ends
        @test PsychophysicsManager.smoothed_means(points) ≈ [4.5, 6.0, 16 / 3, 5.5]
        @test PsychophysicsManager.smoothed_means(points; window = 1) ≈ [4.0, 5.0, 9.0, 2.0]
        @test_throws ArgumentError PsychophysicsManager.smoothed_means(points; window = 2)
        @test PsychophysicsManager.smoothed_means(points; values = [0.0, 1.0, 0.0, 1.0]) ≈
              [0.5, 1 / 3, 2 / 3, 0.5]
        # Along the first variable, among the conditions that share the others
        two = SessionContext("Two", ExperimentParameters("Two", [:level, :side],
                                                         Any[[1.0, 2.0, 3.0], [1.0, 2.0]], 1),
                             BaseStimulusParameters(1.0), ConstantStimuli())
        for (i, (level, side, value)) in enumerate([(1.0, 1.0, 1.0), (2.0, 1.0, 2.0), (3.0, 1.0, 3.0),
                                                    (1.0, 2.0, 10.0), (2.0, 2.0, 20.0),
                                                    (3.0, 2.0, 60.0)])
            push!(two.history, Trial(i, 0.0, 0.1, [level, side], value, true))
        end
        two_points = get_aggregated_data(two)
        smoothed = Dict(point.vals => value for (point, value) in
                        zip(two_points, PsychophysicsManager.smoothed_means(two_points)))
        @test smoothed[[2.0, 1.0]] ≈ 2.0 && smoothed[[3.0, 2.0]] ≈ 40.0

        output = mktemp() do path, io
            redirect_stdout(() -> print_adjustment_summary(s), io)
            close(io)
            read(path, String)
        end
        @test occursin("Mean       | SD         | SEM        | 95% CI", output)
        @test occursin("±$(round(first_level.ci_hi - 4.0, digits = 2))", output)
    end

    @testset "A proportion's interval is binomial" begin
        lo0, hi0 = wilson_interval(0, 20)
        @test lo0 === 0.0 && isapprox(hi0, 0.161; atol = 1e-3)
        lo19, hi19 = wilson_interval(19, 20)
        @test isapprox(lo19, 0.764; atol = 1e-3) && isapprox(hi19, 0.991; atol = 1e-3)
        lo1, hi1 = wilson_interval(1, 1)
        @test isapprox(lo1, 0.207; atol = 1e-3) && hi1 === 1.0
        @test_throws ArgumentError wilson_interval(0, 0)
        @test_throws ArgumentError wilson_interval(-1, 5)
        @test_throws ArgumentError wilson_interval(6, 5)
        @test_throws ArgumentError wilson_interval(1, 5; level = 0.0)
        @test_throws ArgumentError wilson_interval(1, 5; level = 1.0)

        # Constant-stimuli choice session: 0 of 20 and 19 of 20 positive answers
        cs = SessionContext("Wilson", ExperimentParameters("CS", :level, [1.0, 2.0], 20),
                            BaseStimulusParameters(1.0), ConstantStimuli())
        for k in 1:20
            push!(cs.history, Trial(k, 0.0, 0.1, [1.0], 0, true))
        end
        for k in 1:20
            push!(cs.history, Trial(20 + k, 0.0, 0.1, [2.0], k <= 19 ? 1 : 0, true))
        end
        cs_agg = get_aggregated_data(cs)
        @test (cs_agg[1].ci_lo, cs_agg[1].ci_hi) == wilson_interval(0, 20)
        @test (cs_agg[2].ci_lo, cs_agg[2].ci_hi) == wilson_interval(19, 20)

        # Adjustment session keeps Student's t
        adj = SessionContext("Adj", ExperimentParameters("Adj", :level, [1.0, 2.0], 3),
                             BaseStimulusParameters(1.0),
                             Adjustment(dep_var = :duration_ms, dep_range = 0.0:10.0))
        for (i, (lvl, val)) in enumerate([(1.0, 0.0), (1.0, 1.0), (1.0, 0.0), (2.0, 2.0)])
            push!(adj.history, Trial(i, 0.0, 0.1, [lvl], val, true))
        end
        adj_agg = get_aggregated_data(adj)
        t_half = PsychophysicsManager.tdistinvcdf(2, (1 + PsychophysicsManager.CI_LEVEL) / 2) *
                 adj_agg[1].sem
        @test adj_agg[1].ci_lo ≈ adj_agg[1].mean_response - t_half
        @test adj_agg[1].ci_hi ≈ adj_agg[1].mean_response + t_half
        @test isnan(adj_agg[2].ci_lo) && isnan(adj_agg[2].ci_hi)

        # Method adjusting nothing, but responses are ratings (not all 0/1) -> Student's t
        rating = SessionContext("Rate", ExperimentParameters("Rate", :level, [1.0], 3),
                                BaseStimulusParameters(1.0), ConstantStimuli())
        for (i, val) in enumerate([1, 2, 3])
            push!(rating.history, Trial(i, 0.0, 0.1, [1.0], val, true))
        end
        rating_pt = only(get_aggregated_data(rating))
        t_half_rate = PsychophysicsManager.tdistinvcdf(2, (1 + PsychophysicsManager.CI_LEVEL) / 2) *
                      rating_pt.sem
        @test rating_pt.ci_lo ≈ rating_pt.mean_response - t_half_rate
        @test rating_pt.ci_hi ≈ rating_pt.mean_response + t_half_rate

        # Partly scored session: correct_ci_* counts scored trials only; NaN if unscored
        part = SessionContext("Part", ExperimentParameters("Part", :level, [1.0, 2.0], 3),
                              BaseStimulusParameters(1.0), ConstantStimuli())
        push!(part.history, Trial(1, 0.0, 0.1, [1.0], 1, true, :estimated, true))
        push!(part.history, Trial(2, 0.0, 0.1, [1.0], 0, true, :estimated, false))
        push!(part.history, Trial(3, 0.0, 0.1, [1.0], 1, true, :estimated, nothing))
        push!(part.history, Trial(4, 0.0, 0.1, [2.0], 1, true, :estimated, nothing))
        part_agg = get_aggregated_data(part)
        @test (part_agg[1].correct_ci_lo, part_agg[1].correct_ci_hi) == wilson_interval(1, 2)
        @test isnan(part_agg[2].correct_ci_lo) && isnan(part_agg[2].correct_ci_hi)

        # Pooled AnalysisSet of two choice sessions gets Wilson interval of pooled counts
        ex_pool = ExperimentParameters("Pool", :level, [1.0], 2)
        p1 = SessionContext("P1", ex_pool, BaseStimulusParameters(1.0), ConstantStimuli())
        p2 = SessionContext("P2", ex_pool, BaseStimulusParameters(1.0), ConstantStimuli())
        push!(p1.history, Trial(1, 0.0, 0.1, [1.0], 1, true))
        push!(p1.history, Trial(2, 0.0, 0.1, [1.0], 0, true))
        push!(p2.history, Trial(1, 0.0, 0.1, [1.0], 1, true))
        push!(p2.history, Trial(2, 0.0, 0.1, [1.0], 1, true))
        pool_set = AnalysisSet([p1, p2]; checks = collect(COMBINING_CHECKS))
        pool_pt = only(get_aggregated_data(pool_set))
        @test (pool_pt.ci_lo, pool_pt.ci_hi) == wilson_interval(3, 4)
    end

end
