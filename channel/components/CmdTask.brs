' Sends remote-control actions to the laptop one at a time, in order, and
' reports each reply back to the scene.

sub init()
    m.top.functionName = "work"
end sub

sub work()
    port = CreateObject("roMessagePort")
    m.top.observeField("cmd", port)
    while true
        msg = wait(0, port)
        if type(msg) = "roSGNodeEvent"
            c = msg.getData()
            if c <> invalid and c.t <> invalid then send(c)
        end if
    end while
end sub

sub send(c as object)
    xfer = CreateObject("roUrlTransfer")
    query = "t=" + c.t
    if c.args <> invalid
        for each k in c.args
            query = query + "&" + k + "=" + xfer.Escape(c.args[k].toStr())
        end for
    end if
    port = CreateObject("roMessagePort")
    xfer.setMessagePort(port)
    xfer.setUrl(m.top.server + "/input?" + query)
    timeoutMs = 8000
    if c.timeout <> invalid then timeoutMs = c.timeout
    reply = invalid
    if xfer.AsyncGetToString()
        msg = wait(timeoutMs, port)
        if type(msg) = "roUrlEvent"
            if msg.getResponseCode() = 200 then reply = ParseJson(msg.getString())
        else
            xfer.AsyncCancel()
        end if
    end if
    if reply = invalid then reply = {failed: true}
    m.top.result = {id: c.id, t: c.t, reply: reply}
end sub
