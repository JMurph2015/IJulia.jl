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
                    notify(idle_ready_event)
                    if isdefined(Main, :Interact)
                        sleep(interact_min_delay)
                    end
                    # Dead events tell no tales
                    filter!(e->e.state == :open, idle_hold_events)
                    wait.(idle_hold_events)
                    flush_all()
                    send_status("idle", msg)
                    clear(idle_ready_event)
                    clear_temp_holds!(idle_hold_events)
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

    Users have the option of making a 'persistent hold' or
    a 'temporary hold'.  The difference between the two is
    that IJulia will clear temporary holds on every idle
    send.
=#
# Interact.jl band-aid compatibility code.
const interact_min_delay = 0.25

# Channel constants
const idle_hold_events = Array{Event,1}()
const idle_ready_event = Event(false)
const hold_events_timeout_default = 3

"""
    `wait_for_idle_ready()``

    This function blocks until IJulia is ready to send another
    idle status message, before any holds are awaited.
    Use this function to hook into IJulia to reactively hold
    it (or do other things) as it sends an idle message.

    Note: Holds initiated or cleared after this function
    reuturns will have a race condition with IJulia waiting on them.
    Therefore, reactionary code should be set up to hold IJulia by
    default and reactionarily do things with that block in place.
"""
function wait_for_idle_ready()
    return wait(idle_event)
end

"""
    This function is used to add a signal of type Event to block
    IJulia from sending an idle status reply until after the event
    has been set via `notify(event)`.
"""
function add_hold_event(event::Event)
    if !(event in hold_events)
        hold_events = [hold_events..., event]
    end
end

"""
    This function removes an event from IJulia's array of known
    events, and thus stops IJulia from waiting on the event.
    The event supplied must be a reference to the same oject 
    as was registered.
"""
function remove_hold_event(event::Event)
    if event in hold_events
        filter!(e->e != event,hold_events)
    end
end

# On the ropse, removed from main loop, but still an option.
function wait_multi_with_timeout(events::Array{Event,1}, timeout::Number)
    notification = Event(false)
    response = Event(false)
    #=
        This async routine will manually fulfill any events (aka semaphores)
        that don't come through before the timeout.  Doing this because someone
        will inevitably not fulfill the semaphores that they register, and
        thus this will take care of us, at least for the short term.
    =#
    @async begin
        sleep(timeout)
        reset = true
        for i in 1:ceil(Int, timeout/0.001)
            if (sum(is_set.(events)) == length(events))
                reset = false
                break
            end
        if reset
            idxs_to_reset = Array{Int64, 1}()
            for i in eachindex(events):
                if !is_set(events[i])
                    notify(event)
                    push!(idxs_to_reset, i)
                end
            end
            wait(notification)
            for i in idxs_to_reset
                clear(events[i])
            end
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