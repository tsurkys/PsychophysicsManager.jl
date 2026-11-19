using JSON3

@testset "Analysis sets" begin

    function headless_session(participant_id::String = "P1";
                              ex_par = ExperimentParameters("Pooling", :x, [1.0, 2.0], 2),
                              stim_par = BaseStimulusParameters(100.0),
                              method = ConstantStimuli(),
                              trials = Trial[])
        session = SessionContext(participant_id, ex_par, stim_par, method)
        session.engine_name = "EmulatorEngine"
        for trial in trials
            push!(session.history, trial)
        end
        return session
    end

    @testset "Compatible sessions combine, and the rest are refused with a warning" begin
        all_checks = collect(COMBINING_CHECKS)
        s1 = headless_session("P1")
        s2 = headless_session("P2")
        s3 = headless_session("P3"; ex_par = ExperimentParameters("Pooling", :y, [1.0, 2.0], 2))

        set = @test_logs (:warn, r"independent_variables") (:warn, r"already in the set") AnalysisSet([s1, s2, s3, s1]; checks = all_checks)
        @test [s.id for s in set.sessions] == [s1.id, s2.id]

        fresh = AnalysisSet(; checks = all_checks)
        @test add_session!(fresh, s1) === :added
        @test @test_logs (:warn, r"independent_variables") add_session!(fresh, s3) === :incompatible
        @test @test_logs (:warn, r"already in the set") add_session!(fresh, s1) === :duplicate
    end

    @testset "A discarded session is never combined" begin
        mktempdir() do dir
            kept = headless_session("P1")
            thrown = headless_session("P2")
            save_session_checkpoint(kept, dir)
            discard_session(save_session_checkpoint(thrown, dir))
            reloaded = load_session(joinpath(dir, DISCARDED_DIRECTORY,
                                             basename(thrown.save_path)))

            set = AnalysisSet([kept])
            @test @test_logs (:warn, r"discarded") add_session!(set, reloaded) === :discarded
            @test length(set.sessions) == 1
        end
    end

    @testset "A person's answers are never pooled with a program's, whatever the checks" begin
        s_person = headless_session("P1")
        s_prog = headless_session("P2")
        set_observer_metadata!(s_prog, Dict{String, Any}("backend" => "SimulatedObserver"))

        set = AnalysisSet([s_person]; checks = Symbol[])
        @test @test_logs (:warn, r"observer_kind") add_session!(set, s_prog) === :incompatible

        s_tagged = headless_session("P3")
        push!(s_tagged.tags, "ai-observer")
        @test @test_logs (:warn, r"observer_kind") add_session!(set, s_tagged) === :incompatible
    end

    @testset "The response coding and fit_gamma are always compared" begin
        task1 = ObserverTask("Compare", ("left", "right"), "left")
        task2 = ObserverTask("Compare", ("left", "right"), "right")
        s1 = headless_session("P1")
        set_task!(s1, task1)
        s2 = headless_session("P2")
        set_task!(s2, task2)

        set1 = AnalysisSet([s1]; checks = Symbol[])
        @test @test_logs (:warn, r"response_coding") add_session!(set1, s2) === :incompatible

        s3 = headless_session("P3")
        set_fit_gamma!(s3, 0.0)
        s4 = headless_session("P4")
        set_fit_gamma!(s4, 0.5)

        set2 = AnalysisSet([s3]; checks = Symbol[])
        @test @test_logs (:warn, r"fit_gamma") add_session!(set2, s4) === :incompatible
    end

    @testset "An optional check compares only while it is on" begin
        all_checks = collect(COMBINING_CHECKS)

        task_a = ObserverTask("Instructions A", ("left", "right"), "right")
        task_b = ObserverTask("Instructions B", ("left", "right"), "right")
        s_inst1 = headless_session("P1"); set_task!(s_inst1, task_a)
        s_inst2 = headless_session("P2"); set_task!(s_inst2, task_b)
        set_inst = AnalysisSet([s_inst1]; checks = all_checks)
        @test @test_logs (:warn, r"instructions") add_session!(set_inst, s_inst2) === :incompatible
        set_inst_off = AnalysisSet([s_inst1]; checks = setdiff(all_checks, [:instructions]))
        @test add_session!(set_inst_off, s_inst2) === :added

        s_fb1 = headless_session("P1")
        s_fb2 = headless_session("P2"); set_feedback!(s_fb2, true)
        set_fb = AnalysisSet([s_fb1]; checks = all_checks)
        @test @test_logs (:warn, r"feedback") add_session!(set_fb, s_fb2) === :incompatible
        set_fb_off = AnalysisSet([s_fb1]; checks = setdiff(all_checks, [:feedback]))
        @test add_session!(set_fb_off, s_fb2) === :added

        s_to1 = headless_session("P1")
        s_to2 = headless_session("P2"); set_timeout!(s_to2, 2.0)
        set_to = AnalysisSet([s_to1]; checks = all_checks)
        @test @test_logs (:warn, r"timeout") add_session!(set_to, s_to2) === :incompatible
        set_to_off = AnalysisSet([s_to1]; checks = setdiff(all_checks, [:timeout]))
        @test add_session!(set_to_off, s_to2) === :added

        s_st1 = headless_session("P1"; stim_par = BaseStimulusParameters(100.0))
        s_st2 = headless_session("P2"; stim_par = BaseStimulusParameters(200.0))
        set_st = AnalysisSet([s_st1]; checks = all_checks)
        @test @test_logs (:warn, r"stimulus fields duration_ms") add_session!(set_st, s_st2) === :incompatible
        set_st_off = AnalysisSet([s_st1]; checks = setdiff(all_checks, [:stimulus]))
        @test add_session!(set_st_off, s_st2) === :added

        s_ob1 = headless_session("P1")
        set_observer_metadata!(s_ob1, Dict{String, Any}("backend" => "SimulatedObserver", "deliberation" => "low"))
        s_ob2 = headless_session("P2")
        set_observer_metadata!(s_ob2, Dict{String, Any}("backend" => "SimulatedObserver", "deliberation" => "high"))
        set_ob = AnalysisSet([s_ob1]; checks = all_checks)
        @test @test_logs (:warn, r"observer") add_session!(set_ob, s_ob2) === :incompatible
        set_ob_off = AnalysisSet([s_ob1]; checks = setdiff(all_checks, [:observer]))
        @test add_session!(set_ob_off, s_ob2) === :added

        s_req1 = headless_session("P1")
        set_observer_metadata!(s_req1, Dict{String, Any}("backend" => "SimulatedObserver", "requests" => 5, "failed_requests" => 0))
        s_req2 = headless_session("P2")
        set_observer_metadata!(s_req2, Dict{String, Any}("backend" => "SimulatedObserver", "requests" => 12, "failed_requests" => 2))
        set_req = AnalysisSet([s_req1]; checks = all_checks)
        @test add_session!(set_req, s_req2) === :added
    end

    @testset "Members agree on the units, and each converts by its own conversion" begin
        all_checks = collect(COMBINING_CHECKS)
        # One offset measured on two displays: the same pixels, different minutes of arc
        adjustment() = Adjustment(dep_var = :duration_ms, dep_range = -20.0:20.0)
        near = headless_session("P1"; method = adjustment(),
                                trials = [Trial(1, 0.0, 0.1, [1.0], 10.0, true)])
        far = headless_session("P2"; method = adjustment(),
                               trials = [Trial(1, 0.0, 0.1, [1.0], 10.0, true)])
        set_unit_conversion!(near, :duration_ms, UnitConversion("Offset (arcmin)"; scale = 1.0))
        set_unit_conversion!(far, :duration_ms, UnitConversion("Offset (arcmin)"; scale = 0.5))
        set = AnalysisSet([near, far]; checks = all_checks)
        @test length(set.sessions) == 2
        @test only(get_aggregated_data(set)).mean_response == 7.5
        mktempdir() do dir
            lines = readlines(export_session(set, joinpath(dir, "set.csv")))
            @test "# unit_conversion.duration_ms: Offset (arcmin) = duration_ms; " *
                  "Offset (arcmin) = 0.5 * duration_ms" in lines
            @test any(line -> startswith(line, "$(far.id),P2,1,1.0,10.0,5.0,"), lines)
        end

        # A member reported in other units, or in none, would mix them in one mean
        degrees = headless_session("P3"; method = adjustment())
        set_unit_conversion!(degrees, :duration_ms, UnitConversion("Offset (deg)"; scale = 1 / 60))
        @test @test_logs (:warn, r"units") add_session!(set, degrees) === :incompatible
        @test @test_logs (:warn, r"units") add_session!(set, headless_session("P4"; method = adjustment())) === :incompatible

        # A replication is reported in the units of its template
        replica = create_replicated_session(far, "P5")
        @test replica.unit_conversions == far.unit_conversions
        @test replica.unit_conversions !== far.unit_conversions
    end

    @testset "A field the method sets during the run is not a design fact" begin
        m_adj1 = Adjustment(dep_var = :duration_ms, dep_range = 100.0:100.0:300.0)
        m_adj2 = Adjustment(dep_var = :duration_ms, dep_range = 100.0:100.0:300.0)
        @test adjusted_fields(m_adj1) == [:duration_ms]
        @test isempty(adjusted_fields(ConstantStimuli()))

        s1 = headless_session("P1"; stim_par = BaseStimulusParameters(100.0), method = m_adj1)
        s2 = headless_session("P2"; stim_par = BaseStimulusParameters(300.0), method = m_adj2)

        set = AnalysisSet([s1]; checks = collect(COMBINING_CHECKS))
        @test add_session!(set, s2) === :added
    end

    @testset "Interleaved runs combine only when their tracks match in order" begin
        ex_par = ExperimentParameters("Interleaved", [:x, :track], Any[[1.0, 2.0], 1:2], 1)
        m1 = Interleaved([Staircase(2), Staircase(2)])
        m2 = Interleaved([Staircase(2), Staircase(2)])
        m3 = Interleaved([Staircase(2), ConstantStimuli()])

        s1 = headless_session("P1"; ex_par = deepcopy(ex_par), method = m1)
        s2 = headless_session("P2"; ex_par = deepcopy(ex_par), method = m2)
        s3 = headless_session("P3"; ex_par = deepcopy(ex_par), method = m3)

        set = AnalysisSet([s1]; checks = collect(COMBINING_CHECKS))
        @test add_session!(set, s2) === :added
        @test @test_logs (:warn, r"method") add_session!(set, s3) === :incompatible
    end

    @testset "A set is saved whole and read back the same" begin
        mktempdir() do dir
            s1 = headless_session("P1")
            push!(s1.history, Trial(1, 0.0, 0.5, [1.0], 1, true))
            s2 = headless_session("P2")
            push!(s2.history, Trial(1, 0.0, 0.6, [2.0], 0, true))
            push!(s2.history, Trial(2, 1.0, 1.4, [1.0], 1, true))

            orig_set = AnalysisSet([s1, s2]; checks = [:feedback])
            file_path = joinpath(dir, "set.json")
            saved_path = save_analysis_set(orig_set, file_path)

            @test isabspath(saved_path)
            @test isfile(saved_path)
            @test saved_path == abspath(file_path)

            loaded = load_analysis_set(saved_path)
            @test loaded.checks == [:feedback]
            @test length(loaded.sessions) == 2
            @test [s.id for s in loaded.sessions] == [s1.id, s2.id]
            @test [s.participant_id for s in loaded.sessions] == [s1.participant_id, s2.participant_id]
            @test [length(s.history) for s in loaded.sessions] == [length(s1.history), length(s2.history)]
            @test [[t.response for t in s.history] for s in loaded.sessions] ==
                  [[t.response for t in s1.history], [t.response for t in s2.history]]
            @test all(s -> s.save_path === nothing, loaded.sessions)

            @test @test_logs (:warn, r"already in the set") add_session!(loaded, s1) === :duplicate
        end
    end

    @testset "A saved set only grows" begin
        mktempdir() do dir
            all_checks = collect(COMBINING_CHECKS)
            s1 = headless_session("P1")
            s2 = headless_session("P2")
            s3 = headless_session("P3")

            set12 = AnalysisSet([s1, s2]; checks = all_checks)
            set_path = joinpath(dir, "set.json")
            save_analysis_set(set12, set_path)

            set1 = AnalysisSet([s1]; checks = all_checks)
            @test_throws ArgumentError save_analysis_set(set1, set_path)

            set123 = AnalysisSet([s1, s2, s3]; checks = all_checks)
            @test isfile(save_analysis_set(set123, set_path))

            s_single = headless_session("P0")
            single_path = save_session_checkpoint(s_single, dir; filename = "one.json")
            @test_throws ArgumentError save_analysis_set(set12, single_path)

            empty_set = AnalysisSet(; checks = all_checks)
            @test_throws ArgumentError save_analysis_set(empty_set, joinpath(dir, "empty.json"))
        end
    end

    @testset "A file that is not a valid set is refused" begin
        mktempdir() do dir
            s1 = headless_session("P1")
            s2 = headless_session("P2")
            set = AnalysisSet([s1, s2]; checks = collect(COMBINING_CHECKS))
            set_path = joinpath(dir, "set.json")
            save_analysis_set(set, set_path)

            doc = JSON3.read(read(set_path, String), Dict)
            push!(doc["sessions"], deepcopy(first(doc["sessions"])))
            write(set_path, JSON3.write(doc))
            @test_throws ArgumentError load_analysis_set(set_path)

            save_analysis_set(set, set_path)
            @test_throws ArgumentError load_session(set_path)

            single_path = save_session_checkpoint(s1, dir; filename = "one.json")
            @test_throws ArgumentError load_analysis_set(single_path)
        end
    end

    @testset "A new experiment set up from a set starts from its last session" begin
        mktempdir() do dir
            ex1 = ExperimentParameters("Pooling", :x, [1.0, 2.0], 2)
            ex2 = ExperimentParameters("Pooling", :x, [1.0, 2.0, 3.0], 3)
            s1 = headless_session("P1"; ex_par = ex1)
            push!(s1.history, Trial(1, 0.0, 0.5, [1.0], 1, true))
            s2 = headless_session("P2"; ex_par = ex2)
            push!(s2.history, Trial(1, 0.0, 0.5, [1.0], 0, true))

            set = AnalysisSet([s1, s2]; checks = collect(COMBINING_CHECKS))
            path = joinpath(dir, "set.json")
            saved_path = save_analysis_set(set, path)

            rep_from_set = create_replicated_session(set, "P9")
            @test rep_from_set.state == READY
            @test rep_from_set.participant_id == "P9"
            @test rep_from_set.ex_par.repeats == 3
            @test rep_from_set.ex_par.indep_var_ranges[1] == [1.0, 2.0, 3.0]
            @test isempty(rep_from_set.history)
            @test rep_from_set.id != s1.id && rep_from_set.id != s2.id

            rep_from_file = create_replicated_session(saved_path, "P9")
            @test rep_from_file.state == READY
            @test rep_from_file.participant_id == "P9"
            @test rep_from_file.ex_par.repeats == 3
            @test rep_from_file.ex_par.indep_var_ranges[1] == [1.0, 2.0, 3.0]
            @test isempty(rep_from_file.history)
            @test rep_from_file.id != s1.id && rep_from_file.id != s2.id
        end
    end

    @testset "A set is analysed as its trials pooled" begin
        s1 = headless_session("P1")
        push!(s1.history, Trial(1, 0.0, 0.5, [1.0], 1, true))
        push!(s1.history, Trial(2, 0.0, 0.5, [1.0], 0, true))
        push!(s1.history, Trial(3, 0.0, 0.5, [1.0], 1, false))

        s2 = headless_session("P2")
        push!(s2.history, Trial(1, 0.0, 0.5, [1.0], 1, true))
        push!(s2.history, Trial(2, 0.0, 0.5, [1.0], 1, true))
        push!(s2.history, Trial(3, 0.0, 0.5, [2.0], 0, true))

        set = AnalysisSet([s1, s2]; checks = collect(COMBINING_CHECKS))
        agg = get_aggregated_data(set)

        @test length(agg) == 2
        @test agg[1].level == 1.0
        @test agg[1].n == 4
        @test agg[1].mean_response == 0.75
        @test agg[2].level == 2.0
        @test agg[2].n == 1
        @test agg[2].mean_response == 0.0

        s_all = headless_session("P_all")
        append!(s_all.history, s1.history)
        append!(s_all.history, s2.history)
        agg_single = get_aggregated_data(s_all)

        @test length(agg) == length(agg_single)
        for (p1, p2) in zip(agg, agg_single)
            for field in fieldnames(AggregatePoint)
                @test isequal(getfield(p1, field), getfield(p2, field))
            end
        end

        fit = redirect_stdout(devnull) do
            print_psychometric_summary(set)
        end
        @test fit isa CurveFit

        adj = redirect_stdout(devnull) do
            print_adjustment_summary(set)
        end
        @test adj === nothing

        empty_set = AnalysisSet(; checks = collect(COMBINING_CHECKS))
        @test isempty(get_aggregated_data(empty_set))
    end

    @testset "The checks come from settings" begin
        mktempdir() do dir
            @test load_combining_checks(dir) == collect(COMBINING_CHECKS)

            toml_path = joinpath(dir, "settings.toml")
            write(toml_path, "[combining]\ninstructions = false\nstimulus = false\n")
            @test load_combining_checks(dir) == [:observer, :feedback, :timeout]

            write(toml_path, "[combining]\nunknown = true\n")
            @test_throws ArgumentError load_combining_checks(dir)

            write(toml_path, "[combining]\ninstructions = 1\n")
            @test_throws ArgumentError load_combining_checks(dir)
        end

        @test_throws ArgumentError AnalysisSet(; checks = [:bogus])
    end

end
