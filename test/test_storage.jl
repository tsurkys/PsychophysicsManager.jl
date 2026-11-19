# A method whose state is not in its fields: it holds a handle the session file
# cannot write, and rebuilds it from what the file does hold
mutable struct ReplayMethod <: AbstractPsychoMethod
    level::Float64
    answers::Vector{Int}
    handle::Any
    rebuilt::Int

    ReplayMethod() = new(0.0, Int[], nothing, 0)
end

PsychophysicsManager.restore_method_state!(method::ReplayMethod) =
    (method.handle = Ref(sum(method.answers)); method.rebuilt += 1; method)

PsychophysicsManager.register_method_type!(ReplayMethod)

@testset "Storage" begin

    @testset "A method's runtime state is rebuilt, not written" begin
        mktempdir() do dir
            method = ReplayMethod()
            method.level = 2.5
            method.answers = [1, 0, 1]
            method.handle = Ref(99)
            session = SessionContext("P", ExperimentParameters("replay", :x, [1.0], 1),
                                     BaseStimulusParameters(10.0), method)
            path = save_session_checkpoint(session, dir)

            # What cannot be read back is not written, so a handle never lands
            # in a file that the next library version would read wrongly
            stored = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            @test stored["method_instance"]["fields"]["handle"] === nothing
            @test stored["method_instance"]["fields"]["answers"] == [1, 0, 1]

            loaded = load_session(path).method_instance
            @test loaded.level == 2.5
            @test loaded.answers == [1, 0, 1]
            @test loaded.rebuilt == 1        # the hook ran, once
            @test loaded.handle[] == 2       # rebuilt from the recorded answers
        end
    end

    function make_session()
        ex_par = ExperimentParameters("RoundTrip", :DistrN, collect(0.0:2.0), 2)
        stim = MarkerLayout(StimConfig = "d r t", Ref = 24.0, Marker = :rect,
                              MarkerSize = (2, 30), Anchor = :middle)
        m = Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0,
                             init_interval = (-1.0, 1.0))
        s = SessionContext("P001", ex_par, stim, m; tags = ["training"])
        s.start_time = time()
        s.engine_name = "GeometryVisualEngine"
        # One discrete and one continuous response, plus an invalidated trial
        push!(s.history, Trial(1, 1.0, 2.5, [0.0], 1, true))
        push!(s.history, Trial(2, 3.0, 4.0, [2.0], -3.5, true))
        push!(s.history, Trial(3, 5.0, 6.0, [1.0], 0, false))
        s.history[2].onset_source = :engine   # mixed onset provenance
        s.history[2].origin = :operator       # a trial the operator chose
        s.history[2].start_value = 1.0        # where its adjustment began
        push!(s.comments, SessionComment(10.0, 2, "Blinked"), SessionComment(11.5, nothing, "Tired"))
        s.current_trial_idx = 4
        return s
    end

    @testset "Integer adjustment range round-trip" begin
        mktempdir() do dir
            ex_par = ExperimentParameters("PixelRoundTrip", :condition, 1:1, 1)
            method = Adjustment(
                dep_var = :Diff,
                dep_range = -3:3,
                init_interval = (-1, 1),
            )
            session = SessionContext(ex_par, MarkerLayout(), method)

            loaded = load_session(save_session_checkpoint(session, dir)).method_instance
            @test loaded.dep_range == collect(-3:3)
            @test all(value -> value isa Int, loaded.dep_range)
            @test loaded.init_interval === (-1, 1)
        end
    end

    @testset "Save/load round-trip" begin
        mktempdir() do dir
            s = make_session()
            path = save_session_checkpoint(s, dir)
            @test isfile(path)
            # Atomic write leaves no temp files behind
            @test !any(endswith(f, ".tmp") for f in readdir(dir))

            loaded = load_session(path)
            @test loaded.id == s.id
            @test loaded.participant_id == "P001"
            # Version stamped from Project.toml, not hardcoded
            @test loaded.program_version == string(pkgversion(PsychophysicsManager))
            @test loaded.tags == ["training"]
            @test loaded.state == s.state
            @test loaded.engine_name == "GeometryVisualEngine"
            @test loaded.current_trial_idx == 4

            # Experiment parameters
            @test loaded.ex_par.experiment_name == "RoundTrip"
            @test loaded.ex_par.indep_var_names == [:DistrN]
            @test collect(loaded.ex_par.indep_var_ranges[1]) == [0.0, 1.0, 2.0]

            # Stimulus parameters: Symbol and Tuple fields survive JSON
            @test loaded.stim_par isa MarkerLayout
            @test loaded.stim_par.StimConfig == "d r t"
            @test loaded.stim_par.Ref == 24.0
            @test loaded.stim_par.Marker === :rect
            @test loaded.stim_par.MarkerSize === (2, 30)
            @test loaded.stim_par.Anchor === :middle

            # Method configuration and state survive
            lm = loaded.method_instance
            @test lm isa Adjustment
            @test lm.dep_var === :Diff
            @test lm.dep_range == collect(-5.0:1.0:5.0)
            # JSON3 may read integral floats back as Int; values,
            # rather than numeric type tags, are the persistence contract.
            @test lm.init_interval == (-1.0, 1.0)

            # History: response values are preserved exactly. Note: JSON does
            # not keep the Int/Float distinction for integral values (JSON3
            # reads -3.0 back as Int64), so consumers must treat response as
            # a generic Real — values, not type tags, are the contract.
            @test length(loaded.history) == 3
            @test loaded.history[1].response isa Integer
            @test loaded.history[1].response == 1
            @test loaded.history[2].response isa Float64
            @test loaded.history[2].response == -3.5
            @test loaded.history[3].is_valid == false
            @test loaded.history[2].indep_var_vals == [2.0]
            # Onset provenance survives; the 6-arg constructor defaults to :estimated
            @test loaded.history[1].onset_source == :estimated
            @test loaded.history[2].onset_source == :engine
            @test loaded.history[1].origin == :method && loaded.history[2].origin == :operator
            @test loaded.history[1].start_value === nothing && loaded.history[2].start_value === 1.0
            @test [(c.time, c.trial, c.text) for c in loaded.comments] ==
                  [(10.0, 2, "Blinked"), (11.5, nothing, "Tired")]
        end
    end

    @testset "Scoring persistence" begin
        mktempdir() do dir
            s = make_session()
            s.history[1].correct = true
            s.history[2].correct = false
            # The third trial stays unscored: a session may mix a scored task
            # with trials no answer was scored for

            loaded = load_session(save_session_checkpoint(s, dir))
            @test [t.correct for t in loaded.history] == [true, false, nothing]

            # Files written before scoring existed stay loadable
            path = save_session_checkpoint(s, dir)
            older = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            foreach(entry -> delete!(entry, "correct"), older["history"])
            legacy_path = joinpath(dir, "unscored.json")
            write(legacy_path, PsychophysicsManager.JSON3.write(older))
            @test all(t.correct === nothing
                      for t in load_session(legacy_path).history)
        end
    end

    @testset "Fit asymptote persistence" begin
        mktempdir() do dir
            s = make_session()
            @test s.fit_gamma == PsychophysicsManager.DEFAULT_FIT_GAMMA
            set_fit_gamma!(s, 0.5)
            path = save_session_checkpoint(s, dir)
            @test load_session(path).fit_gamma == 0.5

            # A mid-session change reaches the pinned checkpoint on its own:
            # the operator declares the data's nature while it is being
            # collected, and the file must not disagree with the panel
            set_fit_gamma!(s, 0.0)
            @test load_session(path).fit_gamma == 0.0

            # Files written before the setting existed stay loadable
            older = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            delete!(older, "fit_gamma")
            legacy_path = joinpath(dir, "legacy.json")
            write(legacy_path, PsychophysicsManager.JSON3.write(older))
            @test load_session(legacy_path).fit_gamma == PsychophysicsManager.DEFAULT_FIT_GAMMA

            # It is a proportion: an asymptote at or above 1 leaves the curve
            # no room to rise
            @test_throws ArgumentError set_fit_gamma!(s, 1.0)
            @test_throws ArgumentError set_fit_gamma!(s, -0.1)
            @test s.fit_gamma == 0.0
        end
    end

    @testset "Unit conversions persist" begin
        mktempdir() do dir
            s = make_session()
            set_unit_conversion!(s, :DistrN, UnitConversion("Distractors"; offset = 1))
            set_unit_conversion!(s, :Diff, UnitConversion("Diff (arcmin)"; scale = 0.5,
                                                          formula = "Diff * pixel_arcmin"))
            path = save_session_checkpoint(s, dir)
            stored = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            @test !haskey(stored["unit_conversions"]["DistrN"], "formula")
            @test stored["unit_conversions"]["Diff"]["formula"] == "Diff * pixel_arcmin"
            loaded = load_session(path)
            @test loaded.unit_conversions == s.unit_conversions
            @test loaded.unit_conversions[:Diff].formula == "Diff * pixel_arcmin"
            @test loaded.unit_conversions[:DistrN].formula == ""

            # A file without the formula key loads with formula == ""
            delete!(stored["unit_conversions"]["Diff"], "formula")
            no_formula_path = joinpath(dir, "no_formula.json")
            write(no_formula_path, PsychophysicsManager.JSON3.write(stored))
            @test load_session(no_formula_path).unit_conversions[:Diff].formula == ""

            # Declared after the file was pinned, it reaches the file on its own
            set_unit_conversion!(s, :Diff, nothing)
            @test collect(keys(load_session(path).unit_conversions)) == [:DistrN]
            positive = ExperimentParameters("RoundTrip", :DistrN, [1.0, 2.0], 1)
            logarithmic = SessionContext("P001", positive, s.stim_par, s.method_instance)
            set_unit_conversion!(logarithmic, :DistrN,
                                 UnitConversion("log N"; form = :log10, scale = 2.0))
            restored = load_session(save_session_checkpoint(logarithmic, dir))
            @test restored.unit_conversions[:DistrN] ==
                  UnitConversion("log N"; form = :log10, scale = 2.0)

            # Files written before conversions existed load with none
            older = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            delete!(older, "unit_conversions")
            legacy_path = joinpath(dir, "legacy.json")
            write(legacy_path, PsychophysicsManager.JSON3.write(older))
            @test isempty(load_session(legacy_path).unit_conversions)
        end
    end

    @testset "A missing response survives the round trip" begin
        mktempdir() do dir
            s = make_session()
            # JSON has no NaN, so the presentation nobody answered is stored as
            # `null` — a response that is absent rather than zero
            s.history[2].response = MISSING_RESPONSE
            path = save_session_checkpoint(s, dir)
            stored = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            @test stored["history"][2]["response"] === nothing

            loaded = load_session(path)
            @test isnan(loaded.history[2].response)
            @test loaded.history[1].response == s.history[1].response
        end
    end

    @testset "Feedback persistence" begin
        mktempdir() do dir
            s = make_session()
            @test !s.feedback

            events = Symbol[]
            on_session_event!((_, event) -> push!(events, event), s)
            set_feedback!(s, true)
            @test events == [:settings_changed]
            # Declaring what is already declared changes nothing and says nothing
            set_feedback!(s, true)
            @test events == [:settings_changed]

            path = save_session_checkpoint(s, dir)
            @test load_session(path).feedback

            # Switching to measurement mid-session reaches the pinned checkpoint
            set_feedback!(s, false)
            @test !load_session(path).feedback

            # Files written before the setting existed stay loadable
            older = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            delete!(older, "feedback")
            legacy_path = joinpath(dir, "legacy_feedback.json")
            write(legacy_path, PsychophysicsManager.JSON3.write(older))
            @test !load_session(legacy_path).feedback
        end
    end

    @testset "Seed and environment persistence" begin
        mktempdir() do dir
            ex_par = ExperimentParameters("Seeded", :x, [1.0], 1)
            s = SessionContext(ex_par, BaseStimulusParameters(1.0),
                               ConstantStimuli(); rng_seed = typemax(UInt64))
            start_session!(s, OffscreenVisualEngine(320, 240))
            path = save_session_checkpoint(s, dir)

            loaded = load_session(path)
            @test loaded.rng_seed === typemax(UInt64)
            @test loaded.environment == s.environment
            @test loaded.environment["display_resolution"] == "320x240"

            stored = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            # A seed larger than typemax(Int64) has no JSON number to live in
            @test stored["rng_seed"] == string(typemax(UInt64))

            # Files written before the two keys existed stay loadable: the
            # machine is simply unknown, and a fresh seed is drawn for whatever
            # the session would still randomize
            delete!(stored, "rng_seed")
            delete!(stored, "environment")
            legacy_path = joinpath(dir, "legacy_seed.json")
            write(legacy_path, PsychophysicsManager.JSON3.write(stored))
            legacy = load_session(legacy_path)
            @test isempty(legacy.environment)
            @test legacy.rng_seed != s.rng_seed
        end
    end

    @testset "The rig's constants are recorded at the start and kept" begin
        mktempdir() do dir
            user = joinpath(dir, "rig", "settings.toml")
            mkpath(dirname(user))
            write(user, "[rig]\nname = \"Booth 2\"\npixel_pitch_mm = 0.25\n" *
                        "viewing_distance_mm = 1000\n")
            withenv(PsychophysicsManager.USER_SETTINGS_VARIABLE => user) do
                ex_par = ExperimentParameters("Rig", :x, [1.0, 2.0], 2)
                s = SessionContext(ex_par, BaseStimulusParameters(1.0), ConstantStimuli())
                @test isempty(s.rig)
                start_session!(s)
                @test s.rig["name"] == "Booth 2"
                @test s.rig["pixel_arcmin"] ≈ 0.8594 atol = 1e-4
                path = save_session_checkpoint(s, dir)
                stored = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
                @test stored["rig"]["name"] == "Booth 2"
                # A session continued after the rig changed keeps what it recorded
                write(user, "[rig]\nname = \"Booth 3\"\npixel_arcmin = 2.0\n")
                loaded = load_session(path)
                @test loaded.rig == s.rig
                @test loaded.state == RUNNING
                # A file written before the key existed records no rig
                delete!(stored, "rig")
                legacy_path = joinpath(dir, "legacy_rig.json")
                write(legacy_path, PsychophysicsManager.JSON3.write(stored))
                @test isempty(load_session(legacy_path).rig)
            end
        end
    end

    @testset "Unit formulas and defaults resolve at start_session!" begin
        mktempdir() do dir
            user = joinpath(dir, "rig", "settings.toml")
            mkpath(dirname(user))
            project = mkpath(joinpath(dir, "project"))
            withenv(PsychophysicsManager.USER_SETTINGS_VARIABLE => user) do
                cd(project) do
                    write(user, "[rig]\nname = \"Booth A\"\npixel_arcmin = 0.5\n")
                    write(joinpath(project, "settings.toml"), """
                    [units.MarkerLayout]
                    DistrN = "Number of distractors"
                    Diff   = "Illusion (arcmin) = Diff * pixel_arcmin"
                    Angle  = "Ignored non-convertible = Angle * 2"
                    """)

                    # Session without conversions takes [units.MarkerLayout] resolved with [rig]
                    ex_par = ExperimentParameters("Units", :DistrN, [1, 3], 1)
                    stim = MarkerLayout(Ref = 20.0)
                    method = Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0)
                    s = SessionContext("P1", ex_par, stim, method)
                    s.engine_name = "EmulatorEngine"
                    start_session!(s)
                    @test s.state == RUNNING
                    @test s.unit_conversions[:DistrN] == UnitConversion("Number of distractors")
                    @test s.unit_conversions[:Diff].scale ≈ 0.5
                    @test s.unit_conversions[:Diff].formula == "Diff * pixel_arcmin"
                    @test !haskey(s.unit_conversions, :Angle)

                    # Template (READY session saved and loaded, and replicated) with a formula
                    # conversion resolves anew under a different rig constant
                    template = SessionContext("T", ex_par, MarkerLayout(Ref = 20.0),
                                              Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0))
                    template.engine_name = "EmulatorEngine"
                    set_unit_conversion!(template, :Diff,
                        PsychophysicsManager.parse_unit_conversion(
                            :Diff, "Illusion = Diff * pixel_arcmin";
                            constants = Dict(:pixel_arcmin => 0.5)))
                    set_unit_conversion!(template, :DistrN, UnitConversion("Fixed"; scale = 2.0))
                    tpl_path = save_session_checkpoint(template, project; filename = "tpl.json")

                    first_copy = create_replicated_session(tpl_path, "P1")
                    @test first_copy.unit_conversions[:Diff].formula == "Diff * pixel_arcmin"
                    start_session!(first_copy)
                    @test first_copy.unit_conversions[:Diff].scale ≈ 0.5
                    @test first_copy.unit_conversions[:DistrN].scale == 2.0

                    write(user, "[rig]\nname = \"Booth B\"\npixel_arcmin = 0.933\n")
                    second_copy = create_replicated_session(tpl_path, "P2")
                    start_session!(second_copy)
                    @test second_copy.unit_conversions[:Diff].scale ≈ 0.933
                    @test second_copy.unit_conversions[:DistrN].scale == 2.0

                    # Finished session saved, constant changed, loaded again: scale unchanged
                    second_copy.state = FINISHED
                    done_path = save_session_checkpoint(second_copy, project; filename = "done.json")
                    write(user, "[rig]\nname = \"Booth C\"\npixel_arcmin = 2.5\n")
                    reloaded = load_session(done_path)
                    @test reloaded.unit_conversions[:Diff].scale ≈ 0.933
                    @test reloaded.unit_conversions[:Diff].formula == "Diff * pixel_arcmin"

                    # Refusal at start leaves the session READY with conversions unchanged
                    write(joinpath(project, "settings.toml"), """
                    [units.MarkerLayout]
                    DistrN = "Number of distractors"
                    Diff   = "Illusion = Diff * missing_constant"
                    """)
                    failing = SessionContext("P3", ex_par, MarkerLayout(Ref = 20.0),
                                             Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0))
                    err = try
                        start_session!(failing)
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("Diff", err.msg) && occursin("missing_constant", err.msg)
                    @test failing.state == READY
                    @test isempty(failing.unit_conversions) && isempty(failing.rig)

                    # rig["name"] is not a numeric constant; an ambiguous name is refused
                    write(joinpath(project, "settings.toml"), """
                    [units.MarkerLayout]
                    Diff = "Bad = Diff * name"
                    """)
                    @test_throws ArgumentError start_session!(failing)
                    @test failing.state == READY

                    write(user, "[rig]\nRef = 50\n")
                    write(joinpath(project, "settings.toml"), """
                    [units.MarkerLayout]
                    Diff = "Ambig = (Ref - Diff)"
                    """)
                    ambig_err = try start_session!(failing); nothing catch e e end
                    @test ambig_err isa ArgumentError && occursin("Ref", ambig_err.msg)
                    @test failing.state == READY

                    # log10 positivity check applies at start_session!
                    write(user, "[rig]\npixel_arcmin = 1.0\n")
                    write(joinpath(project, "settings.toml"), """
                    [units.MarkerLayout]
                    DistrN = "log N = log10(DistrN)"
                    """)
                    nonpos = SessionContext("P4",
                        ExperimentParameters("Zero", :DistrN, [0, 1, 2], 1),
                        MarkerLayout(), ConstantStimuli())
                    @test_throws ArgumentError start_session!(nonpos)
                    @test nonpos.state == READY && isempty(nonpos.unit_conversions)
                end
            end
        end
    end

    @testset "The random stream's position persists" begin
        mktempdir() do dir
            ex_par = ExperimentParameters("Stream", :x, [1.0, 2.0, 3.0], 1)
            s = SessionContext(ex_par, BaseStimulusParameters(1.0),
                               ConstantStimuli(); rng_seed = 20261116)
            start_session!(s)
            rand(s.rng, 3)
            path = save_session_checkpoint(s, dir)
            @test rand(load_session(path).rng, UInt64, 5) == rand(copy(s.rng), UInt64, 5)

            stored = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            # Words above typemax(Int64) have no JSON number to live in
            @test all(word isa String for word in stored["rng_state"])

            # A file from a Julia whose stream has four words (1.10) gives the same
            # numbers; one with fewer is refused; one without the key opens at the seed
            other_path = joinpath(dir, "other.json")
            stored["rng_state"] = stored["rng_state"][1:4]
            write(other_path, PsychophysicsManager.JSON3.write(stored))
            @test rand(load_session(other_path).rng, UInt64, 5) == rand(copy(s.rng), UInt64, 5)
            stored["rng_state"] = stored["rng_state"][1:3]
            write(other_path, PsychophysicsManager.JSON3.write(stored))
            @test_throws ErrorException load_session(other_path)
            delete!(stored, "rng_state")
            write(other_path, PsychophysicsManager.JSON3.write(stored))
            @test rand(load_session(other_path).rng, UInt64) == rand(Random.Xoshiro(20261116), UInt64)
        end
    end

    @testset "A file is replaced whole or not at all" begin
        mktempdir() do dir
            path = joinpath(dir, "record.json")
            PsychophysicsManager.atomic_write(io -> write(io, "first"), path)
            PsychophysicsManager.atomic_write(io -> write(io, "second"), path)
            @test read(path, String) == "second"
            @test readdir(dir) == ["record.json"]

            # A writer that fails leaves the file as it was
            @test_throws ErrorException PsychophysicsManager.atomic_write(path) do io
                write(io, "half")
                error("the writer failed")
            end
            @test read(path, String) == "second"
        end
    end

    @testset "Filename templating" begin
        s = make_session()
        config = Dict{String,Any}("filename_template" => "{participant_id}_{method}({indep_vars})_{tags}")
        @test generate_session_filename(s, config) == "P001_Adjustment(DistrN)_training.json"

        config2 = Dict{String,Any}("filename_template" => "{short_id}_R{ex_par.repeats}_Ref{stim_par.Ref}")
        @test generate_session_filename(s, config2) == "$(string(s.id)[1:8])_R2_Ref24.0.json"

        # Folders in the template stay relative and keep slashes inside token values sanitized
        folder_cfg = Dict{String,Any}(
            "filename_template" => "{ex_par.experiment_name}/{participant_id}/{participant_id}_{short_id}")
        @test generate_session_filename(s, folder_cfg) ==
              "RoundTrip/P001/P001_$(string(s.id)[1:8]).json"

        # File-system-unsafe characters in token values are sanitized
        s.participant_id = "P/00:1?"
        cfg = Dict{String,Any}("filename_template" => "{participant_id}")
        @test generate_session_filename(s, cfg) == "P_00_1_.json"
        @test generate_session_filename(s, folder_cfg) ==
              "RoundTrip/P_00_1_/P_00_1__$(string(s.id)[1:8]).json"

        # Leading '/', empty, '.' and '..' segments after expansion are refused
        for bad_tmpl in ("/{participant_id}", "../{participant_id}",
                         "{ex_par.experiment_name}/../{participant_id}",
                         "{ex_par.experiment_name}/./{participant_id}",
                         "{ex_par.experiment_name}/{tags}/{participant_id}",
                         "{participant_id}/")
            bad_session = make_session()
            empty!(bad_session.tags)
            err = try
                generate_session_filename(bad_session, Dict{String,Any}("filename_template" => bad_tmpl))
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin(bad_tmpl, sprint(showerror, err))
        end

        s_dot = make_session()
        s_dot.participant_id = ".."
        @test_throws ArgumentError generate_session_filename(
            s_dot, Dict{String,Any}("filename_template" => "{participant_id}/{short_id}"))
    end

    @testset "Folders in filename_template on save and collision" begin
        mktempdir() do dir
            write(joinpath(dir, "settings.toml"),
                  "[storage]\nfilename_template = \"{ex_par.experiment_name}/{participant_id}/{participant_id}\"\n")
            s1 = make_session()
            p1 = save_session_checkpoint(s1, dir)
            @test p1 == abspath(joinpath(dir, "RoundTrip", "P001", "P001.json"))
            @test isfile(p1)

            s2 = make_session()
            p2 = @test_logs (:warn, r"collision") save_session_checkpoint(s2, dir)
            @test dirname(p2) == dirname(p1)
            @test p2 != p1
            @test isfile(p1) && isfile(p2)
        end
    end

    @testset "Schema and state guards" begin
        mktempdir() do dir
            s = make_session()
            path = save_session_checkpoint(s, dir)
            raw = PsychophysicsManager.JSON3.read(read(path, String), Dict)
            @test raw["schema_version"] == PsychophysicsManager.SESSION_SCHEMA_VERSION

            # Older files without the key still load
            delete!(raw, "schema_version")
            write(path, PsychophysicsManager.JSON3.write(raw))
            @test load_session(path) isa SessionContext

            # Files from a NEWER schema are refused instead of misread
            raw["schema_version"] = PsychophysicsManager.SESSION_SCHEMA_VERSION + 1
            write(path, PsychophysicsManager.JSON3.write(raw))
            @test_throws ErrorException load_session(path)

            # An unknown session state errors instead of silently becoming READY
            raw["schema_version"] = PsychophysicsManager.SESSION_SCHEMA_VERSION
            raw["state"] = "NO_SUCH_STATE"
            write(path, PsychophysicsManager.JSON3.write(raw))
            @test_throws ErrorException load_session(path)

            # Unknown stimulus-parameter fields from old files are skipped
            raw["state"] = "READY"
            raw["stim_par"]["fields"]["RemovedLegacyField"] = 42
            write(path, PsychophysicsManager.JSON3.write(raw))
            @test load_session(path) isa SessionContext
        end
    end

    @testset "Registry re-registration warning" begin
        @eval module RegClashA
            using PsychophysicsManager
            struct ClashMethod <: PsychophysicsManager.AbstractPsychoMethod end
        end
        @eval module RegClashB
            using PsychophysicsManager
            struct ClashMethod <: PsychophysicsManager.AbstractPsychoMethod end
        end
        register_method_type!(RegClashA.ClashMethod)
        @test_logs (:warn, r"already registered") register_method_type!(RegClashB.ClashMethod)
        @test PsychophysicsManager.METHOD_REGISTRY[:ClashMethod] === RegClashB.ClashMethod
        delete!(PsychophysicsManager.METHOD_REGISTRY, :ClashMethod)

        # Re-registering the SAME type is silent
        @test_logs register_method_type!(ConstantStimuli)
    end

    @testset "Checkpoint path pinning and collision safety" begin
        mktempdir() do dir
            # Template with no unique token: the legacy default that made two
            # sessions of the same participant + method collide
            write(joinpath(dir, "settings.toml"),
                  "[storage]\nfilename_template = \"{participant_id}_{method}({indep_vars})\"\n")

            s1 = make_session()
            p1 = save_session_checkpoint(s1, dir)
            @test s1.save_path == p1
            # Re-saving reuses the pinned path instead of regenerating it
            @test save_session_checkpoint(s1, dir) == p1

            # A different session generating the same filename must not
            # overwrite the first one: it gets a short-id suffix + warning
            s2 = make_session()
            p2 = @test_logs (:warn, r"collision") save_session_checkpoint(s2, dir)
            @test p2 != p1
            @test occursin(string(s2.id)[1:8], basename(p2))
            @test isfile(p1) && isfile(p2)
            @test string(load_session(p1).id) == string(s1.id)

            # Loading pins the path; later checkpoints keep updating that file
            loaded = load_session(p1)
            @test loaded.save_path == abspath(p1)
            @test save_session_checkpoint(loaded, dir) == abspath(p1)

            # Explicit filename ("save as") re-pins to the requested file
            p3 = save_session_checkpoint(s1, dir; filename = "copy.json")
            @test endswith(p3, "copy.json") && isfile(p3)
            @test s1.save_path == p3
        end

        # The built-in default template is collision-free by construction
        s = make_session()
        default_name = generate_session_filename(s, copy(PsychophysicsManager.DEFAULT_STORAGE_CONFIG))
        @test endswith(default_name, "_$(string(s.id)[1:8]).json")
    end

    @testset "Display configuration" begin
        mktempdir() do dir
            write(joinpath(dir, "settings.toml"),
                  "[display]\nscreen_idx = 2\nscreen_name = \"HDMI\"\n")
            config = load_display_config(dir)
            @test config.screen_idx == 2
            @test config.screen_name == "HDMI"
            # The dashboard is left to the window system unless a monitor is named
            @test config.dashboard_screen_idx === nothing
            @test PsychophysicsManager.dashboard_monitor_index(["A", "B"], config) === nothing
        end
        mktempdir() do dir
            write(joinpath(dir, "settings.toml"),
                  "[display]\ndashboard_screen_idx = 2\n")
            config = load_display_config(dir)
            @test PsychophysicsManager.dashboard_monitor_index(["A", "B", "C"], config) == 2
            config.dashboard_screen_name = "c"
            @test PsychophysicsManager.dashboard_monitor_index(["A", "B", "C"], config) == 3
            @test PsychophysicsManager.dashboard_monitor_index(String[], config) === nothing
        end
        mktempdir() do dir
            # No settings.toml anywhere relevant: defaults apply
            config = load_display_config(dir)
            @test config.screen_idx == 1
            @test config.screen_name == ""
        end
    end

    @testset "Monitor selection" begin
        names = ["Built-in Display", "DELL U2723QE", "EIZO CG279X"]
        # A name fragment beats the index and is matched case-insensitively
        @test PsychophysicsManager.select_monitor_index(names, 1, "eizo") == 3
        @test PsychophysicsManager.select_monitor_index(names, 1, "DELL") == 2
        # No fragment: the index is used, clamped into range
        @test PsychophysicsManager.select_monitor_index(names, 2, "") == 2
        @test PsychophysicsManager.select_monitor_index(names, 99, "") == 3
        @test PsychophysicsManager.select_monitor_index(names, 0, "") == 1
        # An unmatched fragment warns and falls back to the index
        @test (@test_logs (:warn, r"No monitor name contains") PsychophysicsManager.select_monitor_index(names, 2, "projector")) == 2
    end

    @testset "Data directory resolution" begin
        mktempdir() do dir
            # No settings.toml anywhere relevant: falls back to <dir>/data
            fallback = resolve_data_dir(dir)
            @test fallback == joinpath(abspath(dir), "data")
            @test isdir(fallback)

            # data_dir relative to the settings.toml that defines it
            write(joinpath(dir, "settings.toml"), "[storage]\ndata_dir = \"results\"\n")
            sub = mkpath(joinpath(dir, "deep", "nested"))
            resolved = resolve_data_dir(sub)
            @test resolved == joinpath(abspath(dir), "results")
            @test isdir(resolved)
        end
    end

    @testset "A closed response window round-trips" begin
        mktempdir() do dir
            s = make_session()
            set_timeout!(s, 0.75)
            push!(s.history, Trial(4, 7.0, 8.0, [1.0], :timeout, true))
            push!(s.history, Trial(5, 9.0, 10.0, [1.0], MISSING_RESPONSE, true))

            loaded = load_session(save_session_checkpoint(s, dir))
            # The file must say which of the two happened: an expired window is
            # a string, a reply that never arrived is JSON's null
            @test loaded.history[4].response === :timeout
            @test isnan(loaded.history[5].response)
            @test loaded.timeout_s == 0.75

            stored = PsychophysicsManager.JSON3.read(read(s.save_path, String), Dict{String, Any})
            @test stored["history"][4]["response"] == "timeout"
            @test stored["history"][5]["response"] === nothing

            # Nothing else is a response: a file naming another outcome is not
            # read as a number, a symbol, or silence
            @test_throws ArgumentError PsychophysicsManager.response_from_json("abandoned")
        end
    end

    @testset "Audio output configuration" begin
        mktempdir() do dir
            @test load_audio_output_device(dir) === nothing

            write(
                joinpath(dir, "settings.toml"),
                "[audio]\noutput_device = \"Laboratory Output\"\n",
            )
            nested = mkpath(joinpath(dir, "nested"))
            @test load_audio_output_device(nested) == "Laboratory Output"

            write(joinpath(dir, "settings.toml"), "[audio]\noutput_device = \"  \"\n")
            @test load_audio_output_device(nested) === nothing
        end
    end

    @testset "adjusted_fields is recorded and ignored on load" begin
        mktempdir() do dir
            s = make_session()
            path = save_session_checkpoint(s, dir)
            stored = PsychophysicsManager.JSON3.read(read(path, String), Dict{String, Any})
            @test stored["adjusted_fields"] == ["Diff"]

            # dict_to_session derives adjusted_fields from the method rather than the key
            stored["adjusted_fields"] = ["NotAField"]
            write(path, PsychophysicsManager.JSON3.write(stored))
            loaded = load_session(path)
            @test adjusted_fields(loaded.method_instance) == [:Diff]

            delete!(stored, "adjusted_fields")
            write(path, PsychophysicsManager.JSON3.write(stored))
            @test adjusted_fields(load_session(path).method_instance) == [:Diff]
        end
    end

end
