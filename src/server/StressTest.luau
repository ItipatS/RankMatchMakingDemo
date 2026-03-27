-- StressTest.luau
-- Simulates N concurrent servers all hitting the same shared MemoryStore queue.
-- Proves that the CAS claim logic prevents duplicate matches under load.
-- Also projects real MemoryStore request-unit usage at given CCU.
--
-- How the race simulation works:
--   Each "server" is a coroutine running MatchmakingService:tick().
--   All coroutines are spawned simultaneously with task.spawn().
--   Inside claimAsync(), task.wait() yields each coroutine before the atomic read-write,
--   letting other coroutines slip in and attempt to claim the same group.
--   Only the first to resume after the yield wins the claim — the rest see claimed=true and back off.
--   This mirrors how real UpdateAsync atomicity works across Roblox servers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants         = require(ReplicatedStorage.Shared.Constants)
local MemoryStoreAdapter = require(script.Parent.MemoryStoreAdapter)
local MockPlayerProvider = require(script.Parent.MockPlayerProvider)
local MatchmakingModule  = require(script.Parent.MatchmakingService)
local DashboardBridge    = require(script.Parent.DashboardBridge)

local StressTest = {}

function StressTest.run()
	local SERVER_COUNT  = Constants.STRESS_SERVER_COUNT
	local PLAYER_COUNT  = Constants.STRESS_PLAYER_COUNT
	local IDLE_ROUNDS   = Constants.STRESS_IDLE_ROUNDS

	print(string.format(
		"\n[Stress] ════════════════════════════════════════\n"
		.. "[Stress] STRESS TEST: %d servers × %d players\n"
		.. "[Stress] Stops after %d consecutive empty-queue ticks\n"
		.. "[Stress] ════════════════════════════════════════",
		SERVER_COUNT, PLAYER_COUNT, IDLE_ROUNDS
	))

	-- One shared adapter — all "servers" write and read from the same store,
	-- exactly like real MemoryStore is shared across all Roblox servers.
	-- useRealMemoryStore=false overrides the global constant so this
	-- always runs against the mock even if USE_REAL_MEMORYSTORE=true.
	local adapter = MemoryStoreAdapter.new("StressQueue", false)

	-- Bulk-enqueue: no delays — stress test measures CAS correctness and unit cost,
	-- not realistic join timing. Delays here would make the test take minutes.
	local groups = MockPlayerProvider.seedMixed(PLAYER_COUNT)
	local seeder = MatchmakingModule.new(adapter)
	for _, group in groups do
		seeder:enqueueGroup(group)
	end
	print(string.format("[Stress] Enqueued %d groups (%d players) into shared queue",
		#groups, PLAYER_COUNT))

	-- ── Duplicate detection ──────────────────────────────────────────────────
	-- If CAS is broken, the same player can appear in two different match results.
	-- matchedIds tracks every userId we've ever seen across all servers.
	local matchedIds: { [number]: string } = {}
	local totalMatches = 0
	local duplicatesDetected = 0

	-- Create N service instances, one per simulated server.
	-- These are separate from the seeder — seeder only enqueues, never ticks.
	local services = {}
	for i = 1, SERVER_COUNT do
		local svc = MatchmakingModule.new(adapter)
		svc:onMatch(function(result)
			-- CAS check: must happen immediately at match time, not deferred.
			-- matchedIds tracks "currently in a match". If CAS works, no two servers
			-- can both hold the same player as claimed at the same instant.
			for _, team in { result.teamA, result.teamB } do
				for _, member in team do
					if matchedIds[member.userId] then
						duplicatesDetected += 1
						warn(string.format(
							"[Stress] ✗ DUPLICATE — %s (userId %d) matched twice! (Server-%d)",
							member.displayName, member.userId, i
						))
					else
						matchedIds[member.userId] = string.format("Server-%d", i)
					end
				end
			end
			totalMatches += 1

			-- Re-queue in random group sizes so all brackets stay active.
			-- Clear matchedIds before re-enqueue so second matches aren't false positives.
			--[[task.delay(math.random(5, 10), function()
				local all = {}
				for _, team in { result.teamA, result.teamB } do
					for _, m in team do
						matchedIds[m.userId] = nil
						table.insert(all, m)
					end
				end
				-- Fisher-Yates shuffle
				for k = #all, 2, -1 do
					local j = math.random(1, k)
					all[k], all[j] = all[j], all[k]
				end
				local idx2 = 1
				local gCounter = 0
				while idx2 <= #all do
					local size = math.min(math.random(1, 3), #all - idx2 + 1)
					local members, totalMmr, ids = {}, 0, {}
					for k = idx2, idx2 + size - 1 do
						local m = all[k]
						table.insert(members, { userId=m.userId, displayName=m.displayName,
							mmr=m.mmr, rank=m.rank, region=m.region or "NA" })
						totalMmr += m.mmr
						table.insert(ids, tostring(m.userId))
					end
					gCounter += 1
					svc:enqueueGroup({
						groupId       = "rq" .. i .. "_" .. gCounter .. "_" .. table.concat(ids, "_"),
						members       = members,
						avgMmr        = totalMmr / size,
						size          = size,
						queueType     = math.random(size, 3),
						region        = members[1].region or "NA",
						queueJoinTime = os.clock(),
						claimed       = false,
					})
					idx2 += size
				end
			end)]]
		end)

		table.insert(services, svc)
	end

	-- Wire the dashboard to all services so the client sees a panel per server.
	-- Pass PLAYER_COUNT as explicit CCU so the budget formula uses the real player count,
	-- not an approximation derived from the shrinking queue size mid-run.
	-- Only fires if a client is actually connected — safe to leave in either way.
	DashboardBridge.new(services, adapter, PLAYER_COUNT):start()

	-- ── Parallel tick rounds ──────────────────────────────────────────────────
	-- Runs indefinitely until the queue has been empty for IDLE_ROUNDS consecutive
	-- ticks. This lets task.delay() re-queues land and get processed before the
	-- test declares itself done. Each round fires all SERVER_COUNT ticks in parallel.
	adapter:resetStats()
	local totalMatchesPerRound = {}
	local idleCount = 0
	local round = 0

	local zeromatchesRounds = 0	

	while idleCount < IDLE_ROUNDS do
		round += 1
		local roundMatches = 0
		local finished = 0

		for i, svc in services do
			task.spawn(function()
				local m = svc:tick(string.format("Server-%d", i))
				roundMatches += m
				finished += 1
			end)
		end

		-- Spin-wait: task.wait() yields here so spawned coroutines can run.
		while finished < SERVER_COUNT do
			task.wait()
		end

		local remaining = adapter:getSizeAsync()
		table.insert(totalMatchesPerRound, roundMatches)

		if remaining == 0 or zeromatchesRounds >= IDLE_ROUNDS then
			idleCount += 1
			print(string.format(
				"[Stress] Round %d — %d matches | queue empty or no more matches (%d/%d idle ticks)",
				round, roundMatches, idleCount, IDLE_ROUNDS
			))
		else
			idleCount = 0
			print(string.format(
				"[Stress] Round %d — %d matches this round | %d players remaining",
				round, roundMatches, remaining
			))
			zeromatchesRounds = roundMatches == 0 and (zeromatchesRounds + 1) or 0
		end

		task.wait(Constants.QUEUE_TICK_RATE)
	end

	print("[Stress] Queue idle for " .. IDLE_ROUNDS .. " consecutive ticks — stopping")

	-- ── Rate budget projection ────────────────────────────────────────────────
	local stats = adapter:getStats()
	local roundsRun = #totalMatchesPerRound
	local ccu = PLAYER_COUNT
	local budgetPerMinute = 1000 + (120 * ccu)
	local ticksPerMinute = 60 / Constants.QUEUE_TICK_RATE
	local totalTicks = roundsRun * SERVER_COUNT
	local unitsPerTick = totalTicks > 0 and (stats.totalUnits / totalTicks) or 0
	local projectedUnitsPerMinute = unitsPerTick * ticksPerMinute
	local updateUnitCost = stats.updateCalls * 2

	-- Upper bound on matches: every group finds an opponent in its bracket.
	-- Actual max is lower because bracket separation means odd-sized buckets
	-- leave one group unmatched (e.g. 3 solos → only 1 match, 1 solo waits).
	local maxPossible = math.floor(#groups / 2)

	print("\n[Stress] ════════ RESULTS ════════")
	print(string.format("[Stress] Players:                %d  (%d groups)", PLAYER_COUNT, #groups))
	print(string.format("[Stress] Servers simulated:      %d", SERVER_COUNT))
	print(string.format("[Stress] Rounds run:             %d", roundsRun))
	print(string.format("[Stress] Matches formed:         %d  (upper bound: %d)", totalMatches, maxPossible))
	print(string.format("[Stress] Duplicate matches:      %d  (must be 0)", duplicatesDetected))
	print("")
	print("[Stress] ── Op breakdown (request units) ──")
	print(string.format("  SetAsync calls:      %d   × 1 unit  = %d units",  stats.setCalls, stats.setCalls))
	print(string.format("  GetRangeAsync calls: %d   × variable = (included in total)", stats.getRangeCalls))
	print(string.format("  UpdateAsync calls:   %d   × 2 units  = %d units", stats.updateCalls, updateUnitCost))
	print(string.format("  RemoveAsync calls:   %d   × 1 unit   = %d units", stats.removeCalls, stats.removeCalls))
	print(string.format("  Total units used:    %d", stats.totalUnits))
	print("")
	print("[Stress] ── Rate budget projection (single server, production) ──")
	print(string.format("  CCU assumed:         %d", ccu))
	print(string.format("  Budget/min:          %d units", budgetPerMinute))
	print(string.format("  Est. units/tick:     %.1f", unitsPerTick))
	print(string.format("  Ticks/min:           %.1f  (tick rate: %ds)", ticksPerMinute, Constants.QUEUE_TICK_RATE))
	print(string.format("  Projected units/min: %.0f", projectedUnitsPerMinute))
	print(string.format("  Budget utilisation:  %.1f%%", (projectedUnitsPerMinute / budgetPerMinute) * 100))
	print("")

	if duplicatesDetected == 0 then
		print("[Stress] ✓ CAS integrity verified — zero duplicate matches across all servers")
	else
		warn(string.format("[Stress] ✗ %d duplicate matches — CAS logic has a bug", duplicatesDetected))
	end

	print("[Stress] ════════════════════════════════════════")
end

return StressTest
