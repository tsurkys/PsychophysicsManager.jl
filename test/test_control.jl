using Dates
using Sockets

# The control channel (src/UI/control_channel.jl): a script or an AI agent sends the
# dashboard's commands as JSON lines and reads the session back.

@testset "Control channel" begin

    request(controller, payload; client = PsychophysicsManager.ControlClient(nothing)) =
        PsychophysicsManager.JSON3.read(
            PsychophysicsManager.handle_control_request(controller,
                                                        PsychophysicsManager.JSON3.write(payload),
                                                        client),
            Dict{String, Any})

    # A connection to a listening channel; `send` writes one request and reads its reply
    function connect_to(port)
        socket = Sockets.connect(Sockets.localhost, port)
        send(payload) = (println(socket, PsychophysicsManager.JSON3.write(payload));
                         PsychophysicsManager.JSON3.read(readline(socket), Dict{String, Any}))
        return socket, send
    end

    @testset "A request the protocol cannot carry out is an error, not a refusal" begin
        controller = DashboardController()
        raw = PsychophysicsManager.handle_control_request(controller, "start please")
        @test PsychophysicsManager.JSON3.read(raw, Dict{String, Any})["ok"] == false
        unknown = request(controller, Dict("command" => "respond", "response" => 1, "id" => 7))
        # No command supplies an answer: those come from the participant alone
        @test unknown["ok"] == false && occursin("no command `respond`", unknown["error"])
        @test unknown["id"] == 7
        @test !occursin("respond", join(PsychophysicsManager.control_command_names()))
        missing_argument = request(controller, Dict("command" => "mark_outlier"))
        @test occursin("needs `trial`", missing_argument["error"])
        wrong_kind = request(controller, Dict("command" => "repeat_trial", "trial" => 1,
                                              "when" => "later"))
        @test occursin("\"after\" or \"now\"", wrong_kind["error"])
        # Neither is a command the operator sees
        @test !any(entry -> occursin("control channel", last(entry)), controller.messages)
    end

    @testset "Readings answer without touching the session" begin
        controller = DashboardController()
        client = PsychophysicsManager.ControlClient(nothing)
        hello = request(controller, Dict("command" => "hello", "client" => "analysis.py");
                        client)
        @test hello["protocol"] == PsychophysicsManager.CONTROL_PROTOCOL_VERSION
        @test "start" in hello["commands"] && "status" in hello["commands"]
        @test hello["language"] == "en"
        @test controller.message == "analysis.py connected to the control channel."
        status = request(controller, Dict("command" => "status"))
        @test status["ok"] && status["session"] === nothing
        @test status["actions"]["can_start"] == false
        @test request(controller, Dict("command" => "trials"))["trials"] == Any[]
        # A reading is not among the operator's messages: a client polling the
        # status would bury them
        @test count(entry -> occursin("status", last(entry)), controller.messages) == 0
    end

    @testset "Each command does what its control does, with the same message" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml",
                      "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                template = SessionContext("T", ExperimentParameters("Channel", :level,
                                                                    [1.0, 2.0], 1),
                                          BaseStimulusParameters(1.0), ConstantStimuli())
                template.engine_name = "EmulatorEngine"
                save_session_checkpoint(template, resolve_templates_dir(); filename = "base.json")

                controller = DashboardController()
                channel = PsychophysicsManager.start_control_channel(controller; port = 0)
                @test occursin("listens on 127.0.0.1:$(channel.port)", controller.message)
                socket, send = connect_to(channel.port)
                try
                    send(Dict("command" => "hello", "client" => "agent"))
                    templates = send(Dict("command" => "templates"))["templates"]
                    @test [entry["name"] for entry in templates] == ["base"]

                    # A template by name, for a participant, with a parameter changed
                    prepared = send(Dict("command" => "new_session", "template" => "base",
                                         "participant" => "P1",
                                         "parameters" => Dict("ex_par.repeats" => 2)))
                    @test prepared["ok"] && prepared["message"] == controller.message
                    session = controller.session
                    @test session.participant_id == "P1" && session.ex_par.repeats == 2
                    status = send(Dict("command" => "status"))
                    @test status["session"]["state"] == "READY"
                    @test status["actions"]["can_start"]
                    # A change the session refuses is refused all together, in the
                    # panel's words, and the session stays as it was
                    refused = send(Dict("command" => "set_parameters",
                                        "parameters" => Dict("ex_par.repeats" => 3,
                                                             "stim_par.no_such" => 1)))
                    @test !refused["ok"] && refused["message"] == controller.message
                    @test occursin("no_such", refused["message"])
                    @test session.ex_par.repeats == 2
                    # A new session whose parameters are refused is still prepared,
                    # and the reply says so
                    partly = send(Dict("command" => "new_session", "template" => "base",
                                       "parameters" => Dict("stim_par.no_such" => 1)))
                    @test !partly["ok"] && occursin("prepared as the template", partly["message"])
                    @test controller.session !== session && controller.session.state == READY
                    session = controller.session
                    @test send(Dict("command" => "set_parameters",
                                    "parameters" => Dict("ex_par.repeats" => 2)))["ok"]

                    # Pause before the start is refused as the greyed-out button is
                    paused = send(Dict("command" => "pause", "id" => "p1"))
                    @test paused == Dict("ok" => false, "id" => "p1",
                                         "message" => "Only a running session can be paused.")

                    @test send(Dict("command" => "start"))["ok"]
                    wait(controller.run_task)
                    @test session.state == FINISHED
                    @test send(Dict("command" => "status"))["session"]["planned_trials"] == 4
                    # After it, the parameters set are a new session's, which start_new runs
                    @test send(Dict("command" => "set_parameters",
                                    "parameters" => Dict("ex_par.repeats" => 1)))["ok"]
                    prepared = PsychophysicsManager.prepared_session(controller)
                    @test prepared.ex_par.repeats == 1 && session.ex_par.repeats == 2
                    @test controller.session === session
                    trials = send(Dict("command" => "trials"))["trials"]
                    @test length(trials) == 4
                    @test all(trial -> haskey(trial["values"], "level"), trials)
                    @test all(trial -> trial["counted"] && trial["origin"] == "method", trials)
                    @test length(send(Dict("command" => "trials", "after" => 3))["trials"]) == 1

                    @test send(Dict("command" => "mark_outlier", "trial" => 2))["ok"]
                    again = send(Dict("command" => "mark_outlier", "trial" => 2))
                    @test !again["ok"] && again["message"] == controller.message
                    @test !session.history[2].is_valid
                    # A comment, about a trial or the session, after the session has ended
                    @test send(Dict("command" => "add_comment", "text" => "Yawned",
                                    "trial" => 3))["ok"]
                    @test send(Dict("command" => "add_comment", "text" => "Glasses off"))["ok"]
                    empty_comment = send(Dict("command" => "add_comment", "text" => "  "))
                    @test !empty_comment["ok"] && empty_comment["message"] == "Write the comment first."
                    comments = send(Dict("command" => "comments"))["comments"]
                    @test [(c["trial"], c["text"]) for c in comments] ==
                          [(3, "Yawned"), (nothing, "Glasses off")]
                    @test length(load_session(session.save_path).comments) == 2
                    stop = send(Dict("command" => "stop"))
                    @test !stop["ok"] && stop["message"] == controller.message

                    # Every command is in the operator's messages, with who sent it
                    texts = [entry["text"]
                             for entry in send(Dict("command" => "messages"))["messages"]]
                    @test "agent via the control channel: start" in texts
                    @test "agent via the control channel: mark_outlier trial=2" in texts
                    since = controller.messages[end][1]
                    @test isempty(send(Dict("command" => "messages", "since" => since))["messages"])
                finally
                    close(socket)
                end
                timedwait(() -> isempty(channel.connections), 5.0)
                @test controller.message == "agent left the control channel."
                PsychophysicsManager.stop_control_channel!(channel)
                @test_throws Base.IOError Sockets.connect(Sockets.localhost, channel.port)
            end
        end
    end

    @testset "The rules of the controls hold for a program" begin
        # A script's session, which the script's loop runs: the channel only moves it
        session = SessionContext("S", ExperimentParameters("Script", :level, [1.0], 3),
                                 BaseStimulusParameters(1.0), ConstantStimuli())
        controller = DashboardController(session)
        @test request(controller, Dict("command" => "start"))["ok"]
        @test session.state == RUNNING
        @test request(controller, Dict("command" => "pause"))["ok"]
        @test session.state == PAUSED
        resumed = request(controller, Dict("command" => "resume"))
        @test resumed["ok"] && resumed["message"] == "Resumed."
        @test !request(controller, Dict("command" => "resume"))["ok"]
        # Stop asks first, as the button does, and a second request confirms it
        first_stop = request(controller, Dict("command" => "stop"))
        @test !first_stop["ok"] && first_stop["message"] == controller.message
        @test session.state == RUNNING
        @test request(controller, Dict("command" => "stop"))["ok"]
        @test session.state == ABORTED
        # Nothing to undo is said, not ignored
        nothing_undone = @test_logs (:warn, r"Nothing to undo") request(controller,
                                                                        Dict("command" => "undo"))
        @test !nothing_undone["ok"] && nothing_undone["message"] == "Nothing was undone."
        # A participant left empty is refused, as in the participant field
        @test !request(controller, Dict("command" => "set_participant",
                                        "participant" => " "))["ok"]
    end

    @testset "The listener starts only when the settings turn it on" begin
        mktempdir() do dir
            cd(dir) do
                controller = DashboardController()
                @test PsychophysicsManager.start_control_channel_from_settings(controller) === nothing
                write("settings.toml", "[control]\nenabled = false\nport = 5556\n")
                @test PsychophysicsManager.start_control_channel_from_settings(controller) === nothing

                probe = Sockets.listen(Sockets.localhost, 0)
                port = Int(last(Sockets.getsockname(probe)))
                # A port another program holds is reported, and the dashboard goes on
                write("settings.toml", "[control]\nenabled = true\nport = $port\n")
                @test PsychophysicsManager.start_control_channel_from_settings(controller) === nothing
                @test occursin("could not listen on 127.0.0.1:$port", controller.message)
                close(probe)
                channel = PsychophysicsManager.start_control_channel_from_settings(controller)
                @test channel.port == port
                socket, send = connect_to(port)
                @test send(Dict("command" => "hello"))["ok"]
                # Stopping the channel closes the connections it holds
                PsychophysicsManager.stop_control_channel!(channel)
                @test eof(socket)
                close(socket)
            end
        end
    end

    @testset "Filtered sessions and series readings" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                function saved(participant, start; experiment = "Oppel",
                               stim = MarkerLayout(Ref = 10.0),
                               method = ConstantStimuli(),
                               ex_par = ExperimentParameters(experiment, :Diff, [-5.0, 5.0], 1),
                               tags = String[], state = FINISHED, trials = 2)
                    s = SessionContext(participant, ex_par, stim, method; tags = copy(tags))
                    s.engine_name = "EmulatorEngine"
                    s.start_time = start
                    s.state = state
                    for i in 1:trials
                        push!(s.history, Trial(i, start, start + 0.5, [1.0], 1, true))
                    end
                    return save_session_checkpoint(s, resolve_data_dir())
                end

                t1 = datetime2unix(DateTime(2026, 6, 1, 9, 0, 0))
                t2 = datetime2unix(DateTime(2026, 6, 2, 10, 0, 0))
                t3 = datetime2unix(DateTime(2026, 6, 3, 11, 0, 0))
                p1 = saved("P1", t1; stim = MarkerLayout(Ref = 10.0), tags = ["pilot", "ok"])
                p2 = saved("P1", t2; stim = MarkerLayout(Ref = 10.0), tags = ["pilot"], state = PAUSED)
                p3 = saved("P2", t3; experiment = "Oppel", stim = MarkerLayout(Ref = 20.0),
                           tags = ["main"])

                controller = DashboardController()
                hello = request(controller, Dict("command" => "hello"))
                @test "series" in hello["commands"]

                # sessions reading with filters
                all_sessions = request(controller, Dict("command" => "sessions"))
                @test all_sessions["ok"] && length(all_sessions["sessions"]) == 3
                by_p1 = request(controller, Dict("command" => "sessions", "participant" => "P1"))
                @test by_p1["ok"] && [r["path"] for r in by_p1["sessions"]] == abspath.([p2, p1])
                by_cont = request(controller, Dict("command" => "sessions", "state" => "continuable"))
                @test by_cont["ok"] && [r["path"] for r in by_cont["sessions"]] == [abspath(p2)]
                by_tags_list = request(controller, Dict("command" => "sessions",
                                                        "tags" => ["pilot", "ok"]))
                @test by_tags_list["ok"] && [r["path"] for r in by_tags_list["sessions"]] == [abspath(p1)]
                by_tags_str = request(controller, Dict("command" => "sessions", "tags" => "pilot, ok"))
                @test by_tags_str["ok"] && [r["path"] for r in by_tags_str["sessions"]] == [abspath(p1)]
                by_date = request(controller, Dict("command" => "sessions",
                                                   "from" => "2026-06-02", "to" => "2026-06-02"))
                @test by_date["ok"] && [r["path"] for r in by_date["sessions"]] == [abspath(p2)]

                # series reading, unfiltered and filtered
                all_series = request(controller, Dict("command" => "series"))
                @test all_series["ok"] && length(all_series["series"]) == 2
                s_p2, s_p1 = all_series["series"]
                @test s_p2["participant"] == "P2" && s_p2["variables"] == "Ref = 20"
                @test s_p2["repetitions"] == 1 && s_p2["sessions"] == [abspath(p3)]
                @test s_p1["participant"] == "P1" && s_p1["variables"] == "Ref = 10"
                @test s_p1["repetitions"] == 2 && s_p1["continuable"] == true
                @test s_p1["key"] == abspath(p1)
                @test s_p1["sessions"] == abspath.([p1, p2])

                filtered_series = request(controller, Dict("command" => "series",
                                                           "participant" => "P1",
                                                           "state" => "FINISHED"))
                @test filtered_series["ok"] && length(filtered_series["series"]) == 1
                @test filtered_series["series"][1]["sessions"] == [abspath(p1)]

                # Unknown filters and malformed values are refused
                bad_sessions = request(controller, Dict("command" => "sessions", "unknown_key" => "x"))
                @test !bad_sessions["ok"] && occursin("unknown_key", bad_sessions["error"])
                bad_series = request(controller, Dict("command" => "series", "bogus" => 1))
                @test !bad_series["ok"] && occursin("bogus", bad_series["error"])
                bad_state = request(controller, Dict("command" => "sessions", "state" => "NO_SUCH"))
                @test !bad_state["ok"] && occursin("NO_SUCH", bad_state["error"])
                bad_date = request(controller, Dict("command" => "series", "from" => "2026-99"))
                @test !bad_date["ok"] && occursin("from", bad_date["error"])
            end
        end
    end
end
