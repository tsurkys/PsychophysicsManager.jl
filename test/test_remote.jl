# The external-process bridge: a worker outside Julia owns the
# display and the input device and answers one JSON line per presentation. The
# mock worker below is that other process, written in Julia and reachable over a
# localhost socket, so the whole bridge — handshake, presentation, response
# window, feedback, and every way the connection can fail — is exercised without
# MATLAB, Psychtoolbox, or a second machine.

using Sockets
using JSON3
using Logging

_worker_send(sock, payload) = (println(sock, JSON3.write(payload)); flush(sock))

"""
    serve_mock_worker(; kwargs...) -> (port, task, log)

Starts a PsychophysicsManager presentation worker on an ephemeral localhost port and
returns the port to connect to, the task serving it, and the list of requests it
received (so a test can assert what actually crossed the connection).

`responses` is what the worker answers to successive `present` commands: a
number, `:timeout` for a closed response window, `nothing` for a worker that
reads no input, or a `Dict` used verbatim as the reply line — which is how a
malformed or implausibly stamped answer is staged.

`drop_after` closes the connection instead of answering the *n*-th presentation;
`silent` keeps it open and answers nothing at all. They are the two different
ways a worker stops being there.

`capabilities` is the list its hello reply names, and `stimuli` the stimuli it
declares with their defaults (a `NamedTuple` keeps their order on the wire). The
presentations numbered in
`hold` are answered only when an `abandon` command names them, with
`"abandoned"`; an `abandon` naming a presentation already answered is ignored.
"""
function serve_mock_worker(; responses = Any[],
                           display_info = Dict("display_resolution" => "800x600"),
                           worker = "mock-worker",
                           protocol = PsychophysicsManager.REMOTE_PROTOCOL_VERSION,
                           capabilities = nothing,
                           stimuli = nothing,
                           hello_reply = nothing,
                           message_reply = nothing,
                           drop_after = nothing,
                           silent = false,
                           hold = Int[])
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    log = Any[]

    task = @async begin
        sock = Sockets.accept(server)
        try
            presented = 0
            held = nothing
            while true
                line = readline(sock)
                isempty(line) && break
                request = JSON3.read(line)
                push!(log, request)
                command = request.command

                if command == "hello"
                    reply = Dict{String, Any}("worker" => worker, "protocol" => protocol,
                                              "display_info" => display_info)
                    capabilities === nothing || (reply["capabilities"] = capabilities)
                    stimuli === nothing || (reply["stimuli"] = stimuli)
                    _worker_send(sock, hello_reply === nothing ? reply : hello_reply)
                elseif command == "abandon"
                    # No reply of its own: the presentation it ends is answered instead
                    if held !== nothing && request.presentation == held
                        held = nothing
                        _worker_send(sock, Dict{String, Any}("response" => "abandoned"))
                    end
                elseif command == "present"
                    presented += 1
                    drop_after !== nothing && presented > drop_after && break
                    silent && continue
                    request.presentation in hold && (held = request.presentation; continue)
                    answer = presented <= length(responses) ? responses[presented] : nothing
                    if answer isa Dict
                        _worker_send(sock, answer)
                    else
                        # The response timestamp is taken here, where the input
                        # device is read, and not by the Core when the reply lands
                        onset = time()
                        _worker_send(sock, Dict{String, Any}(
                            "response" => answer === :timeout ? "timeout" : answer,
                            "onset" => onset,
                            "timestamp_response" => time()))
                    end
                elseif command == "feedback"
                    _worker_send(sock, Dict{String, Any}("ok" => true))
                elseif command == "message"
                    _worker_send(sock, message_reply === nothing ? Dict{String, Any}("ok" => true) : message_reply)
                elseif command == "close"
                    break
                else
                    _worker_send(sock, Dict{String, Any}(
                        "error" => "unknown command $command"))
                end
            end
        finally
            close(sock)
            close(server)
        end
    end

    return (port = port, task = task, log = log)
end

@testset "RemoteEngine (external-process bridge)" begin

    @testset "Handshake" begin
        mock = serve_mock_worker()
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            @test engine.worker == "mock-worker"
            @test mock.log[1].command == "hello"
            @test mock.log[1].protocol == PsychophysicsManager.REMOTE_PROTOCOL_VERSION

            # What the worker knows about its own display reaches the session
            # record: the engine name says only that a remote worker presented
            info = display_info(engine)
            @test info["display_resolution"] == "800x600"
            @test info["remote_worker"] == "mock-worker"
            @test occursin(string(mock.port), info["remote_address"])
        finally
            close_engine!(engine)
        end

        # A worker names its own version, optionally: the session records the worker
        # as the program that presented it, and its version or that none is known
        stim = BaseStimulusParameters(1.0)
        @test stimulus_identity(engine, stim) == ("remote worker mock-worker",
                                                  UNKNOWN_STIMULUS_VERSION)
        versioned = serve_mock_worker(hello_reply = Dict(
            "worker" => "versioned", "protocol" => PsychophysicsManager.REMOTE_PROTOCOL_VERSION,
            "version" => "2.1"))
        engine = RemoteEngine(Sockets.localhost, versioned.port)
        try
            @test stimulus_identity(engine, stim) == ("remote worker versioned", "2.1")
            session = SessionContext("P", ExperimentParameters("Remote", :x, [1.0], 1), stim,
                                     ConstantStimuli())
            start_session!(session, engine)
            @test session.environment["stimulus_program"] == "remote worker versioned"
            @test session.environment["stimulus_version"] == "2.1"
        finally
            close_engine!(engine)
        end

        # A program that is not a worker is refused at connection time
        wrong = serve_mock_worker(hello_reply = Dict("greeting" => "hello"))
        @test_throws ErrorException RemoteEngine(Sockets.localhost, wrong.port)

        # So is one that speaks a different version of the line protocol, and
        # one that names no version at all
        old = serve_mock_worker(protocol = PsychophysicsManager.REMOTE_PROTOCOL_VERSION + 1)
        @test_throws ErrorException RemoteEngine(Sockets.localhost, old.port)

        silent_version = serve_mock_worker(hello_reply = Dict("worker" => "nameless"))
        @test_throws ErrorException RemoteEngine(Sockets.localhost, silent_version.port)

        # And a port with nothing behind it fails immediately, not on trial 1
        @test_throws ErrorException RemoteEngine(Sockets.localhost, 1)
    end

    @testset "A worker driven over the standard streams" begin
        # The other transport: a spawned process reached through its own stdin
        # and stdout, with no socket anywhere
        script = joinpath(@__DIR__, "stdio_worker.jl")
        child = open(`$(Base.julia_cmd()) --startup-file=no
                      --project=$(Base.active_project()) $script
                      $(PsychophysicsManager.REMOTE_PROTOCOL_VERSION)`, "r+")
        engine = RemoteEngine(child; address = "stdio")
        try
            @test engine.worker == "stdio-worker"
            @test display_info(engine)["display_resolution"] == "640x480"

            result = present_stimulus(engine, BaseStimulusParameters(100.0), [100.0])
            @test result.response == 1
            @test result.onset > 1.0e9
            @test result.timestamp_response >= result.onset
        finally
            close_engine!(engine)
        end
        @test timedwait(() -> !process_running(child), 10.0) === :ok
    end

    @testset "A full session over a localhost socket" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

                mock = serve_mock_worker(responses = Any[1, -1, 1, -1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                ex_par = ExperimentParameters("RemoteCS", :duration_ms,
                                              [100.0, 200.0], 2)
                session = SessionContext("P-remote", ex_par,
                                         BaseStimulusParameters(100.0),
                                         ConstantStimuli())
                try
                    run_experiment!(session, engine; report = :silent)
                finally
                    close_engine!(engine)
                end

                @test session.state == FINISHED
                @test session.engine_name == "RemoteEngine"
                @test length(session.history) == 4
                @test [t.response for t in session.history] == [1, 0, 1, 0]

                # The worker's clock is the session's clock: every trial
                # is stamped by the process that read the input device
                @test all(t.onset_source == :engine for t in session.history)
                @test all(t.timestamp_response >= t.timestamp_onset
                          for t in session.history)

                # The worker was told what to present, in the shape a session
                # file stores it in, with the trial's values already bound
                presents = filter(r -> r.command == "present", mock.log)
                @test length(presents) == 4
                @test presents[1].stimulus._type == "BaseStimulusParameters"
                @test presents[1].stimulus.fields.duration_ms in (100.0, 200.0)
                @test presents[1].values ==
                      [presents[1].stimulus.fields.duration_ms]
                @test [r.presentation for r in presents] == [1, 2, 3, 4]

                # It identified itself in the session's environment record
                @test session.environment["remote_worker"] == "mock-worker"
                @test session.environment["display_resolution"] == "800x600"

                # The connection closed with a goodbye, and the worker is done
                @test mock.log[end].command == "close"
                @test timedwait(() -> istaskdone(mock.task), 5.0) === :ok
                @test !istaskfailed(mock.task)
            end
        end
    end

    @testset "The engine contract holds across the connection" begin
        mock = serve_mock_worker(responses = Any[1, -1, 1])
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            report = verify_engine(engine, BaseStimulusParameters(100.0);
                                   vals = [100.0])
            @test report.probes == 3
            @test !report.render_only
            @test report.reports_onset
            @test report.reports_response_time

            # The response window reached the worker, which is the side that
            # enforces it — it reads the input device
            presents = filter(r -> r.command == "present", mock.log)
            @test all(r -> r.timeout_s == 1.0, presents)
        finally
            close_engine!(engine)
        end
    end

    @testset "A closed response window" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml",
                      "[storage]\ndata_dir = \"out\"\n[input]\nmin_response_s = 0.2\n")

                mock = serve_mock_worker(responses = Any[:timeout, 1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                ex_par = ExperimentParameters("RemoteTimeout", :duration_ms,
                                              [100.0], 2)
                session = SessionContext("P-timeout", ex_par,
                                         BaseStimulusParameters(100.0),
                                         ConstantStimuli())
                set_timeout!(session, 0.25)
                try
                    run_experiment!(session, engine; report = :silent)
                finally
                    close_engine!(engine)
                end

                @test length(session.history) == 2
                # The window that closed is written down as such, not as a "no"
                @test session.history[1].response === :timeout
                @test session.history[1].correct === nothing
                @test session.history[2].response == 1

                presents = filter(r -> r.command == "present", mock.log)
                @test all(r -> r.timeout_s == 0.25, presents)
                # So did the settings' shortest response time, for the worker to apply
                @test all(r -> r.min_response_s == 0.2, presents)
            end
        end
    end

    @testset "A worker that reads no input" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

                # A render-only worker answers null, and the Core collects the
                # response from the active source exactly as for a local engine
                mock = serve_mock_worker(responses = Any[nothing, nothing])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                ex_par = ExperimentParameters("RemoteRenderOnly", :duration_ms,
                                              [100.0], 2)
                session = SessionContext("P-render", ex_par,
                                         BaseStimulusParameters(100.0),
                                         ConstantStimuli())
                try
                    with_response_source(ScriptedResponseSource([1, -1])) do
                        run_experiment!(session, engine; report = :silent)
                    end
                finally
                    close_engine!(engine)
                end

                @test [t.response for t in session.history] == [1, 0]
                # The onset still came from the worker; only the answer did not
                @test all(t.onset_source == :engine for t in session.history)
            end
        end
    end

    @testset "Feedback is announced by the process that owns the screen" begin
        mock = serve_mock_worker(responses = Any[1])
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            present_feedback(engine, true)
            @test mock.log[end].command == "feedback"
            @test mock.log[end].correct === true
        finally
            close_engine!(engine)
        end
    end

    @testset "A dropped connection stops the session, continuable" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

                mock = serve_mock_worker(responses = Any[1, -1, 1, -1],
                                         drop_after = 2)
                engine = RemoteEngine(Sockets.localhost, mock.port)
                ex_par = ExperimentParameters("RemoteDrop", :duration_ms,
                                              [100.0, 200.0], 2)
                session = SessionContext("P-drop", ex_par,
                                         BaseStimulusParameters(100.0),
                                         ConstantStimuli())

                with_logger(NullLogger()) do
                    @test_throws ErrorException run_experiment!(session, engine;
                                                                report = :silent)
                end

                # The session stopped instead of hanging, and what was measured
                # before the worker vanished is on disk, ready to be continued
                @test session.state == PAUSED
                @test length(session.history) == 2
                @test load_session(session.save_path).state == PAUSED
                close_engine!(engine)
            end
        end
    end

    @testset "A worker that stops answering" begin
        mock = serve_mock_worker(silent = true)
        engine = RemoteEngine(Sockets.localhost, mock.port; read_timeout_s = 0.3)
        try
            failure = try
                present_stimulus(engine, BaseStimulusParameters(100.0), [100.0])
                nothing
            catch e
                e
            end
            @test failure isa ErrorException
            @test occursin("read_timeout_s", failure.msg)

            # A worker that answered nothing is not asked again
            @test_throws ErrorException present_stimulus(
                engine, BaseStimulusParameters(100.0), [100.0])
        finally
            close_engine!(engine)
        end

        # Left unset, the transport is patient: it is the operator, not a
        # transport deadline, that ends a legitimate long response window
        patient = serve_mock_worker(responses = Any[1])
        engine2 = RemoteEngine(Sockets.localhost, patient.port)
        try
            @test engine2.read_timeout_s === nothing
        finally
            close_engine!(engine2)
        end
    end

    @testset "A presentation awaiting the worker's reply is not abandoned" begin
        # A reply abandoned on the way would answer the next command
        mock = serve_mock_worker(silent = true)
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            @test isempty(engine.capabilities)
            @test can_abandon_presentation(engine)
            waiting = @async try
                present_stimulus(engine, BaseStimulusParameters(100.0), [100.0])
            catch
            end
            timedwait(() -> !can_abandon_presentation(engine), 5.0)
            @test !can_abandon_presentation(engine)
            # Nor is the worker asked to end it: it did not say it can
            @test !abandon_presentation!(engine)
            @test !any(r -> r.command == "abandon", mock.log)
        finally
            close_engine!(engine)
        end

        # The optional commands a worker answers are a list of their names
        listless = serve_mock_worker(hello_reply = Dict(
            "worker" => "listless", "protocol" => PsychophysicsManager.REMOTE_PROTOCOL_VERSION,
            "capabilities" => "abandon"))
        @test_throws ErrorException RemoteEngine(Sockets.localhost, listless.port)
    end

    @testset "A worker that ends a presentation when asked" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

                # The first presentation waits until it is abandoned; a capability this
                # PsychophysicsManager does not know is kept and never used
                mock = serve_mock_worker(capabilities = ["abandon", "a-later-command"],
                                         hold = [1], responses = Any[nothing, 1, -1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                @test engine.capabilities == ["abandon", "a-later-command"]
                ex_par = ExperimentParameters("RemoteNow", :duration_ms, [100.0, 200.0], 1)
                s = SessionContext("P-now", ex_par, BaseStimulusParameters(100.0),
                                   ConstantStimuli())
                events = Symbol[]
                on_session_event!((_, event) -> push!(events, event), s)
                loop = @async run_experiment!(s, engine; report = :silent)
                waiting = Float64[]
                chosen = Float64[]
                try
                    @test timedwait(() -> engine.awaiting == "present", 10.0) === :ok
                    @test can_abandon_presentation(engine)
                    waiting = collect(Float64, only(filter(r -> r.command == "present",
                                                           mock.log)).values)
                    chosen = waiting == [100.0] ? [200.0] : [100.0]
                    @test present_condition!(s, chosen; when = :now)
                    @test timedwait(() -> istaskdone(loop), 10.0) === :ok
                    @test !istaskfailed(loop)
                finally
                    close_engine!(engine)
                end

                # The command named the presentation it ended, whose "abandoned" was not
                # recorded: the chosen condition came first, the abandoned one after it
                abandons = filter(r -> r.command == "abandon", mock.log)
                @test length(abandons) == 1 && only(abandons).presentation == 1
                @test :trial_abandoned in events
                @test [t.indep_var_vals for t in s.history] == [chosen, waiting]
                @test [t.origin for t in s.history] == [:operator, :method]
                @test s.state == FINISHED
                @test count(r -> r.command == "present", mock.log) == 3

                # Stop, as the dashboard's control sends it, does not wait for an answer
                # that may never come
                mock = serve_mock_worker(capabilities = ["abandon"], hold = [1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                s = SessionContext("P-stop", ex_par, BaseStimulusParameters(100.0),
                                   ConstantStimuli())
                loop = @async run_experiment!(s, engine; report = :silent)
                try
                    @test timedwait(() -> engine.awaiting == "present", 10.0) === :ok
                    abort!(s)
                    @test PsychophysicsManager.abandon_trial!(s)
                    @test timedwait(() -> istaskdone(loop), 10.0) === :ok
                finally
                    close_engine!(engine)
                end
                @test s.state == ABORTED && isempty(s.history)
                @test only(filter(r -> r.command == "abandon", mock.log)).presentation == 1
            end
        end
    end

    @testset "A worker that declares its own stimuli" begin
        declared = (oppel_kundt = (Ref = 100, DistrN = 3, StimConfig = "r d t"),
                    bisection = (Gap = 0.5, Mirror = false))
        mock = serve_mock_worker(worker = "declaring", stimuli = declared)
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            @test declared_stimuli(engine) == ["oppel_kundt", "bisection"]
            stimulus = worker_stimulus(engine, "oppel_kundt")
            @test stimulus isa WorkerStimulus
            @test parameter_names(stimulus) == [:Ref, :DistrN, :StimConfig]
            @test parameter_value(stimulus, :StimConfig) == "r d t"
            # A copy: the declaration itself does not change with a session's stimulus
            set_parameter!(stimulus, :Ref, 120)
            @test parameter_value(worker_stimulus(engine, "oppel_kundt"), :Ref) == 100
            @test_throws ArgumentError worker_stimulus(engine, "gabor")

            # What is sent is exactly what the worker declares
            @test_throws ErrorException present_stimulus(
                engine, WorkerStimulus("oppel_kundt"; Ref = 100), Float64[])
            @test_throws ErrorException present_stimulus(
                engine, WorkerStimulus("gabor"; contrast = 0.1), Float64[])
            @test !any(r -> r.command == "present", mock.log)

            # A preview is completed to the declaration, the caller's stimulus is not
            incomplete = WorkerStimulus("oppel_kundt"; Ref = 100, DistrN = 3)
            preview_stimulus(engine, incomplete)
            previewed = only(filter(r -> r.command == "present", mock.log))
            @test previewed.stimulus._type == "oppel_kundt"
            @test Set(keys(previewed.stimulus.fields)) == Set([:Ref, :DistrN, :StimConfig])
            @test parameter_names(incomplete) == [:Ref, :DistrN]
        finally
            close_engine!(engine)
        end

        # A worker that declares none is given Julia stimulus types, and no other
        plain = serve_mock_worker()
        engine = RemoteEngine(Sockets.localhost, plain.port)
        try
            @test isempty(declared_stimuli(engine))
            failure = try
                worker_stimulus(engine, "oppel_kundt")
                nothing
            catch e
                e
            end
            @test failure isa ArgumentError && occursin("declares no stimuli", failure.msg)
        finally
            close_engine!(engine)
        end

        # A declaration that cannot be read is refused at the handshake
        for stimuli in ("oppel_kundt", (oppel_kundt = 3,),
                        (oppel_kundt = (Color = (r = 1, g = 0, b = 0),),))
            refused = serve_mock_worker(stimuli = stimuli)
            @test_throws ErrorException RemoteEngine(Sockets.localhost, refused.port)
        end

        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                ex_par = ExperimentParameters("Declared", :DistrN, [1.0, 3.0], 1)

                # A variable binds into the declared parameters, and the session file
                # keeps them, in the worker's order
                mock = serve_mock_worker(worker = "declaring", stimuli = declared,
                                         responses = Any[1, -1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                s = SessionContext("P-declared", ex_par, worker_stimulus(engine, "oppel_kundt"),
                                   ConstantStimuli())
                try
                    run_experiment!(s, engine; report = :silent)
                finally
                    close_engine!(engine)
                end
                @test s.state == FINISHED && length(s.history) == 2
                presents = filter(r -> r.command == "present", mock.log)
                @test all(r -> r.stimulus._type == "oppel_kundt", presents)
                @test all(r -> Set(keys(r.stimulus.fields)) == Set([:Ref, :DistrN, :StimConfig]),
                          presents)
                @test all(r -> r.stimulus.fields.DistrN == only(r.values), presents)
                @test s.environment["stimulus_program"] == "remote worker declaring"
                loaded = load_session(s.save_path)
                @test loaded.stim_par isa WorkerStimulus
                @test loaded.stim_par.stimulus == "oppel_kundt"
                @test parameter_names(loaded.stim_par) == [:Ref, :DistrN, :StimConfig]
                # Values, not tags, are the contract: a whole number reads back as an Int
                @test all(parameter_value(loaded.stim_par, name) ==
                          parameter_value(s.stim_par, name) for name in parameter_names(s.stim_par))

                # A parameter the worker no longer declares stops the start, by name,
                # before anything is presented
                mock = serve_mock_worker(worker = "declaring", stimuli = declared)
                engine = RemoteEngine(Sockets.localhost, mock.port)
                old = SessionContext("P-old", ex_par,
                                     WorkerStimulus("oppel_kundt"; Ref = 100, DistrN = 3,
                                                    StimConfig = "r d t", Distance = 2),
                                     ConstantStimuli())
                failure = try
                    run_experiment!(old, engine; report = :silent)
                    nothing
                catch e
                    e
                finally
                    close_engine!(engine)
                end
                @test failure isa ErrorException && occursin("Distance", failure.msg)
                @test old.state == READY && isempty(old.history)
                @test !any(r -> r.command == "present", mock.log)

                # One it newly declares is presented with its default and recorded: in
                # the stimulus from the start, with the trial it begins at on a resume
                mock = serve_mock_worker(worker = "declaring", stimuli = declared,
                                         responses = Any[1, -1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                fresh = SessionContext("P-new", ex_par,
                                       WorkerStimulus("oppel_kundt"; DistrN = 3, Ref = 100),
                                       ConstantStimuli())
                try
                    @test_logs (:warn, r"StimConfig = \"r d t\"") match_mode = :any run_experiment!(
                        fresh, engine; report = :silent)
                finally
                    close_engine!(engine)
                end
                @test parameter_names(fresh.stim_par) == [:Ref, :DistrN, :StimConfig]
                @test parameter_value(fresh.stim_par, :StimConfig) == "r d t"
                @test !any(startswith("stimulus_parameters_added"), keys(fresh.environment))
                @test all(r -> haskey(r.stimulus.fields, :StimConfig),
                          filter(r -> r.command == "present", mock.log))

                resumed = SessionContext("P-resumed", ex_par,
                                         WorkerStimulus("oppel_kundt"; Ref = 100, DistrN = 3),
                                         ConstantStimuli())
                # A dry run presents it as it is: an emulator declares nothing
                start_session!(resumed)
                run_next_trial!(resumed, EmulatorEngine())
                pause!(resumed)
                mock = serve_mock_worker(worker = "declaring", stimuli = declared,
                                         responses = Any[1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                try
                    with_logger(NullLogger()) do
                        run_experiment!(resumed, engine; report = :silent,
                                        accept_changed_stimulus = true)
                    end
                finally
                    close_engine!(engine)
                end
                @test resumed.state == FINISHED
                @test resumed.environment["stimulus_parameters_added_from_trial_2"] ==
                      "StimConfig = \"r d t\""
            end
        end
    end

    @testset "A reply that cannot be believed" begin
        # A stopwatch reading is not a unix time. A session recorded against two
        # clocks cannot be repaired afterwards, so the engine refuses it.
        mock = serve_mock_worker(responses = Any[Dict("response" => 1,
                                                      "onset" => 12345.0,
                                                      "timestamp_response" => 12345.1)])
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            failure = try
                present_stimulus(engine, BaseStimulusParameters(100.0), [100.0])
                nothing
            catch e
                e
            end
            @test failure isa ErrorException
            @test occursin("unix", failure.msg)
        finally
            close_engine!(engine)
        end

        # A word that is not "timeout" is not an answer, and "abandoned" answers only
        # a presentation the worker was asked to abandon
        words = serve_mock_worker(responses = Any[Dict("response" => "yes"),
                                                  Dict("response" => "abandoned")])
        engine = RemoteEngine(Sockets.localhost, words.port)
        try
            @test_throws ErrorException present_stimulus(
                engine, BaseStimulusParameters(100.0), [100.0])
            failure = try
                present_stimulus(engine, BaseStimulusParameters(100.0), [100.0])
                nothing
            catch e
                e
            end
            @test failure isa ErrorException
            @test occursin("abandon none", failure.msg)
        finally
            close_engine!(engine)
        end

        # A worker that cannot present says so, in its own words
        refusing = serve_mock_worker(
            responses = Any[Dict("error" => "the display did not open")])
        engine = RemoteEngine(Sockets.localhost, refusing.port)
        try
            failure = try
                present_stimulus(engine, BaseStimulusParameters(100.0), [100.0])
                nothing
            catch e
                e
            end
            @test failure isa ErrorException
            @test occursin("the display did not open", failure.msg)
        finally
            close_engine!(engine)
        end
    end

    @testset "Participant messages on a remote worker" begin
        struct RemoteRecordingSource <: AbstractResponseSource
            log::Vector{ParticipantMessage}
            RemoteRecordingSource() = new(ParticipantMessage[])
        end
        PsychophysicsManager.present_message(s::RemoteRecordingSource, msg::ParticipantMessage) =
            (push!(s.log, msg); nothing)

        # 1. A worker declaring capabilities = ["message"] receives the message command
        # with kind, text, dismissible, min_s as sent, and present_message returns after
        # the reply for a dismissible message.
        mock = serve_mock_worker(capabilities = ["message"])
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            msg = ParticipantMessage(:instructions, "Please read carefully", true, 0.5, () -> true)
            present_message(engine, msg)
            msg_cmd = filter(req -> req.command == "message", mock.log)
            @test length(msg_cmd) == 1
            req = only(msg_cmd)
            @test req.kind == "instructions"
            @test req.text == "Please read carefully"
            @test req.dismissible == true
            @test req.min_s == 0.5
        finally
            close_engine!(engine)
        end

        # Malformed reply without ok: true is an error
        bad_mock = serve_mock_worker(capabilities = ["message"], message_reply = Dict("ok" => false))
        bad_engine = RemoteEngine(Sockets.localhost, bad_mock.port)
        try
            msg = ParticipantMessage(:instructions, "Test", true, 0.0, () -> true)
            err = try
                present_message(bad_engine, msg)
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("expected {\"ok\": true}", err.msg)
            @test occursin(bad_engine.worker, err.msg)
        finally
            close_engine!(bad_engine)
        end

        # 2. A non-dismissible message: present_message returns only after keep_waiting
        # turns false (flip a Ref from another task after ~0.1 s and check the elapsed time).
        mock = serve_mock_worker(capabilities = ["message"])
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            keep = Ref(true)
            t_task = @async begin
                sleep(0.1)
                keep[] = false
            end
            msg = ParticipantMessage(:break, "Operator break", false, 0.0, () -> keep[])
            t0 = time()
            present_message(engine, msg)
            elapsed = time() - t0
            @test elapsed >= 0.09
            @test !keep[]
            wait(t_task)
        finally
            close_engine!(engine)
        end

        # 3. A worker without the capability is sent no message command; the message reaches
        # the active response source (install a small recording AbstractResponseSource
        # with with_response_source).
        mock = serve_mock_worker(capabilities = ["abandon"])
        engine = RemoteEngine(Sockets.localhost, mock.port)
        try
            rec = RemoteRecordingSource()
            msg = ParticipantMessage(:closing, "Goodbye", true, 0.0, () -> false)
            with_response_source(rec) do
                present_message(engine, msg)
            end
            @test !any(req -> req.command == "message", mock.log)
            @test length(rec.log) == 1
            @test rec.log[1] === msg
        finally
            close_engine!(engine)
        end

        # 4. A session over a mock worker with capabilities = ["message"], a task,
        # set_messages!(session; instructions = true, break_every = 1, break_text = "Rest",
        # closing_text = "Thanks") and 2 trials: the worker's log holds, in order,
        # message(instructions), present, message(break), present, message(closing) —
        # no break after the last trial.
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                mock = serve_mock_worker(capabilities = ["message"], responses = Any[1, 1])
                engine = RemoteEngine(Sockets.localhost, mock.port)
                ex_par = ExperimentParameters("RemoteMsgTest", :level, [1.0, 2.0], 1)
                stim = BaseStimulusParameters(100.0)
                session = SessionContext("P_Msg", ex_par, stim, ConstantStimuli())
                set_task!(session, length_comparison_task())
                set_messages!(session; instructions = true, break_every = 1,
                              break_text = "Rest", closing_text = "Thanks")
                try
                    run_experiment!(session, engine; report = :silent)
                finally
                    close_engine!(engine)
                end
                @test session.state == FINISHED
                @test length(session.history) == 2

                actions = [(req.command == "message" ? (:message, Symbol(req.kind)) : (:present,))
                           for req in mock.log if req.command in ("message", "present")]
                @test actions == [
                    (:message, :instructions),
                    (:present,),
                    (:message, :break),
                    (:present,),
                    (:message, :closing),
                ]
                msg_reqs = filter(req -> req.command == "message", mock.log)
                @test [r.text for r in msg_reqs] == [session.task.instructions, "Rest", "Thanks"]
            end
        end
    end

    @testset "The worker's address is configuration" begin
        mktempdir() do dir
            cd(dir) do
                # Without a [remote] section there is no address to connect to,
                # and the message says what to write down
                failure = try
                    load_remote_worker_config()
                    nothing
                catch e
                    e
                end
                @test failure isa ErrorException
                @test occursin("[remote]", failure.msg)

                mock = serve_mock_worker(responses = Any[1])
                write("settings.toml",
                      """
                      [storage]
                      data_dir = "out"

                      [remote]
                      host = "127.0.0.1"
                      port = $(mock.port)
                      read_timeout_s = 30.0
                      """)

                config = load_remote_worker_config()
                @test config.host == "127.0.0.1"
                @test config.port == mock.port
                @test config.read_timeout_s == 30.0

                # The registered engine type is therefore restorable from a
                # session file: the address comes from the laboratory, not from
                # the record
                @test PsychophysicsManager.registered_type(PsychophysicsManager.ENGINE_REGISTRY, "engine",
                                                :RemoteEngine, "") === RemoteEngine
                engine = initialize_engine(RemoteEngine,
                                           BaseStimulusParameters(100.0),
                                           DisplayConfig())
                try
                    @test engine.worker == "mock-worker"
                    @test engine.read_timeout_s == 30.0
                finally
                    close_engine!(engine)
                end
            end
        end
    end
end
