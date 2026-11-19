# A PsychophysicsManager presentation worker driven over the standard streams rather than a
# socket, spawned by test_remote.jl. It is deliberately a separate process: the
# stdio transport is a claim about `Base.Process`, and the only way to check it
# is to have a real child on the other end of the pipes.
#
# Over stdio the worker's stdout carries protocol lines and nothing else — a
# stray `println` of its own would be read as a reply.

using JSON3

const PROTOCOL = parse(Int, ARGS[1])

while true
    line = readline(stdin)
    isempty(line) && break
    request = JSON3.read(line)
    command = request.command

    reply = if command == "hello"
        Dict("worker" => "stdio-worker", "protocol" => PROTOCOL,
             "display_info" => Dict("display_resolution" => "640x480"))
    elseif command == "present"
        Dict("response" => 1, "onset" => time(), "timestamp_response" => time())
    elseif command == "feedback"
        Dict("ok" => true)
    elseif command == "close"
        break
    else
        Dict("error" => "unknown command $command")
    end

    println(stdout, JSON3.write(reply))
    flush(stdout)
end
