AddCSLuaFile()

--------------------------------------------------------------------------------------------------------------------------------

local net_Start = net.Start
local net_WriteUInt = net.WriteUInt
local _net_WriteData = net.WriteData
local net_ReadUInt = net.ReadUInt
local _net_ReadData = net.ReadData
local net_ReadBool = net.ReadBool
local net_Receive = net.Receive
local net_SendToServer = net.SendToServer
local hook_Add = hook.Add
local hook_Run = hook.Run
local _util_Compress = util.Compress
local _util_Decompress = util.Decompress
local util_JSONToTable = util.JSONToTable
local util_TableToJSON = util.TableToJSON

local MsgC = MsgC

--------------------------------------------------------------------------------------------------------------------------------

_G.Globalize = {}
local GlobalizeInternal = {}

GlobalizeInternal.Receivers = {}
GlobalizeInternal.GlobalVariables = {}
GlobalizeInternal.ActiveSegmentedPackets = {}

--------------------------------------------------------------------------------------------------------------------------------

function GlobalizeInternal.Message(...)
    MsgC(Color(255, 128, 0), "[Globalize]", Color(235, 235, 235), ": ", unpack({...}), "\n")
end

local function Fallback(tbl, index, fallback)
    if not tbl then return end
    if not index then return end

    if tbl[index] == nil then
        tbl[index] = fallback
    end
    return tbl[index]
end

--------------------------------------------------------------------------------------------------------------------------------

local function util_Compress(Data)
    if #Data > 1e8 then 
        GlobalizeInternal.Message("ERROR - Data too long for compression!")
        return 
    end


    return _util_Compress(Data)
end

local function util_Decompress(Data, MaxSize)
    if not Data then return end

    if MaxSize ~= nil and MaxSize > 1e8 then 
        GlobalizeInternal.Message("ERROR - Max size too big for decompression!")
        return 
    end

    if #Data > 1e8 then 
        GlobalizeInternal.Message("ERROR - Data too long for decompression!")
        return 
    end

    if #Data < 13 then 
        GlobalizeInternal.Message("ERROR - Data too short for decompression!")
        return 
    end

    return _util_Decompress(Data)
end

--------------------------------------------------------------------------------------------------------------------------------

local function net_WriteData(Data)
    local Size = #Data
    net_WriteUInt(#Data, 16)
    _net_WriteData(Data, Size)
end

local function net_ReadData()
    local Size = net_ReadUInt(16)
    return _net_ReadData(Size)
end

local function net_Send()
    net_SendToServer()
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

function Globalize.Send(NetworkID, Data)
    if not NetworkID then return end
    if not Data then Data = {} end

    local CompressedPacket = CreateCompressedPacket(NetworkID, Data)

    net_Start("Globalize.NetworkChannel")

    net_WriteData(CompressedPacket) -- Data

    net_Send()
end

function GlobalizeInternal.CallReceiver(NetworkID, Data, Len, Ply)
    if not NetworkID then return end
    if not Data then return end
    if not GlobalizeInternal.Receivers[NetworkID] then return end

    local _Receiver = GlobalizeInternal.Receivers[NetworkID]

    local Callback = _Receiver.callback

    Callback(Data, Len, Ply)
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

net_Receive("Globalize.NetworkChannel", function(len, ply)
    local IsSegmented = net_ReadBool()
    
    if IsSegmented then
        
        local SegmentID = net_ReadUInt(16)
        local SegmentsSent = net_ReadUInt(16)
        local NumSegments = net_ReadUInt(16)
        local Segment = net_ReadData()

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

    local Packet = UncompressPacket(net_ReadData())

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

--------------------------------------------------------------------------------------------------------------------------------

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

hook_Add("InitPostEntity", "GlobalizeAskData", function()
    Globalize.Send("GlobalizeInternalAskForGlobalVar")
end)


