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
                    idle_ready_event += 1
                    if isdefined(Main, :Interact)
                        sleep(interact_min_delay)
                    end
                    wait(idle_hold_cond)
                    flush_all()
                    send_status("idle", msg)
                    idle_ready_event -= 1
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
const idle_hold_cond = LevelTrigger()
const idle_ready_event = LevelTrigger()

"""
    Increment the semaphore to hold IJulia from sending the "status":"idle" message.
"""
function busy()
    idle_hold_cond += 1
end
"""
    Decrement the semaphore that holds IJulia from sending the "status":"idle" message.
"""
function idle()
    idle_hold_cond -= 1
end
"""
    Wait until IJulia is ready to send an "status":"idle" message.
"""
function wait_for_ready()
    wait(idle_ready_event)
end

# Define an even more simple level triggered event so that we can easily wait on it.
import Base.+, Base.-, Base.notify, Base.wait
mutable struct LevelTrigger
    state::Ref{Int}
    cond::Condition
    LevelTrigger() = new(Ref(0), Condition())
end
notify(x::LevelTrigger) = notify(x.cond)
wait(x::LevelTrigger) = (x.state[] > 0 ? wait(x.cond) : Void; Void)
+(x::LevelTrigger, y::Any) = (x.state[]+=y;x)::LevelTrigger
+(y::Any, x::LevelTrigger) = +(x,y)::LevelTrigger
-(x::LevelTrigger, y::Any) = (x.state[]-=y; x.state[] <= 0 ? notify(x) : Void; x)::LevelTrigger
-(y::Any, x::LevelTrigger) = y-x.state[]
