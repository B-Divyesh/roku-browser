' Browser: shows web pages rendered by roku-browser on the laptop.
sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)
    scene = screen.CreateScene("BrowserScene")
    screen.show()

    ' Deep links sent while the channel is already open (ECP /input) arrive here.
    input = CreateObject("roInput")
    input.setMessagePort(port)
    scene.observeField("exitApp", port)
    scene.launchArgs = args

    while true
        msg = wait(0, port)
        t = type(msg)
        if t = "roSGScreenEvent"
            if msg.isScreenClosed() then return
        else if t = "roSGNodeEvent"
            if msg.getField() = "exitApp" then return
        else if t = "roInputEvent"
            if msg.isInput() then scene.inputArgs = msg.getInfo()
        end if
    end while
end sub
