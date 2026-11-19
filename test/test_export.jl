@testset "Session export" begin

    function export_test_session(; participant_id="P001")
        ex_par = ExperimentParameters(
            "Export study", [:contrast, :frequency],
            Any[[0.1, 0.2], [100.0, 200.0]], 2,
        )
        session = SessionContext(
            participant_id, ex_par, BaseStimulusParameters(100.0),
            ConstantStimuli(); tags=["training", "first pass"],
        )
        session.start_time = 0.0
        session.engine_name = "EmulatorEngine"
        # A scored trial, an unscored one, and an invalidated scored one the operator chose
        push!(session.history, Trial(1, 1.0, 1.25, [0.1, 100.0], 1, true, :engine, true))
        push!(session.history, Trial(2, 2.0, 2.5, [0.2, 200.0], -0.5, true, :estimated))
        push!(session.history, Trial(3, 3.0, 4.0, [0.1, 100.0], 0, false, :engine, false,
                                     :operator))
        return session
    end

    @testset "Trial and summary content in both formats" begin
        mktempdir() do dir
            session = export_test_session()
            for (format, extension, separator) in ((:csv, "csv", ','), (:tsv, "tsv", '\t'))
                trial_path = joinpath(dir, "trials.$extension")
                @test export_session(session, trial_path; format=format) == trial_path
                trial_lines = readlines(trial_path)
                @test startswith(trial_lines[1], "# participant_id: P001")
                @test any(==("# method: ConstantStimuli"), trial_lines)
                @test any(==("# engine: EmulatorEngine"), trial_lines)
                @test any(==("# start_time: 1970-01-01T00:00:00.000Z"), trial_lines)
                header_index = findfirst(==("trial_index$(separator)contrast$(separator)frequency$(separator)response$(separator)correct$(separator)reaction_time_s$(separator)is_valid$(separator)timestamp_onset$(separator)timestamp_response$(separator)onset_source$(separator)origin"), trial_lines)
                @test header_index !== nothing
                @test length(trial_lines) == header_index + 3
                @test trial_lines[header_index + 1] == "1$(separator)0.1$(separator)100.0$(separator)1$(separator)true$(separator)0.25$(separator)true$(separator)1.0$(separator)1.25$(separator)engine$(separator)method"
                # An unscored trial leaves the cell empty, never "nothing"
                @test trial_lines[header_index + 2] == "2$(separator)0.2$(separator)200.0$(separator)-0.5$(separator)$(separator)0.5$(separator)true$(separator)2.0$(separator)2.5$(separator)estimated$(separator)method"
                @test endswith(trial_lines[header_index + 3], "$(separator)false$(separator)3.0$(separator)4.0$(separator)engine$(separator)operator")

                summary_path = joinpath(dir, "summary.$extension")
                @test export_session(session, summary_path; format=format, content=:summary) == summary_path
                summary_lines = readlines(summary_path)
                summary_header = findfirst(==(join(["contrast", "frequency", "n", "mean_response", "sd", "sem",
                                                     "ci_lo", "ci_hi", "proportion_correct",
                                                     "correct_ci_lo", "correct_ci_hi"], separator)),
                                           summary_lines)
                @test summary_header !== nothing
                @test length(summary_lines) == summary_header + 2
                c_lo, c_hi = wilson_interval(1, 1)
                # One trial: no t-interval, and Wilson interval on the scored trial
                @test summary_lines[summary_header + 1] == join(["0.1", "100.0", "1", "1.0", "0.0", "0.0",
                                                                 "", "", "1.0", string(c_lo), string(c_hi)],
                                                                separator)
                # No scored trial of the condition: empty cells, not zeros
                @test summary_lines[summary_header + 2] == join(["0.2", "200.0", "1", "-0.5", "0.0", "0.0",
                                                                 "", "", "", "", ""], separator)
            end
        end
    end

    @testset "Filtering, quoting, and checkpoint convenience" begin
        mktempdir() do dir
            session = export_test_session(participant_id="P, \"quoted\"")
            csv_path = joinpath(dir, "filtered.csv")
            export_session(session, csv_path; valid_only=true)
            lines = readlines(csv_path)
            header_index = findfirst(line -> startswith(line, "trial_index,"), lines)
            @test lines[1] == "# participant_id: \"P, \"\"quoted\"\"\""
            @test length(lines) == header_index + 2
            @test !any(occursin(",false,"), lines[header_index + 1:end])

            checkpoint = save_session_checkpoint(session, dir; filename="source.json")
            copied_path = joinpath(dir, "from-checkpoint.tsv")
            @test export_session(checkpoint, copied_path; format=:tsv, content=:summary) == copied_path
            copied_lines = readlines(copied_path)
            @test any(==("# participant_id: \"P, \"\"quoted\"\"\""), copied_lines)
            @test any(line -> startswith(line, "contrast\tfrequency\tn\t"), copied_lines)
        end
    end

    @testset "A closed response window exports as itself" begin
        session = export_test_session()
        push!(session.history, Trial(4, 5.0, 6.0, [0.2, 200.0], :timeout, true))
        mktempdir() do dir
            for (format, extension, separator) in ((:csv, "csv", ','), (:tsv, "tsv", '\t'))
                path = joinpath(dir, "window.$extension")
                export_session(session, path; format = format)
                line = last(readlines(path))
                # The cell reads "timeout": neither a number a reader could
                # average nor the empty cell that means "not scored"
                @test line == "4$(separator)0.2$(separator)200.0$(separator)timeout$(separator)$(separator)1.0$(separator)true$(separator)5.0$(separator)6.0$(separator)estimated$(separator)method"
            end
        end
    end

    @testset "Converted values are exported beside the recorded ones" begin
        ex_par = ExperimentParameters("Units", :DistrN, [0.0, 1.0], 1)
        session = SessionContext("P001", ex_par, BaseStimulusParameters(100.0),
                                 Adjustment(dep_var = :duration_ms,
                                                  dep_range = -10.0:10.0))
        push!(session.history, Trial(1, 1.0, 1.5, [0.0], 4.0, true, :estimated, nothing,
                                     :method, -2.0))
        push!(session.history, Trial(2, 2.0, 2.5, [1.0], 6.0, true, :estimated, nothing,
                                     :method, 8.0))
        push!(session.history, Trial(3, 3.0, 3.5, [1.0], :timeout, true))
        set_unit_conversion!(session, :DistrN, UnitConversion("Distractors"; offset = 1))
        set_unit_conversion!(session, :duration_ms, UnitConversion("Diff (arcmin)";
                                                                   scale = 0.5))
        add_comment!(session, "Squinted"; trial = 2)
        add_comment!(session, "Lights on;\n then off")
        session.rig = Dict{String, Any}("pixel_arcmin" => 0.86, "name" => "Booth 2")
        mktempdir() do dir
            path = export_session(session, joinpath(dir, "trials.csv"))
            lines = readlines(path)
            # The rig the session ran on, its name first
            rig_lines = filter(startswith("# rig."), lines)
            @test rig_lines == ["# rig.name: Booth 2", "# rig.pixel_arcmin: 0.86"]
            @test "# unit_conversion.DistrN: Distractors = DistrN + 1.0" in lines
            @test "# unit_conversion.duration_ms: Diff (arcmin) = 0.5 * duration_ms" in lines
            @test "# response_label: Diff (arcmin)" in lines
            # The operator's comments, one line each, line breaks and all
            @test count(line -> startswith(line, "# comment: "), lines) == 2
            @test any(line -> occursin(r"^# comment: \d{4}-\d\d-\d\dT[\d:.]+Z trial 2: Squinted$", line), lines)
            @test any(line -> occursin(r"^# comment: \S+: Lights on; then off$", line), lines)
            header_index = findfirst(==("trial_index,DistrN,Distractors,response,Diff (arcmin),start_value,start Diff (arcmin),correct,reaction_time_s,is_valid,timestamp_onset,timestamp_response,onset_source,origin"), lines)
            @test header_index !== nothing
            # Where each adjustment began, converted as the response is
            @test startswith(lines[header_index + 1], "1,0.0,1.0,4.0,2.0,-2.0,-1.0,,")
            @test startswith(lines[header_index + 2], "2,1.0,2.0,6.0,3.0,8.0,4.0,,")
            # A response that is not a value is not converted into one
            @test startswith(lines[header_index + 3], "3,1.0,2.0,timeout,timeout,,,,")

            # The summary is an analysis, in the converted units only
            summary = readlines(export_session(session, joinpath(dir, "summary.csv");
                                               content = :summary))
            summary_header = findfirst(==("Distractors,n,mean_response,sd,sem,ci_lo,ci_hi," *
                                          "proportion_correct,correct_ci_lo,correct_ci_hi"), summary)
            # One trial per condition: no spread, and no interval to give
            @test summary[summary_header + 1:end] == ["1.0,1,2.0,0.0,0.0,,,,,", "2.0,1,3.0,0.0,0.0,,,,,"]
        end
    end

    @testset "A summary pools over a counterbalancing variable" begin
        session = export_test_session()
        push!(session.history, Trial(4, 5.0, 6.0, [0.1, 200.0], 3, true, :engine, false))
        mktempdir() do dir
            lines = readlines(export_session(session, joinpath(dir, "pooled.csv");
                                             content = :summary, collapse = :frequency))
            @test "# collapsed_over: frequency" in lines
            header = findfirst(==("contrast,n,mean_response,sd,sem,ci_lo,ci_hi," *
                                  "proportion_correct,correct_ci_lo,correct_ci_hi"), lines)
            @test header !== nothing
            @test length(lines) == header + 2
            # Contrast 0.1 pools its two frequencies: the responses 1 and 3
            @test startswith(lines[header + 1], "0.1,2,2.0,")
            c_lo, c_hi = wilson_interval(1, 2)
            @test endswith(lines[header + 1], ",0.5,$c_lo,$c_hi")
            @test startswith(lines[header + 2], "0.2,1,-0.5,")

            # Nothing pooled, no metadata line
            @test !any(startswith("# collapsed_over"),
                       readlines(export_session(session, joinpath(dir, "full.csv");
                                                content = :summary)))

            # The set pools the same way, and so does each file it splits into
            set = AnalysisSet([session, export_test_session(participant_id = "P002")];
                              checks = collect(COMBINING_CHECKS))
            set_lines = readlines(export_session(set, joinpath(dir, "set.csv");
                                                 content = :summary, collapse = [:frequency]))
            @test "# collapsed_over: frequency" in set_lines
            @test any(startswith("0.1,3,"), set_lines)
            for file in export_session(set, joinpath(dir, "split.csv"); content = :summary,
                                       collapse = :frequency, split = true)
                @test "# collapsed_over: frequency" in readlines(file)
            end

            # Refused before any file is written: trial rows, an unknown variable,
            # and pooling over every variable
            for (content, collapse) in ((:trials, :frequency), (:summary, :size),
                                        (:summary, [:contrast, :frequency]))
                path = joinpath(dir, "refused.csv")
                @test_throws ArgumentError export_session(session, path; content, collapse)
                @test_throws ArgumentError export_session(set, path; content, collapse)
                @test !isfile(path)
            end
        end
    end

    @testset "Validation and empty history" begin
        session = export_test_session()
        mktempdir() do dir
            path = joinpath(dir, "export.csv")
            @test_throws ArgumentError export_session(session, path; format=:json)
            @test_throws ArgumentError export_session(session, path; content=:raw)

            empty!(session.history)
            export_session(session, path)
            lines = readlines(path)
            header_index = findfirst(line -> startswith(line, "trial_index,"), lines)
            @test header_index !== nothing
            @test length(lines) == header_index
        end
    end

    @testset "An analysis set exports pooled or split" begin
        mktempdir() do dir
            a = export_test_session(participant_id = "P001")
            b = export_test_session(participant_id = "P002")
            set = AnalysisSet([a, b]; checks = collect(COMBINING_CHECKS))

            trial_path = joinpath(dir, "set_trials.csv")
            @test export_session(set, trial_path) == trial_path
            trial_lines = readlines(trial_path)
            @test any(==("# sessions: 2"), trial_lines)
            trials_header = "session_id,participant_id,trial_index,contrast,frequency,response,correct,reaction_time_s,is_valid,timestamp_onset,timestamp_response,onset_source,origin"
            trials_header_index = findfirst(==(trials_header), trial_lines)
            @test trials_header_index !== nothing
            @test length(trial_lines) == trials_header_index + 6
            @test startswith(trial_lines[trials_header_index + 1], "$(a.id),P001,1,0.1,100.0,1,true,")
            @test startswith(trial_lines[trials_header_index + 4], "$(b.id),P002,1,")

            valid_path = joinpath(dir, "set_valid.csv")
            export_session(set, valid_path; valid_only = true)
            valid_lines = readlines(valid_path)
            valid_header_index = findfirst(==(trials_header), valid_lines)
            @test valid_header_index !== nothing
            @test length(valid_lines) == valid_header_index + 4

            summary_path = joinpath(dir, "set_summary.csv")
            @test export_session(set, summary_path; content = :summary) == summary_path
            summary_lines = readlines(summary_path)
            summary_header = "contrast,frequency,n,mean_response,sd,sem,ci_lo,ci_hi,proportion_correct,correct_ci_lo,correct_ci_hi"
            summary_header_index = findfirst(==(summary_header), summary_lines)
            @test summary_header_index !== nothing
            agg = get_aggregated_data(set)
            @test length(summary_lines) == summary_header_index + length(agg)
            for (i, point) in enumerate(agg)
                parts = split(summary_lines[summary_header_index + i], ',')
                @test parse(Int, parts[3]) == point.n
            end

            split_path = joinpath(dir, "set.csv")
            written = export_session(set, split_path; split = true)
            @test length(written) == 2
            @test endswith(written[1], "_$(string(a.id)[1:8]).csv")
            @test endswith(written[2], "_$(string(b.id)[1:8]).csv")
            for (member, member_file) in zip((a, b), written)
                single_path = joinpath(dir, "single_$(member.id).csv")
                export_session(member, single_path)
                split_lines = filter(line -> !startswith(line, "# export_time:"), readlines(member_file))
                single_lines = filter(line -> !startswith(line, "# export_time:"), readlines(single_path))
                @test split_lines == single_lines
            end

            xlsx_path = joinpath(dir, "set.xlsx")
            @test_throws ArgumentError export_session(set, xlsx_path; format = :xlsx)
            @test !isfile(xlsx_path)

            empty_set = AnalysisSet(; checks = collect(COMBINING_CHECKS))
            empty_path = joinpath(dir, "empty.csv")
            @test_throws ArgumentError export_session(empty_set, empty_path)
            @test !isfile(empty_path)
        end
    end
end
