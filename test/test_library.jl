using Dates
using Logging

@testset "Session library" begin

    # Every fixture is written by the package's own writer: browsing reads the session
    # file directly, so only a real save keeps the two readers of the schema together
    function saved_session(directory::String, participant::String;
                           tags = String[], state = READY, started = nothing,
                           trials = 0, invalid = 0,
                           method = ConstantStimuli(),
                           stim_par = BaseStimulusParameters(100.0),
                           ex_par = ExperimentParameters("Library", :Diff, [-5.0, 5.0], 2),
                           task = nothing, feedback = false, timeout_s = nothing,
                           fit_gamma = DEFAULT_FIT_GAMMA,
                           unit_conversions = Pair{Symbol, UnitConversion}[],
                           observer_metadata = Dict{String, Any}(),
                           comments = String[])
        session = SessionContext(participant, ex_par, stim_par, method; tags = copy(tags))
        session.engine_name = "EmulatorEngine"
        session.state = state
        session.start_time = started
        task === nothing || set_task!(session, task)
        feedback && set_feedback!(session, true)
        timeout_s === nothing || set_timeout!(session, timeout_s)
        fit_gamma == DEFAULT_FIT_GAMMA || set_fit_gamma!(session, fit_gamma)
        for (variable, conversion) in unit_conversions
            set_unit_conversion!(session, variable, conversion)
        end
        isempty(observer_metadata) || set_observer_metadata!(session, observer_metadata)
        for note in comments
            add_comment!(session, note)
        end
        for index in 1:trials
            push!(session.history,
                  Trial(index, 1.0, 1.5, [Float64(index)], 1, index > invalid, :estimated))
        end
        return (session, save_session_checkpoint(session, directory))
    end

    @testset "A data directory is catalogued as it stands" begin
        mktempdir() do dir
            data = joinpath(dir, "data")
            mkpath(data)
            _, early = saved_session(data, "P01"; tags = ["practice"], state = FINISHED,
                                     started = 1.0e9, trials = 4, invalid = 1)
            _, late = saved_session(data, "P02"; state = PAUSED, started = 2.0e9,
                                    trials = 2)
            _, template = saved_session(data, "P03")            # never started
            write(joinpath(data, "notes.json"), "{\"unrelated\": 1}")
            write(joinpath(data, "half-written.json.tmp"), "{\"id\":")
            register_participant!("P01", Dict("age" => 25); directory = dir)

            entries = @test_logs (:warn, r"notes.json") browse_sessions(data)
            @test [entry.path for entry in entries] == abspath.([early, late, template])
            @test all(entry -> entry.kind === :session, entries)

            first_entry = entries[1]
            @test first_entry.participants == ["P01"]
            @test first_entry.tags == ["practice"]
            @test first_entry.experiment_name == "Library"
            @test first_entry.method == "ConstantStimuli"
            @test first_entry.stimulus == "BaseStimulusParameters"
            @test first_entry.indep_var_names == [:Diff]
            @test first_entry.state === FINISHED
            @test first_entry.start_time == 1.0e9
            @test (first_entry.trials, first_entry.valid_trials) == (4, 3)
            @test length(first_entry.ids) == 1

            @test entries[3].state === READY
            @test entries[3].start_time === nothing   # a template sorts last

            # What is known about the people is joined by the id the file names
            @test get_participant(only(first_entry.participants);
                                  directory = dir)["age"] == 25
            @test get_participant(only(entries[2].participants);
                                  directory = dir) === nothing
        end
    end

    @testset "What browsing reports is what loading gives" begin
        mktempdir() do dir
            saved_session(dir, "P01"; tags = ["recording"], state = FINISHED,
                          started = 1.7e9, trials = 3, invalid = 1)
            saved_session(dir, "P02"; method = Staircase(),
                          stim_par = MarkerLayout(Ref = 10.0),
                          ex_par = ExperimentParameters("Threshold", :Diff, [1.0, 2.0], 1))

            for entry in browse_sessions(dir)
                session = load_session(entry.path)
                @test entry.ids == [string(session.id)]
                @test entry.participants == [session.participant_id]
                @test entry.tags == session.tags
                @test entry.experiment_name == session.ex_par.experiment_name
                @test entry.method == PsychophysicsManager.type_name(session.method_instance)
                @test entry.stimulus == PsychophysicsManager.type_name(session.stim_par)
                @test entry.indep_var_names == session.ex_par.indep_var_names
                @test entry.state === session.state
                @test entry.start_time === session.start_time
                @test entry.trials == length(session.history)
                @test entry.valid_trials == count(t -> t.is_valid, session.history)
            end
        end
    end

    @testset "A combined dataset is one entry holding its members" begin
        mktempdir() do dir
            first_member, _ = saved_session(dir, "P01"; tags = ["pooled"],
                                            state = FINISHED, started = 1.0e9, trials = 2)
            second_member, own_file = saved_session(dir, "P02"; tags = ["pooled", "late"],
                                                    state = FINISHED, started = 3.0e9,
                                                    trials = 3, invalid = 1)
            set_path = save_analysis_set(AnalysisSet([first_member, second_member]),
                                         joinpath(dir, "pooled.json"))

            entries = browse_sessions(dir)
            @test length(entries) == 3
            set_entry = only(filter(entry -> entry.kind === :set, entries))
            @test set_entry.path == abspath(set_path)
            @test set_entry.ids == string.([first_member.id, second_member.id])
            @test set_entry.participants == ["P01", "P02"]
            @test set_entry.tags == ["pooled", "late"]
            @test set_entry.state === nothing          # a dataset had no run of its own
            @test set_entry.start_time == 1.0e9        # the first member's
            @test (set_entry.trials, set_entry.valid_trials) == (5, 4)

            # A member is also its own file, and both are listed: they are two files
            member_entry = only(filter(entry -> entry.path == abspath(own_file), entries))
            @test member_entry.ids == [string(second_member.id)]
            @test set_entry.ids ⊇ member_entry.ids

            @test [entry.kind for entry in browse_sessions(dir; participant = "P01")] ==
                  [:session, :set]
            @test isempty(browse_sessions(dir; state = READY))   # no dataset has a state
        end
    end

    @testset "What browsing lists is combined in one call" begin
        mktempdir() do dir
            first_member, _ = saved_session(dir, "P01"; tags = ["pooled"],
                                            state = FINISHED, started = 1.0e9, trials = 2)
            second_member, _ = saved_session(dir, "P02"; tags = ["pooled"],
                                             state = FINISHED, started = 3.0e9, trials = 3)
            save_analysis_set(AnalysisSet([first_member, second_member]),
                              joinpath(dir, "pooled.json"))
            other, _ = saved_session(dir, "P03"; state = FINISHED, started = 2.0e9,
                                     trials = 1, method = Staircase())

            # Each session is listed twice — its own file and the dataset — and taken once
            entries = browse_sessions(dir; tags = "pooled")
            @test length(entries) == 3
            set = @test_nowarn AnalysisSet(entries; checks = Symbol[])
            @test [member.id for member in set.sessions] == [first_member.id, second_member.id]
            @test set.checks == Symbol[]
            @test length(AnalysisSet(filter(entry -> entry.kind === :set, entries)).sessions) == 2

            # A session that does not combine is refused as add_session! refuses it
            mixed = @test_logs (:warn, r"not added to the set") AnalysisSet(browse_sessions(dir))
            @test other.id ∉ [member.id for member in mixed.sessions]
            @test isempty(AnalysisSet(LibraryEntry[]).sessions)
        end
    end

    @testset "The catalogue is filtered by participant, tags, method and state" begin
        mktempdir() do dir
            saved_session(dir, "P01"; tags = ["practice", "left-eye"], state = FINISHED,
                          started = 1.0e9)
            saved_session(dir, "P01"; tags = ["recording"], state = PAUSED,
                          started = 2.0e9, method = Staircase())
            saved_session(dir, "P02"; tags = ["practice"], state = FINISHED,
                          started = 3.0e9)

            participants(; kwargs...) = [only(entry.participants)
                                         for entry in browse_sessions(dir; kwargs...)]
            @test length(browse_sessions(dir; participant = "P01")) == 2
            @test participants(; participant = "P02") == ["P02"]
            @test length(browse_sessions(dir; tags = "practice")) == 2
            @test length(browse_sessions(dir; tags = ["practice", "left-eye"])) == 1
            @test isempty(browse_sessions(dir; tags = ["practice", "recording"]))
            @test length(browse_sessions(dir; method = Staircase)) == 1
            @test length(browse_sessions(dir; method = "ConstantStimuli")) == 2
            @test length(browse_sessions(dir; state = FINISHED)) == 2
            @test length(browse_sessions(dir; participant = "P01", state = PAUSED)) == 1
            @test isempty(browse_sessions(dir; participant = "P01", tags = "practice",
                                          method = Staircase))
        end
    end

    @testset "Where the library looks" begin
        mktempdir() do dir
            @test browse_sessions(dir) == LibraryEntry[]
            @test_throws ArgumentError browse_sessions(joinpath(dir, "no-such-folder"))

            saved_session(dir, "P01")
            per_participant = joinpath(dir, "P02")
            mkpath(per_participant)
            saved_session(per_participant, "P02")
            # Dotfiles are not session files and are never read or warned about
            write(joinpath(dir, ".hidden.json"), "not valid json")

            entries = @test_logs browse_sessions(dir)
            @test length(entries) == 2
            @test length(browse_sessions(dir; participant = "P02")) == 1
        end
    end

    @testset "A discarded session is set aside, and can be restored" begin
        mktempdir() do dir
            _, kept = saved_session(dir, "P01"; state = FINISHED, trials = 2)
            _, thrown = saved_session(dir, "P02"; state = FINISHED, trials = 2)

            set_aside = discard_session(thrown)
            @test set_aside == joinpath(dir, DISCARDED_DIRECTORY, basename(thrown))
            @test isfile(set_aside) && !isfile(thrown)
            @test is_discarded(set_aside) && !is_discarded(kept)
            # Gone from the library; listed where it lies
            @test [only(entry.participants) for entry in browse_sessions(dir)] == ["P01"]
            @test [only(entry.participants) for entry in
                   browse_sessions(joinpath(dir, DISCARDED_DIRECTORY))] == ["P02"]

            # Never twice, never over another file, and never a file that is not ours
            @test_throws ArgumentError discard_session(set_aside)
            write(joinpath(dir, "notes.json"), "{\"unrelated\": 1}")
            @test_throws ArgumentError discard_session(joinpath(dir, "notes.json"))
            @test_throws ArgumentError restore_discarded(kept)

            @test restore_discarded(set_aside) == thrown
            @test isfile(thrown) && !isfile(set_aside)
            @test length(browse_sessions(dir)) == 2
            cp(thrown, set_aside)
            @test_throws ArgumentError restore_discarded(set_aside)
            @test_throws ArgumentError discard_session(thrown)
        end
    end

    @testset "A running session discarded is stopped, and its file follows it" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"data\"\n")
                session = SessionContext("P01",
                                         ExperimentParameters("Discard", :x, [1.0, 2.0], 2),
                                         BaseStimulusParameters(100.0),
                                         ConstantStimuli())
                # Not started, never saved: there is nothing to set aside
                @test discard_session(session) === nothing
                @test session.state == READY

                start_session!(session)
                run_next_trial!(session, EmulatorEngine())
                original = session.save_path
                set_aside = discard_session(session)
                @test session.state == ABORTED
                @test session.save_path == set_aside && !isfile(original)
                @test load_session(set_aside).state == ABORTED
                # A later checkpoint lands beside it, not back in the library
                save_session_checkpoint(session)
                @test !isfile(original)
                @test discard_session(session) == set_aside
            end
        end
    end

    @testset "A file this version cannot read is left out, not guessed at" begin
        mktempdir() do dir
            _, path = saved_session(dir, "P01")
            write(joinpath(dir, "truncated.json"), read(path, String)[1:40])
            write(joinpath(dir, "foreign.json"),
                  replace(read(path, String), "\"READY\"" => "\"MEASURING\""))

            entries = @test_logs((:warn, r"truncated.json"), (:warn, r"foreign.json"),
                                 match_mode = :any, browse_sessions(dir))
            @test [only(entry.participants) for entry in entries] == ["P01"]
        end
    end

    @testset "An entry says what it is in one line" begin
        mktempdir() do dir
            saved_session(dir, "P01"; tags = ["practice"], state = FINISHED,
                          started = 1.0e9, trials = 4, invalid = 1)
            entry = only(browse_sessions(dir))

            line = sprint(show, entry)
            @test occursin("P01", line)
            @test occursin("ConstantStimuli", line)
            @test occursin("FINISHED", line)
            @test occursin("3/4 trials", line)

            block = sprint(show, MIME"text/plain"(), entry)
            @test occursin(entry.path, block)
            @test occursin("Library", block)
            @test occursin("practice", block)
        end
    end

    @testset "Labels of saved sessions" begin
        function strip_labels(doc)
            cleaned = deepcopy(doc)
            delete!(cleaned, "tags")
            delete!(cleaned, "comments")
            delete!(cleaned["ex_par"], "experiment_name")
            return cleaned
        end

        @testset "Tags, comment and experiment name across files" begin
            mktempdir() do dir
                _, p1 = saved_session(dir, "P01"; tags = ["pilot", "old"], state = FINISHED,
                                      started = 1.0e9, trials = 2)
                _, p2 = saved_session(dir, "P02"; tags = ["old"], state = FINISHED,
                                      started = 2.0e9, trials = 3)
                _, p3 = saved_session(dir, "P03"; tags = String[], state = PAUSED,
                                      started = 3.0e9, trials = 1)

                before = [PsychophysicsManager.JSON3.read(read(p, String), Dict{String, Any})
                          for p in (p1, p2, p3)]

                rewritten = relabel_sessions!([p1, p2, p3];
                                              add_tags = ["verified", "left-eye"],
                                              remove_tags = ["old"],
                                              comment = "  cleaned after QC  ",
                                              experiment_name = "MainStudy")
                @test rewritten == [p1, p2, p3]

                for (index, path) in enumerate((p1, p2, p3))
                    session = load_session(path)
                    @test session.ex_par.experiment_name == "MainStudy"
                    @test length(session.comments) == 2
                    @test session.comments[1].trial === nothing
                    @test session.comments[1].text == "cleaned after QC"
                    @test session.comments[2].trial === nothing
                    @test startswith(session.comments[2].text, "Relabelled: ")

                    after = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
                    @test strip_labels(after) == strip_labels(before[index])
                end

                @test load_session(p1).tags == ["pilot", "verified", "left-eye"]
                @test load_session(p2).tags == ["verified", "left-eye"]
                @test load_session(p3).tags == ["verified", "left-eye"]
            end
        end

        @testset "Recording comment text" begin
            mktempdir() do dir
                _, p_tags = saved_session(dir, "P01"; tags = ["drop"],
                                          ex_par = ExperimentParameters("Keep", :Diff, [-1.0, 1.0], 1))
                _, p_name = saved_session(dir, "P02"; tags = String[],
                                          ex_par = ExperimentParameters("Old", :Diff, [-1.0, 1.0], 1))
                _, p_both = saved_session(dir, "P03"; tags = ["drop"],
                                          ex_par = ExperimentParameters("Old", :Diff, [-1.0, 1.0], 1))

                relabel_sessions!([p_tags]; add_tags = ["a", "b"], remove_tags = ["drop"])
                relabel_sessions!([p_name]; experiment_name = "New")
                relabel_sessions!([p_both]; add_tags = ["a", "b"], remove_tags = ["drop"],
                                  experiment_name = "New")

                @test only(load_session(p_tags).comments).text ==
                      "Relabelled: tags added: a, b; tags removed: drop"
                @test only(load_session(p_name).comments).text ==
                      "Relabelled: experiment name: \"Old\" → \"New\""
                @test only(load_session(p_both).comments).text ==
                      "Relabelled: tags added: a, b; tags removed: drop; experiment name: \"Old\" → \"New\""
            end
        end

        @testset "No-op changes do not record or rewrite" begin
            mktempdir() do dir
                _, p_same = saved_session(dir, "P01"; tags = ["kept"],
                                          ex_par = ExperimentParameters("Same", :Diff, [-1.0, 1.0], 1))
                _, p_changed = saved_session(dir, "P02"; tags = String[],
                                             ex_par = ExperimentParameters("Same", :Diff, [-1.0, 1.0], 1))
                bytes_before = read(p_same)

                rewritten = relabel_sessions!([p_same, p_changed];
                                              add_tags = ["kept"],
                                              remove_tags = ["absent"],
                                              experiment_name = "Same")
                @test rewritten == [p_changed]
                @test read(p_same) == bytes_before
                @test isempty(load_session(p_same).comments)

                # Adding only a comment when tags and name stay as they were adds no recording comment
                rewritten_note = relabel_sessions!([p_same];
                                                   add_tags = ["kept"],
                                                   remove_tags = ["absent"],
                                                   comment = "verified")
                @test rewritten_note == [p_same]
                comments = load_session(p_same).comments
                @test length(comments) == 1
                @test only(comments).text == "verified"
            end
        end

        @testset "All-or-none validation and refusals" begin
            mktempdir() do dir
                s1, p1 = saved_session(dir, "P01"; tags = ["orig"], state = FINISHED)
                s2, p2 = saved_session(dir, "P02"; tags = ["orig"], state = FINISHED)
                bad = joinpath(dir, "bad.json")
                write(bad, "not json")
                b1, b2, b_bad = read(p1), read(p2), read(bad)

                err = try
                    relabel_sessions!([p1, bad, p2]; add_tags = ["new"])
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin(bad, sprint(showerror, err))
                @test read(p1) == b1
                @test read(p2) == b2
                @test read(bad) == b_bad

                # Combined dataset file is refused, leaving session files untouched
                set_path = save_analysis_set(AnalysisSet([s1, s2]), joinpath(dir, "set.json"))
                b_set = read(set_path)
                err_set = try
                    relabel_sessions!([p1, set_path]; add_tags = ["new"])
                    nothing
                catch e
                    e
                end
                @test err_set isa ArgumentError
                @test occursin(set_path, sprint(showerror, err_set))
                @test read(p1) == b1
                @test read(set_path) == b_set

                # Discarded file is refused, leaving other files untouched
                discarded_path = discard_session(p2)
                b_disc = read(discarded_path)
                err_disc = try
                    relabel_sessions!([p1, discarded_path]; add_tags = ["new"])
                    nothing
                catch e
                    e
                end
                @test err_disc isa ArgumentError
                @test occursin(discarded_path, sprint(showerror, err_disc))
                @test read(p1) == b1
                @test read(discarded_path) == b_disc

                # Non-session JSON and missing file are refused
                other_json = joinpath(dir, "other.json")
                write(other_json, "{\"unrelated\": 1}")
                @test_throws ArgumentError relabel_sessions!([p1, other_json]; add_tags = ["new"])
                @test_throws ArgumentError relabel_sessions!([p1, joinpath(dir, "missing.json")];
                                                             add_tags = ["new"])
                @test read(p1) == b1
            end
        end

        Sys.iswindows() || @testset "A failed write puts the rewritten files back" begin
            mktempdir() do dir
                locked = mkpath(joinpath(dir, "locked"))
                _, p1 = saved_session(dir, "P01"; tags = ["orig"])
                _, p2 = saved_session(locked, "P02"; tags = ["orig"])
                b1, b2 = read(p1), read(p2)
                # No temporary file can be made beside the second session
                chmod(locked, 0o555)
                try
                    @test_throws Exception relabel_sessions!([p1, p2]; add_tags = ["new"])
                finally
                    chmod(locked, 0o755)
                end
                @test read(p1) == b1
                @test read(p2) == b2
            end
        end

        @testset "Argument checks and duplicate paths" begin
            mktempdir() do dir
                _, p1 = saved_session(dir, "P01"; tags = ["a"])

                @test_throws ArgumentError relabel_sessions!(String[]; add_tags = ["x"])
                @test_throws ArgumentError relabel_sessions!(LibraryEntry[]; add_tags = ["x"])
                @test_throws ArgumentError relabel_sessions!([p1])
                @test_throws ArgumentError relabel_sessions!([p1]; add_tags = ["  "])
                @test_throws ArgumentError relabel_sessions!([p1]; remove_tags = ["\t"])
                @test_throws ArgumentError relabel_sessions!([p1]; comment = "   ")
                @test_throws ArgumentError relabel_sessions!([p1]; experiment_name = "  ")
                @test_throws ArgumentError relabel_sessions!([p1]; add_tags = ["x"],
                                                             remove_tags = ["x"])

                # A label is kept without the blanks around it
                _, p2 = saved_session(dir, "P02"; tags = String[])
                relabel_sessions!([p2]; add_tags = [" spaced "], experiment_name = " Named ")
                @test load_session(p2).tags == ["spaced"]
                @test load_session(p2).ex_par.experiment_name == "Named"

                # Paths given twice are handled once
                rewritten = relabel_sessions!([p1, p1]; add_tags = ["b"], comment = "once")
                @test rewritten == [p1]
                session = load_session(p1)
                @test session.tags == ["a", "b"]
                @test length(session.comments) == 2
            end
        end

        @testset "LibraryEntry method through browse_sessions" begin
            mktempdir() do dir
                saved_session(dir, "P01"; tags = ["batch"], state = FINISHED, started = 1.0e9)
                saved_session(dir, "P02"; tags = ["batch"], state = FINISHED, started = 2.0e9)
                saved_session(dir, "P03"; tags = ["other"], state = FINISHED, started = 3.0e9)

                entries = browse_sessions(dir; tags = "batch")
                rewritten = relabel_sessions!(entries; add_tags = ["reviewed"],
                                              experiment_name = "Renamed")
                @test rewritten == [entry.path for entry in entries]

                refreshed = browse_sessions(dir; tags = "reviewed")
                @test length(refreshed) == 2
                @test all(entry -> entry.experiment_name == "Renamed", refreshed)
                @test [entry.experiment_name for entry in browse_sessions(dir; tags = "other")] ==
                      ["Library"]
            end
        end
    end

    @testset "Stored combining facts agree with loaded session facts" begin
        mktempdir() do dir
            task = ObserverTask("Choose longer", ("left", "right"), "right")
            _, p_const = saved_session(dir, "P01";
                stim_par = MarkerLayout(Ref = 20.0, Marker = :circle, MarkerSize = (3, 25)),
                method = ConstantStimuli())
            _, p_adj = saved_session(dir, "P02";
                stim_par = MarkerLayout(Ref = 20.0, Diff = 3.5),
                method = Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0),
                ex_par = ExperimentParameters("Adj", :DistrN, [0, 2, 4], 1))
            _, p_inter = saved_session(dir, "P03";
                method = Interleaved([Staircase(2),
                                      Adjustment(dep_var = :duration_ms, dep_range = 50.0:50.0:150.0)]),
                ex_par = ExperimentParameters("Inter", [:Diff, :track], Any[[-2.0, 2.0], 1:2], 1),
                stim_par = MarkerLayout(Ref = 15.0))
            _, p_rich = saved_session(dir, "P04";
                tags = ["ai-observer", "model:demo"],
                task = task,
                fit_gamma = 0.5,
                feedback = true,
                timeout_s = 1.5,
                unit_conversions = [:Diff => UnitConversion("Diff (arcmin)"; scale = 0.5)],
                observer_metadata = Dict{String, Any}(
                    "backend" => "SimulatedObserver",
                    "deliberation" => "medium",
                    "requests" => 12,
                    "failed_requests" => 1))
            _, p_worker = saved_session(dir, "P05";
                stim_par = WorkerStimulus("oppel_kundt"; Ref = 100, DistrN = 3, StimConfig = "r d t"),
                ex_par = ExperimentParameters("Remote", :Ref, [80.0, 100.0], 1))

            for path in (p_const, p_adj, p_inter, p_rich, p_worker)
                doc = PsychophysicsManager.read_json_document(path)
                expected = PsychophysicsManager.session_facts(load_session(path), COMBINING_CHECKS)
                actual = PsychophysicsManager.stored_combining_facts(doc, COMBINING_CHECKS)
                @test isequal(actual, expected)
            end

            # A file without `adjusted_fields` is read as if it held an empty list
            doc_const = PsychophysicsManager.read_json_document(p_const)
            delete!(doc_const, "adjusted_fields")
            @test isequal(
                PsychophysicsManager.stored_combining_facts(doc_const, COMBINING_CHECKS),
                PsychophysicsManager.session_facts(load_session(p_const), COMBINING_CHECKS))
        end
    end

    @testset "Browse filters" begin
        mktempdir() do dir
            t1 = datetime2unix(DateTime(2026, 5, 10, 9, 0, 0))
            t2 = datetime2unix(DateTime(2026, 5, 10, 23, 59, 59))
            t3 = datetime2unix(DateTime(2026, 5, 11, 0, 0, 0))

            s1, _ = saved_session(dir, "P01";
                ex_par = ExperimentParameters("Oppel", :Diff, [-4.0, 0.0, 4.0], 2),
                stim_par = MarkerLayout(Ref = 5.0, Color = :white),
                tags = ["pilot", "eye:left"],
                state = FINISHED, started = t1, trials = 2,
                comments = ["Clean run"])
            s2, _ = saved_session(dir, "P02";
                ex_par = ExperimentParameters("Oppel", :Diff, [-2.0, 2.0], 2),
                stim_par = MarkerLayout(Ref = 10.0, Color = :white),
                tags = ["main"],
                state = PAUSED, started = t2, trials = 1)
            s3, _ = saved_session(dir, "P03";
                ex_par = ExperimentParameters("Contrast", :contrast, [0.1, 0.2], 1),
                stim_par = Gabor(sigma_px = 12.0),
                method = Staircase(),
                tags = ["main", "Reviewed"],
                state = FINISHED, started = t3, trials = 3)
            s4, _ = saved_session(dir, "P04";
                ex_par = ExperimentParameters("Oppel", :Diff, [-4.0, 4.0], 1),
                stim_par = MarkerLayout(Ref = 5.0, Color = :yellow),
                state = READY, started = nothing)
            set_path = save_analysis_set(AnalysisSet([s1, s4]; checks = Symbol[]),
                                         joinpath(dir, "pooled.json"))

            ids_of(entries) = [e.kind === :set ? :set : only(e.participants) for e in entries]

            # participant: one id and collection of ids
            @test ids_of(browse_sessions(dir; participant = "P02")) == ["P02"]
            @test Set(ids_of(browse_sessions(dir; participant = ["P01", "P03"]))) ==
                  Set(["P01", "P03", :set])

            # experiment and stimulus
            @test Set(ids_of(browse_sessions(dir; experiment = "Contrast"))) == Set(["P03"])
            @test Set(ids_of(browse_sessions(dir; stimulus = "Gabor"))) == Set(["P03"])
            @test Set(ids_of(browse_sessions(dir; stimulus = "MarkerLayout"))) ==
                  Set(["P01", "P02", "P04", :set])

            # from / to with Date and DateTime; to::Date covers whole day; never-started excluded
            @test ids_of(browse_sessions(dir; from = Date(2026, 5, 10),
                                         to = Date(2026, 5, 10))) == ["P01", :set, "P02"]
            @test ids_of(browse_sessions(dir; from = DateTime(2026, 5, 10, 12, 0, 0),
                                         to = DateTime(2026, 5, 11, 0, 0, 0))) == ["P02", "P03"]
            @test isempty(browse_sessions(dir; from = Date(2026, 5, 12)))

            # parameter: fixed parameter (Int matches Float64), independent level, multiple pairs,
            # and independent variable does not match its placeholder field in stim_par
            @test ids_of(browse_sessions(dir; parameter = :Ref => 5)) == ["P01", :set, "P04"]
            @test ids_of(browse_sessions(dir; parameter = "Diff" => -4)) == ["P01", :set, "P04"]
            @test isempty(browse_sessions(dir; parameter = :Diff => 0.0, participant = "P04"))
            @test ids_of(browse_sessions(dir; parameter = [:Ref => 5, "Color" => :white])) == ["P01"]

            # text: comment, tag, experiment, participant, basename (case-insensitive)
            @test ids_of(browse_sessions(dir; text = "clean RUN")) == ["P01", :set]
            @test ids_of(browse_sessions(dir; text = "reviewed")) == ["P03"]
            @test ids_of(browse_sessions(dir; text = "contrast")) == ["P03"]
            @test ids_of(browse_sessions(dir; text = "pooled")) == [:set]

            # Combined filters (AND)
            @test ids_of(browse_sessions(dir; participant = ["P01", "P03"], text = "reviewed")) == ["P03"]
            @test ids_of(browse_sessions(dir; experiment = "Oppel", parameter = :Ref => 5,
                                         state = FINISHED)) == ["P01"]
        end
    end

    @testset "browse_series matches AnalysisSet and groups by participant, experiment and tags" begin
        mktempdir() do dir
            base_task = ObserverTask("Word A", ("left", "right"), "right")
            other_task = ObserverTask("Word B", ("left", "right"), "right")
            base_obs = Dict{String, Any}("backend" => "Sim", "mode" => "fast", "requests" => 1)

            _, p_base = saved_session(dir, "P01"; started = 10.0, task = base_task,
                                      observer_metadata = base_obs,
                                      stim_par = MarkerLayout(Ref = 10.0))
            _, p_inst = saved_session(dir, "P01"; started = 20.0, task = other_task,
                                      observer_metadata = base_obs,
                                      stim_par = MarkerLayout(Ref = 10.0))
            _, p_obs = saved_session(dir, "P01"; started = 30.0, task = base_task,
                                     observer_metadata = Dict{String, Any}(
                                         "backend" => "Sim", "mode" => "slow", "requests" => 5),
                                     stim_par = MarkerLayout(Ref = 10.0))
            _, p_fb = saved_session(dir, "P01"; started = 40.0, task = base_task,
                                    observer_metadata = base_obs, feedback = true,
                                    stim_par = MarkerLayout(Ref = 10.0))
            _, p_to = saved_session(dir, "P01"; started = 50.0, task = base_task,
                                    observer_metadata = base_obs, timeout_s = 2.0,
                                    stim_par = MarkerLayout(Ref = 10.0))
            _, p_stim = saved_session(dir, "P01"; started = 60.0, task = base_task,
                                      observer_metadata = base_obs,
                                      stim_par = MarkerLayout(Ref = 20.0))

            paths = [p_base, p_inst, p_obs, p_fb, p_to, p_stim]
            all_series = browse_series(dir; checks = collect(COMBINING_CHECKS))
            @test length(all_series) == 6

            for (check, idx) in ((:instructions, 2), (:observer, 3), (:feedback, 4),
                                 (:timeout, 5), (:stimulus, 6))
                checks = filter(!=(check), collect(COMBINING_CHECKS))
                grouped = browse_series(dir; checks)
                @test length(grouped) == 5
                series_by_path = Dict(e.path => s for s in grouped for e in s.entries)
                for i in 1:length(paths), j in (i + 1):length(paths)
                    same_series = series_by_path[abspath(paths[i])] ===
                                  series_by_path[abspath(paths[j])]
                    admitted = @test_logs min_level = Logging.Error begin
                        length(AnalysisSet(load_session.([paths[i], paths[j]]); checks).sessions) == 2
                    end
                    @test same_series == ((i == 1 && j == idx) ? true : false)
                    @test same_series == admitted
                end
            end
        end

        @testset "Units, participants, experiments, key:value tags, ordering and show" begin
            mktempdir() do dir
                s1, _ = saved_session(dir, "P01"; started = 100.0, trials = 4, invalid = 1,
                    tags = ["plain", "time:10:30", ":ignored", "ignored:"],
                    unit_conversions = [:Diff => UnitConversion("Diff (arcmin)"; scale = 1.0)])
                s2, _ = saved_session(dir, "P01"; started = 200.0, trials = 2,
                    tags = ["other-plain", "time:10:30"],
                    unit_conversions = [:Diff => UnitConversion("Diff (arcmin)"; scale = 0.5)])
                # Different key:value tag, participant, experiment, and never-started
                saved_session(dir, "P01"; started = 300.0, tags = ["time:11:00"],
                    unit_conversions = [:Diff => UnitConversion("Diff (arcmin)"; scale = 1.0)])
                saved_session(dir, "P02"; started = 50.0, tags = ["time:10:30"],
                    unit_conversions = [:Diff => UnitConversion("Diff (arcmin)"; scale = 1.0)])
                saved_session(dir, "P01"; started = nothing,
                    ex_par = ExperimentParameters("SecondExp", :Diff, [-5.0, 5.0], 1),
                    tags = ["time:10:30"],
                    unit_conversions = [:Diff => UnitConversion("Diff (arcmin)"; scale = 1.0)])
                # A saved dataset must be excluded by browse_series
                save_analysis_set(AnalysisSet([s1, s2]; checks = Symbol[]),
                                  joinpath(dir, "set.json"))

                series = browse_series(dir)
                @test length(series) == 4
                # Ordered by first session start_time, never-started last
                @test [s.participant for s in series] == ["P02", "P01", "P01", "P01"]
                @test [s.experiment_name for s in series] ==
                      ["Library", "Library", "Library", "SecondExp"]

                rep_series = series[2]
                @test length(rep_series.entries) == 2
                @test [e.start_time for e in rep_series.entries] == [100.0, 200.0]
                @test rep_series.tag_values == Dict("time" => "10:30")

                one_line = sprint(show, rep_series)
                @test occursin("P01", one_line)
                @test occursin("Library", one_line)
                @test occursin("2 sessions", one_line)
                @test occursin("5/6 trials", one_line)

                block = sprint(show, MIME"text/plain"(), rep_series)
                @test occursin("time:10:30", block)
                @test occursin(basename(rep_series.entries[1].path), block)
                @test occursin(basename(rep_series.entries[2].path), block)

                # A session renamed into another experiment joins that experiment's series
                renamed = rep_series.entries[2].path
                relabel_sessions!([renamed]; experiment_name = "SecondExp")
                moved = browse_series(dir)
                @test length(moved) == 4
                @test [e.path for e in moved[2].entries] == [rep_series.entries[1].path]
                second = only(filter(s -> s.experiment_name == "SecondExp", moved))
                @test first(second.entries).path == renamed   # it now starts the series
                @test length(second.entries) == 2
            end
        end
    end

        @testset "session_variables" begin
            mktempdir() do dir
                saved_session(dir, "P01"; started = 1.0, stim_par = MarkerLayout(Ref = 10.0))
                saved_session(dir, "P01"; started = 2.0, stim_par = MarkerLayout(Ref = 20.0))
                saved_session(dir, "P01"; started = 3.0, stim_par = MarkerLayout(Ref = 30.0))

                s_param = browse_series(dir)
                @test length(s_param) == 3
                @test session_variables(s_param) ==
                      (parameters = [:Ref], tags = String[], other = Symbol[])
                @test session_variables(s_param[1:1]) ==
                      (parameters = Symbol[], tags = String[], other = Symbol[])
                @test session_variables(SessionSeries[]) ==
                      (parameters = Symbol[], tags = String[], other = Symbol[])

                # When no series has a :stimulus fact, `parameters` is empty
                no_stim = browse_series(dir; checks = Symbol[])
                @test session_variables(no_stim) ==
                      (parameters = Symbol[], tags = String[], other = Symbol[])
            end

            mktempdir() do dir
                saved_session(dir, "P01"; started = 1.0, tags = ["eye:left"])
                saved_session(dir, "P01"; started = 2.0, tags = ["eye:right"])
                @test session_variables(browse_series(dir)) ==
                      (parameters = Symbol[], tags = ["eye"], other = Symbol[])
            end

            mktempdir() do dir
                saved_session(dir, "P01"; started = 1.0, feedback = false)
                saved_session(dir, "P01"; started = 2.0, feedback = true)
                @test session_variables(browse_series(dir)) ==
                      (parameters = Symbol[], tags = String[], other = [:feedback])
            end
        end

        @testset "Library index cache and round trip" begin
            mktempdir() do dir
                s1, p1 = saved_session(dir, "P01"; tags = ["pilot"], state = FINISHED,
                                       started = 1.0e9, trials = 2,
                                       stim_par = MarkerLayout(Ref = 12.0))
                s2, p2 = saved_session(dir, "P02"; state = FINISHED, started = 2.0e9, trials = 1,
                                       stim_par = MarkerLayout(Ref = 12.0))
                save_analysis_set(AnalysisSet([s1, s2]), joinpath(dir, "pooled.json"))
                write(joinpath(dir, "notes.json"), "{\"unrelated\": 1}")
                write(joinpath(dir, "broken.json"), "{not-json")
                write(joinpath(dir, ".hidden.json"), "{broken")

                entries = @test_logs (:warn, r"notes\.json.*broken\.json|broken\.json.*notes\.json") browse_sessions(dir)
                index_path = joinpath(dir, PsychophysicsManager.LIBRARY_INDEX_FILE)
                @test isfile(index_path)

                # Unchanged directory does not rewrite the index; unreadable file is omitted from index
                idx_mtime = stat(index_path).mtime
                @test_logs (:warn, r"broken\.json") browse_sessions(dir)
                @test stat(index_path).mtime == idx_mtime

                # Entry round trip for both session and dataset entries
                session_entry = only(filter(e -> e.path == abspath(p1), entries))
                set_entry = only(filter(e -> e.kind === :set, entries))
                for entry in (session_entry, set_entry)
                    rebuilt = PsychophysicsManager.entry_from_index(
                        PsychophysicsManager.entry_to_index(entry), dir)
                    @test isequal(rebuilt, entry)
                end

                # Modifying the index directly is reflected on the next browse (cache hit)
                idx_doc = PsychophysicsManager.JSON3.read(read(index_path, String), Dict{String, Any})
                @test idx_doc["files"]["notes.json"]["entry"] === nothing
                @test !haskey(idx_doc["files"], "broken.json")
                @test !haskey(idx_doc["files"], ".hidden.json")
                rel_p1 = basename(p1)
                idx_doc["files"][rel_p1]["entry"]["experiment_name"] = "CachedName"
                write(index_path, PsychophysicsManager.JSON3.write(idx_doc))

                cached_entries = @test_logs (:warn, r"notes\.json") browse_sessions(dir)
                @test only(filter(e -> e.path == abspath(p1), cached_entries)).experiment_name ==
                      "CachedName"

                # Changing the file invalidates its cache slot and reads its real labels
                relabel_sessions!([p1]; add_tags = ["relabelled"], experiment_name = "FreshName")
                reloaded_entries = @test_logs (:warn, r"notes\.json") browse_sessions(dir)
                refreshed_p1 = only(filter(e -> e.path == abspath(p1), reloaded_entries))
                @test refreshed_p1.experiment_name == "FreshName"
                @test "relabelled" in refreshed_p1.tags

                # Deleting a file drops it from the index; deleting or corrupting the index rebuilds identically
                rm(joinpath(dir, "broken.json"))
                rm(p2)
                after_drop = @test_logs (:warn, r"notes\.json") browse_sessions(dir)
                idx_after_drop = PsychophysicsManager.JSON3.read(read(index_path, String), Dict{String, Any})
                @test !haskey(idx_after_drop["files"], basename(p2))

                rm(index_path)
                after_delete = @test_logs (:warn, r"notes\.json") browse_sessions(dir)
                @test isfile(index_path)
                @test after_delete == after_drop

                write(index_path, "not valid json")
                after_garbage = @test_logs (:warn, r"notes\.json") browse_sessions(dir)
                @test after_garbage == after_drop

                write(index_path, "{\"version\": 99, \"files\": {}}")
                after_wrong_ver = @test_logs (:warn, r"notes\.json") browse_sessions(dir)
                @test after_wrong_ver == after_drop

                # Read-only directory still lists without any extra warning
                Sys.iswindows() || begin
                    rm(index_path)
                    chmod(dir, 0o555)
                    try
                        ro_entries = @test_logs (:warn, r"notes\.json") browse_sessions(dir)
                        @test ro_entries == after_drop
                        @test !isfile(index_path)
                    finally
                        chmod(dir, 0o755)
                    end
                end
            end
        end

        @testset "Folders in filename_template with settings.toml and browse_sessions" begin
            mktempdir() do dir
                write(joinpath(dir, "settings.toml"),
                      "[storage]\nfilename_template = \"{ex_par.experiment_name}/{participant_id}/{participant_id}_{short_id}\"\n")
                s1 = SessionContext("P/01", ExperimentParameters("Nested", :Diff, [-1.0, 1.0], 1),
                                    BaseStimulusParameters(100.0), ConstantStimuli())
                p1 = save_session_checkpoint(s1, dir)
                @test p1 == abspath(joinpath(dir, "Nested", "P_01", "P_01_$(string(s1.id)[1:8]).json"))
                @test isfile(p1)

                entries = browse_sessions(dir)
                @test [e.path for e in entries] == [p1]

                # Discarding and restoring inside nested folders keeps working with the index
                aside = discard_session(p1)
                @test isempty(browse_sessions(dir))
                @test restore_discarded(aside) == p1
                @test [e.path for e in browse_sessions(dir)] == [p1]

                write(joinpath(dir, "settings.toml"),
                      "[storage]\nfilename_template = \"{ex_par.experiment_name}/../{participant_id}\"\n")
                s_bad = SessionContext("P02", ExperimentParameters("Nested", :Diff, [-1.0, 1.0], 1),
                                       BaseStimulusParameters(100.0), ConstantStimuli())
                @test_throws ArgumentError save_session_checkpoint(s_bad, dir)
            end
        end

        @testset "Planned trials in session files, library and index" begin
            mktempdir() do dir
                cd(dir) do
                    write("settings.toml", "[storage]\ndata_dir = \"data\"\n")
                    data = joinpath(dir, "data")
                    mkpath(data)

                    ex = ExperimentParameters("PlannedLib", :level, [1.0, 2.0, 3.0], 2)
                    s1 = SessionContext("P01", ex, BaseStimulusParameters(100.0), ConstantStimuli())
                    start_session!(s1)
                    foreach(_ -> run_next_trial!(s1, EmulatorEngine()), 1:3)
                    pause!(s1)
                    p1 = s1.save_path

                    s2 = SessionContext("P02", ex, BaseStimulusParameters(100.0), ConstantStimuli())
                    run_experiment!(s2, EmulatorEngine(); report = :silent)
                    p2 = s2.save_path

                    open_s = SessionContext("P03", ex, BaseStimulusParameters(100.0), Staircase())
                    p_open = save_session_checkpoint(open_s, data)

                    started_stair = SessionContext("P04", ex, BaseStimulusParameters(100.0),
                                                   Staircase(; trial_limit = 6))
                    start_session!(started_stair)

                    @test PsychophysicsManager.read_json_document(p1)["planned_trials"] == 6
                    @test PsychophysicsManager.read_json_document(p2)["planned_trials"] == 6
                    @test PsychophysicsManager.read_json_document(p_open)["planned_trials"] === nothing

                    # A file written without the key gives `nothing`
                    legacy_doc = PsychophysicsManager.read_json_document(p1)
                    delete!(legacy_doc, "planned_trials")
                    p_legacy = joinpath(data, "legacy.json")
                    write(p_legacy, PsychophysicsManager.JSON3.write(legacy_doc))

                    # Combined datasets sum members' planned trials when all are known
                    set_path = save_analysis_set(AnalysisSet([s1, s2]), joinpath(data, "both.json"))
                    mixed_path = save_analysis_set(AnalysisSet([started_stair, open_s]),
                                                   joinpath(data, "mixed.json"))

                    entries = browse_sessions(data)
                    by_path = Dict(e.path => e for e in entries)
                    @test by_path[abspath(p1)].planned_trials == 6
                    @test by_path[abspath(p2)].planned_trials == 6
                    @test by_path[abspath(p_open)].planned_trials === nothing
                    @test by_path[abspath(p_legacy)].planned_trials === nothing
                    @test by_path[abspath(set_path)].planned_trials == 12
                    @test by_path[abspath(mixed_path)].planned_trials === nothing

                    # Reading back from the index preserves planned_trials
                    idx_doc = PsychophysicsManager.read_json_document(
                        joinpath(data, PsychophysicsManager.LIBRARY_INDEX_FILE))
                    @test idx_doc["version"] == 2
                    cached = Dict(e.path => e for e in browse_sessions(data))
                    @test cached[abspath(p1)].planned_trials == 6
                    @test cached[abspath(p_open)].planned_trials === nothing
                    @test cached[abspath(p_legacy)].planned_trials === nothing
                    @test cached[abspath(set_path)].planned_trials == 12
                    @test cached[abspath(mixed_path)].planned_trials === nothing
                end
            end
        end
end
