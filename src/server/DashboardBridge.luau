-- DashboardBridge.luau
-- Sits between MatchmakingService(s) and the client UI.
-- Creates the RemoteEvent, subscribes to onTick on every service, fires stats to all clients.
-- Server → client only. No client → server traffic.
--
-- Accepts either a single service or an array of services.
-- When given multiple services (stress test), each service's latest tickStats is stored
-- and the full per-server list is included in every payload so the client can show N panels.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local DashboardBridge = {}
DashboardBridge.__index = DashboardBridge

-- RemoteEvent name. Client uses WaitForChild with this exact string.
local REMOTE_NAME = "MmkStats"

-- serviceOrServices: a single MatchmakingService instance, or an array of them.
-- Duck-type check: if it has a .tick method it's a single service, otherwise it's an array.
-- ccu: optional explicit player count for the budget formula (1000 + 120*CCU).
--      Pass STRESS_PLAYER_COUNT from StressTest. Nil = approximate from queue stats.
function DashboardBridge.new(serviceOrServices: any, adapter: any, ccu: number?)
	local self = setmetatable({}, DashboardBridge)
	self._adapter = adapter
	self._ccu = ccu
	self._latestStats = {} -- [i] → most recent tickStats from services[i]

	if type(serviceOrServices.tick) == "function" then
		-- Single service (normal demo mode)
		self._services = { serviceOrServices }
	else
		-- Array of services (stress test mode)
		self._services = serviceOrServices
	end

	-- Create the RemoteEvent the client will listen on
	local remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE_NAME
	remote.Parent = ReplicatedStorage
	self._remote = remote

	return self
end

-- Builds and fires the dashboard payload using stored per-service stats.
-- Called whenever any service ticks; triggerIdx identifies which service just fired.
function DashboardBridge:_fire(triggerIdx: number)
	local adapterStats = self._adapter:getStats()
	local triggerStats = self._latestStats[triggerIdx] or {}

	-- Budget: use explicit CCU if provided (stress test passes PLAYER_COUNT),
	-- otherwise approximate from queue + matched players visible to this service.
	local ccu = self._ccu or ((triggerStats.queueSize or 0) + (triggerStats.totalMatches or 0) * 2)
	local budgetPerMin = 1000 + (120 * ccu)
	local ticksPerMin = 60 / Constants.QUEUE_TICK_RATE
	-- Units/match: stable metric regardless of how full the queue is at tick time.
	-- Projected units/min = unitsPerMatch × matchesPerTick × ticksPerMin.
	local totalMatches = adapterStats.totalMatches or 0
	local unitsPerMatch = totalMatches > 0
		and (adapterStats.totalUnits / totalMatches)
		or  0
	local totalTicks = math.max(triggerStats.tickCount or 1, 1)
	local matchesPerTick = totalMatches / totalTicks
	local projectedPerMin = unitsPerMatch * matchesPerTick * ticksPerMin
	local budgetPct = math.clamp((projectedPerMin / math.max(budgetPerMin, 1)) * 100, 0, 999)

	-- Per-server snapshot — only include services that have ticked at least once
	local servers = {}
	for i = 1, #self._services do
		local s = self._latestStats[i]
		if s then
			table.insert(servers, {
				serverId            = string.format("Server-%d", i),
				tickCount           = s.tickCount,
				matchesThisTick     = s.matchesThisTick,
				totalMatches        = s.totalMatches,
				queueSize           = s.queueSize,
				spreadExpandedCount = s.spreadExpandedCount,
				bracketStats        = s.bracketStats or {},
			})
		end
	end

	-- Merge recentMatches from all services, sort newest-first, take top 10.
	-- Each entry has a timestamp field added by MatchmakingService.
	-- Different services matched different players (CAS ensures no overlap), so no dedup needed.
	local allMatches = {}
	for i = 1, #self._services do
		local s = self._latestStats[i]
		if s and s.recentMatches then
			for _, m in s.recentMatches do
				table.insert(allMatches, m)
			end
		end
	end
	table.sort(allMatches, function(a, b)
		return (a.timestamp or 0) > (b.timestamp or 0)
	end)
	local recentMatches = {}
	for i = 1, math.min(200, #allMatches) do
		recentMatches[i] = allMatches[i]
	end

	self._remote:FireAllClients({
		mode          = Constants.RUN_STRESS_TEST and "STRESS TEST" or "DEMO",
		servers       = servers,
		recentMatches = recentMatches,
		-- Bracket stats from the triggering service (shared queue → values converge across services)
		bracketStats  = triggerStats.bracketStats or {},
		-- Live queue snapshot — up to 20 waiting groups with label, size, avgMmr, waitSeconds
		-- queueServerId: which server's tick produced this snapshot (changes each fire)
		queueSnapshot  = triggerStats.queueSnapshot or {},
		-- Adapter op counts (cumulative, shared across all servers)
		totalUnits    = adapterStats.totalUnits,
		setCalls      = adapterStats.setCalls,
		getRangeCalls = adapterStats.getRangeCalls,
		updateCalls   = adapterStats.updateCalls,
		removeCalls   = adapterStats.removeCalls,
		totalMatches  = totalMatches,
		unitsPerMatch = math.round(unitsPerMatch * 10) / 10, -- 1 decimal place
		-- Derived
		budgetPct     = budgetPct,
		queueServerId  = string.format("Server-%d", triggerIdx),
	})
end

-- Subscribe to every service's onTick. On each tick, store stats and fire the payload.
function DashboardBridge:start()
	for i, svc in self._services do
		svc:onTick(function(tickStats)
			self._latestStats[i] = tickStats
			self:_fire(i)
		end)
	end
end

return DashboardBridge
