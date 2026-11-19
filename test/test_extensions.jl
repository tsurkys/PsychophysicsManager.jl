# Extension loading tests. This file must be included LAST: it loads the
# graphics/audio backends, and the headless assertions below must run before
# any backend is in the session.

@testset "Headless core (before backends load)" begin
    loaded = [k.name for k in keys(Base.loaded_modules)]
    @test "GLMakie" ∉ loaded
    @test "Makie" ∉ loaded
    @test "PortAudio" ∉ loaded
    @test "CImGui" ∉ loaded

    # Ext-implemented functions give actionable errors instead of UndefVarError
    @test_throws ErrorException plot_psychometric_curve()
    @test_throws ErrorException open_operator_dashboard()

    # Visual stimuli have no default engine until a backend registers one
    @test_throws ErrorException default_engine_type(MarkerLayout())
    @test_throws ErrorException default_engine_type(TemporalOppelKundt())
    @test_throws ErrorException default_engine_type(Gabor())
    @test !haskey(PsychophysicsManager.ENGINE_REGISTRY, :GeometryVisualEngine)
    @test !haskey(PsychophysicsManager.ENGINE_REGISTRY, :AudioStimulusEngine)
    @test PsychophysicsManager.ENGINE_BACKEND_HINTS[:GeometryVisualEngine] == [:GLMakie]
    @test PsychophysicsManager.ENGINE_BACKEND_HINTS[:AudioStimulusEngine] == [:PortAudio, :SampledSignals]

    @testset "Engine backend hints" begin
        engine_name = :TestBackendHintEngine
        try
            register_engine_backend!(engine_name, [:FirstBackend])
            @test_logs (:warn, r"already registered")
                register_engine_backend!(engine_name, [:SecondBackend])
            @test PsychophysicsManager.ENGINE_BACKEND_HINTS[engine_name] == [:SecondBackend]
        finally
            delete!(PsychophysicsManager.ENGINE_BACKEND_HINTS, engine_name)
        end

        unhinted_error = try
            PsychophysicsManager.activate_engine_backend!("UnhintedTestEngine")
            nothing
        catch err
            err
        end
        @test unhinted_error isa ErrorException
        @test occursin("register_engine_backend!", sprint(showerror, unhinted_error))

        missing_name = :MissingBackendHintEngine
        try
            register_engine_backend!(missing_name, [:PsychophysicsManagerMissingBackend])
            missing_error = try
                PsychophysicsManager.activate_engine_backend!(String(missing_name))
                nothing
            catch err
                err
            end
            @test missing_error isa ErrorException
            @test occursin("PsychophysicsManagerMissingBackend", sprint(showerror, missing_error))
        finally
            delete!(PsychophysicsManager.ENGINE_BACKEND_HINTS, missing_name)
        end
    end

    # Built-in hints activate their extensions without an engine-name branch in Core.
    @test PsychophysicsManager.activate_engine_backend!("GeometryVisualEngine") === nothing
    @test haskey(PsychophysicsManager.ENGINE_REGISTRY, :GeometryVisualEngine)
    @test PsychophysicsManager.activate_engine_backend!("AudioStimulusEngine") === nothing
    @test haskey(PsychophysicsManager.ENGINE_REGISTRY, :AudioStimulusEngine)

    # close_all_windows is a safe no-op without a display backend
    @test PsychophysicsManager.close_all_windows() === nothing
end

using GLMakie
using GLMakie: ShaderAbstractions, GLFW

# Windows are opened only where there is a screen to open them on
const has_display = Sys.iswindows() || Sys.isapple() ||
                    haskey(ENV, "DISPLAY") || haskey(ENV, "WAYLAND_DISPLAY")

@testset "GLMakie extension" begin
    glext = Base.get_extension(PsychophysicsManager, :PsychophysicsManagerGLMakieExt)
    @test glext !== nothing
    @test Base.get_extension(PsychophysicsManager, :PsychophysicsManagerMakieExt) !== nothing
    # The dashboard is Dear ImGui's, not GLMakie's
    @test_throws ErrorException open_operator_dashboard()

    # Engine registered and selected as default for geometric stimuli
    @test haskey(PsychophysicsManager.ENGINE_REGISTRY, :GeometryVisualEngine)
    @test default_engine_type(MarkerLayout()) === glext.GeometryVisualEngine
    # The two-interval Gabor is drawn by the same window
    @test default_engine_type(Gabor()) === glext.GeometryVisualEngine
    @test PsychophysicsManager.ACTIVE_DISPLAY_BACKEND[] isa glext.GLMakieDisplayBackend
    # Its window reads the response keys, so the console explains them at a session's start
    @test PsychophysicsManager.reads_response_keys(glext.GeometryVisualEngine())

    @testset "Key mapping" begin
        # One mapping for both windows; no window needed to check it
        @test glext.response_from_key(Keyboard.left) == -1
        @test glext.response_from_key(Keyboard.right) == 1
        @test glext.response_from_key(Keyboard.enter) == 0
        @test glext.response_from_key(Keyboard.space) == 0
        @test glext.response_from_key(Keyboard.a) === nothing
        @test glext.response_from_key(Keyboard.escape) === nothing
    end

    @testset "The engine is told the session's response window" begin
        # It owns its keyboard, so the window reaches it only through the core
        # hook; no window has to be open for that
        windowless = glext.GeometryVisualEngine()
        set_response_timeout!(windowless, 0.3)
        @test windowless.timeout_s == 0.3
    end

    @testset "An engine without a window is closed, and closes again harmlessly" begin
        windowless = glext.GeometryVisualEngine()
        @test !isopen(windowless) && !windowless.closable
        @test close_engine!(windowless) === nothing
        @test close_engine!(windowless) === nothing
    end

    @testset "A windowless engine forwards present_message to active response source" begin
        struct GLMakieRecordingSource <: AbstractResponseSource
            log::Vector{ParticipantMessage}
            GLMakieRecordingSource() = new(ParticipantMessage[])
        end
        PsychophysicsManager.present_message(s::GLMakieRecordingSource, msg::ParticipantMessage) =
            (push!(s.log, msg); nothing)

        windowless = glext.GeometryVisualEngine()
        rec = GLMakieRecordingSource()
        msg = ParticipantMessage(:instructions, "Look here", true, 0.0, () -> false)
        with_response_source(rec) do
            present_message(windowless, msg)
        end
        @test length(rec.log) == 1
        @test rec.log[1] === msg
    end

    # The headless rasterizer accepts the engine's own buffer type: the pixel
    # layout is covered in test_marker_layout.jl, this only pins the RGBf path
    canvas = fill(RGBf(0, 0, 0), 20, 20)
    render_stimulus!(canvas, MarkerLayout(StimConfig = "", Anchor = :first,
                                            MarkerSize = (2, 2));
                     on = RGBf(1, 1, 1), off = RGBf(0, 0, 0))
    @test canvas[9:10, 9:10] == fill(RGBf(1, 1, 1), 2, 2)
    @test canvas[1, 1] == RGBf(0, 0, 0)
    # A Gabor frame reaches the same buffer through its grey-level mapping
    gabor_canvas = fill(RGBf(0, 0, 0), 64, 64)
    render_stimulus!(gabor_canvas, Gabor(sigma_px = 4.0, size_px = 24);
                     interval = 0, pixel = glext.grey_pixel)
    @test all(==(RGBf(0.5, 0.5, 0.5)), gabor_canvas)

    # Plotting works on a synthetic finished session (no window opened)
    ex_par = ExperimentParameters("PlotTest", :level, [1.0, 2.0, 3.0], 2)
    s = SessionContext("Plotter", ex_par, BaseStimulusParameters(100.0),
                       ConstantStimuli())
    for (i, (lvl, resp)) in enumerate(zip([1.0, 2.0, 3.0, 1.0, 2.0, 3.0],
                                          [0, 1, 1, 1, 0, 1]))
        push!(s.history, Trial(i, 0.0, 0.1, [lvl], resp, true))
    end
    fig = plot_psychometric_curve(s)
    @test fig isa Figure
    @test plot_psychometric_curve(s; spread = :ci) isa Figure
    @test plot_psychometric_curve(s; spread = :none) isa Figure
    @test_throws ArgumentError plot_psychometric_curve(s; spread = :sd)
    @test_throws ArgumentError plot_psychometric_curve(s; spread = :range)
    @test plot_psychometric_curve(AnalysisSet([s]; checks = collect(COMBINING_CHECKS))) isa Figure

    adj = SessionContext("Plotter", ex_par, BaseStimulusParameters(100.0),
                         Adjustment(dep_var=:duration_ms,
                                          dep_range=0.0:10.0))
    for (i, (lvl, val)) in enumerate(zip([1.0, 2.0, 1.0, 2.0], [3.0, 5.0, 4.0, 6.0]))
        push!(adj.history, Trial(i, 0.0, 0.1, [lvl], val, true))
    end
    # The legend's entries, which name what each plot of a figure draws
    plot_labels(figure) = [string(plot.label[])
                           for plot in only(filter(block -> block isa Axis, figure.content)).scene.plots
                           if haskey(plot.attributes, :label)]
    fig2 = plot_adjustment_results(adj)
    @test fig2 isa Figure
    # The bars the operator chooses, and a curve through the means that assumes no model
    @test "Mean ± SEM" in plot_labels(fig2)
    @test "Mean ± SD" in plot_labels(plot_adjustment_results(adj; spread = :sd))
    ci_labels = plot_labels(plot_adjustment_results(adj; spread = :ci, smooth = true))
    @test "Mean, 95% CI" in ci_labels
    @test "Smoothed (moving average of 3 levels)" in ci_labels
    @test "Mean" in plot_labels(plot_adjustment_results(adj; spread = :none))
    # Several datasets share one axis, each in its colour and under its name, and an
    # axis keeps the labels it was given
    axis_labels(ax) = [string(plot.label[]) for plot in ax.scene.plots
                       if haskey(plot.attributes, :label) && plot.label[] !== nothing]
    shared = Axis(Figure()[1, 1])
    @test plot_psychometric_curve!(shared, s; label = "A", color = :blue) isa CurveFit
    plot_psychometric_curve!(shared, s; label = "B", color = :green)
    @test ["A", "B", "A: Logistic fit", "B: Logistic fit"] ⊆ axis_labels(shared)
    @test shared.xlabel[] == "level" && shared.ylabel[] == "Proportion 'Yes'"
    mine = Axis(Figure()[1, 1], xlabel = "Mine")
    plot_adjustment_results!(mine, adj; label = "P1", color = :orange)
    plot_adjustment_results!(mine, adj; label = "P2", color = :purple, spread = :sd)
    @test ["P1: Mean ± SEM", "P2: Mean ± SD"] ⊆ axis_labels(mine)
    @test !("Trials" in axis_labels(mine)) && mine.xlabel[] == "Mine"
    # A set's members each in a panel of their own
    other = SessionContext("Other", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
    append!(other.history, deepcopy(s.history))
    makie_ext = Base.get_extension(PsychophysicsManager, :PsychophysicsManagerMakieExt)
    panels = makie_ext.plot_members(AnalysisSet([s, other]; checks = collect(COMBINING_CHECKS));
                                    title = "Both", collapse = (), adjustment = false)
    @test [axis.title[] for axis in filter(block -> block isa Axis, panels.content)] ==
          ["Plotter · " * string(s.id)[1:8], "Other · " * string(other.id)[1:8]]
    @test_throws ArgumentError plot_adjustment_results(adj; spread = :range)
    @test "Smoothed (moving average of 3 levels)" in
          plot_labels(plot_psychometric_curve(s; smooth = true))
    # A declared conversion names the axes and moves the points
    set_unit_conversion!(adj, :level, UnitConversion("Level (dB)"; scale = 10.0))
    set_unit_conversion!(adj, :duration_ms, UnitConversion("Duration (s)"; scale = 1e-3))
    axis = only(filter(block -> block isa Axis, plot_adjustment_results(adj).content))
    @test axis.xlabel[] == "Level (dB)" && axis.ylabel[] == "Duration (s)"
    @test axis.xticks[] == [10.0, 20.0]
    # A fit made beforehand is drawn as it was estimated: its model, and the
    # interval of its threshold as a band
    bootstrapped = CurveFit(:logistic, 2.0, 3.0, 0.0, 0.0, 0.1, 0.5,
                            (1.8, 2.2), (2.0, 4.0), 200, true)
    labels = plot_labels(plot_psychometric_curve(s; fit = bootstrapped))
    @test "Logistic fit" in labels
    @test "α interval (200 bootstrap samples)" in labels
    @test !any(startswith("α interval"), plot_labels(plot_psychometric_curve(s)))
    @test "Logistic fit" in plot_labels(plot_psychometric_curve(s))
    set_unit_conversion!(s, :level, UnitConversion("Level (dB)"; scale = 10.0))
    axis = only(filter(block -> block isa Axis, plot_psychometric_curve(s).content))
    @test axis.xlabel[] == "Level (dB)"

    # An adaptive session's levels, trial by trial, its reversals marked
    stairs = SessionContext("Plotter", ExperimentParameters("Stairs", :level, collect(1.0:5.0), 8),
                            BaseStimulusParameters(1.0), Staircase(2))
    for (i, (level, right)) in enumerate([(5.0, true), (4.0, true), (3.0, false), (4.0, true),
                                          (3.0, true), (2.0, false), (3.0, true), (2.0, true)])
        push!(stairs.history, Trial(i, 0.0, 0.1, [level], right ? 1 : -1, i != 2,
                                    :estimated, right))
    end
    stair_labels = plot_labels(plot_adaptive_sequence(stairs))
    @test ["Presented level", "Correct", "Wrong or unanswered", "Reversal",
           "Not counted"] ⊆ stair_labels
    @test any(startswith("Fitted threshold"), stair_labels) ||
          !fit_psychometric_curve(get_aggregated_data(stairs); gamma = stairs.fit_gamma).converged
    @test_throws ArgumentError plot_adaptive_sequence(s)

    # A counterbalancing variable pooled over: one point per level, and no warning
    # about a second variable
    two = SessionContext("Plotter", ExperimentParameters("2IFC", [:contrast, :target_interval],
                                                         Any[[0.1, 0.2, 0.3], [1, 2]], 1),
                         Gabor(), ConstantStimuli())
    for (i, (contrast, interval, right)) in enumerate([(0.1, 1, false), (0.1, 2, true),
                                                       (0.2, 1, true), (0.2, 2, false),
                                                       (0.3, 1, true), (0.3, 2, true)])
        push!(two.history, Trial(i, 0.0, 0.1, [contrast, Float64(interval)], right ? 1 : -1,
                                 true, :estimated, right))
    end
    @test_logs (:warn, r"2 independent variables") match_mode = :any plot_psychometric_curve(two)
    @test (@test_logs plot_psychometric_curve(two; collapse = :target_interval)) isa Figure
    @test (@test_logs plot_psychometric_curve(two; collapse = :target_interval, spread = :ci)) isa Figure

    # GLMakie trusts its own record of the current OpenGL context; the
    # dashboard's frames make another context current behind it. The check must
    # ask GLFW too, or GLMakie draws into the dashboard's context.
    if has_display
        GLFW.WindowHint(GLFW.VISIBLE, false)
        recorded, other = GLFW.CreateWindow(64, 64, "recorded"), GLFW.CreateWindow(64, 64, "other")
        GLFW.DefaultWindowHints()
        previous = ShaderAbstractions.ACTIVE_OPENGL_CONTEXT[]
        try
            ShaderAbstractions.ACTIVE_OPENGL_CONTEXT[] = recorded
            GLFW.MakeContextCurrent(recorded)
            @test ShaderAbstractions.is_current_context(recorded)
            GLFW.MakeContextCurrent(other)
            @test !ShaderAbstractions.is_current_context(recorded)
        finally
            ShaderAbstractions.ACTIVE_OPENGL_CONTEXT[] = previous
            GLFW.DestroyWindow(recorded)
            GLFW.DestroyWindow(other)
        end
    else
        @test_skip "no display to open a GLFW window on"
    end
end

using CImGui, ImPlot   # GLMakie has loaded GLFW and ModernGL, which CImGui draws with

@testset "Dear ImGui extension" begin
    @test Base.get_extension(PsychophysicsManager, :PsychophysicsManagerImGuiExt) !== nothing
    @test hasmethod(open_operator_dashboard, Tuple{})
    @test hasmethod(open_operator_dashboard, Tuple{SessionContext})
    @test hasmethod(open_operator_dashboard, Tuple{DashboardController})
    # The cursor theme is searched where the system keeps it, not where the
    # artifact's libXcursor was built
    (Sys.islinux() || Sys.isbsd()) && @test haskey(ENV, "XCURSOR_PATH")

    if has_display
        # The window draws frames from a session, is the response source while
        # open, and gives everything back when it closes
        session = SessionContext("Window", ExperimentParameters("ImGuiSmoke", :level,
                                                               [1.0, 2.0, 3.0], 1),
                                 BaseStimulusParameters(100.0), ConstantStimuli())
        before = PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[]
        dashboard = open_operator_dashboard(session)
        try
            @test isopen(dashboard)
            @test_throws ArgumentError open_operator_dashboard(session)
            @test PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[] isa PsychophysicsManager.ChannelResponseSource
            timedwait(() -> dashboard.frames >= 5, 30.0)
            @test dashboard.frames >= 5
            # A session event only marks the view out of date; the frame rereads
            push!(session.history, Trial(1, 0.0, 0.1, [2.0], 1, true))
            PsychophysicsManager.notify_session_listeners(session, :history_changed)
            @test dashboard.stale
            timedwait(() -> !dashboard.stale, 10.0)
            @test length(dashboard.rows) == 1
        finally
            close(dashboard)
            wait(dashboard)
        end
        @test !isopen(dashboard)
        @test PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[] === before
        @test dashboard.controller.session === nothing

        # A window still open at exit is closed before GLFW.jl's own exit hook
        # terminates the library under it (Julia runs the later-registered hook first)
        imgui_ext = Base.get_extension(PsychophysicsManager, :PsychophysicsManagerImGuiExt)
        @test findfirst(==(imgui_ext.close_dashboard_at_exit), Base.atexit_hooks) <
              findfirst(==(GLFW.Terminate), Base.atexit_hooks)
        dashboard = open_operator_dashboard(session)
        imgui_ext.close_dashboard_at_exit()
        @test !isopen(dashboard)
    else
        @test_skip "no display to open the dashboard on"
    end
end

using PortAudio, SampledSignals

@testset "Audio extension" begin
    audio_ext = Base.get_extension(PsychophysicsManager, :PsychophysicsManagerAudioExt)
    @test audio_ext !== nothing
    # Registration only — constructing the engine needs an audio device
    @test haskey(PsychophysicsManager.ENGINE_REGISTRY, :AudioStimulusEngine)
    @test default_engine_type(TemporalOppelKundt()) ===
          audio_ext.AudioStimulusEngine
end

using HTTP, PNGFiles, JSON3

@testset "Model observer extension" begin
    ext = Base.get_extension(PsychophysicsManager, :PsychophysicsManagerModelObserverExt)
    @test ext !== nothing

    task = length_comparison_task()
    engine = OffscreenVisualEngine(600, 160)
    params = MarkerLayout(StimConfig = "d r t", Ref = 240.0, DistrN = 4,
                                Diff = 20.0, MarkerSize = (2, 30), Anchor = :middle)
    present_stimulus(engine, params, [20.0])
    context = TrialContext(params, [:Diff], [20.0], 1, "OK_AI", last_frame(engine))
    question = ObserverQuestion(task, context)

    @testset "The presented pixels reach the request" begin
        png = ext.frame_to_png(last_frame(engine))
        decoded = PNGFiles.load(IOBuffer(png))
        # PNG rows are the canvas transposed and flipped: the model is shown the
        # figure the same way up a participant sees it
        @test size(decoded) == (160, 600)
        expected = reverse(permutedims(last_frame(engine)), dims = 1)
        @test (decoded .> 0) == expected
    end

    @testset "Request shape is stateless and forced-choice" begin
        observer = ext.ClaudeObserver(api_key = "test-key", model = "claude-opus-5")
        body = JSON3.read(ext.build_claude_request(observer, question))

        @test body.model == "claude-opus-5"
        # Exactly one user turn, rebuilt per trial: no conversation history
        @test length(body.messages) == 1
        @test body.messages[1].role == "user"
        @test [String(b.type) for b in body.messages[1].content] == ["image", "text"]
        @test body.messages[1].content[1].source.media_type == "image/png"
        @test !isempty(body.messages[1].content[1].source.data)
        @test String(body.messages[1].content[2].text) == task.instructions

        # The answer is constrained to the task's options
        schema = body.output_config.format.schema
        @test String(body.output_config.format.type) == "json_schema"
        @test [String(o) for o in schema.properties.longer.enum] == collect(task.options)
        @test schema.additionalProperties == false

        # Parameters current models reject must not be sent
        @test !haskey(body, :temperature)
        @test !haskey(body, :top_p)
        @test !haskey(body, :top_k)
        @test String(body.thinking.type) == "disabled"

        deliberating = ext.ClaudeObserver(api_key = "k", thinking = :adaptive, effort = "medium")
        adaptive_body = JSON3.read(ext.build_claude_request(deliberating, question))
        @test String(adaptive_body.thinking.type) == "adaptive"
        @test String(adaptive_body.output_config.effort) == "medium"
    end

    @testset "Replies are parsed, refusals are not" begin
        reply(text; stop = "end_turn") = JSON3.write(Dict(
            "id" => "msg_test", "model" => "claude-opus-5", "stop_reason" => stop,
            "usage" => Dict("input_tokens" => 812, "output_tokens" => 9),
            "content" => [Dict("type" => "text", "text" => text)]))
        stub(payload; status = 200) = (_, _) -> (status, payload)

        answered = ext.ClaudeObserver(api_key = "k",
                                      transport = stub(reply("{\"longer\":\"right\"}")))
        answer = query_observer(answered, question)
        @test answer.choice == "right"
        @test response_code(task, answer.choice) == 1
        @test answer.metadata["input_tokens"] == 812
        @test answer.metadata["request_id"] == "msg_test"
        @test answer.metadata["image_size"] == [600, 160]

        # A refusal is missing data: content must not be read as an answer
        refused = ext.ClaudeObserver(api_key = "k",
                                     transport = stub(reply("{\"longer\":\"left\"}", stop = "refusal")))
        @test query_observer(refused, question).choice === nothing
        @test query_observer(refused, question).metadata["failure"] == "refusal"

        for (payload, status, failure) in (
                ("not json at all", 200, "unparseable_response"),
                (reply("I cannot tell."), 200, "unparseable_choice"),
                (reply("{\"longer\":\"neither\"}"), 200, "choice_not_an_option"),
                (reply("{\"other\":\"right\"}"), 200, "missing_choice_field"),
                ("{\"error\":\"overloaded\"}", 529, "http_529"),
                ("connection refused", 0, "transport_error"))
            observer = ext.ClaudeObserver(api_key = "k", transport = stub(payload, status = status))
            unusable = query_observer(observer, question)
            @test unusable.choice === nothing
            @test unusable.metadata["failure"] == failure
        end
    end

    @testset "The model is pinned for the whole session" begin
        answered(model) = JSON3.write(Dict(
            "id" => "msg_test", "model" => model, "stop_reason" => "end_turn",
            "content" => [Dict("type" => "text", "text" => "{\"longer\":\"right\"}")]))
        asking(model, served) =
            ext.ClaudeObserver(api_key = "k", model = model,
                               transport = (_, _) -> (200, answered(served)))

        # The model asked for is the model that answered
        @test query_observer(asking("claude-opus-5", "claude-opus-5"), question).choice ==
              "right"
        # An alias answering under its dated release is one model, not two
        @test query_observer(asking("claude-opus-5", "claude-opus-5-20260201"),
                             question).choice == "right"

        # Anything else after the name is a different instrument, date or not
        for served in ("claude-sonnet-5", "claude-opus-5-mini", "claude-opus-5-fast-20260201")
            @test_throws ErrorException query_observer(asking("claude-opus-5", served),
                                                       question)
        end

        # Pinning the dated id is stricter still: an alias reply is not that id
        @test_throws ErrorException query_observer(
            asking("claude-opus-5-20260201", "claude-opus-5"), question)

        # A reply too broken to name its model is missing data, not a substitution
        silent = ext.ClaudeObserver(api_key = "k",
                                    transport = (_, _) -> (200, "{\"stop_reason\":\"end_turn\"}"))
        @test query_observer(silent, question).metadata["failure"] == "no_content"
    end

    @testset "Provenance and guards" begin
        observer = ext.ClaudeObserver(api_key = "k", model = "claude-sonnet-5")
        description = describe_backend(observer)
        @test description["backend"] == "ClaudeObserver"
        @test description["model"] == "claude-sonnet-5"
        @test occursin("stateless", description["conversation_history"])

        # The experiment's own word for the condition, read back from the two
        # fields this API expresses it in
        @test description["deliberation"] == "none"
        @test describe_backend(ext.ClaudeObserver(api_key = "k", thinking = :adaptive,
                                                  effort = "medium"))["deliberation"] == "medium"

        # No key: fail before spending a request, and say where the key belongs
        keyless = ext.ClaudeObserver(api_key = "")
        @test_throws ErrorException query_observer(keyless, question)

        # No rendered frame: the observer must not be asked about nothing
        blind = TrialContext(params, [:Diff], [20.0], 1, "OK_AI", nothing)
        @test_throws ErrorException ext.build_claude_request(observer, ObserverQuestion(task, blind))

        # A canvas the API would downscale changes the stimulus: warn, don't hide it
        big = OffscreenVisualEngine(3000, 100)
        present_stimulus(big, params, [20.0])
        oversized = ObserverQuestion(task, TrialContext(params, [:Diff], [20.0], 1, "OK_AI",
                                                        last_frame(big)))
        @test_logs (:warn, r"downscaled") ext.build_claude_request(observer, oversized)
    end
end

@testset "OpenRouter observer" begin
    ext = Base.get_extension(PsychophysicsManager, :PsychophysicsManagerModelObserverExt)
    task = length_comparison_task()
    engine = OffscreenVisualEngine(600, 160)
    params = MarkerLayout(StimConfig = "d r t", Ref = 240.0, DistrN = 4,
                                Diff = 20.0, MarkerSize = (2, 30), Anchor = :middle)
    present_stimulus(engine, params, [20.0])
    question = ObserverQuestion(task, TrialContext(params, [:Diff], [20.0], 1, "OK_AI",
                                                   last_frame(engine)))

    @testset "Request shape matches the OpenAI-compatible API" begin
        observer = ext.OpenRouterObserver(api_key = "k", model = "anthropic/claude-opus-5")
        body = JSON3.read(ext.build_openrouter_request(observer, question))

        @test body.model == "anthropic/claude-opus-5"
        # `max_tokens`, not `max_completion_tokens`: verified against the live
        # API, endpoint parameter filtering rejects the newer name with a 404
        @test haskey(body, :max_tokens)
        @test !haskey(body, :max_completion_tokens)

        # One user turn, rebuilt per trial: no conversation history
        @test length(body.messages) == 1
        @test body.messages[1].role == "user"
        content = body.messages[1].content
        @test [String(c.type) for c in content] == ["image_url", "text"]
        @test startswith(String(content[1].image_url.url), "data:image/png;base64,")
        @test String(content[2].text) == task.instructions

        # Forced choice, in strict mode so a native implementation enforces it
        @test String(body.response_format.type) == "json_schema"
        @test body.response_format.json_schema.strict == true
        schema = body.response_format.json_schema.schema
        @test [String(o) for o in schema.properties.longer.enum] == collect(task.options)
        @test schema.additionalProperties == false

        # Routing pinned by construction: no silent reroute, and only endpoints
        # that actually honour the schema
        @test body.provider.allow_fallbacks == false
        @test body.provider.require_parameters == true

        # "none" genuinely disables reasoning; "exclude" would only hide it
        @test String(body.reasoning.effort) == "none"
        # Nothing is claimed about sampling unless it is deliberately set
        @test !haskey(body, :temperature)
    end

    @testset "Deliberate condition and pinned provider" begin
        observer = ext.OpenRouterObserver(api_key = "k", reasoning = :high,
                                          temperature = 1.0,
                                          provider_order = ["Anthropic"])
        body = JSON3.read(ext.build_openrouter_request(observer, question))
        @test String(body.reasoning.effort) == "high"
        @test body.temperature == 1.0
        @test [String(p) for p in body.provider.order] == ["Anthropic"]

        bad = ext.OpenRouterObserver(api_key = "k", reasoning = :sometimes)
        @test_throws ArgumentError ext.build_openrouter_request(bad, question)
    end

    @testset "Replies, costs and every way a trial can go missing" begin
        reply(text; finish = "stop") = JSON3.write(Dict(
            "id" => "gen-123", "model" => "anthropic/claude-opus-5",
            "provider" => "Anthropic",
            "usage" => Dict("prompt_tokens" => 640, "completion_tokens" => 8,
                            "total_tokens" => 648, "cost" => 0.00432),
            "choices" => [Dict("finish_reason" => finish,
                               "message" => Dict("role" => "assistant", "content" => text))]))
        stub(payload; status = 200) = (_, _) -> (status, payload)

        answered = ext.OpenRouterObserver(api_key = "k",
                                          transport = stub(reply("{\"longer\":\"left\"}")))
        answer = query_observer(answered, question)
        @test answer.choice == "left"
        @test response_code(task, answer.choice) == -1
        # The broker reports the real price per request, so a session can be
        # costed exactly instead of estimated
        @test answer.metadata["cost"] == 0.00432
        @test answer.metadata["provider"] == "Anthropic"
        @test answer.metadata["responding_model"] == "anthropic/claude-opus-5"
        @test answer.metadata["generation_id"] == "gen-123"

        for (payload, status, failure) in (
                (reply("{\"longer\":\"left\"}", finish = "content_filter"), 200, "content_filter"),
                (reply("{\"longer\":\"le", finish = "length"), 200, "truncated"),
                (reply("Neither looks longer to me."), 200, "unparseable_choice"),
                (reply("{\"longer\":\"middle\"}"), 200, "choice_not_an_option"),
                ("{\"error\":{\"message\":\"no endpoints\"}}", 200, "api_error"),
                ("{\"choices\":[]}", 200, "no_choices"),
                ("{\"id\":\"x\"}", 200, "no_choices"),
                ("rate limited", 429, "http_429"),
                ("connection reset", 0, "transport_error"))
            observer = ext.OpenRouterObserver(api_key = "k",
                                              transport = stub(payload, status = status))
            unusable = query_observer(observer, question)
            @test unusable.choice === nothing
            @test unusable.metadata["failure"] == failure
        end
    end

    @testset "The route is pinned for the whole session" begin
        # A substitution is refused rather than recorded: it swaps the instrument
        # without swapping anything the data would show.
        routed(text; model = "anthropic/claude-opus-5", provider = "Anthropic") =
            JSON3.write(Dict(
                "id" => "gen-1", "model" => model, "provider" => provider,
                "choices" => [Dict("finish_reason" => "stop",
                                   "message" => Dict("role" => "assistant",
                                                     "content" => text))]))
        answer_json = "{\"longer\":\"right\"}"

        substituted = ext.OpenRouterObserver(
            api_key = "k", model = "openai/gpt-5",
            transport = (_, _) -> (200, routed(answer_json, model = "openai/gpt-5-mini")))
        @test_throws ErrorException query_observer(substituted, question)

        # The first reply fixes the provider; a later one that differs stops the run
        replies = [routed(answer_json, provider = "Anthropic"),
                   routed(answer_json, provider = "Amazon Bedrock")]
        served = 0
        rerouting = ext.OpenRouterObserver(api_key = "k",
                                           transport = function (_, _)
                                               served += 1
                                               return (200, replies[served])
                                           end)
        @test query_observer(rerouting, question).choice == "right"
        @test rerouting.served_by[] == "Anthropic"
        @test_throws ErrorException query_observer(rerouting, question)

        # A steady route just answers, trial after trial
        steady = ext.OpenRouterObserver(api_key = "k",
                                        transport = (_, _) -> (200, routed(answer_json)))
        @test query_observer(steady, question).choice == "right"
        @test query_observer(steady, question).choice == "right"
        @test steady.served_by[] == "Anthropic"

        # A reply too broken to name its route is missing data, not a substitution
        broken = ext.OpenRouterObserver(api_key = "k",
                                        transport = (_, _) -> (200, "{\"choices\":[]}"))
        @test query_observer(broken, question).metadata["failure"] == "no_choices"
    end

    @testset "Provenance and guards" begin
        observer = ext.OpenRouterObserver(api_key = "k", model = "openai/gpt-5",
                                          reasoning = :medium, provider_order = ["OpenAI"])
        description = describe_backend(observer)
        @test description["backend"] == "OpenRouterObserver"
        @test description["model"] == "openai/gpt-5"
        @test description["reasoning_effort"] == "medium"
        @test description["deliberation"] == "medium"
        @test description["provider_order"] == ["OpenAI"]
        @test description["require_parameters"] == true
        @test description["temperature"] == "unset"

        keyless = ext.OpenRouterObserver(api_key = "")
        @test_throws ErrorException query_observer(keyless, question)

        blind = ObserverQuestion(task, TrialContext(params, [:Diff], [20.0], 1, "OK_AI", nothing))
        @test_throws ErrorException ext.build_openrouter_request(observer, blind)

        big = OffscreenVisualEngine(3000, 100)
        present_stimulus(big, params, [20.0])
        oversized = ObserverQuestion(task, TrialContext(params, [:Diff], [20.0], 1, "OK_AI",
                                                        last_frame(big)))
        @test_logs (:warn, r"downscaled") ext.build_openrouter_request(observer, oversized)
    end

    @testset "A spec names the channel, and the key is checked up front" begin
        withenv("OPENROUTER_API_KEY" => "broker-key") do
            backend = model_observer("anthropic/claude-opus-5")
            @test backend isa ext.OpenRouterObserver
            @test backend.model == "anthropic/claude-opus-5"
            @test backend.api_key == "broker-key"
            # The defaults are the immediate-judgement condition
            @test backend.reasoning === :none
            @test model_observer("openai/gpt-5"; deliberation = :high).reasoning === :high

            # Whatever the channel calls it, the session records the level asked for
            @test describe_backend(backend)["deliberation"] == "none"
            @test describe_backend(model_observer("openai/gpt-5";
                                                  deliberation = :high))["deliberation"] == "high"
            @test model_observer("openai/gpt-5";
                                 require_parameters = false).require_parameters == false

            # One name for the condition: the channel's own is refused rather
            # than silently overriding the experiment's
            @test_throws ArgumentError model_observer("openai/gpt-5"; reasoning = :high)
            @test_throws ArgumentError model_observer("openai/gpt-5"; deliberation = :fast)
        end

        # A slug and a channel prefix reach different instruments
        withenv("ANTHROPIC_API_KEY" => "vendor-key") do
            backend = model_observer("anthropic:claude-opus-5")
            @test backend isa ext.ClaudeObserver
            @test backend.model == "claude-opus-5"
            @test backend.thinking === :disabled
            @test backend.effort === nothing

            # The same condition, spelled the way this API spells it
            deliberating = model_observer("anthropic:claude-opus-5"; deliberation = :low)
            @test deliberating.thinking === :adaptive
            @test deliberating.effort == "low"
            @test describe_backend(deliberating)["deliberation"] == "low"
            @test describe_backend(backend)["deliberation"] == "none"

            # A level this API does not grade is refused, not rounded
            @test_throws ArgumentError model_observer("anthropic:claude-opus-5";
                                                      deliberation = :minimal)
            @test_throws ArgumentError model_observer("anthropic:claude-opus-5";
                                                      thinking = :adaptive)
        end

        # A missing key stops the run before a session exists, not on trial 1
        withenv("OPENROUTER_API_KEY" => nothing) do
            @test_throws ErrorException model_observer("openai/gpt-5")
        end
    end
end

@testset "An extension adds methods to the core's functions, never a copy" begin
    # A method written for a core function the extension did not import becomes
    # a private function of the same name, which the core never calls: the hook
    # it was meant to implement is silently left at its default. Names starting
    # with `#` are generated by Julia, never a hook: Julia 1.13 binds hundreds of
    # them, and the same one can name different functions in the core and in an
    # extension.
    for name in (:PsychophysicsManagerGLMakieExt, :PsychophysicsManagerMakieExt, :PsychophysicsManagerAudioExt,
                 :PsychophysicsManagerModelObserverExt, :PsychophysicsManagerImGuiExt)
        ext = Base.get_extension(PsychophysicsManager, name)
        shadowed = [n for n in names(ext; all = true)
                    if n ∉ (:eval, :include) && !startswith(string(n), '#') &&
                       isdefined(ext, n) &&
                       isdefined(PsychophysicsManager, n) && getfield(ext, n) isa Function &&
                       getfield(ext, n) !== getfield(PsychophysicsManager, n)]
        @test isempty(shadowed)
    end
end
