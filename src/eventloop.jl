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
                    notify(idle_event)
                    if isdefined(Main, :Interact)
                        sleep(interact_min_delay)
                    end
                    # Dead events tell no tales
                    filter!(e->e.state == :open, hold_events)
                    wait_multi_with_timeout(hold_events, hold_events_timeout_default)
                    flush_all()
                    send_status("idle", msg)
                    clear(idle_event)
                    clear_temp_holds!(hold_events)
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


mutable struct Event
    channel::Channel{Bool}
    state::Symbol
    persistent::Bool
    function Event(p::Bool)
        c = Channel{Bool}(1)
        s = c.state
        x = new(c, s, p)
    end
end
function notify(x::Event) 
    if length(x.channel.data) < 1
        put!(x.channel, true)
        return true
    else
        return false
    end
end
function clear(x::Event)
    if length(x.channel.data) > 0
        take!(x.channel)
        return true
    else
        return false
    end
end
function close(x::Event)
    x.state = :closed
    close(x.channel)
end
function is_set(x::Event)
    return length(x.channel.data) > 0
end
function wait(x::Event)
    if !(length(x.channel.data) > 0)
        wait(x.channel)
    end      
end

#=
    Hold Channel Interface
    This allows user processes to register and deregister
    channels that allow user code to hold IJulia from sending
    the idle status message until signaled.  This would have
    been prettier if there were level-triggered events in
    Julia base, but this will do okay for now.

    Users should reset their own channels as IJulia will not
    reach into their channel state manually unless there is a
    timeout, in which case a temporary variable is put onto the channel
    buffer and removed after the wait process.
    See wait_multi_with_timeout()
=#
# Interact.jl band-aid compatibility code.
const interact_min_delay = 0.25

# Channel constants
const hold_events = Array{Event,1}()
const idle_event = Event(false)
const hold_events_timeout_default = 3

function wait_for_idle_ready()
    return wait(idle_event)
end
function add_hold_event(event::Event)
    if !(event in hold_events)
        hold_events = [hold_events..., event]
    end
end
function remove_hold_event(event::Event)
    if event in hold_events
        filter!(e->e∉[event],hold_events)
    end
end
function wait_multi_with_timeout(events::Array{Event,1}, timeout::Number)
    notification = Event(false)
    #=
        This async routine will manually fulfill any events (aka semaphores)
        that don't come through before the timeout.  Doing this because someone
        will inevitably not fulfill the semaphores that they register, and
        thus this will take care of us, at least for the short term.
    =#
    @async begin
        sleep(timeout)
        idxs_to_reset = []
        for i in eachindex(events)
            if !is_set(events[i])
                notify(events[i])
                idxs_to_reset = [idxs_to_reset..., i]
            end
        end
        wait(notification)
        for i in idxs_to_reset
            clear(events[i])
        end
    end
    for event in events
        wait(event)
    end
    notify(notification)
end

# Here I realized that without some way of clearing
# Events deterministically from IJulia's side,
# we would create race conditions all over the place.
function clear_temp_holds!(events::Array{Event,1})
    for event in events
        if !event.persistent
            clear(event)
        end
    end
end