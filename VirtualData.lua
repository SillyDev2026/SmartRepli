local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local StatsModules = {}
local Modules = script.Parent:WaitForChild('Modules')

for _, moduleScripts in ipairs(Modules:GetChildren()) do
	if moduleScripts:IsA('ModuleScript') and (moduleScripts.Name ~= 'PlayersDataStore' and moduleScripts.Name ~= 'DataStore') then
		StatsModules[moduleScripts.Name] = require(moduleScripts)
	end
end

local FolderSyncEvent = ReplicatedStorage:FindFirstChild("FolderSyncEvent")
if not FolderSyncEvent then
	FolderSyncEvent = Instance.new("RemoteEvent")
	FolderSyncEvent.Name = "FolderSyncEvent"
	FolderSyncEvent.Parent = ReplicatedStorage
end

local ActiveFolders = {}
local lastRemoteRequest = {} -- rate-limit two request types per user
local MIN_REQUEST_INTERVAL = 0.1

local function requestAllowed(player: Player, channel: string): boolean
    if player.Parent ~= Players then return false end
    local now = os.clock()
    local bucket = lastRemoteRequest[player.UserId]
    if not bucket then
        bucket = {Update = -math.huge, Module = -math.huge}
        lastRemoteRequest[player.UserId] = bucket
    end
    if now - bucket[channel] < MIN_REQUEST_INTERVAL then return false end
    bucket[channel] = now
    return true
end

local function isValidPath(path: any): boolean
    return type(path) == "string" and #path <= 96
        and path:match("^[%w_]+%.[%w_]+$") ~= nil
end

local function publicSnapshot(source: {[string]: any}): {[string]: any}
    local snapshot = {}
    for name, folder in pairs(source) do
        if type(folder) == "table" and folder.__sync == "Public" then
            snapshot[name] = folder
        end
    end
    return snapshot
end


local function DeepCopy(tbl)
	local copy = {}
	for k,v in pairs(tbl) do
		if type(v)=="table" then copy[k]=DeepCopy(v) else copy[k]=v end
	end
	return copy
end

local PlayerFolder = {}
PlayerFolder.__index = PlayerFolder

export type VirtualData = {
	EnsureFolder: (self: VirtualData, folderName: string) -> VirtualData,
	Define: (self: VirtualData, path: string, dataType: string, defaultValue: any, syncMode: string?) -> VirtualData,
	AddMiddleware: (self: VirtualData, path: string, func: (value: any, oldValue: any) -> any) -> VirtualData,
	OnCreated: (self:VirtualData, callBack: (folderName: string) -> ()) ->(),
	OnChanged: (self: VirtualData, path: string, callBack: (newVal: any, oldVal: any) -> any) -> (),
	Update: (self: VirtualData, folderName: string, itemName: string, value: any) -> (),
	SetSyncMode: (self: VirtualData, folderName: string, mode: string) -> (),
	TogglePublic: (self: VirtualData, folderName: string) -> (),
	Destroy: (self: VirtualData) -> (),
	GetData: (self: VirtualData, path: string) -> any,
	CreateFolder: (self: VirtualData, name: string, parent: any) -> Folder,
	CreateValue: (self: VirtualData, instanceType: 'NumberValue'|'StringValue'|'BoolValue'|'IntValue', name: string, val: any, parent: any) -> ()
}

function PlayerFolder.new(player, schema, dataStore): VirtualData
	if ActiveFolders[player.UserId] then return ActiveFolders[player.UserId] end
	local self = setmetatable({}, PlayerFolder)
	self.Player = player
	self.Data = schema and DeepCopy(schema) or {}
	self.Version = 1
	self.ChangeListeners = {}
	self.CreatedListeners = {}
	self.Middleware = {}
    self.ClientWritable = {} -- Default deny
	self.Store = dataStore
	ActiveFolders[player.UserId] = self

	for folderName,_ in pairs(self.Data) do
		self:FireCreated(folderName)
	end

    FolderSyncEvent:FireAllClients("InitPlayer", player.UserId, publicSnapshot(self.Data))
    FolderSyncEvent:FireClient(player, "InitPlayer", player.UserId, self.Data)
	return self
end

function PlayerFolder:EnsureFolder(folderName)
	if not self.Data[folderName] then
		self.Data[folderName] = { __sync = "Private" }
		self:FireCreated(folderName)
	end
end

function PlayerFolder:Define(path, dataType, defaultValue, syncMode)
	local folderName, itemName = path:match("([^.]+)%.([^.]+)")
	self:EnsureFolder(folderName)
	local folder = self.Data[folderName]
	folder[itemName] = defaultValue
	folder.__sync = syncMode or "Private"
	folder[itemName.."__type"] = dataType
end

function PlayerFolder:AllowClientUpdate(path: string, validator: ((any, any) -> boolean)?)
    assert(isValidPath(path), "Client update path must be Folder.Key")
    assert(validator == nil or type(validator) == "function", "Validator must be callable")
    self.ClientWritable[path] = validator or true
    return self
end

function PlayerFolder:DisallowClientUpdate(path: string)
    self.ClientWritable[path] = nil
    return self
end

function PlayerFolder:AddMiddleware(path, func)
	self.Middleware[path] = func
end

function PlayerFolder:FireCreated(folderName)
	for _,cb in ipairs(self.CreatedListeners) do
		cb(folderName)
	end
end

function PlayerFolder:OnCreated(callback)
	table.insert(self.CreatedListeners, callback)
end

function PlayerFolder:FireChanged(path, newValue, oldValue)
	if self.ChangeListeners[path] then
		for _, cb in ipairs(self.ChangeListeners[path]) do
			cb(newValue, oldValue)
		end
	end
end

function PlayerFolder:OnChanged(path, callback)
	self.ChangeListeners[path] = self.ChangeListeners[path] or {}
	table.insert(self.ChangeListeners[path], callback)
end

function PlayerFolder:Update(folderName, itemName, value)
	self:EnsureFolder(folderName)
	local folder = self.Data[folderName]
    if itemName == "__sync" or itemName:match("__type$") then return end
	local expectedType = folder[itemName.."__type"]
	if expectedType and type(value) ~= expectedType then
		warn("Type mismatch on update:", folderName, itemName)
		return
	end
	local path = folderName.."."..itemName
	if self.Middleware[path] then
		value = self.Middleware[path](value, folder[itemName])
	end
	local oldValue = folder[itemName]
	folder[itemName] = value
	self.Version += 1
	self:FireChanged(path, value, oldValue)
	local syncMode = folder.__sync or "Private"
	if syncMode == "Public" then
		FolderSyncEvent:FireAllClients("Update", self.Player.UserId, folderName, itemName, value)
	else
		FolderSyncEvent:FireClient(self.Player, "Update", self.Player.UserId, folderName, itemName, value)
	end
	if self.Store then
		local key = self.Store.SetKey(self.Player)
		self.Store.Session[key] = self.Data
	end
end

function PlayerFolder:SetSyncMode(folderName, mode)
	local folder = self.Data[folderName]
	if not folder then return end
    assert(mode == "Public" or mode == "Private", "Expected Public or Private")
    folder.__sync = mode
    for itemName, value in pairs(folder) do
        if itemName ~= "__sync" and not itemName:match("__type$") then
            if mode == "Public" then
                FolderSyncEvent:FireAllClients("Update", self.Player.UserId, folderName, itemName, value)
            else
                FolderSyncEvent:FireAllClients("Update", self.Player.UserId, folderName, itemName, nil)
                FolderSyncEvent:FireClient(self.Player, "Update", self.Player.UserId, folderName, itemName, value)
            end
        end
    end
	if self.Store then
		local key = self.Store.SetKey(self.Player)
		self.Store.Session[key] = self.Data
	end
end

function PlayerFolder:TogglePublic(folderName)
	local folder = self.Data[folderName]
	if not folder then return end
	local newMode = (folder.__sync == "Public") and "Private" or "Public"
	self:SetSyncMode(folderName, newMode)
end

function PlayerFolder:Destroy()
	ActiveFolders[self.Player.UserId] = nil
	FolderSyncEvent:FireAllClients("RemovePlayer", self.Player.UserId)
end

function PlayerFolder.get(player): VirtualData
	local folder = ActiveFolders[player.UserId]
	while not folder do
		task.wait()
	end
	return folder
end

function PlayerFolder.remove(player)
	local folder = ActiveFolders[player.UserId]
	if folder then folder:Destroy() end
end

FolderSyncEvent.OnServerEvent:Connect(function(player, action, ...)
    if player.Parent ~= Players then return end
    local folder = ActiveFolders[player.UserId]
    if not folder then return end
    if action == "RequestUpdate" then
        if not requestAllowed(player, "Update") then return end
        local folderName, itemName, value = ...
        if type(folderName) ~= "string" or type(itemName) ~= "string" then return end
        local path = folderName .. "." .. itemName
        if not isValidPath(path) or value == nil then return end
        local writable = folder.ClientWritable[path]
        if writable == nil then return end
        local data = folder.Data[folderName]
        if type(data) ~= "table" or data[itemName] == nil then return end
        if itemName == "__sync" or itemName:match("__type$") then return end
        if typeof(data[itemName]) ~= typeof(value) then return end
        if type(value) ~= "number" and type(value) ~= "boolean" and type(value) ~= "string" then return end
        if type(value) == "number" and (value ~= value or math.abs(value) == math.huge) then return end
        if type(value) == "string" and #value > 512 then return end
        if type(writable) == "function" then
            local ok, accepted = pcall(writable, value, data[itemName])
            if not ok or accepted ~= true then return end
        end
        folder:Update(folderName, itemName, value)
    elseif action == "RequestModule" then
        if not requestAllowed(player, "Module") then return end
        local args = table.pack(...)
        local moduleName = args[1]
        local moduleAction = args[2]
        if type(moduleName) ~= "string" or type(moduleAction) ~= "string" then return end
        local module = StatsModules[moduleName]
        if type(module) ~= "table" or type(module.ClientActions) ~= "table" then return end
        if module.ClientActions[moduleAction] ~= true then return end
        local callback = module[moduleAction]
        if type(callback) ~= "function" then return end
        local ok, err = pcall(callback, player, folder, table.unpack(args, 3, args.n))
        if not ok then warn("[SmartRepli] Client action failed:", err) end
    end
end)

Players.PlayerRemoving:Connect(function(player)
    lastRemoteRequest[player.UserId] = nil
	PlayerFolder.remove(player)
end)

function PlayerFolder:GetData(path: string): any
	local folderName, itemName = path:match('([^.]+)%.([^.]+)')
	if not folderName or not itemName then
		warn(`Invalid path: {path}`)
		return nil
	end
	local folder = self.Data[folderName]
    if type(folder) ~= "table" then return nil end
	return folder[itemName]
end

function PlayerFolder:CreateFolder(name: string, parent: any): Folder
	local folder = Instance.new('Folder')
	folder.Name = name
	folder.Parent = parent
	return folder
end

function PlayerFolder:CreateValue(instType: 'NumberValue'|'StringValue'|'BoolValue'|'IntValue', name: string, val: any, parent: any)
	local value = Instance.new(instType)
	value.Name = name
	value.Value = val
	value.Parent = parent
	return parent
end

return PlayerFolder
