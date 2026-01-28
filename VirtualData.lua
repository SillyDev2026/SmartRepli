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
	self.Store = dataStore
	ActiveFolders[player.UserId] = self

	for folderName,_ in pairs(self.Data) do
		self:FireCreated(folderName)
	end

	FolderSyncEvent:FireAllClients("InitPlayer", player.UserId, self.Data)
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
	if itemName == "__sync" then return end
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
	folder.__sync = mode
	for itemName,value in pairs(folder) do
		if itemName ~= "__sync" and not itemName:match("__type$") then
			if mode == "Public" then
				FolderSyncEvent:FireAllClients("Update", self.Player.UserId, folderName, itemName, value)
			else
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
	local folder = PlayerFolder.get(player)
	if not folder then return end
	if action == "RequestUpdate" then
		local folderName, itemName, value = ...
		if folder then folder:Update(folderName, itemName, value) end
	elseif action == 'RequestModule' then
		local moduleName, moduleAction, args = ...
		local module = StatsModules[moduleName]
		if module and module[moduleAction] then
			module[moduleAction](player, folder, table.unpack({args}))
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	PlayerFolder.remove(player)
end)

function PlayerFolder:GetData(path: string): any
	local folderName, itemName = path:match('([^.]+)%.([^.]+)')
	if not folderName or not itemName then
		warn(`Invalid path: {path}`)
		return nil
	end
	local folder = self.Data[folderName]
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
