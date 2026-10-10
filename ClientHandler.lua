local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local FolderSyncEvent = ReplicatedStorage:WaitForChild("FolderSyncEvent")
local ActiveFolders = {}
export type ClientData = {
	EnsureFolder: (self: ClientData, folderName: string) -> (),
	OnCreated: (self: ClientData, callback: (folderName: string) -> ()) -> (),
	OnChanged: (self: ClientData, path: string, callback: (newValue: any, oldValue: any?) -> ()) -> (),
	ApplyUpdate: (self: ClientData, folderName: string, itemName: string, value: any) -> (),
	RequestUpdate: (self: ClientData, folderName: string, itemName: string, value: any) -> (),
	RequestModule: <T...>(self: ClientData, moduleName: string, action: string, T...) -> (),
	GetData: (self: ClientData, path: string) -> any,
}

local function DeepCopy(tbl)
	local copy = {}
	for k,v in pairs(tbl) do
		if type(v)=="table" then copy[k]=DeepCopy(v) else copy[k]=v end
	end
	return copy
end
local ClientFolder = {}
ClientFolder.__index = ClientFolder

function ClientFolder.new(userId, schema)
	if ActiveFolders[userId] then
        if type(schema) == "table" then
            local existing = ActiveFolders[userId]
            for name, value in pairs(schema) do
                existing.Data[name] = DeepCopy(value)
            end
        end
        return ActiveFolders[userId]
    end
	local self = setmetatable({}, ClientFolder)
	self.UserId = userId
	self.Data = schema and DeepCopy(schema) or {}
	self.Version = 1
	self.ChangeListeners = {}
	self.CreatedListeners = {}
	ActiveFolders[userId] = self
	for folderName,_ in pairs(self.Data) do
		self:FireCreated(folderName)
	end
	return self
end

function ClientFolder:EnsureFolder(folderName: string)
	if not self.Data[folderName] then
		self.Data[folderName] = {}
		self:FireCreated(folderName)
	end
end

function ClientFolder:FireCreated(folderName: string)
	for _,cb in ipairs(self.CreatedListeners) do
		cb(folderName)
	end
end

function ClientFolder:OnCreated(callback: () -> ())
	table.insert(self.CreatedListeners, callback)
end

function ClientFolder:FireChanged(path, newValue, oldValue)
	if self.ChangeListeners[path] then
		for _, cb in ipairs(self.ChangeListeners[path]) do
			cb(newValue, oldValue)
		end
	end
end

function ClientFolder:OnChanged(path, callback)
	self.ChangeListeners[path] = self.ChangeListeners[path] or {}
	table.insert(self.ChangeListeners[path], callback)
end

function ClientFolder:ApplyUpdate(folderName, itemName, value)
	self:EnsureFolder(folderName)
	local folder = self.Data[folderName]
	local oldValue = folder[itemName]
	folder[itemName] = value
	self.Version += 1
	self:FireChanged(folderName.."."..itemName, value, oldValue)
end

function ClientFolder:RequestUpdate(folderName, itemName, value)
	FolderSyncEvent:FireServer("RequestUpdate", folderName, itemName, value)
end

-- able to get data but must use Player.UserId
function ClientFolder.get(userId): ClientData
	local folder = ActiveFolders[userId]
	while not folder do
		task.wait()
		folder = ActiveFolders[userId]
	end
	return folder
end

function ClientFolder.remove(userId)
    local normalized = tonumber(userId)
    if normalized then ActiveFolders[normalized] = nil end
end

FolderSyncEvent.OnClientEvent:Connect(function(action, userId, ...)
	if action == "InitPlayer" then
		local data = ...
		ClientFolder.new(userId, data)
	elseif action == "Update" then
		local folderName, itemName, value = ...
        -- The update may arrive before InitPlayer; do not block the
        -- OnClientEvent handler waiting for a folder that isn't created yet.
        local folder = ActiveFolders[userId] or ClientFolder.new(userId)
        folder:ApplyUpdate(folderName, itemName, value)
	elseif action == "RemovePlayer" then
		ClientFolder.remove(userId)
	end
end)

function ClientFolder:RequestModule<T...>(moduleName, action, ...: T...)
	FolderSyncEvent:FireServer('RequestModule', moduleName, action, ...)
end

function ClientFolder:GetData(path: string): any
	local folderName, itemName = path:match('([^.]+)%.([^.]+)')
	if not folderName or not itemName then
		warn(`Invalid path: {path}`)
		return nil
	end
    local folder = self.Data[folderName]
    if type(folder) ~= "table" then return nil end
    return folder[itemName]
end

return ClientFolder
