using TOML

# The settings editor's reading, checking and writing (src/IO/settings.jl). Every case
# works in a directory of its own: the editor writes the settings.toml it finds.

@testset "Settings editor" begin

    # A file as people write them: comments above and beside keys, a key commented out
    # beside its active line, and one that is only commented out
    HANDWRITTEN = """
    # Laboratory settings

    [storage]
    # Where the sessions go
    data_dir = "data"   # beside this file

    [display]

    # Monitor index (1, 2, 3...)
    screen_idx = 2
    screen_name = "HDMI"
    # screen_name = "HDMI"

    # Whether to open the stimulus window in fullscreen mode
    fullscreen = true
    # dashboard_screen_idx = 2

    [audio]
    output_device = ""
    """

    lines_of(path) = split(read(path, String), "\n")

    @testset "Each section round-trips through the editor" begin
        values = Dict(
            "storage" => Dict("data_dir" => "results", "templates_dir" => "setups",
                              "filename_template" => "{participant_id}_{short_id}",
                              "indep_vars_separator" => "+",
                              "timestamp_format" => "yyyy-mm-dd"),
            "ui" => Dict("language" => "lt"),
            "display" => Dict("screen_idx" => 3, "screen_name" => "DELL", "fullscreen" => false,
                              "width" => 1600, "height" => 900, "title" => "Stimulus \"A\"",
                              "dashboard_screen_idx" => 2, "dashboard_screen_name" => "EIZO"),
            "audio" => Dict("output_device" => "Laboratory Output"),
            "input" => Dict("min_response_s" => 0.3),
            "combining" => Dict("instructions" => false, "observer" => true,
                                "feedback" => false, "timeout" => true, "stimulus" => true),
            "plot" => Dict("raw" => false, "mean" => true, "spread" => "ci",
                           "smooth" => true, "fit" => false, "converted" => false,
                           "split" => "panels"),
            "control" => Dict("enabled" => true, "port" => 6000),
            "remote" => Dict("host" => "10.0.0.2", "port" => 5555, "read_timeout_s" => 30.0),
            "rig" => Dict("name" => "Booth 2", "pixel_pitch_mm" => 0.25,
                          "viewing_distance_mm" => 1000.0, "frame_ms" => 16.7),
        )
        @test Set(keys(values)) == Set(first.(PEM.settings_schema()))
        mktempdir() do dir
            path = joinpath(dir, "settings.toml")
            write(path, HANDWRITTEN)
            for (name, changes) in values
                @test PEM.write_settings!(name, changes; directory = dir, target = path) == path
                section = PEM.settings_section(name, dir)
                @test all(==(path), Base.values(section.sources))
                for (key, value) in changes
                    @test PEM.setting_in_effect(section, key) == value
                end
            end
            # The loaders read what the editor wrote
            @test resolve_data_dir(dir) == joinpath(dir, "results")
            @test resolve_templates_dir(dir) == joinpath(dir, "setups")
            display = load_display_config(dir)
            @test (display.screen_idx, display.screen_name, display.fullscreen) == (3, "DELL", false)
            @test display.window_size == (1600, 900)
            @test display.title == "Stimulus \"A\""
            @test (display.dashboard_screen_idx, display.dashboard_screen_name) == (2, "EIZO")
            @test load_audio_output_device(dir) == "Laboratory Output"
            @test load_combining_checks(dir) == [:observer, :timeout, :stimulus]
            @test load_plot_options(dir) == PlotOptions(raw = false, mean = true, spread = :ci,
                                                        smooth = true, fit = false,
                                                        converted = false, split = :panels)
            @test PEM.load_ui_language(dir) == "lt"
            @test load_control_config(dir) == (enabled = true, port = 6000)
            @test load_remote_worker_config(dir) == (host = "10.0.0.2", port = 5555,
                                                     read_timeout_s = 30.0)
            @test load_rig(dir)["frame_ms"] == 16.7
            # Every comment the file had is still in it
            # (but for the commented-out keys the edits set)
            comments = filter(line -> startswith(line, "#") && !occursin(r"^#\s*\w+\s*=", line),
                              split(HANDWRITTEN, "\n"))
            @test all(in(lines_of(path)), comments)
        end
    end

    @testset "An edit changes its own line and keeps the rest of the file" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.toml")
            write(path, HANDWRITTEN)
            before = lines_of(path)
            PEM.write_settings!("display", Dict("screen_name" => "DELL"); directory = dir)
            after = lines_of(path)
            # The active line changes; the commented-out copy below it does not
            @test length(after) == length(before)
            changed = findall(i -> before[i] != after[i], eachindex(before))
            @test before[only(changed)] == "screen_name = \"HDMI\""
            @test after[only(changed)] == "screen_name = \"DELL\""
            @test "# screen_name = \"HDMI\"" in after

            # A comment beside the value stays beside it, and a # inside a string is text
            PEM.write_settings!("storage", Dict("data_dir" => "runs #2"); directory = dir)
            @test "data_dir = \"runs #2\"   # beside this file" in lines_of(path)
            @test PEM.settings_section("storage", dir).values["data_dir"] == "runs #2"
            # Writing the value a file already has leaves it byte for byte
            text = read(path, String)
            PEM.write_settings!("display", Dict("screen_idx" => 2); directory = dir)
            @test read(path, String) == text
        end
    end

    @testset "A key the file lacks goes where people would write it" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.toml")
            write(path, HANDWRITTEN)
            # Only commented out: the commented line becomes the setting
            PEM.write_settings!("display", Dict("dashboard_screen_idx" => 3); directory = dir)
            @test "dashboard_screen_idx = 3" in lines_of(path)
            @test !any(contains("# dashboard_screen_idx"), lines_of(path))
            # Not there at all: after the section's last key, before the next section
            PEM.write_settings!("display", Dict("width" => 1600); directory = dir)
            after = lines_of(path)
            @test findfirst(==("width = 1600"), after) ==
                  findfirst(==("dashboard_screen_idx = 3"), after) + 1
            @test findfirst(==("width = 1600"), after) < findfirst(==("[audio]"), after)
            # Back to its default: commented out, and set again later in the same place
            PEM.write_settings!("display", Dict("dashboard_screen_idx" => nothing); directory = dir)
            @test "# dashboard_screen_idx = 3" in lines_of(path)
            @test load_display_config(dir).dashboard_screen_idx === nothing
            PEM.write_settings!("display", Dict("dashboard_screen_idx" => 2); directory = dir)
            @test "dashboard_screen_idx = 2" in lines_of(path)
            @test load_display_config(dir).dashboard_screen_idx == 2
            # A section the file lacks is added at its end
            PEM.write_settings!("ui", Dict("language" => "lt"); directory = dir, target = path)
            @test lines_of(path)[end-2:end] == ["[ui]", "language = \"lt\"", ""]
            # A file with Windows line ends keeps them
            write(path, replace(HANDWRITTEN, "\n" => "\r\n"))
            PEM.write_settings!("display", Dict("width" => 1024); directory = dir)
            text = read(path, String)
            @test occursin("width = 1024\r\n", text)
            @test !occursin(r"[^\r]\n", text)
        end
    end

    @testset "A value its loader refuses is refused before anything is written" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.toml")
            write(path, HANDWRITTEN)
            refused = [("display", "width", 0), ("display", "screen_idx", "2"),
                       ("display", "fullscreen", "yes"), ("display", "no_such_key", 1),
                       ("storage", "data_dir", "  "), ("ui", "language", ""),
                       ("combining", "observer", 1), ("remote", "port", 70000),
                       ("remote", "read_timeout_s", 0)]
            for (name, key, value) in refused
                @test_throws ArgumentError PEM.write_settings!(name, Dict(key => value);
                                                             directory = dir)
            end
            @test_throws ArgumentError PEM.write_settings!("network", Dict("port" => 1);
                                                         directory = dir)
            # A section that cannot do without a key cannot lose it, nor start without it
            @test_throws ArgumentError PEM.write_settings!("remote", Dict("host" => "lab");
                                                         directory = dir)
            @test read(path, String) == HANDWRITTEN
            # The loader refuses the same value written by hand, naming the file
            write(path, "[display]\nwidth = 0\n")
            failure = try load_display_config(dir); nothing catch err; err end
            @test failure isa ArgumentError
            @test occursin(dir, failure.msg) && occursin("width", failure.msg)
            write(path, "[remote]\nhost = \"lab\"\n")
            @test_throws ArgumentError load_remote_worker_config(dir)
            @test_throws ArgumentError PEM.write_settings!("remote", Dict("port" => nothing);
                                                         directory = dir)
            @test PEM.write_settings!("remote", Dict("port" => 5555); directory = dir) == path
            @test load_remote_worker_config(dir).port == 5555
        end
    end

    @testset "A file the editor cannot edit line by line is left to the operator" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.toml")
            # A value spanning several lines
            text = "[display]\ntitle = \"\"\"Two\nlines\"\"\"\n"
            write(path, text)
            @test_throws ArgumentError PEM.write_settings!("display", Dict("title" => "One");
                                                           directory = dir)
            @test read(path, String) == text
            # Not valid TOML, which the loaders skip with a warning: no setting is
            # written anywhere, since which file sets a key cannot be known
            text = "[display]\nwidth = \n"
            write(path, text)
            @test_throws ArgumentError PEM.write_settings!("display", Dict("title" => "One");
                                                           directory = dir)
            @test_throws ArgumentError PEM.write_settings!("storage", Dict("data_dir" => "x");
                                                           directory = dir)
            @test read(path, String) == text
        end
    end

    # The per-user file, the rig's, is one of the test's own
    with_user_file(f, path) = withenv(f, PEM.USER_SETTINGS_VARIABLE => path)

    @testset "A key is written back to the file it came from" begin
        mktempdir() do root
            user = joinpath(root, "config", "PsychophysicsManager", "settings.toml")
            with_user_file(user) do
                lab = joinpath(root, "settings.toml")
                write(lab, "[display]\nscreen_idx = 1\n")
                study = mkpath(joinpath(root, "study"))
                local_file = joinpath(study, "settings.toml")
                write(local_file, "[storage]\ndata_dir = \"data\"\n")
                @test PEM.settings_files(study) == [local_file, lab]

                @test PEM.write_settings!("display", Dict("screen_idx" => 2); directory = study) == lab
                @test PEM.write_settings!("storage", Dict("data_dir" => "out"); directory = study) ==
                      local_file
                @test read(local_file, String) == "[storage]\ndata_dir = \"out\"\n"
                @test read(lab, String) == "[display]\nscreen_idx = 2\n"
                # A key comes from one file, and is not moved into another
                @test_throws ArgumentError PEM.write_settings!("display", Dict("screen_idx" => 3);
                                                             directory = study, target = local_file)
                # A key no file sets joins its section's file
                @test PEM.write_settings!("display", Dict("width" => 900); directory = study) == lab

                # Where a section no file has goes: the project's nearest file, or the
                # per-user file for a section of the rig, unless another is chosen
                @test PEM.settings_targets(study) == [local_file, lab, user]
                @test PEM.write_settings!("combining", Dict("feedback" => false);
                                        directory = study) == local_file
                @test !isfile(user)
                @test PEM.write_settings!("audio", Dict("output_device" => "Out");
                                        directory = study) == user
                @test read(user, String) == "[audio]\noutput_device = \"Out\"\n"
                @test PEM.settings_files(study) == [local_file, lab, user]
                @test PEM.write_settings!("ui", Dict("language" => "lt"); directory = study,
                                        target = lab) == lab
                @test PEM.settings_section("ui", study).sources["language"] == lab
                # ... but only to a file that would be read from there
                elsewhere = mkpath(joinpath(root, "elsewhere"))
                @test_throws ArgumentError PEM.write_settings!(
                    "remote", Dict("port" => 1); directory = study,
                    target = joinpath(elsewhere, "settings.toml"))
                # Returning an unset key to its default writes nothing
                @test PEM.write_settings!("remote", Dict("read_timeout_s" => nothing);
                                        directory = study) == user
                @test !occursin("remote", read(user, String))
                # Changes that belong in two files are made one file at a time
                @test PEM.write_settings!("display", Dict("fullscreen" => true);
                                        directory = study, target = local_file) == local_file
                @test_throws ArgumentError PEM.write_settings!(
                    "display", Dict("screen_idx" => 3, "fullscreen" => false);
                    directory = study)
            end
        end

        # With no settings.toml at all, a section of the project goes into a new one in
        # the directory, and one of the rig into the per-user file
        mktempdir() do dir
            user = joinpath(dir, "user", "settings.toml")
            with_user_file(user) do
                path = joinpath(dir, "settings.toml")
                @test PEM.settings_targets(dir) == [path, user]
                @test isempty(PEM.settings_section("display", dir).sources)
                @test PEM.write_settings!("storage", Dict("data_dir" => "runs");
                                        directory = dir) == path
                @test read(path, String) == "[storage]\ndata_dir = \"runs\"\n"
                @test PEM.write_settings!("display", Dict("fullscreen" => true);
                                        directory = dir) == user
                @test read(user, String) == "[display]\nfullscreen = true\n"
            end
        end
    end

    @testset "Settings are read key by key: the project's, then the rig's" begin
        mktempdir() do root
            user = joinpath(root, "rig", "settings.toml")
            mkpath(dirname(user))
            write(user, """
            [display]
            screen_idx = 2
            fullscreen = true
            width = 1920

            [audio]
            output_device = "Booth speakers"

            [input]
            min_response_s = 0.25

            [storage]
            data_dir = "rig data"
            """)
            project = mkpath(joinpath(root, "study"))
            project_file = joinpath(project, "settings.toml")
            write(project_file, """
            [display]
            fullscreen = false

            [audio]
            output_device = "Study headphones"
            """)
            with_user_file(user) do
                @test PEM.user_settings_file() == user
                @test PEM.settings_files(project) == [project_file, user]
                # A key found only in the per-user file
                @test load_input_config(project).min_response_s == 0.25
                # A project's key wins, and the rig's other keys of the section stay
                display = load_display_config(project)
                @test (display.screen_idx, display.fullscreen, display.window_size) ==
                      (2, false, (1920, 800))
                @test load_audio_output_device(project) == "Study headphones"
                # The source of every key
                section = PEM.settings_section("display", project)
                @test section.sources == Dict("screen_idx" => user, "fullscreen" => project_file,
                                              "width" => user)
                # A relative directory is resolved against the file that sets it
                @test resolve_data_dir(project) == joinpath(dirname(user), "rig data")
                # A write lands in the file that set the key
                @test PEM.write_settings!("display", Dict("width" => 1280);
                                        directory = project) == user
                @test PEM.write_settings!("display", Dict("fullscreen" => true);
                                        directory = project) == project_file
                @test occursin("width = 1280", read(user, String))
                # The project's key returned to its default: the rig's value applies again
                @test PEM.write_settings!("audio", Dict("output_device" => nothing);
                                        directory = project) == project_file
                @test load_audio_output_device(project) == "Booth speakers"
                # A misspelt key is named with its file
                open(io -> print(io, "\n[input]\nmin_responce_s = 1\n"), project_file, "a")
                @test (project_file => "[input] min_responce_s") in unread_settings(project)
            end
        end
        # Without the variable, the file lies in the user's configuration directory
        withenv(PEM.USER_SETTINGS_VARIABLE => nothing,
                "XDG_CONFIG_HOME" => "/config", "APPDATA" => "C:\\Users\\x\\AppData") do
            expected = Sys.iswindows() ? joinpath("C:\\Users\\x\\AppData", "PsychophysicsManager") :
                       Sys.isapple() ? joinpath(homedir(), "Library", "Application Support",
                                                "PsychophysicsManager") :
                       joinpath("/config", "PsychophysicsManager")
            @test PEM.user_settings_file() == joinpath(expected, "settings.toml")
        end
    end

    @testset "The rig's constants" begin
        mktempdir() do root
            user = joinpath(root, "rig", "settings.toml")
            mkpath(dirname(user))
            write(user, """
            [rig]
            name = "Booth 2"
            pixel_pitch_mm = 0.25
            viewing_distance_mm = 1000
            frame_ms = 16.667
            """)
            project = mkpath(joinpath(root, "study"))
            with_user_file(user) do
                rig = load_rig(project)
                @test rig["name"] == "Booth 2"
                @test rig["frame_ms"] == 16.667
                # 0.25 mm at 1 m: 2 atan(0.125 / 1000) rad, about 0.859 arc min
                @test rig["pixel_arcmin"] ≈ 60 * rad2deg(2 * atan(0.125 / 1000))
                @test rig["pixel_arcmin"] ≈ 0.8594 atol = 1e-4
                # A constant named in the files is read, never reported as unread
                @test isempty(unread_settings(project))
                # A stated value wins over the derived one, and a project replaces a
                # constant while the rig's others stay
                write(joinpath(project, "settings.toml"), "[rig]\npixel_arcmin = 1.0\n")
                rig = load_rig(project)
                @test rig["pixel_arcmin"] == 1.0
                @test rig["name"] == "Booth 2" && rig["frame_ms"] == 16.667
                # A constant that is not a number is refused, naming the file
                write(joinpath(project, "settings.toml"), "[rig]\nframe_ms = \"fast\"\n")
                failure = try load_rig(project); nothing catch err; err end
                @test failure isa ArgumentError
                @test occursin(project, failure.msg) && occursin("frame_ms", failure.msg)
                # Without the two numbers nothing is derived
                write(user, "[rig]\nname = \"Booth 3\"\n")
                rm(joinpath(project, "settings.toml"))
                @test load_rig(project) == Dict{String, Any}("name" => "Booth 3")
                # A constant is written like any setting
                @test PEM.write_settings!("rig", Dict("frame_ms" => 8.333);
                                        directory = project) == user
                @test load_rig(project)["frame_ms"] == 8.333
            end
            with_user_file(joinpath(root, "nowhere", "settings.toml")) do
                @test isempty(load_rig(project))
            end
        end
    end

    @testset "Unit and label defaults per stimulus" begin
        mktempdir() do root
            user = joinpath(root, "rig", "settings.toml")
            mkpath(dirname(user))
            write(user, """
            [units.MarkerLayout]
            DistrN = "Distractors (rig)"
            Diff   = "Illusion (rig) = Diff * pixel_arcmin"
            """)
            project = mkpath(joinpath(root, "study"))
            project_file = joinpath(project, "settings.toml")
            write(project_file, """
            [storage]
            data_dir = "data"

            [units.MarkerLayout]
            Diff = "Illusion (project) = Diff * pixel_arcmin"
            """)
            nested = mkpath(joinpath(project, "sub"))
            nested_file = joinpath(nested, "settings.toml")
            write(nested_file, """
            [units.MarkerLayout]
            Test = "Offset = (Ref - Test) * pixel_arcmin"
            """)
            with_user_file(user) do
                # Read key by key, nearest file first, reporting the source per parameter
                defaults = PEM.load_unit_defaults("MarkerLayout", nested)
                @test defaults[:Test] == (text = "Offset = (Ref - Test) * pixel_arcmin",
                                          source = nested_file)
                @test defaults[:Diff] == (text = "Illusion (project) = Diff * pixel_arcmin",
                                          source = project_file)
                @test defaults[:DistrN] == (text = "Distractors (rig)", source = user)
                @test isempty(PEM.load_unit_defaults("Gabor", nested))
                # [units.*] tables and string entries are not reported as unread
                @test isempty(unread_settings(nested))

                # A non-string entry under [units.*], or a direct key under [units], is reported
                write(nested_file, """
                [units]
                stray = "nope"

                [units.MarkerLayout]
                Test = 42
                """)
                bad = unread_settings(nested)
                @test (nested_file => "[units] stray") in bad
                @test (nested_file => "[units.MarkerLayout] Test") in bad
                @test_throws ArgumentError PEM.load_unit_defaults("MarkerLayout", nested)
            end
        end

        # write_settings! on "units.<stimulus>": add, replace in place, remove, and quote
        mktempdir() do dir
            user = joinpath(dir, "rig", "settings.toml")
            project = mkpath(joinpath(dir, "project"))
            path = joinpath(project, "settings.toml")
            write(path, "# Project settings\n[storage]\ndata_dir = \"data\"\n")
            with_user_file(user) do
                # New section goes to the project's nearest file
                @test PEM.write_settings!("units.MarkerLayout",
                    Dict("Diff" => "Illusion = Diff * pixel_arcmin"); directory = project) == path
                @test occursin("[units.MarkerLayout]", read(path, String))
                @test PEM.load_unit_defaults("MarkerLayout", project)[:Diff] ==
                      (text = "Illusion = Diff * pixel_arcmin", source = path)

                # Replace in place, keeping comments and other sections
                @test PEM.write_settings!("units.MarkerLayout",
                    Dict("Diff" => "Illusion (arcmin) = Diff * pixel_arcmin");
                    directory = project) == path
                @test PEM.load_unit_defaults("MarkerLayout", project)[:Diff].text ==
                      "Illusion (arcmin) = Diff * pixel_arcmin"
                @test occursin("# Project settings", read(path, String))

                # Remove a key with nothing
                @test PEM.write_settings!("units.MarkerLayout",
                    Dict("Diff" => nothing); directory = project) == path
                @test isempty(PEM.load_unit_defaults("MarkerLayout", project))
                @test "# Diff = \"Illusion (arcmin) = Diff * pixel_arcmin\"" in lines_of(path)

                # Non-bare stimulus name is quoted in the TOML header and parses back
                @test PEM.write_settings!("units.my stim.v1",
                    Dict("x" => "Scaled = 2 * x"); directory = project) == path
                @test occursin("[units.\"my stim.v1\"]", read(path, String))
                @test PEM.load_unit_defaults("my stim.v1", project)[:x] ==
                      (text = "Scaled = 2 * x", source = path)
                @test isempty(unread_settings(project))
            end
        end
    end

    @testset "Plot options ([plot])" begin
        @test !("plot" in PEM.RIG_SECTIONS)
        @test_throws ArgumentError PlotOptions(spread = :iqr)
        @test_throws ArgumentError PlotOptions(split = :stacked)

        mktempdir() do root
            user = joinpath(root, "rig", "settings.toml")
            project = mkpath(joinpath(root, "study"))
            project_file = joinpath(project, "settings.toml")
            write(project_file, "[storage]\ndata_dir = \"data\"\n")

            with_user_file(user) do
                # Defaults when no file defines [plot]
                @test load_plot_options(project) == PlotOptions(
                    raw = true, mean = true, spread = :sem, smooth = false,
                    fit = true, converted = true, split = :pooled,
                )

                # With no [plot] section anywhere, set_plot_option! writes to the per-user file
                @test !isfile(user)
                @test set_plot_option!(:smooth, true; directory = project) == user
                @test isfile(user)
                @test !occursin("[plot]", read(project_file, String))
                @test load_plot_options(project).smooth == true
                @test set_plot_option!(:spread, :ci; directory = project) == user
                @test load_plot_options(project).spread === :ci

                # Once the project file has a [plot] section, project values win key-by-key
                # and set_plot_option! writes new keys into the project file
                open(project_file, "a") do io
                    print(io, "\n[plot]\nraw = false\nsplit = \"overlaid\"\n")
                end
                opts = load_plot_options(project)
                @test opts.raw == false && opts.split === :overlaid
                @test opts.smooth == true && opts.spread === :ci   # inherited from per-user file
                @test set_plot_option!(:fit, false; directory = project) == project_file
                @test load_plot_options(project).fit == false
                @test occursin("fit = false", read(project_file, String))
                @test set_plot_option!(:split, :panels; directory = project) == project_file
                @test load_plot_options(project).split === :panels
                @test isempty(unread_settings(project))

                # A refused spread (and split) is rejected before writing and on loading
                @test_throws ArgumentError set_plot_option!(:spread, :range; directory = project)
                @test_throws ArgumentError set_plot_option!(:split, :grid; directory = project)
                write(project_file, "[plot]\nspread = \"bogus\"\n")
                err = try load_plot_options(project); nothing catch e; e end
                @test err isa ArgumentError
                @test occursin("spread", err.msg) && occursin(project, err.msg)
            end
        end
    end
end
