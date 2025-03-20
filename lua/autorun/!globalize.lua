AddCSLuaFile()

local function Fallback(tbl, index, fallback)
    if not tbl then return end
    if not index then return end

    if tbl[index] == nil then
        tbl[index] = fallback
    end
    return tbl[index]
end

--------------------------------------------------------------------------------------------------------------------------------

Fallback(_G, "Globalize", {}) -- Globalize
Fallback(Globalize, "Internal", {}) -- Globalize.Internal
Fallback(Globalize.Internal, "Receivers", {}) -- Globalize.Internal.Receivers
Fallback(Globalize.Internal, "RateLimiting", {}) -- Globalize.Internal.RateLimiting
Fallback(Globalize.Internal, "GlobalVariables", {}) -- Globalize.Internal.GlobalVariables

--------------------------------------------------------------------------------------------------------------------------------

Globalize.Internal.MaxPacketSize = 2^15
Globalize.Internal.PacketSegmentDelay = 0.1
Globalize.Internal.RequestID = 0 -- Increments everytime we send a packet

local function bufferSplitter(buffer, maxBufferSize)
    local bufferLen = #buffer
    local bufferSplits = math.ceil(bufferLen / maxBufferSize)
    local buffers = {}
    for i = 1, bufferSplits do
        local start = (i - 1) * maxBufferSize + 1
        local endpos = i * maxBufferSize
        buffers[i] = buffer:sub(start, endpos)
    end
    return buffers
end

function Globalize.Internal.SplitPacket(Packet, MaxSize)
    local Size = #Packet
    if Size < MaxSize then return {}, 0 end

    local Splits = math.ceil(Size / MaxSize)
    local SegmentedPackets = {}

    for i=1, Splits do
        local Start = (i - 1) * MaxSize + 1
        local End = i * MaxSize
        SegmentedPackets[i] = Packet:sub(Start, End)
    end
    return SegmentedPackets, Splits
end

function Globalize.Internal.Message(...)
    MsgC(Color(255, 128, 0), "[Globalize]", Color(235, 235, 235), ": ", unpack({...}), "\n")
end

--------------------------------------------------------------------------------------------------------------------------------

local function WriteData(Data)
    local Size = #Data
    net.WriteUInt(#Data, 16)
    net.WriteData(Data, Size)
end

local function ReadData()
    local Size = net.ReadUInt(16)
    return net.ReadData(Size)
end

local function Send(Recipients)
    if CLIENT then
        net.SendToServer()
        return
    end

    local Type = type(Recipients)
    if Recipients and Type == "Player" or Type == "table" then 
        net.Send(Recipients)
        return
    end
    net.Broadcast()
end

--------------------------------------------------------------------------------------------------------------------------------

local function UncompressPacket(CompressedPacket)
    return util.JSONToTable(util.Decompress(CompressedPacket))
end

local function CreateCompressedPacket(NetworkID, Data)
    local Packet = {
        id = NetworkID,
        data = Data
    }

    return util.Compress(util.TableToJSON(Packet))
end

--------------------------------------------------------------------------------------------------------------------------------

if SERVER then
    util.AddNetworkString("Globalize.NetworkChannel")

    function Globalize.LimitRate(NetworkID, Ply, Delay)
        if not NetworkID then return false end
        if not IsValid(Ply) then return false end
        if not Delay then return false end
        if Delay <= 0 then return false end

        local IsLimited = false

        local CurrentTime = CurTime()
        local PlayerID = Ply:SteamID64()

        local Internal = Globalize.Internal

        Fallback(Internal.RateLimiting, PlayerID, {})
        Fallback(Internal.RateLimiting[PlayerID], NetworkID, 0)

        if Internal.RateLimiting[PlayerID][NetworkID] > CurrentTime then
            IsLimited = true
        end

        Internal.RateLimiting[PlayerID][NetworkID] = CurrentTime + Delay

        return IsLimited
    end

    function Globalize.Send(NetworkID, Data, Recipients)
        if not NetworkID then return end
        if not Data then Data = {} end

        local Internal = Globalize.Internal

        Internal.RequestID = Internal.RequestID + 1 -- Used for differencing packets from the same NetworkID but not from the same unsegmented packet

        local CompressedPacket = CreateCompressedPacket(NetworkID, Data)
        local Segments, NumSegments = Internal.SplitPacket(CompressedPacket, Internal.MaxPacketSize)

        if NumSegments == 0 then
            net.Start("Globalize.NetworkChannel")

            net.WriteBool(false) -- Packet segmented?
            WriteData(CompressedPacket) -- Data
    
            Send(Recipients)
            return
        end

        Globalize.Internal.Message(
            string.format("Packet too BIG (%i bytes) max(%i bytes), Segmenting packet (%i Segments) (%i bytes max) (eta %G seconds)", 
            #CompressedPacket, 
            Internal.MaxPacketSize, 
            NumSegments, 
            Internal.MaxPacketSize,
            NumSegments * Internal.PacketSegmentDelay
        ))

        local SegmentsSent = 0
        local SegmentID = Internal.RequestID

        timer.Create(NetworkID .. math.random(-9e9, 9e9), Internal.PacketSegmentDelay, NumSegments, function()
            SegmentsSent = SegmentsSent + 1
            local Segment = Segments[SegmentsSent]

            net.Start("Globalize.NetworkChannel")

            net.WriteBool(true) -- Packet segmented?
            net.WriteUInt(SegmentID, 16) -- Segment ID
            net.WriteUInt(SegmentsSent, 16) -- Segments sent
            net.WriteUInt(NumSegments, 16) -- Number of segments
            WriteData(Segment) -- Data 

            Send(Recipients)
        end)
    end

    function Globalize.Internal.CallReceiver(NetworkID, Data, Len, Ply)
        if not NetworkID then return end
        if not Data then return end
        if not Globalize.Internal.Receivers[NetworkID] then return end
        if not IsValid(Ply) then return end

        local _Receiver = Globalize.Internal.Receivers[NetworkID]

        local Callback = _Receiver.callback
        local Delay = _Receiver.ratelimit

        if Globalize.LimitRate(NetworkID, Ply, Delay) then
            Globalize.Internal.Message(string.format("[%s|%i|%s] hit ratelimit! [%s] only accepts packets every %G seconds", 
                Ply:Name(), 
                Ply:EntIndex(), 
                Ply:SteamID(), 
                NetworkID, 
                Delay
            ))
            return
        end

        Callback(Data, Len, Ply)
    end
end

--------------------------------------------------------------------------------------------------------------------------------

if CLIENT then
    function Globalize.Send(NetworkID, Data)
        if not NetworkID then return end
        if not Data then Data = {} end

        local Internal = Globalize.Internal

        Internal.RequestID = Internal.RequestID + 1 -- Used for differencing packets from the same NetworkID but not from the same unsegmented packet

        local CompressedPacket = CreateCompressedPacket(NetworkID, Data)
        local Segments, NumSegments = Internal.SplitPacket(CompressedPacket, Internal.MaxPacketSize)

        if NumSegments == 0 then
            net.Start("Globalize.NetworkChannel")

            net.WriteBool(false) -- Packet segmented?
            WriteData(CompressedPacket) -- Data
    
            Send()
        end

        Globalize.Internal.Message(
            string.format("Packet too BIG (%i bytes) max(%i bytes), Segmenting packet (%i Segments) (%i bytes max) (eta %G seconds)", 
            #CompressedPacket, 
            Internal.MaxPacketSize, 
            NumSegments, 
            Internal.MaxPacketSize,
            NumSegments * Internal.PacketSegmentDelay
        ))

        local SegmentsSent = 0
        local SegmentID = Internal.RequestID

        timer.Create(NetworkID .. math.random(-9e9, 9e9), Internal.PacketSegmentDelay, NumSegments, function()
            SegmentsSent = SegmentsSent + 1
            local Segment = Segments[SegmentsSent]

            net.Start("Globalize.NetworkChannel")

            net.WriteBool(true) -- Packet segmented?
            net.WriteUInt(SegmentID, 16) -- Segment ID
            net.WriteUInt(SegmentsSent, 16) -- Segments sent
            net.WriteUInt(NumSegments, 16) -- Number of segments
            WriteData(Segment) -- Data 

            Send()
        end)
    end

    function Globalize.Internal.CallReceiver(NetworkID, Data, Len, Ply)
        if not NetworkID then return end
        if not Data then return end
        if not Globalize.Internal.Receivers[NetworkID] then return end
    
        local _Receiver = Globalize.Internal.Receivers[NetworkID]

        local Callback = _Receiver.callback

        Callback(Data, Len, Ply)
    end
end

--------------------------------------------------------------------------------------------------------------------------------

function Globalize.Subscribe(NetworkID, Callback, RateLimit)
    if not NetworkID then return end
    if not Callback then return end

    local Internal = Globalize.Internal

    Fallback(Internal.Receivers, NetworkID, {})

    Internal.Receivers[NetworkID] = {
        callback = Callback,
        ratelimit = RateLimit or 0
    }
end

function Globalize.Unsubscribe(NetworkID)
    if not NetworkID then return end

    local Internal = Globalize.Internal

    Fallback(Internal.Receivers, NetworkID, {})

    Internal.Receivers[NetworkID] = nil
end

--------------------------------------------------------------------------------------------------------------------------------

Globalize.Internal.ActiveSegmentedPackets = {}
net.Receive("Globalize.NetworkChannel", function(len, ply)
    local IsSegmented = net.ReadBool()
    
    if IsSegmented then
        
        local SegmentID = net.ReadUInt(16)
        local SegmentsSent = net.ReadUInt(16)
        local NumSegments = net.ReadUInt(16)
        local Segment = ReadData()

        local SegmentedPacket = Fallback(Globalize.Internal.ActiveSegmentedPackets, SegmentID, {
            data = "",
            len = 0
        })

        SegmentedPacket.data = SegmentedPacket.data .. Segment
        SegmentedPacket.len = SegmentedPacket.len + len

        if SegmentsSent == NumSegments then
            local CompressedPacket = SegmentedPacket
            local len = SegmentedPacket.len

            ActiveSegPackets[SegmentID] = nil

            local Packet = UncompressPacket(CompressedPacket.data)
            Globalize.Internal.CallReceiver(Packet.id, Packet.data, len, ply)
        end

        return
    end

    local Packet = UncompressPacket(ReadData())

    Globalize.Internal.CallReceiver(Packet.id, Packet.data, len, ply)
end)

--------------------------------------------------------------------------------------------------------------------------------

function Globalize.SetGlobal(VariableID, ...)
    if VariableID == nil then return end

    local Data = {...}

    local GlobalVariables = Globalize.Internal.GlobalVariables

    Globalize.Send("GlobalizeInternalGlobalVar", {
        VariableID = VariableID,
        Data = Data
    })

    table.CopyFromTo(Data, GlobalVariables[VariableID])
end

function Globalize.GetGlobal(VariableID)
    if VariableID == nil then return end

    local GlobalVariables = Globalize.Internal.GlobalVariables

    return unpack(GlobalVariables[VariableID])
end

function Globalize.Internal.NetworkGlobal(VariableID, Ply)
    if VariableID == nil then return end

    local Data = {Globalize.GetGlobal(VariableID)}

    Globalize.Send("GlobalizeInternalGlobalVar", {
        VariableID = VariableID,
        Data = Data
    }, Ply)
end

--------------------------------------------------------------------------------------------------------------------------------

Globalize.Subscribe("GlobalizeInternalGlobalVar", function(Packet)
    local VariableID = Packet.VariableID
    local Data = Packet.Data

    Globalize.SetGlobal(VariableID, unpack(Data))
end)

--------------------------------------------------------------------------------------------------------------------------------

if CLIENT then
    hook.Add("InitPostEntity", "GlobalizeAskData", function()
        Globalize.Send("GlobalizeInternalAskForGlobalVar")
    end)
end

if SERVER then
    Globalize.Subscribe("GlobalizeInternalAskForGlobalVar", function(Packet, len, ply)
        local GlobalVariables = Globalize.Internal.GlobalVariables

        for VariableID in pairs(GlobalVariables) do
            Globalize.Internal.NetworkGlobal(VariableID, ply)
        end
    end)
end
