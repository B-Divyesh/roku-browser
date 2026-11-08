' Long-polls the laptop for new frames and page state, and finds the laptop
' by broadcast when it can't be reached (new IP, first run).

sub init()
    m.top.functionName = "work"
end sub

sub work()
    since = -1
    sv = -1
    failures = 0
    uiWidth = CreateObject("roDeviceInfo").GetUIResolution().width
    while true
        server = m.top.server
        if server = "" or failures >= 2
            found = discover()
            if found <> ""
                failures = 0
                if found <> server
                    server = found
                    m.top.server = found
                end if
            end if
        end if

        if server = ""
            m.top.online = false
            sleep(1500)
        else
            body = fetch(server + "/poll?since=" + since.toStr() + "&sv=" + sv.toStr() + "&w=" + uiWidth.toStr(), 15000)
            data = invalid
            if body <> invalid then data = ParseJson(body)
            if data = invalid
                failures = failures + 1
                if failures >= 2 then m.top.online = false
                sleep(1000)
            else
                failures = 0
                since = data.frame
                sv = data.sv
                data.server = server
                m.top.update = data
                m.top.online = true
            end if
        end if
    end while
end sub

function fetch(url as string, timeoutMs as integer) as dynamic
    xfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    xfer.setMessagePort(port)
    xfer.setUrl(url)
    if not xfer.AsyncGetToString() then return invalid
    msg = wait(timeoutMs, port)
    if type(msg) = "roUrlEvent"
        if msg.getResponseCode() = 200 then return msg.getString()
        return invalid
    end if
    xfer.AsyncCancel()
    return invalid
end function

' Asks every machine on the network for roku-browser; it answers with its address.
function discover() as string
    udp = CreateObject("roDatagramSocket")
    port = CreateObject("roMessagePort")
    udp.setMessagePort(port)
    bindAddr = CreateObject("roSocketAddress")
    bindAddr.setPort(8767)
    udp.setAddress(bindAddr)
    udp.setBroadcast(true)
    dest = CreateObject("roSocketAddress")
    dest.setAddress("255.255.255.255:8766")
    udp.setSendToAddress(dest)
    udp.notifyReadable(true)
    result = ""
    for attempt = 1 to 3
        udp.sendStr("ROKU-BROWSER?")
        msg = wait(800, port)
        if type(msg) = "roSocketEvent" and udp.isReadable()
            data = ParseJson(udp.receiveStr(512))
            if data <> invalid and data.server <> invalid
                result = data.server
                exit for
            end if
        end if
    end for
    udp.close()
    return result
end function
