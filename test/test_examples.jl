using TOML

@testset "The examples environment resolves the package's dependencies" begin
    # A dependency added to the package but not resolved into the examples
    # manifest stops every example at `using PsychophysicsManager`; re-resolve it with
    # `julia --project=examples -e 'using Pkg; Pkg.resolve()'`
    package_root = normpath(joinpath(@__DIR__, ".."))
    declared = keys(TOML.parsefile(joinpath(package_root, "Project.toml"))["deps"])
    manifest = TOML.parsefile(joinpath(package_root, "examples", "Manifest.toml"))
    @test Set(only(manifest["deps"]["PsychophysicsManager"])["deps"]) == Set(declared)
end

@testset "Example scripts parse" begin
    examples_dir = normpath(joinpath(@__DIR__, "..", "examples"))
    scripts = sort(filter(
        path -> endswith(path, ".jl"),
        readdir(examples_dir; join = true),
    ))

    @test !isempty(scripts)
    for script in scripts
        @testset "$(basename(script))" begin
            source = read(script, String)
            position = 1
            while true
                expression, position = Meta.parse(source, position; raise = true)
                expression === nothing && break
            end
            @test true
        end
    end
end

@testset "Temporal Oppel-Kundt example configuration" begin
    include(joinpath(
        @__DIR__,
        "..",
        "examples",
        "_temporal_oppel_kundt_setup.jl",
    ))
    session = create_temporal_oppel_kundt_session(
        "Audio_Example_Test";
        repeats = 3,
        extra_tags = ["configuration-test"],
    )

    @test session.participant_id == "Audio_Example_Test"
    @test session.ex_par.experiment_name ==
          "Temporal_Oppel_Kundt_Constant_Stimuli"
    @test session.ex_par.indep_var_names == [:comparison_interval_ms]
    @test collect(only(session.ex_par.indep_var_ranges)) ==
          collect(800.0:200.0:2000.0)
    @test session.ex_par.repeats == 3
    @test session.stim_par isa TemporalOppelKundt
    @test session.stim_par.reference_interval_ms == 1000.0
    @test session.stim_par.filler_count == 6
    @test session.stim_par.frequency_hz == 1000.0
    @test session.stim_par.burst_duration_ms == 30.0
    @test session.stim_par.ramp_duration_ms == 3.4
    @test session.stim_par.peak_amplitude == 0.5
    @test session.stim_par.sample_rate_hz == 48000
    @test session.stim_par.leading_silence_ms == 2600.0
    @test session.method_instance isa ConstantStimuli
    @test "configuration-test" in session.tags
    @test_throws ArgumentError create_temporal_oppel_kundt_session(
        "Invalid";
        repeats = 0,
    )
end

@testset "OK example configuration" begin
    include(joinpath(@__DIR__, "..", "examples", "_ok_experiment_setup.jl"))
    session = create_ok_session("Example_Test"; extra_tags = ["dashboard-test"])

    @test session.participant_id == "Example_Test"
    @test session.ex_par.experiment_name == "OK_Geometry_Study"
    @test session.ex_par.indep_var_names == [:DistrN]
    @test collect(only(session.ex_par.indep_var_ranges)) == collect(0:5)
    @test session.ex_par.repeats == 2
    @test session.stim_par.Ref == 240.0
    @test session.stim_par.MarkerSize == (2, 30)
    @test session.method_instance.dep_var == :Diff
    @test session.method_instance.dep_range == collect(-120:120)
    @test all(value -> value isa Int, session.method_instance.dep_range)
    @test "dashboard-test" in session.tags

    # Omitted participant falls back to the reserved default id
    @test create_ok_session().participant_id == DEFAULT_PARTICIPANT_ID
    @test_throws ArgumentError create_ok_session("Invalid"; repeats = 0)
end
