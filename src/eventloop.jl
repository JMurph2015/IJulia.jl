function eventloop(socket)
    task_local_storage(:IJulia_task, "write task")
    try
        while true
            msg = recv_ipython(socket)
            try
                send_status("busy", msg)
                invokelatest(handlers[msg.header["msg_type"]], socket, msg)
            catch e
                # Try to keep going if we get an exception, but
                # send the exception traceback to the front-ends.
                # (Ignore SIGINT since this may just be a user-requested
                #  kernel interruption to interrupt long calculations.)
                if !isa(e, InterruptException)
                    content = error_content(e, msg="KERNEL EXCEPTION")
                    map(s -> println(orig_STDERR[], s), content["traceback"])
                    send_ipython(publish[], msg_pub(execute_msg, "error", content))
                end
            finally
                @async begin
                    readycount[] = 1
                    if isdefined(Main, :Interact)
                        sleep(interact_min_delay)
                    end
                    wait(idlecond)
                    flush_all()
                    send_status("idle", msg)
                    readycount[] = 0
                end
            end
        end
    catch e
        # the Jupyter manager may send us a SIGINT if the user
        # chooses to interrupt the kernel; don't crash on this
        if isa(e, InterruptException)
            eventloop(socket)
        else
            rethrow()
        end
    end
end

function waitloop()
    @async eventloop(control[])
    requests_task = @async eventloop(requests[])
    while true
        try
            wait()
        catch e
            # send interrupts (user SIGINT) to the code-execution task
            if isa(e, InterruptException)
                @async Base.throwto(requests_task, e)
            else
                rethrow()
            end
        end
    end
end

# Interact.jl band-aid compatibility code.
const interact_min_delay = 0.25
const busycount = Ref(0)
const readycount = Ref(0)
const idlecond = Condition()
const readycond = Condition()

"""
    IJulia.busy()
    Add to IJulia's lock preventing it from sending the idle condition.
    This is intended for scenarios where output will be streamed asynchronously
    to a Jupyter notebook.
"""
function busy()
    busycount[] += 1
end
"""
    IJulia.idle()
    Decrement IJulia's lock holding the idle status reply.
    Use this to allow IJulia to send idle signals.
"""
function idle()
    busycount[] -= 1
    notify(idlecond)
end

function waitidle()
    while busycount[] > 0
        wait(idlecond)
    end
end

"""
    wait_for_ready()
    This function blocks until IJulia is preparing to send an idle message.
    Use this to reactively hold IJulia from sending an idle status.
    For instance, the code below starts a task that persistently delays
    IJulia's idle signals by at least 0.5 seconds.
    @async begin
        while true
            IJulia.wait_for_ready()
            IJulia.busy()
            sleep(0.5)
            IJulia.idle()
        end
    end
"""
function wait_for_ready()
    while readycount[] <= 0
        wait(readycond)
    end
end
        