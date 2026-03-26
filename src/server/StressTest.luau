-- StressTest.luau
-- Simulates N concurrent servers all hitting the same shared MemoryStore queue.
-- Proves that the CAS claim logic prevents duplicate matches under load.
-- Also projects real MemoryStore request-unit usage at given CCU.
--
-- How the race simulation works:
--   Each "server" is a coroutine running MatchmakingService:tick().
--   All coroutines are spawned simultaneously with task.spawn().
--   Inside claimAsync(), task.wait() yields each coroutine before the atomic read-write,
--   letting other coroutines slip in and attempt to claim the same player.
--   Only the first to resume after the yield wins the claim — the rest see claimed=true and back off.
--   This mirrors how real UpdateAsync atomicity works across Roblox servers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local MemoryStoreAdapter = require(script.Parent.MemoryStoreAdapter)
local MockPlayerProvider = require(script.Parent.MockPlayerProvider)
local MatchmakingService = require(script.Parent.MatchmakingService)

local StressTest = {}

function StressTest.run()
	local SERVER_COUNT = Constants.STRESS_SERVER_COUNT
	local PLAYER_COUNT = Constants.STRESS_PLAYER_COUNT
	local TICK_ROUNDS = Constants.STRESS_TICK_ROUNDS

	print(string.format(
		"\n[Stress] ════════════════════════════════════════\n"
		.. "[Stress] STRESS TEST: %d servers × %d players × %d rounds\n"
		.. "[Stress] ════════════════════════════════════════",
		SERVER_COUNT, PLAYER_COUNT, TICK_ROUNDS
	))

	-- One shared adapter — all "servers" write and read from the same store,
	-- exactly like real MemoryStore is shared across all Roblox servers in an experience.
	local adapter = MemoryStoreAdapter.new("StressQueue")

	-- Seed and enqueue all players
	MockPlayerProvider.seed(PLAYER_COUNT)
	local players = MockPlayerProvider.drainAll()

	-- Use a temporary service just for bulk enqueue (no match callback needed here)
	local seeder = MatchmakingService.new(adapter)
	for _, player in players do
		seeder:enqueue(player)
	end
	print(string.format("[Stress] Enqueued %d players into shared queue", #players))

	-- ── Duplicate detection ──────────────────────────────────────────────────
	-- If CAS is broken, the same player can appear in two different match results.
	-- matchedIds tracks every userId we've ever seen in a result.
	local matchedIds: { [number]: string } = {} -- userId → matched by which result log
	local totalMatches = 0
	local duplicatesDetected = 0

	-- Create N service instances, one per simulated server
	local services = {}
	for i = 1, SERVER_COUNT do
		local svc = MatchmakingService.new(adapter)
		svc:onMatch(function(result)
			-- Check both players for duplicates
			for _, entry in { result.playerA, result.playerB } do
				if matchedIds[entry.userId] then
					duplicatesDetected += 1
					warn(string.format(
						"[Stress] ✗ DUPLICATE — %s (userId %d) matched twice! (Server-%d)",
						entry.displayName, entry.userId, i
					))
				else
					matchedIds[entry.userId] = string.format("Server-%d", i)
				end
			end
			totalMatches += 1
		end)
		table.insert(services, svc)
	end

	-- ── Parallel tick rounds ──────────────────────────────────────────────────
	-- Each round fires all SERVER_COUNT ticks simultaneously,
	-- then waits for all to finish before moving to the next round.
	adapter:resetStats()
	local totalMatchesPerRound = {}

	for round = 1, TICK_ROUNDS do
		local roundMatches = 0
		local finished = 0

		for i, svc in services do
			task.spawn(function()
				local m = svc:tick(string.format("Server-%d", i))
				roundMatches += m
				finished += 1
			end)
		end

		-- Spin-wait for all coroutines to finish this round.
		-- task.wait() here yields control so spawned coroutines can actually run.
		while finished < SERVER_COUNT do
			task.wait()
		end

		local remaining = adapter:getSizeAsync()
		table.insert(totalMatchesPerRound, roundMatches)
		print(string.format(
			"[Stress] Round %d/%d — %d matches this round | %d players remaining",
			round, TICK_ROUNDS, roundMatches, remaining
		))

		if remaining == 0 then
			print("[Stress] Queue drained — stopping early")
			break
		end

		task.wait(0.05) -- small pause between rounds
	end

	-- ── Rate budget projection ────────────────────────────────────────────────
	-- Real MemoryStore budget: 1000 + 120 × (concurrent users) units/minute.
	-- We simulate CCU = PLAYER_COUNT (worst case: everyone is online at once).
	local stats = adapter:getStats()
	local roundsRun = #totalMatchesPerRound
	local ccu = PLAYER_COUNT
	local budgetPerMinute = 1000 + (120 * ccu)
	local ticksPerMinute = 60 / Constants.QUEUE_TICK_RATE
	-- Units used per tick (averaged across rounds and servers)
	local totalTicks = roundsRun * SERVER_COUNT
	local unitsPerTick = totalTicks > 0 and (stats.totalUnits / totalTicks) or 0
	-- Project: one server running the loop alone (production has one matchmaking server)
	local projectedUnitsPerMinute = unitsPerTick * ticksPerMinute

	-- Breakdown: note UpdateAsync costs 2 units per call
	local updateUnitCost = stats.updateCalls * 2 -- already counted in totalUnits, shown for clarity

	print("\n[Stress] ════════ RESULTS ════════")
	print(string.format("[Stress] Players:                %d", PLAYER_COUNT))
	print(string.format("[Stress] Servers simulated:      %d", SERVER_COUNT))
	print(string.format("[Stress] Rounds run:             %d", roundsRun))
	print(string.format("[Stress] Matches formed:         %d  (max possible: %d)", totalMatches, math.floor(PLAYER_COUNT / 2)))
	print(string.format("[Stress] Duplicate matches:      %d  (must be 0)", duplicatesDetected))
	print("")
	print("[Stress] ── Op breakdown (request units) ──")
	print(string.format("  SetAsync calls:      %d   × 1 unit  = %d units", stats.setCalls, stats.setCalls))
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
