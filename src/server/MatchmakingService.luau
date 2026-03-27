-- MatchmakingService.luau
-- TEAM_SIZE-vs-TEAM_SIZE matchmaking supporting solo players and premade groups.
-- Groups of any size ≤ TEAM_SIZE queue as a single entry. The matchmaker assembles
-- virtual teams from those groups, then matches two teams by avgMmr + spread.
--
-- CAS claim covers every group in both teams atomically:
--   claim all teamA groups → claim all teamB groups → commit
--   any failure → release everything claimed so far

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local RankCalculator = require(script.Parent.RankCalculator)

local MatchmakingService = {}
MatchmakingService.__index = MatchmakingService

function MatchmakingService.new(adapter: any)
	local self = setmetatable({}, MatchmakingService)
	self._adapter = adapter
	self._running = false
	self._tickCount = 0
	self._totalMatches = 0
	self._onMatch = nil
	self._onTick = nil
	self._recentMatches = {}
	self._totalMatchesByBracket = {} -- [teamSize] → total matches formed
	return self
end

function MatchmakingService:onMatch(callback: (any) -> ())
	self._onMatch = callback
end

function MatchmakingService:onTick(callback: (any) -> ())
	self._onTick = callback
end

-- Enqueue a group (solo or premade). One MemoryStore entry per group.
function MatchmakingService:enqueueGroup(group: any): boolean
	local key = "group_" .. group.groupId
	return self._adapter:setAsync(key, group, Constants.QUEUE_TTL)
end

-- Backward compat: wrap a single player as a size-1 group.
-- Stress test and old call sites use this path.
-- queueJoinTime defaults to os.clock() so re-queued players get a fresh wait timer.
function MatchmakingService:enqueue(player: any): boolean
	local group = {
		groupId = tostring(player.userId),
		members = {{
			userId = player.userId,
			displayName = player.displayName,
			mmr = player.mmr,
			rank = player.rank,
			region = player.region,
		}},
		avgMmr        = player.mmr,
		size          = 1,
		queueType     = player.queueType or 1,
		rank          = player.rank,
		region        = player.region,
		queueJoinTime = player.queueJoinTime or os.clock(),
		claimed       = false,
	}
	return self:enqueueGroup(group)
end

-- Attempt to atomically claim all groups in both teams, then commit the match.
-- CAS order: teamA groups first, then teamB groups.
-- On any claim failure: release all keys claimed so far and return false.
function MatchmakingService:_tryMatchTeams(teamA: any, teamB: any): boolean
	local allGroups = {}
	for _, g in teamA.groups do table.insert(allGroups, g) end
	for _, g in teamB.groups do table.insert(allGroups, g) end

	local claimedKeys = {}
	local success = true

	for _, g in allGroups do
		local key = "group_" .. g.groupId
		if self._adapter:claimAsync(key, Constants.QUEUE_TTL) then
			table.insert(claimedKeys, key)
		else
			success = false
			break
		end
	end

	if not success then
		for _, key in claimedKeys do
			self._adapter:releaseAsync(key, Constants.QUEUE_TTL)
		end
		return false
	end

	-- All claimed — permanently remove from queue and record match for budget tracking
	for _, key in claimedKeys do
		self._adapter:removeAsync(key)
	end
	self._adapter:recordMatch()

	-- Flatten group members into team rosters
	local membersA, membersB = {}, {}
	for _, g in teamA.groups do
		for _, m in g.members do table.insert(membersA, m) end
	end
	for _, g in teamB.groups do
		for _, m in g.members do table.insert(membersB, m) end
	end

	-- Team ELO: each team is treated as a single entity at avgMmr
	local winner = math.random() > 0.5 and "A" or "B"
	local winnerMmr = winner == "A" and teamA.avgMmr or teamB.avgMmr
	local loserMmr  = winner == "A" and teamB.avgMmr or teamA.avgMmr
	local deltaWin, deltaLose = RankCalculator.calculateMMRDelta({ mmr = winnerMmr }, { mmr = loserMmr })

	local result = {
		teamA     = membersA,
		teamB     = membersB,
		winner    = winner,        -- "A" or "B"
		mmrDeltaA = winner == "A" and deltaWin or deltaLose,
		mmrDeltaB = winner == "B" and deltaWin or deltaLose,
		avgMmrA   = teamA.avgMmr,
		avgMmrB   = teamB.avgMmr,
		matchType = string.format("%dv%d", #membersA, #membersB),
		timestamp = os.time(),
	}

	self._totalMatches += 1
	local bracketSize = #membersA
	self._totalMatchesByBracket[bracketSize] = (self._totalMatchesByBracket[bracketSize] or 0) + 1
	table.insert(self._recentMatches, 1, {
		teamA      = membersA,
		teamB      = membersB,
		winner     = winner,
		deltaA     = result.mmrDeltaA,
		deltaB     = result.mmrDeltaB,
		matchType  = result.matchType,
		timestamp  = os.time(),
	})
	if #self._recentMatches > 500 then
		table.remove(self._recentMatches)
	end

	if self._onMatch then
		self._onMatch(result)
	end

	return true
end

-- Run one queue scan.
-- Groups are bucketed by queueType (the match type the player chose), not group.size.
-- A solo queuing for 3v3 and a duo queuing for 3v3 share the same bucket.
-- Within each bracket the matchmaker assembles two teams of exactly queueType players
-- from any combination of waiting groups (solo fills one slot, duo fills two, etc.).
function MatchmakingService:tick(serverId: string?): number
	self._tickCount += 1
	local matchesThisTick = 0

	local snapshot = self._adapter:getSnapshotAsync()
	if #snapshot < 2 then return 0 end

	-- Bucket by queueType — the team size the player selected, independent of group size
	local buckets: { [number]: { any } } = {}
	for _, group in snapshot do
		local queueType = group.queueType or group.size or 1
		if not buckets[queueType] then buckets[queueType] = {} end
		table.insert(buckets[queueType], group)
	end

	local usedGroupIds = {}
	local matchesByBracket = {}

	-- Greedily assembles a team of exactly teamSize players from `groups`.
	-- Scans from fromIdx, skips groups in usedGroupIds or excludeIds.
	-- MMR window: [anchorMmr - spread, anchorMmr + spread].
	-- Returns { groups, avgMmr, queueJoinTime } or nil.
	local function assembleTeam(groups, fromIdx, excludeIds, anchorMmr, spread, teamSize)
		local picked    = {}
		local slotsFilled = 0
		local totalMmr  = 0
		local oldestJoin = math.huge

		for j = fromIdx, #groups do
			local g = groups[j]
			if usedGroupIds[g.groupId] or excludeIds[g.groupId] then continue end
			local gMmr  = g.avgMmr or g.mmr or 0
			if gMmr < anchorMmr - spread then continue end -- below window, keep scanning
			if gMmr > anchorMmr + spread then break end    -- above window, sorted list ends here
			local gSize = g.size or 1
			if slotsFilled + gSize > teamSize then continue end -- too big to fit remaining slots
			table.insert(picked, g)
			slotsFilled  += gSize
			totalMmr     += gMmr * gSize
			oldestJoin    = math.min(oldestJoin, g.queueJoinTime or math.huge)
			if slotsFilled == teamSize then break end
		end

		if slotsFilled ~= teamSize then return nil end
		return {
			groups        = picked,
			avgMmr        = totalMmr / teamSize,
			queueJoinTime = oldestJoin ~= math.huge and oldestJoin or os.clock(),
		}
	end

	for queueType, groups in buckets do
		-- Sort by avgMmr — adjacent groups have the closest MMR
		table.sort(groups, function(a, b)
			return (a.avgMmr or a.mmr or 0) < (b.avgMmr or b.mmr or 0)
		end)

		for i = 1, #groups do
			local anchor = groups[i]
			if usedGroupIds[anchor.groupId] then continue end
			if (anchor.size or 1) > queueType then continue end -- group too large for this bracket

			local anchorMmr = anchor.avgMmr or anchor.mmr or 0
			local spread    = RankCalculator.getMMRSpread(anchor.queueJoinTime)

			-- Build teamA starting from anchor (lowest MMR in window)
			local teamA = assembleTeam(groups, i, {}, anchorMmr, spread, queueType)
			if not teamA then continue end

			-- Exclude teamA groups from teamB search
			local excludeA = {}
			for _, g in teamA.groups do excludeA[g.groupId] = true end

			-- Search from index 1 so teamB can be anywhere in the MMR window
			local teamB = assembleTeam(groups, 1, excludeA, anchorMmr, spread, queueType)
			if not teamB then continue end

			if self:_tryMatchTeams(teamA, teamB) then
				for _, g in teamA.groups do usedGroupIds[g.groupId] = true end
				for _, g in teamB.groups do usedGroupIds[g.groupId] = true end
				matchesThisTick += 1
				matchesByBracket[queueType] = (matchesByBracket[queueType] or 0) + 1
				break
			end
		end
	end

	-- Build per-bracket stats for the dashboard (keyed by queueType = team size)
	local bracketStats = {}
	for queueType, groups in buckets do
		local queuePlayers = 0
		for _, g in groups do queuePlayers += (g.size or 1) end
		bracketStats[queueType] = {
			bracket         = string.format("%dv%d", queueType, queueType),
			queuePlayers    = queuePlayers,
			matchesThisTick = matchesByBracket[queueType] or 0,
			totalMatches    = self._totalMatchesByBracket[queueType] or 0,
		}
	end

	-- Remaining player count: total in snapshot minus those just matched
	local totalPlayers = 0
	local matchedPlayers = 0
	for _, g in snapshot do
		local size = g.size or 1
		totalPlayers += size
		if usedGroupIds[g.groupId] then matchedPlayers += size end
	end
	local remaining = totalPlayers - matchedPlayers

	local spreadExpandedCount = 0
	for _, g in snapshot do
		if RankCalculator.getMMRSpread(g.queueJoinTime) > Constants.BASE_MMR_SPREAD then
			spreadExpandedCount += (g.size or 1)
		end
	end

	if serverId == nil then
		local spreadNote = spreadExpandedCount > 0
			and string.format(" (spread expanded for %d players)", spreadExpandedCount)
			or ""
		print(string.format("[Queue] Tick %d — %d players waiting%s",
			self._tickCount, remaining, spreadNote))
	end

	-- Build queue snapshot for the dashboard — up to 20 groups, sorted by MMR.
	-- waitSeconds is computed here so the client doesn't need server-side clock access.
	local queueSnapshot = {}
	for i, g in snapshot do
		if i > 20 then break end
		if not usedGroupIds[g.groupId] then -- only show groups still waiting
			local names = {}
			for _, m in g.members do table.insert(names, m.displayName) end
			table.insert(queueSnapshot, {
				label       = table.concat(names, "+"),
				size        = g.size or 1,
				queueType   = g.queueType or g.size or 1,
				avgMmr      = math.round(g.avgMmr or g.mmr or 0),
				waitSeconds = math.floor(math.max(0,
					os.clock() - ((g.queueJoinTime and g.queueJoinTime > 0) and g.queueJoinTime or os.clock())
				)),
			})
		end
	end

	if self._onTick then
		self._onTick({
			tickCount           = self._tickCount,
			matchesThisTick     = matchesThisTick,
			totalMatches        = self._totalMatches,
			queueSize           = remaining,
			spreadExpandedCount = spreadExpandedCount,
			recentMatches       = self._recentMatches,
			bracketStats        = bracketStats,
			queueSnapshot       = queueSnapshot,
		})
	end

	return matchesThisTick
end

function MatchmakingService:start(serverId: string?)
	self._running = true
	task.spawn(function()
		while self._running do
			self:tick(serverId)
			task.wait(Constants.QUEUE_TICK_RATE)
		end
	end)
end

function MatchmakingService:stop()
	self._running = false
end

return MatchmakingService
