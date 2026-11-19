function psychtoolbox_worker(port)
%PSYCHTOOLBOX_WORKER  Reference presentation worker for PsychophysicsManager.jl.
%
%   psychtoolbox_worker(PORT) listens on PORT, waits for PsychophysicsManager to connect,
%   and then presents one stimulus per request using Psychtoolbox, reading the
%   keyboard itself and reporting both timestamps from this process. The line
%   protocol is described in workers/README.md; this file is its
%   reference implementation and the starting point for a laboratory's own.
%
%   Run it before starting the session on the Julia side:
%       >> psychtoolbox_worker(5555)
%   and point PsychophysicsManager at it through the [remote] section of settings.toml.
%
%   STATUS: this worker has never been run against real hardware. It was
%   written against the protocol and validated only by the mock worker in
%   PsychophysicsManager.jl/test/test_remote.jl, which speaks the same lines. Treat the
%   Psychtoolbox calls below as a template to verify on your own rig before a
%   participant sits in front of it. PsychophysicsManager's `verify_engine` is the first
%   check to run against it.
%
%   REQUIREMENTS: MATLAB R2021a or newer (for `tcpserver`) and Psychtoolbox-3.
%   Octave needs the `instrument-control` package and a different socket call;
%   see workers/README.md.

if nargin < 1
    port = 5555;
end

PROTOCOL = 1;

% Which version of this program presented a session: PsychophysicsManager records it, and
% refuses to continue a session under another version unless the operator
% chooses to. Change it whenever the stimulus code changes.
VERSION = 'reference 1';

% The stimuli this worker presents, each with its parameters and their
% defaults. PsychophysicsManager lists them for the operator and sends every one of them
% back with each presentation, so a parameter added here needs no change on
% the Julia side. Change VERSION along with them.
STIMULI = struct('number', struct('value', 100, 'text_size', 48));

% The one measurement that must be right: PsychophysicsManager records unix times, and
% GetSecs counts from an arbitrary origin (system boot). The offset is captured
% ONCE, here, and added to every reported timestamp. Recomputing it per trial
% would fold the cost of the clock call into the reaction times, and reporting
% a raw GetSecs value would record the session against a second clock — which
% PsychophysicsManager refuses rather than writes down.
clockOffset = posixtime(datetime('now', 'TimeZone', 'UTC')) - GetSecs();

window = [];
server = tcpserver("0.0.0.0", port, "Timeout", Inf);
configureTerminator(server, "LF");
fprintf('PsychophysicsManager worker listening on port %d. Waiting for a connection.\n', port);

cleanup = onCleanup(@() shutdown(window));

while true
    if ~server.Connected
        pause(0.05);
        continue
    end
    if server.NumBytesAvailable == 0
        pause(0.005);
        continue
    end

    line = readline(server);
    if strlength(line) == 0
        break
    end
    request = jsondecode(line);

    switch request.command
        case 'hello'
            % Answering this is what identifies the program as a worker: a
            % wrong program on the port fails here rather than on trial 1.
            [window, reply] = openWindow(PROTOCOL, VERSION, STIMULI);
            writeline(server, jsonencode(reply));

        case 'present'
            reply = present(server, window, request, clockOffset);
            writeline(server, jsonencode(reply));

        case 'abandon'
            % It names a presentation already answered: the answer stands, and
            % abandon has no reply of its own. One that arrives in time is read
            % while the presentation awaits its response (awaitResponse).

        case 'feedback'
            % The screen belongs to this process, so what the announcement is
            % belongs here too. A worker that shows none still acknowledges.
            showFeedback(window, request.correct);
            writeline(server, jsonencode(struct('ok', true)));

        case 'message'
            showMessage(window, request);
            writeline(server, jsonencode(struct('ok', true)));

        case 'close'
            % No reply: the connection is going away.
            break

        otherwise
            writeline(server, jsonencode(struct('error', ...
                sprintf('unknown command %s', request.command))));
    end
end

clear cleanup
end

% -------------------------------------------------------------------------

function [window, reply] = openWindow(protocol, version, stimuli)
%OPENWINDOW  Opens the stimulus window and reports the viewing conditions.
%   What this reports reaches the session's environment record, so it is the
%   only place the resolution the participant actually saw is written down.

screens = Screen('Screens');
screenNumber = max(screens);
window = Screen('OpenWindow', screenNumber, 128);
[widthPx, heightPx] = Screen('WindowSize', window);
frameRate = Screen('FrameRate', screenNumber);
HideCursor;

% 'capabilities' names the optional commands this worker answers: abandon
% ends a presentation before its response, when the operator wants another
% stimulus at once or stops the session; message shows instructions, breaks,
% and closing text on this display.
reply = struct( ...
    'worker', 'psychtoolbox-reference', ...
    'protocol', protocol, ...
    'version', version, ...
    'capabilities', {{'abandon', 'message'}}, ...
    'stimuli', stimuli, ...
    'display_info', struct( ...
        'display_resolution', sprintf('%dx%d', widthPx, heightPx), ...
        'display_refresh_hz', sprintf('%g', frameRate), ...
        'display_backend', 'Psychtoolbox'));
end

function reply = present(server, window, request, clockOffset)
%PRESENT  Draws one stimulus, reads one response, and stamps both here.

if isempty(window)
    reply = struct('error', 'the display was never opened');
    return
end

fields = request.stimulus.fields;

% ---- Draw the stimulus -------------------------------------------------
% Replace this block with the laboratory's own stimulus. Its name arrives as
% request.stimulus.x_type (jsondecode renames _type) and its parameters, by
% name, in fields. The independent variable of the trial arrives twice: in
% request.values, in the order the design declares, and already bound into
% the parameter it names, so reading the parameter by name is usually enough.
Screen('FillRect', window, 128);
switch request.stimulus.x_type
    case 'number'
        % Declared in STIMULI at the top of this file
        Screen('TextSize', window, fields.text_size);
        DrawFormattedText(window, sprintf('%g', fields.value), ...
                          'center', 'center', 0);
    otherwise
        % A Julia stimulus type, such as BaseStimulusParameters
        if isfield(fields, 'duration_ms')
            Screen('TextSize', window, 48);
            DrawFormattedText(window, sprintf('%g', fields.duration_ms), ...
                              'center', 'center', 0);
        end
end

% Screen('Flip') returns the timestamp of the vertical retrace the stimulus
% appeared on: the most defensible onset available on this hardware.
[~, stimulusOnset] = Screen('Flip', window);

% ---- Read the response -------------------------------------------------
% request.timeout_s is the participant's response window, or empty for an
% unbounded wait. It is enforced HERE, because this process reads the device;
% the Julia side cannot end a wait it is not performing.
if isfield(request, 'timeout_s') && ~isempty(request.timeout_s)
    deadline = stimulusOnset + request.timeout_s;
else
    deadline = Inf;
end

% request.min_response_s drops a press made sooner after the onset: a double
% press, or a key still held from the previous trial (0 when none is asked for)
earliest = stimulusOnset;
if isfield(request, 'min_response_s') && ~isempty(request.min_response_s)
    earliest = stimulusOnset + request.min_response_s;
end

[response, responseTime] = awaitResponse(server, request.presentation, deadline, earliest);

if strcmp(response, 'abandoned')
    % Ended at PsychophysicsManager's request: nothing is recorded, so no timestamps
    Screen('FillRect', window, 128);
    Screen('Flip', window);
    reply = struct('response', 'abandoned');
elseif isempty(response)
    reply = struct('response', 'timeout', ...
                   'onset', stimulusOnset + clockOffset, ...
                   'timestamp_response', responseTime + clockOffset);
else
    reply = struct('response', response, ...
                   'onset', stimulusOnset + clockOffset, ...
                   'timestamp_response', responseTime + clockOffset);
end
end

function [response, responseTime] = awaitResponse(server, presentation, deadline, earliest)
%AWAITRESPONSE  One keypress in the abstract -1 / 0 / +1 coding.
%   Left arrow is -1, right arrow is +1, space confirms (0). An empty response
%   means the window closed with nothing answered, and 'abandoned' that
%   PsychophysicsManager asked for this presentation to end. A key down before
%   EARLIEST is not an answer.

leftKey  = KbName('LeftArrow');
rightKey = KbName('RightArrow');
spaceKey = KbName('space');
escapeKey = KbName('ESCAPE');

response = [];
responseTime = GetSecs();

while GetSecs() < deadline
    if abandonRequested(server, presentation)
        response = 'abandoned';
        responseTime = GetSecs();
        return
    end
    [pressed, secs, keyCode] = KbCheck(-1);
    if ~pressed || secs < earliest
        WaitSecs(0.001);
        continue
    end
    responseTime = secs;
    if keyCode(leftKey)
        response = -1;
    elseif keyCode(rightKey)
        response = 1;
    elseif keyCode(spaceKey)
        response = 0;
    elseif keyCode(escapeKey)
        error('pem:aborted', 'The operator pressed ESCAPE.');
    else
        continue
    end
    KbReleaseWait(-1);
    return
end

responseTime = GetSecs();
end

function abandoned = abandonRequested(server, presentation)
%ABANDONREQUESTED  Whether PsychophysicsManager asked for this presentation to end.
%   PsychophysicsManager sends nothing else while a presentation awaits its response, so
%   a line that arrives now is an abandon command; one naming another
%   presentation came too late for it and is ignored.

abandoned = false;
if server.NumBytesAvailable == 0
    return
end
request = jsondecode(readline(server));
abandoned = strcmp(request.command, 'abandon') && ...
            request.presentation == presentation;
end

function showFeedback(window, correct)
if isempty(window)
    return
end
if correct
    Screen('FillRect', window, [0 160 0]);
else
    Screen('FillRect', window, [160 0 0]);
end
Screen('Flip', window);
WaitSecs(0.2);
Screen('FillRect', window, 128);
Screen('Flip', window);
end

function showMessage(window, request)
%SHOWMESSAGE  Shows a message to the participant and waits if dismissible.
%   Draws request.text wrapped to 70 characters and flips the screen. For a
%   dismissible message, waits request.min_s and then waits for any key press.
%   A non-dismissible message returns immediately after the flip.

if isempty(window)
    return
end

Screen('FillRect', window, 128);
DrawFormattedText(window, request.text, 'center', 'center', 255, 70);
Screen('Flip', window);

if request.dismissible
    WaitSecs(request.min_s);
    KbReleaseWait;
    KbWait;
    KbReleaseWait;
end
end

function shutdown(window)
if ~isempty(window)
    Screen('CloseAll');
end
ShowCursor;
end
