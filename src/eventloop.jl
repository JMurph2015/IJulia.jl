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
                    if check_interact_loaded() && idle_delay[] < 0.5
                        set_idle_delay(0.5)
                    end
                    if idle_delay[] > 0
                        sleep(idle_delay[])
                    end
                    for channel in hold_channels
                        wait(channel)
                    end
                    # alt code for Julia 0.6+
                    # wait.(hold_channels)
                    flush_all()
                    send_status("idle", msg)
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

const idle_delay = Ref(0)
function set_idle_delay(delay_secs::Float64=0.5)
    idle_delay[] = delay_secs
end

const hold_channels = Array{Channel{Bool},1}()
function add_hold_channel(channel::Channel{Bool})
    if !(channel in hold_channels)
        hold_channels = [hold_channels..., channel]
    end
end

# Interact.jl compatibility code
function check_interact_loaded()
    return isdefined(:Interact)
end
