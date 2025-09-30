local RunService = game:GetService('RunService')
local DataStoreModule = {}
DataStoreModule.__index = DataStoreModule
local DataStore = require(script.Parent.PlayersDataStore)

function DataStoreModule.new(config: {Name: string, Scope: string?})
	local self = {}
	self.DataStore = DataStore.new(config)
	self.Session = {}
	setmetatable(self, DataStoreModule)
	return self
end

function DataStoreModule:IsSessionLocked(key)
	return self.DataStore:IsLocked(key)
end

function DataStoreModule:AcquireLockSession(key: string)
	return self.DataStore:AcquireLock(key)
end

function DataStoreModule:ReleaseLockSession(key)
	return self.DataStore:ReleaseLock(key)
end

function DataStoreModule:GetAsync(key: string, player: Player, template)
	local lockSuccess, lockErr = self:AcquireLockSession(key)
	if self:IsSessionLocked(key) and not lockSuccess then
		player:Kick('Your session is already active in another server')
		return nil
	end
	local success, result = pcall(function()
		return self.DataStore:GetAsync(key)
	end)
	if not success or not result then
		result = self.DataStore:_GetFromCache(key) or {}
	end
	if template then
		result = self.DataStore:MergeTemplate(template, result)
		result = self.DataStore:CleanData(template, result)
	end
	self.Session[key] = result
	self.DataStore:_SaveToCache(key, result)
	self:ReleaseLockSession(key)
	return self.Session[key]
end

function DataStoreModule:GetSession(key)
	local session = self.Session[key]
	if not session then return end
	return session
end

function DataStoreModule:SetAsync(key: string, canBindData: boolean?, userIds: {number}?, option: DataStoreSetOptions?)
	local lockSuccess, lockErr = self:AcquireLockSession(key)
	if not lockSuccess then
		warn('failed to get lock', lockErr)
	end
	local session = self:GetSession(key)
	if not session then return end
	local success, err = self.DataStore:SetAsync(key, session, canBindData, userIds, option)
	if not success then
		warn(`Failed to save data because of: {err}`)
	end
	self:ReleaseLockSession(key)
	return success, err
end

function DataStoreModule:UpdateAsync(key: string, canBind: boolean?)
	local lockSuccess, lockErr = self:AcquireLockSession(key)
	if not lockSuccess then
		warn('failed to get lock', lockErr)
	end
	local session = self:GetSession(key)
	if not session then return end
	local success, err = pcall(function()
		return self.DataStore:UpdateAsync(key, function(oldData)
			return session
		end, canBind)
	end)
	if not success then
		warn(`Failed to save data because of: {err}`)
	end
	self:ReleaseLockSession(key)
	return success, err
end

function DataStoreModule:OnLeaveSet(key, userIds: {any}?, options: DataStoreSetOptions?)
	self:SetAsync(key, false, userIds, options)
end

function DataStoreModule:OnLeaveUpdate(key)
	self:UpdateAsync(key, false)
end

function DataStoreModule:BindOnSet(key, players: Players)
	if RunService:IsServer() then return task.wait(2) end
	local bind = Instance.new('BindableEvent')
	local allPlayers = players:GetPlayers()
	local allCurrent = #allPlayers
	for _, player in pairs(allPlayers) do
		task.spawn(function()
			key = key .. player.UserId
			self:SetAsync(key, true)
			allCurrent -= 1
			if allCurrent <= 0 then bind:Fire() end
		end)
	end
	bind.Event:Wait()
end

function DataStoreModule:BindOnUpdate(key: string, players: Players)
	if RunService:IsServer() then return task.wait(2) end
	local bind = Instance.new('BindableEvent')
	local allPlayers = players:GetPlayers()
	local allCurrent = #allPlayers
	for _, player in pairs(allPlayers) do
		task.spawn(function()
			key = key .. player.UserId
			self:UpdateAsync(key, true)
			allCurrent -= 1
			if allCurrent <= 0 then bind:Fire() end
		end)
	end
	bind.Event:Wait()
end

function DataStoreModule.SetKey(player: Player)
	return 'Player_' .. player.UserId
end

function DataStoreModule:AutoSaveSet(Players: Players)
	task.spawn(function()
		while task.wait(math.random(180, 300)) do
			for _, players in pairs(Players:GetPlayers()) do
				local key = 'Player_' .. players.UserId
				local success, err = pcall(self.OnLeaveSet, self, key)
				if not success then
					warn('Failed to auto save', err)
				else
					print('Saving in success')
				end	
			end
		end
	end)
end

function DataStoreModule:AutoSaveUpdate(Players: Players)
	while task.wait(math.random(180, 300)) do
		for _, players in pairs(Players:GetPlayers()) do
			local key = 'Player_' .. players.UserId
			local success, err = pcall(self.OnLeaveUpdate, self, key)
			if not success then
				warn('Failed to auto save', err)
			else
				print('Saving in success')
			end	
		end
	end
end

return DataStoreModule