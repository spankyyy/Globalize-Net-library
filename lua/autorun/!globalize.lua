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

local net_Start = net.Start
local net_WriteUInt = net.WriteUInt
local net_WriteData = net.WriteData
local net_WriteBool = net.WriteBool
local net_ReadUInt = net.ReadUInt
local net_ReadData = net.ReadData
local net_ReadBool = net.ReadBool
local net_Receive = net.Receive
local net_SendToServer = net.SendToServer
local net_Send = net.Send
local net_Broadcast = net.Broadcast
local timer_Create = timer.Create
local hook_Add = hook.Add
local hook_Run = hook.Run
local math_random = math.random
local math_ceil = math.ceil
local util_Compress = util.Compress
local util_Decompress = util.Decompress
local util_JSONToTable = util.JSONToTable
local util_TableToJSON = util.TableToJSON
local util_AddNetworkString = util.AddNetworkString
local string_format = string.format

local CurTime = CurTime
local MsgC = MsgC
local IsValid = IsValid

--------------------------------------------------------------------------------------------------------------------------------

local GlobalizeInternal = {}

Fallback(_G, "Globalize", {}) -- Globalize
Fallback(GlobalizeInternal, "Receivers", {}) -- GlobalizeInternal.Receivers
Fallback(GlobalizeInternal, "RateLimiting", {}) -- GlobalizeInternal.RateLimiting
Fallback(GlobalizeInternal, "GlobalVariables", {}) -- GlobalizeInternal.GlobalVariables

--------------------------------------------------------------------------------------------------------------------------------

GlobalizeInternal.MaxPacketSize = 2^15
GlobalizeInternal.PacketSegmentDelay = 0.1
GlobalizeInternal.RequestID = 0 -- Increments everytime we send a packet

--------------------------------------------------------------------------------------------------------------------------------

local function bufferSplitter(buffer, maxBufferSize)
    local bufferLen = #buffer
    local bufferSplits = math_ceil(bufferLen / maxBufferSize)
    local buffers = {}
    for i = 1, bufferSplits do
        local start = (i - 1) * maxBufferSize + 1
        local endpos = i * maxBufferSize
        buffers[i] = buffer:sub(start, endpos)
    end
    return buffers
end

function GlobalizeInternal.SplitPacket(Packet, MaxSize)
    local Size = #Packet
    if Size < MaxSize then return {}, 0 end

    local Splits = math_ceil(Size / MaxSize)
    local SegmentedPackets = {}

    for i=1, Splits do
        local Start = (i - 1) * MaxSize + 1
        local End = i * MaxSize
        SegmentedPackets[i] = Packet:sub(Start, End)
    end
    return SegmentedPackets, Splits
end

function GlobalizeInternal.Message(...)
    MsgC(Color(255, 128, 0), "[Globalize]", Color(235, 235, 235), ": ", unpack({...}), "\n")
end

--------------------------------------------------------------------------------------------------------------------------------

local function WriteData(Data)
    local Size = #Data
    net_WriteUInt(#Data, 16)
    net_WriteData(Data, Size)
end

local function ReadData()
    local Size = net_ReadUInt(16)
    return net_ReadData(Size)
end

local function Send(Recipients)
    if CLIENT then
        net_SendToServer()
        return
    end

    local Type = type(Recipients)
    if Recipients and Type == "Player" or Type == "table" then 
        net_Send(Recipients)
        return
    end
    net_Broadcast()
end

--------------------------------------------------------------------------------------------------------------------------------

local function UncompressPacket(CompressedPacket)
    return util_JSONToTable(util_Decompress(CompressedPacket))
end

local function CreateCompressedPacket(NetworkID, Data)
    local Packet = {
        id = NetworkID,
        data = Data
    }

    return util_Compress(util_TableToJSON(Packet))
end

--------------------------------------------------------------------------------------------------------------------------------

if SERVER then
    util_AddNetworkString("Globalize.NetworkChannel")

    function Globalize.LimitRate(NetworkID, Ply, Delay)
        if not NetworkID then return false end
        if not IsValid(Ply) then return false end
        if not Delay then return false end
        if Delay <= 0 then return false end

        local IsLimited = false

        local CurrentTime = CurTime()
        local PlayerID = Ply:SteamID64()

        Fallback(GlobalizeInternal.RateLimiting, PlayerID, {})
        Fallback(GlobalizeInternal.RateLimiting[PlayerID], NetworkID, 0)

        if GlobalizeInternal.RateLimiting[PlayerID][NetworkID] > CurrentTime then
            IsLimited = true
        end

        GlobalizeInternal.RateLimiting[PlayerID][NetworkID] = CurrentTime + Delay

        return IsLimited
    end

    function Globalize.Send(NetworkID, Data, Recipients)
        if not NetworkID then return end
        if not Data then Data = {} end

        GlobalizeInternal.RequestID = GlobalizeInternal.RequestID + 1 -- Used for differencing packets from the same NetworkID but not from the same unsegmented packet

        local CompressedPacket = CreateCompressedPacket(NetworkID, Data)
        local Segments, NumSegments = GlobalizeInternal.SplitPacket(CompressedPacket, GlobalizeInternal.MaxPacketSize)

        if NumSegments == 0 then
            net_Start("Globalize.NetworkChannel")

            net_WriteBool(false) -- Packet segmented?
            WriteData(CompressedPacket) -- Data
    
            Send(Recipients)
            return
        end

        GlobalizeInternal.Message(
            string_format("Packet too BIG (%i bytes) max(%i bytes), Segmenting packet (%i Segments) (%i bytes max) (eta %G seconds)", 
            #CompressedPacket, 
            GlobalizeInternal.MaxPacketSize, 
            NumSegments, 
            GlobalizeInternal.MaxPacketSize,
            NumSegments * GlobalizeInternal.PacketSegmentDelay
        ))

        local SegmentsSent = 0
        local SegmentID = GlobalizeInternal.RequestID

        timer_Create(NetworkID .. math_random(-9e9, 9e9), GlobalizeInternal.PacketSegmentDelay, NumSegments, function()
            SegmentsSent = SegmentsSent + 1
            local Segment = Segments[SegmentsSent]

            net_Start("Globalize.NetworkChannel")

            net_WriteBool(true) -- Packet segmented?
            net_WriteUInt(SegmentID, 16) -- Segment ID
            net_WriteUInt(SegmentsSent, 16) -- Segments sent
            net_WriteUInt(NumSegments, 16) -- Number of segments
            WriteData(Segment) -- Data 

            Send(Recipients)
        end)
    end

    function GlobalizeInternal.CallReceiver(NetworkID, Data, Len, Ply)
        if not NetworkID then return end
        if not Data then return end
        if not GlobalizeInternal.Receivers[NetworkID] then return end
        if not IsValid(Ply) then return end

        local _Receiver = GlobalizeInternal.Receivers[NetworkID]

        local Callback = _Receiver.callback
        local Delay = _Receiver.ratelimit

        if Globalize.LimitRate(NetworkID, Ply, Delay) then
            GlobalizeInternal.Message(string_format("[%s|%i|%s] hit ratelimit! [%s] only accepts packets every %G seconds", 
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

        GlobalizeInternal.RequestID = GlobalizeInternal.RequestID + 1 -- Used for differencing packets from the same NetworkID but not from the same unsegmented packet

        local CompressedPacket = CreateCompressedPacket(NetworkID, Data)
        local Segments, NumSegments = GlobalizeInternal.SplitPacket(CompressedPacket, GlobalizeInternal.MaxPacketSize)

        if NumSegments == 0 then
            net_Start("Globalize.NetworkChannel")

            net_WriteBool(false) -- Packet segmented?
            WriteData(CompressedPacket) -- Data
    
            Send()
        end

        GlobalizeInternal.Message(
            string_format("Packet too BIG (%i bytes) max(%i bytes), Segmenting packet (%i Segments) (%i bytes max) (eta %G seconds)", 
            #CompressedPacket, 
            GlobalizeInternal.MaxPacketSize, 
            NumSegments, 
            GlobalizeInternal.MaxPacketSize,
            NumSegments * GlobalizeInternal.PacketSegmentDelay
        ))

        local SegmentsSent = 0
        local SegmentID = GlobalizeInternal.RequestID

        timer_Create(NetworkID .. math_random(-9e9, 9e9), GlobalizeInternal.PacketSegmentDelay, NumSegments, function()
            SegmentsSent = SegmentsSent + 1
            local Segment = Segments[SegmentsSent]

            net_Start("Globalize.NetworkChannel")

            net_WriteBool(true) -- Packet segmented?
            net_WriteUInt(SegmentID, 16) -- Segment ID
            net_WriteUInt(SegmentsSent, 16) -- Segments sent
            net_WriteUInt(NumSegments, 16) -- Number of segments
            WriteData(Segment) -- Data 

            Send()
        end)
    end

    function GlobalizeInternal.CallReceiver(NetworkID, Data, Len, Ply)
        if not NetworkID then return end
        if not Data then return end
        if not GlobalizeInternal.Receivers[NetworkID] then return end
    
        local _Receiver = GlobalizeInternal.Receivers[NetworkID]

        local Callback = _Receiver.callback

        Callback(Data, Len, Ply)
    end
end

--------------------------------------------------------------------------------------------------------------------------------

function Globalize.Subscribe(NetworkID, Callback, RateLimit)
    if not NetworkID then return end
    if not Callback then return end

    

    Fallback(GlobalizeInternal.Receivers, NetworkID, {})

    GlobalizeInternal.Receivers[NetworkID] = {
        callback = Callback,
        ratelimit = RateLimit or 0
    }
end

function Globalize.Unsubscribe(NetworkID)
    if not NetworkID then return end

    

    Fallback(GlobalizeInternal.Receivers, NetworkID, {})

    GlobalizeInternal.Receivers[NetworkID] = nil
end

--------------------------------------------------------------------------------------------------------------------------------

GlobalizeInternal.ActiveSegmentedPackets = {}
net_Receive("Globalize.NetworkChannel", function(len, ply)
    local IsSegmented = net_ReadBool()
    
    
    if IsSegmented then
        
        local SegmentID = net_ReadUInt(16)
        local SegmentsSent = net_ReadUInt(16)
        local NumSegments = net_ReadUInt(16)
        local Segment = ReadData()

        local SegmentedPacket = Fallback(GlobalizeInternal.ActiveSegmentedPackets, SegmentID, {
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
            GlobalizeInternal.CallReceiver(Packet.id, Packet.data, len, ply)
        end

        return
    end

    local Packet = UncompressPacket(ReadData())

    GlobalizeInternal.CallReceiver(Packet.id, Packet.data, len, ply)
end)

--------------------------------------------------------------------------------------------------------------------------------

function GlobalizeInternal.SetGlobal(VariableID, ...)
    if VariableID == nil then return end

    local Data = {...}

    local GlobalVariables = GlobalizeInternal.GlobalVariables

    GlobalVariables[VariableID] = Data

    hook_Run("GlobalizeGlobalChanged", GlobalVariables[VariableID])

    return Data
end

function GlobalizeInternal.NetworkGlobal(VariableID, Ply)
    if VariableID == nil then return end

    local Data = {Globalize.GetGlobal(VariableID)}

    Globalize.Send("GlobalizeInternalGlobalVar", {
        VariableID = VariableID,
        Data = Data
    }, Ply)

    return Data
end

--------------------------------------------------------------------------------------------------------------------------------

function Globalize.SetGlobal(VariableID, ...)
    if CLIENT then return end
    if VariableID == nil then return end

    local Data = GlobalizeInternal.SetGlobal(VariableID, ...)

    Globalize.Send("GlobalizeInternalGlobalVar", {
        VariableID = VariableID,
        Data = Data
    })

    return Data
end

function Globalize.GetGlobal(VariableID)
    if VariableID == nil then return end

    local GlobalVariables = GlobalizeInternal.GlobalVariables

    if GlobalVariables[VariableID] == nil then return end

    return unpack(GlobalVariables[VariableID])
end

--------------------------------------------------------------------------------------------------------------------------------

Globalize.Subscribe("GlobalizeInternalGlobalVar", function(Packet)
    local VariableID = Packet.VariableID
    local Data = Packet.Data

    GlobalizeInternal.SetGlobal(VariableID, unpack(Data))
end)

--------------------------------------------------------------------------------------------------------------------------------

if CLIENT then
    hook_Add("InitPostEntity", "GlobalizeAskData", function()
        Globalize.Send("GlobalizeInternalAskForGlobalVar")
    end)
end

if SERVER then
    Globalize.Subscribe("GlobalizeInternalAskForGlobalVar", function(Packet, len, ply)
        local GlobalVariables = GlobalizeInternal.GlobalVariables

        for VariableID in pairs(GlobalVariables) do
            GlobalizeInternal.NetworkGlobal(VariableID, ply)
        end
    end)
end
