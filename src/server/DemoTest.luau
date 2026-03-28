-- DemoTest.luau
-- Runs the matchmaking system against the real MemoryStore API.
-- Proves the adapter layer works end-to-end with actual Roblox infrastructure.
-- Output shows every match, op counts, and units/match efficiency.
--
-- Unlike StressTest (which uses mock MemoryStore to prove CAS correctness),
-- this test is the final integration check before wiring in real players:
-- "do the real API calls succeed and produce correct matchmaking results?"

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Constants          = require(ReplicatedStorage.Shared.Constants)
local MemoryStoreAdapter = require(script.Parent.MemoryStoreAdapter)
local MockPlayerProvider = require(script.Parent.MockPlayerProvider)
local MatchmakingModule  = require(script.Parent.MatchmakingService)
local DashboardBridge    = require(script.Parent.DashboardBridge)

local DemoTest = {}

local function teamStr(members)
	local parts = {}
	for _, m in members do
		table.insert(parts, string.format("%s (%s %d)", m.displayName, m.rank, m.mmr))
	end
	return table.concat(parts, " + ")
end

function DemoTest.run()
	local PLAYER_COUNT = Constants.DEMO_PLAYER_COUNT
	local IDLE_ROUNDS  = Constants.STRESS_IDLE_ROUNDS

	print(string.format(
		"\n[Demo] ════════════════════════════════════════\n"
		.. "[Demo] DEMO TEST: %d players — Real MemoryStore: %s\n"
		.. "[Demo] Stops after %d consecutive empty-queue ticks\n"
		.. "[Demo] ════════════════════════════════════════",
		PLAYER_COUNT,
		tostring(Constants.USE_REAL_MEMORYSTORE),
		IDLE_ROUNDS
	))

	-- Adapter uses Constants.USE_REAL_MEMORYSTORE (true for demo)
	local adapter = MemoryStoreAdapter.new("DemoQueue")
	local svc     = MatchmakingModule.new(adapter)

	-- Wire dashboard so client sees live stats while the test runs
	DashboardBridge.new(svc, adapter):start()

	local totalMatches = 0

	svc:onMatch(function(result)
		totalMatches += 1
		print(string.format(
			"[Demo][%s][%s] Team A [%.0f avg]: %s",
			result.region or "NA", result.matchType, result.avgMmrA, teamStr(result.teamA)
		))
		print(string.format(
			"[Demo][%s][%s] Team B [%.0f avg]: %s",
			result.region or "NA", result.matchType, result.avgMmrB, teamStr(result.teamB)
		))
		print(string.format(
			"[MMR]  Team A %+d | Team B %+d | Winner: Team %s",
			result.mmrDeltaA, result.mmrDeltaB, result.winner
		))

		-- Re-queue all players in random group sizes after a simulated match duration
		local matchDuration = math.random(5, 10)
		task.delay(matchDuration, function()
			local all = {}
			for _, team in { result.teamA, result.teamB } do
				for _, m in team do table.insert(all, m) end
			end
			-- Fisher-Yates shuffle so pairings change each round
			for i = #all, 2, -1 do
				local j = math.random(1, i)
				all[i], all[j] = all[j], all[i]
			end
			local idx = 1
			local gCounter = 0
			while idx <= #all do
				local size = math.min(math.random(1, 3), #all - idx + 1)
				local members, totalMmr, ids = {}, 0, {}
				for k = idx, idx + size - 1 do
					local m = all[k]
					table.insert(members, {
						userId = m.userId, displayName = m.displayName,
						mmr = m.mmr, rank = m.rank, region = m.region or "NA",
					})
					totalMmr += m.mmr
					table.insert(ids, tostring(m.userId))
				end
				gCounter += 1
				svc:enqueueGroup({
					groupId       = "rq" .. gCounter .. "_" .. table.concat(ids, "_"),
					members       = members,
					avgMmr        = totalMmr / size,
					size          = size,
					queueType     = math.random(size, 3),
					region        = members[1].region or "NA",
					queueJoinTime = os.clock(),
					claimed       = false,
				})
				idx += size
			end
		end)
	end)

	-- Seed initial players
	local groups = MockPlayerProvider.seedMixed(PLAYER_COUNT)
	for _, group in groups do
		local names = {}
		for _, m in group.members do table.insert(names, m.displayName) end
		print(string.format("[Demo] Enqueuing %s [size=%d, %.0f avgMMR, %s]",
			table.concat(names, "+"), group.size, group.avgMmr, group.region or "NA"))
		svc:enqueueGroup(group)
	end
	print(string.format("[Demo] Enqueued %d groups (%d players) — starting queue loop\n",
		#groups, PLAYER_COUNT))

	adapter:resetStats()

	-- Drain-aware loop: stops after IDLE_ROUNDS consecutive empty-queue ticks.
	-- Covers the task.delay re-queue window (max 10s; IDLE_ROUNDS × tick rate ≥ 15s).
	local idleCount = 0
	local round = 0

	local zeromatchesRounds = 0	

	while idleCount < IDLE_ROUNDS do
		round += 1
		local matched = svc:tick(string.format("Demo-%d", round))
		local remaining = adapter:getSizeAsync()

		if remaining == 0 and matched == 0 or zeromatchesRounds >= IDLE_ROUNDS then
			idleCount += 1
			print(string.format(
				"[Demo] Round %d — queue empty or no more matches (%d/%d idle ticks)",
				round, idleCount, IDLE_ROUNDS
			))
		else
			idleCount = 0
			print(string.format(
				"[Demo] Round %d — %d matches this tick | %d groups remaining",
				round, matched, remaining
			))
			zeromatchesRounds = matched == 0 and (zeromatchesRounds + 1) or 0
		end

		task.wait(Constants.QUEUE_TICK_RATE)
	end

	print("[Demo] Queue idle for " .. IDLE_ROUNDS .. " consecutive ticks — stopping")

	-- ── Summary ───────────────────────────────────────────────────────────────
	local stats = adapter:getStats()
	local unitsPerMatch = totalMatches > 0
		and (stats.totalUnits / totalMatches)
		or  0
	local updateUnitCost = stats.updateCalls * 2

	print("\n[Demo] ════════ RESULTS ════════")
	print(string.format("[Demo] Players:            %d  (%d groups)", PLAYER_COUNT, #groups))
	print(string.format("[Demo] Rounds run:         %d", round))
	print(string.format("[Demo] Matches formed:     %d", totalMatches))
	print(string.format("[Demo] Real MemoryStore:   %s", tostring(Constants.USE_REAL_MEMORYSTORE)))
	print("")
	print("[Demo] ── Op breakdown (request units) ──")
	print(string.format("  SetAsync calls:      %d   × 1 unit  = %d units",  stats.setCalls,    stats.setCalls))
	print(string.format("  GetRangeAsync calls: %d   (included in total)",   stats.getRangeCalls))
	print(string.format("  UpdateAsync calls:   %d   × 2 units  = %d units", stats.updateCalls, updateUnitCost))
	print(string.format("  RemoveAsync calls:   %d   × 1 unit   = %d units", stats.removeCalls, stats.removeCalls))
	print(string.format("  Total units used:    %d", stats.totalUnits))
	print(string.format("  Units/match:         %.1f  (efficiency metric — scales to any CCU)", unitsPerMatch))
	print("")
	print("[Demo] ════════════════════════════════════════")
end

return DemoTest
