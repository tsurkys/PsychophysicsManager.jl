using Dates, TOML

# Every test works in its own data directory, so the registry under test is never the
# one of the machine running the suite
with_registry(body) = mktempdir() do dir
    cd(dir) do
        write("settings.toml", "[storage]\ndata_dir = \"data\"\n")
        body(participant_registry_path())
    end
end

@testset "Participant registry" begin

    @testset "A participant is registered, listed and read back" begin
        with_registry() do path
            @test list_participants() == String[]
            @test get_participant("P01") === nothing

            profile = register_participant!("P01", Dict("age" => 25,
                                                        "vision" => "corrected",
                                                        "sessions_planned" => 3))
            @test profile["age"] == 25
            @test isfile(path)
            @test list_participants() == ["P01"]
            @test get_participant("P01") == profile

            register_participant!("P02", Dict("age" => 31))
            @test list_participants() == ["P01", "P02"]
            @test get_participant("P02")["age"] == 31
            @test get_participant("P01")["vision"] == "corrected"

            # The registry is TOML anyone can read, laid out as the design says
            stored = TOML.parsefile(path)
            @test collect(keys(stored)) == ["participants"]
            @test sort(collect(keys(stored["participants"]))) == ["P01", "P02"]
            @test stored["participants"]["P01"]["age"] == 25
            @test occursin("# The people measured with PsychophysicsManager", read(path, String))
        end
    end

    @testset "Registering again describes the same person further" begin
        with_registry() do _
            register_participant!("P01", Dict("age" => 25, "vision" => "corrected"))
            register_participant!("P01", Dict("vision" => "normal",
                                              "notes" => "tested in the afternoon"))

            profile = get_participant("P01")
            @test profile["age"] == 25                        # untouched
            @test profile["vision"] == "normal"               # replaced
            @test profile["notes"] == "tested in the afternoon"  # added
            @test list_participants() == ["P01"]
        end
    end

    @testset "Free-form metadata keeps its shape" begin
        with_registry() do _
            register_participant!("P01", Dict(:age => 25,          # a symbol names a key
                                              "born" => Date(2001, 3, 4),
                                              "glasses" => true,
                                              "acuity" => [1.0, 0.8],
                                              "contact" => Dict("email" => "p01@lab")))
            profile = get_participant("P01")
            @test profile["age"] == 25
            @test profile["born"] == Date(2001, 3, 4)
            @test profile["glasses"] === true
            @test profile["acuity"] == [1.0, 0.8]
            @test profile["contact"]["email"] == "p01@lab"
        end
    end

    @testset "What the registry refuses" begin
        with_registry() do path
            @test_throws ArgumentError register_participant!("")
            @test_throws ArgumentError register_participant!("   ")
            @test_throws ArgumentError register_participant!(DEFAULT_PARTICIPANT_ID,
                                                             Dict("age" => 25))
            @test !isfile(path)   # nothing was written by any of the three

            register_participant!("P01", Dict("age" => 25))
            before = read(path, String)

            # A value TOML cannot hold is refused before the file is touched, and the
            # temporary file of the atomic write is not left behind either
            @test_throws ArgumentError register_participant!("P01", Dict("sex" => :male))
            @test_throws ArgumentError register_participant!("P01",
                                                             Dict("seen" => nothing))
            @test read(path, String) == before
            @test !isfile(path * ".tmp")
            @test get_participant("P01") == Dict{String, Any}("age" => 25)
        end
    end

    @testset "A registry that cannot mean what it says is refused" begin
        with_registry() do path
            write(path, "[participants.P01]\nage = 25\n\n[sessions]\nx = 1\n")
            @test_throws ArgumentError list_participants()

            write(path, "participants = \"P01\"\n")
            @test_throws ArgumentError list_participants()

            write(path, "[participants]\nP01 = \"aged 25\"\n")
            @test_throws ArgumentError get_participant("P01")
        end
    end

    @testset "Sessions know nothing of the registry" begin
        with_registry() do path
            register_participant!("P01", Dict("age" => 25))
            session = SessionContext("P01",
                                     ExperimentParameters("Registry", :Diff, [1.0], 1),
                                     BaseStimulusParameters(10.0),
                                     ConstantStimuli())
            saved = save_session_checkpoint(session, resolve_data_dir())

            # The person is named, never described, so a shared dataset identifies nobody
            stored = PsychophysicsManager.JSON3.read(read(saved, String), Dict{String, Any})
            @test stored["participant_id"] == "P01"
            @test !any(occursin("age"), keys(stored))

            # And the session is loaded where no registry exists at all
            rm(path)
            loaded = load_session(saved)
            @test loaded.participant_id == "P01"
            @test get_participant("P01") === nothing
            @test list_participants() == String[]
        end
    end
end
