Base.@kwdef mutable struct IntegerAdjustmentParameters <: AbstractStimulusParameters
    pixel_offset::Int = 0
end

# A method written against the original contract: it knows nothing about scoring
mutable struct UnscoredMethod <: AbstractPsychoMethod
    responses::Vector{Real}
    UnscoredMethod() = new(Real[])
end
PsychophysicsManager.update_method_state!(method::UnscoredMethod, response::Real) =
    push!(method.responses, response)

# A detection task whose signal is present on every trial: "yes" (+1) is the
# correct answer for every presentation, which is the yes/no semantics the
# staircase carried before it began stepping on scored responses
struct SignalPresentStimulus <: AbstractStimulusParameters end
PsychophysicsManager.correct_answer(::SignalPresentStimulus, ::NamedTuple) = 1
register_stimulus_type!(SignalPresentStimulus)

@testset "Methods" begin

    @testset "ConstantStimuli" begin
        ex_par = ExperimentParameters("t", [:a, :b], [[1.0, 2.0, 3.0], [10.0, 20.0]], 2)
        stim = BaseStimulusParameters(100.0)
        m = ConstantStimuli()
        session = SessionContext("p", ex_par, stim, m)
        initialize_method!(m, ex_par)

        # Full factorial (3 x 2) x 2 repeats
        @test length(m.order) == 12
        counts = Dict{Vector{Float64}, Int}()
        for t in m.trial_table
            counts[t] = get(counts, t, 0) + 1
        end
        @test all(c == 2 for c in values(counts))
        @test length(counts) == 6
        # Repeated entries are independent copies, not aliases of one vector
        @test length(unique(objectid.(m.trial_table))) == length(m.trial_table)

        # Progress/reporting hooks
        @test planned_trial_count(m) == 12
        @test planned_trial_count(ConstantStimuli()) === nothing
        t_demo = Trial(1, 0.0, 1.0, [2.0, 20.0], 1, true)
        @test describe_trial(m, ex_par, t_demo) == "a=2.0, b=20.0 → 1"
        @test describe_method_state(m) === nothing

        vals = get_next_trial_params(m, session)
        @test vals in m.trial_table
        @test length(vals) == 2

        # Response 0 = "show again": trial not finished, index unchanged
        update_method_state!(m, 0)
        @test !is_trial_finished(m)
        @test get_next_trial_params(m, session) == vals

        # A real response advances the trial
        update_method_state!(m, 1)
        @test is_trial_finished(m)
        @test get_next_trial_params(m, session) !== nothing
        @test m.current_idx == 2

        # Binary recoding: -1 -> 0, +1 -> 1
        @test get_trial_result(m, -1) == 0
        @test get_trial_result(m, 1) == 1

        # Revert re-queues the last trial
        trial = Trial(1, 0.0, 0.0, vals, 1, false)
        revert_method_state!(m, trial)
        @test m.current_idx == 1
        @test get_next_trial_params(m, session) == vals

        # Completion
        for _ in 1:12
            update_method_state!(m, -1)
        end
        @test is_experiment_finished(m)
    end

    @testset "Adjustment" begin
        ex_par = ExperimentParameters("t", :DistrN, [0.0, 2.0], 2)
        stim = MarkerLayout(Diff = 0.0)
        m = Adjustment(dep_var = :Diff, dep_range = 0.0:1.0:10.0,
                             init_interval = (5.0, 5.0))
        session = SessionContext("p", ex_par, stim, m)
        initialize_method!(m, ex_par)
        @test length(m.order) == 4
        @test planned_trial_count(m) == 4
        @test describe_trial(m, ex_par, Trial(1, 0.0, 1.0, [2.0], 6.0, true)) ==
              "DistrN=2.0 → Diff = 6.0"

        # Trial starts at the init_interval value
        vals = get_next_trial_params(m, session)
        @test length(vals) == 1
        apply_method_state!(m, stim)
        @test stim.Diff == 5.0
        @test m.init_vals == [5.0]

        # +1 moves one range step up
        update_method_state!(m, 1)
        @test !is_trial_finished(m)
        apply_method_state!(m, stim)
        @test stim.Diff == 6.0

        # 0 confirms: the recorded result is the adjusted value
        update_method_state!(m, 0)
        @test is_trial_finished(m)
        @test get_trial_result(m, 0) == 6.0
        @test !is_experiment_finished(m)

        # Next trial re-initializes
        get_next_trial_params(m, session)
        apply_method_state!(m, stim)
        @test stim.Diff == 5.0
        @test length(m.init_vals) == 2

        # Clamping at the range edges
        for _ in 1:20
            update_method_state!(m, 1)
        end
        apply_method_state!(m, stim)
        @test stim.Diff == 10.0
        for _ in 1:30
            update_method_state!(m, -1)
        end
        apply_method_state!(m, stim)
        @test stim.Diff == 0.0

        # Revert removes the recorded init value and re-queues
        update_method_state!(m, 0)
        n_before = m.current_trial
        revert_method_state!(m, Trial(2, 0.0, 0.0, [0.0], 0.0, false))
        @test m.current_trial == n_before - 1
        @test length(m.init_vals) == 1

        # Without init_interval the trial starts from the current stim value
        m2 = Adjustment(dep_var = :Diff, dep_range = 0.0:1.0:10.0)
        session2 = SessionContext("p", ex_par, MarkerLayout(Diff = 3.2), m2)
        initialize_method!(m2, ex_par)
        get_next_trial_params(m2, session2)
        apply_method_state!(m2, session2.stim_par)
        @test session2.stim_par.Diff == 3.0

        # fresh_instance keeps configuration, drops runtime state
        f = fresh_instance(m)
        @test f.dep_var == m.dep_var
        @test f.dep_range == m.dep_range
        @test f.init_interval == m.init_interval
        @test isempty(f.init_vals) && isempty(f.order)

        # Ranges need no collect. Integer inputs stay integer so discrete
        # adjustments (for example, pixel positions) produce integer results.
        pixel_method = Adjustment(
            dep_var = :pixel_offset,
            dep_range = -2:2,
            init_interval = (0, 0),
        )
        pixel_stim = IntegerAdjustmentParameters()
        pixel_session = SessionContext("pixels", ex_par, pixel_stim, pixel_method)
        initialize_method!(pixel_method, ex_par)
        get_next_trial_params(pixel_method, pixel_session)
        apply_method_state!(pixel_method, pixel_stim)
        @test pixel_stim.pixel_offset === 0
        update_method_state!(pixel_method, 1)
        apply_method_state!(pixel_method, pixel_stim)
        @test pixel_stim.pixel_offset === 1
        @test get_trial_result(pixel_method, 0) === 1
        @test all(value -> value isa Int, pixel_method.dep_range)

        float_method = Adjustment(dep_range = Float32[0, 0.5, 1])
        @test float_method.dep_range == [0.0, 0.5, 1.0]
        @test all(value -> value isa Float64, float_method.dep_range)

        # The adjusted parameter and its range are the stimulus's: without them the
        # method is built, stored and read back, but no session starts
        unset = Adjustment()
        @test unset.dep_var === nothing && isempty(unset.dep_range)
        @test unset_settings(unset) == [:dep_var, :dep_range] && isempty(adjusted_fields(unset))
        @test unset_settings(Adjustment(dep_range = Int[], dep_var = :Diff)) == [:dep_range]
        @test isempty(unset_settings(m2))
        read_back = PsychophysicsManager.method_from_dict(PsychophysicsManager.method_to_dict(unset))
        @test read_back.dep_var === nothing && isempty(read_back.dep_range)
        @test_throws ArgumentError initialize_method!(Adjustment(dep_var = :Diff), ex_par)
        unstarted = SessionContext("u", ex_par, MarkerLayout(), Adjustment())
        err = try start_session!(unstarted) catch e e end
        @test err isa ArgumentError && occursin("dep_var and dep_range", err.msg)
        @test unstarted.state == READY
        # Chosen for a stimulus, it adjusts the first number the stimulus lists that is
        # not a variable, and leaves the range to the experimenter
        filled = fill_stimulus_settings(unset, MarkerLayout(), ex_par)
        @test filled.dep_var == first(filter(!in(ex_par.indep_var_names),
                                             numeric_parameters(MarkerLayout())))
        @test unset_settings(filled) == [:dep_range]
        @test fill_stimulus_settings(m2, Gabor(), ex_par) === m2
        @test_throws ArgumentError Adjustment(dep_range = [0.0, Inf])
        @test_throws ArgumentError Adjustment(dep_range = Any[0, "one"])
        @test_throws ArgumentError Adjustment(init_interval = (2, 1))
    end

    @testset "Staircase" begin
        ex_par = ExperimentParameters("t", :level, [1.0, 2.0, 3.0, 4.0, 5.0], 10)
        m = Staircase(2)
        session = SessionContext("p", ex_par, SignalPresentStimulus(), m)
        initialize_method!(m, ex_par)

        # Starts at the easiest (highest) level
        @test get_next_trial_params(m, session) == [5.0]
        @test planned_trial_count(m) == 10

        # Two correct -> one step down
        update_method_state!(m, 1, true)
        @test get_next_trial_params(m, session) == [5.0]
        update_method_state!(m, 1, true)
        @test get_next_trial_params(m, session) == [4.0]

        # One incorrect -> immediately up, and the run of correct answers restarts
        update_method_state!(m, -1, false)
        @test get_next_trial_params(m, session) == [5.0]
        @test m.correct_count == 0

        # Neither non-answer moves the level, and they part company over whose
        # trial it still is: a repeat request is the participant asking to see
        # the same stimulus again
        spent = m.current_trial
        level = get_next_trial_params(m, session)
        update_method_state!(m, 0, nothing)
        @test !is_trial_finished(m)
        @test m.current_trial == spent
        @test get_next_trial_params(m, session) == level

        # An answer concludes the trial again
        update_method_state!(m, 1, true)
        @test is_trial_finished(m)
        @test m.current_trial == spent + 1
        @test get_next_trial_params(m, session) == level

        # A missing response is missing data: the trial is spent and concluded,
        # so the Core records it and it can be marked invalid
        counted = m.correct_count
        update_method_state!(m, MISSING_RESPONSE, nothing)
        @test is_trial_finished(m)
        @test m.current_trial == spent + 2
        @test m.correct_count == counted
        @test get_next_trial_params(m, session) == level

        # The limit counts every spent trial
        for _ in 1:5
            update_method_state!(m, 1, true)
        end
        @test is_experiment_finished(m)

        # In a task that scores its answers, a presentation without a correct
        # answer cannot drive the staircase, and neither can a response alone
        @test_throws ArgumentError update_method_state!(m, 1, nothing)
        @test_throws ArgumentError update_method_state!(m, 1)

        @test fresh_instance(m).n_down == 2

        # The reporter's intra-trial line names the level being presented
        @test describe_method_state(m) ==
              "level $(only(get_next_trial_params(m, session)))"
        @test describe_method_state(Staircase(2)) === nothing
    end

    @testset "Staircase trial limit and further variables" begin
        # The limit is declared, or falls back to the only length an
        # experiment that declares none states about itself
        declared = Staircase(2; trial_limit = 30)
        defaulted = Staircase(2)
        ex_par = ExperimentParameters("limits", :level, [1.0, 2.0], 8)
        initialize_method!(declared, ex_par)
        initialize_method!(defaulted, ex_par)
        @test declared.trial_limit == 30
        @test defaulted.trial_limit == 8

        # The declaration is configuration, so it survives a replication
        @test fresh_instance(declared).declared_trial_limit == 30
        @test fresh_instance(defaulted).declared_trial_limit === nothing

        @test_throws ArgumentError Staircase(2; trial_limit = 0)
        @test_throws ArgumentError Staircase(0)

        # The staircase adapts the first variable; every further one is drawn
        # uniformly from its own range, once per trial
        two_ifc = ExperimentParameters("2IFC", [:level, :target_interval],
                                       [[1.0, 2.0, 3.0], [1.0, 2.0]], 40)
        method = Staircase(2)
        session = SessionContext("p", two_ifc, SignalPresentStimulus(), method;
                                 rng_seed = UInt64(4242))
        start_session!(session)
        sides = Float64[]
        for _ in 1:40
            vals = get_next_trial_params(method, session)
            @test length(vals) == 2
            push!(sides, vals[2])
            # A repeat request must show the same stimulus, not a new draw
            update_method_state!(method, 0, nothing)
            @test get_next_trial_params(method, session) == vals
            update_method_state!(method, 1, true)
        end
        @test Set(sides) == Set([1.0, 2.0])

        # A missing response spends its trial without moving the level, and the
        # next trial draws its own side again
        spent = method.current_trial
        level = get_next_trial_params(method, session)[1]
        update_method_state!(method, MISSING_RESPONSE, nothing)
        @test is_trial_finished(method)
        @test method.current_trial == spent + 1
        @test get_next_trial_params(method, session)[1] == level

        # Save -> load -> continue keeps both the declaration and the level
        # the staircase had reached
        mktempdir() do dir
            s = SessionContext("p", ExperimentParameters("saved", :level, [1.0, 2.0], 5),
                               SignalPresentStimulus(),
                               Staircase(3; trial_limit = 12))
            start_session!(s)
            update_method_state!(s.method_instance, -1, false)
            loaded = load_session(save_session_checkpoint(s, dir))
            @test loaded.method_instance.declared_trial_limit == 12
            @test loaded.method_instance.trial_limit == 12
            @test loaded.method_instance.n_down == 3
            @test loaded.method_instance.current_trial == 2

            open_ended = SessionContext("p",
                                        ExperimentParameters("resolved", :level, [1.0, 2.0], 5),
                                        SignalPresentStimulus(), Staircase(2))
            start_session!(open_ended)
            reloaded = load_session(save_session_checkpoint(open_ended, dir))
            @test reloaded.method_instance.declared_trial_limit === nothing
            @test reloaded.method_instance.trial_limit == 5
        end
    end

    @testset "Interleaved" begin
        fine = [1.0, 2.0, 3.0, 4.0]
        coarse = [10.0, 20.0, 30.0]
        design(names, ranges) =
            ExperimentParameters("interleaved", names, ranges, 1)
        full = design([:level, :track], Any[fine, 1:2])

        @testset "The design must name the track" begin
            m = Interleaved([Staircase(2), Staircase(2)])
            # Without the variable there is nowhere to record which track ran
            @test_throws ArgumentError initialize_method!(
                m, design([:level], Any[fine]))
            # And its range is one value per track, not an arbitrary list
            @test_throws ArgumentError initialize_method!(
                m, design([:level, :track], Any[fine, 1:3]))

            # One value per track: a range naming a track twice is a mistake
            @test_throws ArgumentError initialize_method!(
                m, design([:level, :track], Any[fine, [1.0, 2.0, 2.0]]))

            @test_throws ArgumentError Interleaved(AbstractPsychoMethod[])
            @test_throws ArgumentError Interleaved([Staircase(2)];
                                                         order = :alternating)

            # A run whose recorded column is not the design's track column
            # belongs to another experiment, and says so
            initialize_method!(m, full)
            elsewhere = SessionContext("p", design([:level, :other], Any[fine, 1:2]),
                                       SignalPresentStimulus(), m)
            @test_throws ArgumentError get_next_trial_params(m, elsewhere)
        end

        @testset "Each track walks its own levels" begin
            tracks = [Staircase(2; levels = fine, trial_limit = 4),
                      Staircase(2; levels = coarse, trial_limit = 4)]
            m = Interleaved(tracks; order = :round_robin)
            session = SessionContext("p", full, SignalPresentStimulus(), m)
            initialize_method!(m, full; rng = Xoshiro(1))

            # Round robin starts at the first track and alternates; the level
            # comes from that track's own list, and the track's index is the
            # column the design declared for it
            first_trial = get_next_trial_params(m, session)
            @test first_trial == [4.0, 1.0]
            update_method_state!(m, 1, true)
            @test get_next_trial_params(m, session) == [30.0, 2.0]
            update_method_state!(m, 1, true)
            @test get_next_trial_params(m, session)[2] == 1.0

            # A repeat request keeps the trial, and the track, where it was
            level = get_next_trial_params(m, session)
            update_method_state!(m, 0, nothing)
            @test !is_trial_finished(m)
            @test get_next_trial_params(m, session) == level

            @test planned_trial_count(m) == 8
            @test occursin("track 1", describe_method_state(m))
        end

        @testset "A finished track is skipped, not presented" begin
            tracks = [Staircase(2; levels = fine, trial_limit = 1),
                      Staircase(2; levels = coarse, trial_limit = 4),
                      Staircase(2; levels = coarse, trial_limit = 4)]
            m = Interleaved(tracks; order = :round_robin)
            wide = design([:level, :track], Any[fine, 1:3])
            session = SessionContext("p", wide, SignalPresentStimulus(), m)
            initialize_method!(m, wide; rng = Xoshiro(2))

            visited = Int[]
            while !is_experiment_finished(m)
                push!(visited, Int(get_next_trial_params(m, session)[2]))
                update_method_state!(m, 1, true)
            end
            # The first track ends after one trial and never comes up again,
            # while the other two run to their own limits
            @test count(==(1), visited) == 1
            @test count(==(2), visited) == 4
            @test count(==(3), visited) == 4
        end

        @testset "Undo reaches the track that owns the trial" begin
            tracks = [ConstantStimuli(), ConstantStimuli()]
            m = Interleaved(tracks; order = :round_robin)
            initialize_method!(m, full; rng = Xoshiro(3))
            session = SessionContext("p", full, SignalPresentStimulus(), m)
            # One trial each, so both tracks have something to re-queue
            for _ in 1:2
                get_next_trial_params(m, session)
                update_method_state!(m, 1)
            end
            advanced = [track.current_idx for track in tracks]

            # Telling a method about a trial it never handed out is an error,
            # not a response attributed to whichever track came first
            @test_throws ArgumentError update_method_state!(
                Interleaved([ConstantStimuli()]), 1)

            # The trial names its track, and only that track re-queues it
            undone = Trial(2, 0.0, 0.1, [2.0, 2.0], 1, true)
            @test revert_method_state!(m, undone)
            @test tracks[2].current_idx == advanced[2] - 1
            @test tracks[1].current_idx == advanced[1]
            @test is_trial_finished(m)

            # A trial from another design names no track of this run
            @test_logs (:warn, r"does not name a track") begin
                @test !revert_method_state!(m, Trial(3, 0.0, 0.1, [2.0, 9.0], 1, true))
            end
        end

        @testset "What the track decides stays the track's" begin
            tracks = [ConstantStimuli(), Staircase(2; levels = coarse)]
            m = Interleaved(tracks; order = :round_robin)
            initialize_method!(m, full; rng = Xoshiro(4))
            session = SessionContext("p", full, SignalPresentStimulus(), m)

            # Constant stimuli recodes its responses, the staircase does not
            get_next_trial_params(m, session)
            @test get_trial_result(m, -1) == 0
            update_method_state!(m, 1, true)
            get_next_trial_params(m, session)
            @test get_trial_result(m, -1) == -1
            # An unanswered trial is the active track's decision too
            @test timeout_result(m, session) === :timeout
        end

        @testset "A track keeps the values it owns" begin
            adjustment = Adjustment(dep_var = :duration_ms,
                                          dep_range = 100.0:50.0:300.0)
            single = design([:level, :track], Any[fine, 1:1])
            m = Interleaved([adjustment])
            initialize_method!(m, single; rng = Xoshiro(5))
            session = SessionContext("p", single, BaseStimulusParameters(100.0), m)

            # The composite adds its column to a copy: a method that hands out a
            # vector of its own must not find a track index in it afterwards
            vals = get_next_trial_params(m, session)
            @test length(vals) == 2
            @test all(row -> length(row) == 1, adjustment.trial_table)

            # The operator line stays the track's own phrasing
            trial = Trial(1, 0.0, 0.1, [2.0, 1.0], 250.0, true)
            @test occursin("duration_ms = 250.0", describe_trial(m, single, trial))
        end
    end

    @testset "Reproducible randomization" begin
        # Everything a method decides at random comes from the session's seed,
        # so two sessions that declare the same seed present the same sequence
        constant_order(seed) = begin
            ex_par = ExperimentParameters("Seeded", [:a, :b],
                                          [[1.0, 2.0, 3.0], [10.0, 20.0]], 3)
            method = ConstantStimuli()
            session = SessionContext("p", ex_par, BaseStimulusParameters(100.0),
                                     method; rng_seed = seed)
            start_session!(session)
            return copy(method.order)
        end

        @test constant_order(UInt64(20260907)) == constant_order(UInt64(20260907))
        @test constant_order(UInt64(20260907)) != constant_order(UInt64(20260908))

        # The adjustment starting values are drawn per trial, not at setup, so
        # they test that the stream itself is carried through the run
        adjustment_starts(seed) = begin
            ex_par = ExperimentParameters("SeededAdj", :contrast, [0.2, 0.8], 2)
            method = Adjustment(dep_var = :duration_ms,
                                      dep_range = 100.0:10.0:500.0,
                                      init_interval = (200.0, 400.0))
            session = SessionContext("p", ex_par, BaseStimulusParameters(300.0),
                                     method; rng_seed = seed)
            start_session!(session)
            for _ in 1:4
                get_next_trial_params(method, session)
                update_method_state!(method, 0)   # confirm, next trial re-initializes
            end
            return copy(method.init_vals)
        end

        @test length(adjustment_starts(UInt64(11))) == 4
        @test adjustment_starts(UInt64(11)) == adjustment_starts(UInt64(11))
        @test adjustment_starts(UInt64(11)) != adjustment_starts(UInt64(12))

        # A session that is not given a seed draws its own
        ex_par = ExperimentParameters("Unseeded", :a, [1.0], 1)
        one_session = SessionContext("p", ex_par, BaseStimulusParameters(1.0),
                                     ConstantStimuli())
        another_session = SessionContext("p", ex_par, BaseStimulusParameters(1.0),
                                         ConstantStimuli())
        @test one_session.rng_seed != another_session.rng_seed

        # A method that makes no random choice still accepts the keyword
        staircase = Staircase(2)
        initialize_method!(staircase, ExperimentParameters("s", :level, [1.0, 2.0], 4);
                           rng = Random.Xoshiro(1))
        @test staircase.trial_limit == 4
    end

    @testset "A scored update falls back to the two-argument form" begin
        method = UnscoredMethod()
        update_method_state!(method, 1, true)
        update_method_state!(method, -1, false)
        update_method_state!(method, 0, nothing)
        @test method.responses == [1, -1, 0]
    end

end
