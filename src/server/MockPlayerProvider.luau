-- MockPlayerProvider.luau
-- Single source of all fake player data.
-- Zero game logic — data only. Every other system is unaware this data is fake.

local RankCalculator = require(script.Parent.RankCalculator)

local MockPlayerProvider = {}

-- Display name pool. Loops if more players than names are seeded.
local NAMES = {
	"Archer", "Blaze", "Comet", "Drake", "Echo",
	"Frostbite", "Ghost", "Havoc", "Ironside", "Jade",
	"Kraken", "Lynx", "Maverick", "Nova", "Omega",
	"Phantom", "Quake", "Raven", "Specter", "Titan",
	"Ultra", "Viper", "Wolf", "Xero", "Yield", "Zenith",
	"Abyss", "Bolt", "Cipher", "Dusk",
}

local REGIONS = { "NA", "EU", "ASIA" }

local _pool: { any } = {}
local _nextId = 1
local _groupIdCounter = 0

-- Bell-curve MMR distribution centered at Gold (1200 MMR), std dev ~500.
-- This gives a realistic rank spread: mostly Gold/Silver, fewer at extremes.
local function randomMMR(): number
	-- Box-Muller transform approximation
	local u = math.max(math.random(), 1e-10) -- guard against log(0)
	local v = math.random()
	local z = math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v)
	return math.clamp(math.round(1200 + z * 500), 0, 3000)
end

local function makePlayer(mmr: number): any
	local id = _nextId
	_nextId += 1
	return {
		userId = id,
		displayName = NAMES[(id - 1) % #NAMES + 1] .. string.format("_%02d", id),
		mmr = mmr,
		rank = RankCalculator.getRankTier(mmr),
		wins = math.random(0, 300),
		losses = math.random(0, 300),
		region = REGIONS[math.random(1, #REGIONS)],
		queueJoinTime = os.time(),
		isBot = true,
	}
end

-- Seed the internal pool with `count` mock players.
-- Call this before any getNextPlayer() or drainAll() calls.
function MockPlayerProvider.seed(count: number)
	_pool = {}
	_nextId = 1
	for _ = 1, count do
		table.insert(_pool, makePlayer(randomMMR()))
	end
	print(string.format("[MockProvider] Seeded %d players into pool", #_pool), _pool)
end

-- Pop one random player from the pool (simulates a player joining the queue).
-- Returns nil when the pool is empty.
function MockPlayerProvider.getNextPlayer(): any?
	if #_pool == 0 then
		return nil
	end
	local idx = math.random(1, #_pool)
	local player = _pool[idx]
	table.remove(_pool, idx)
	player.queueJoinTime = os.time()
	return player
end

-- Remove and return all remaining players at once (bulk queue seed).
function MockPlayerProvider.drainAll(): { any }
	local all = _pool
	_pool = {}
	for _, p in all do
		p.queueJoinTime = os.time()
	end
	return all
end

function MockPlayerProvider.poolSize(): number
	return #_pool
end

-- Build a group entry from one or more players.
-- queueType: the match type the group chose (1=1v1, 2=2v2, 3=3v3). Must be >= #members.
-- Defaults to #members when not provided (premade fills exactly one team slot).
local function makeGroup(members: { any }, queueType: number?): any
	_groupIdCounter += 1
	local totalMmr = 0
	local MostMmrPlayer = nil
	for _, m in members do
		totalMmr += m.mmr
		if not MostMmrPlayer or m.mmr > MostMmrPlayer.mmr then
			MostMmrPlayer = m
		end
	end
	local avgMmr = math.round(totalMmr / #members)
	local groupSize = #members
	return {
		groupId       = tostring(_groupIdCounter),
		members       = members,
		avgMmr        = avgMmr,
		size          = groupSize,
		queueType     = queueType or groupSize, -- desired team size (bucket key)
		rank          = RankCalculator.getRankTier(avgMmr),
		region        = members[1].region,
		queueJoinTime = os.time(),
		claimed       = false,
		mostlyMMRPlayer = MostMmrPlayer,
	}
end

-- Seed and return a mix of solo and premade duo groups.
-- soloCount  : players queuing alone (size=1 groups)
-- duoCount   : premade pairs queuing together (size=2 groups)
-- Total players = soloCount + duoCount * 2
function MockPlayerProvider.seedGroups(soloCount: number, duoCount: number?): { any }
	_pool = {}
	_nextId = 1
	_groupIdCounter = 0

	local groups = {}

	for _ = 1, soloCount do
		local p = makePlayer(randomMMR())
		table.insert(groups, makeGroup({
			{ userId = p.userId, displayName = p.displayName, mmr = p.mmr, rank = p.rank, region = p.region },
		}))
	end

	for _ = 1, (duoCount or 0) do
		local p1 = makePlayer(randomMMR())
		local p2 = makePlayer(randomMMR())
		table.insert(groups, makeGroup({
			{ userId = p1.userId, displayName = p1.displayName, mmr = p1.mmr, rank = p1.rank, region = p1.region },
			{ userId = p2.userId, displayName = p2.displayName, mmr = p2.mmr, rank = p2.rank, region = p2.region },
		}))
	end

	print(string.format("[MockProvider] Seeded %d groups (%d solo, %d duo)",
		#groups, soloCount, duoCount or 0))
	return groups
end

-- Seed and return groups of random sizes (1–3) until playerCount players are distributed.
-- Exercises 1v1, 2v2, and 3v3 code paths in a single run.
function MockPlayerProvider.seedMixed(playerCount: number): { any }
	_pool = {}
	_nextId = 1
	_groupIdCounter = 0

	local groups = {}
	local sizeCounts = { 0, 0, 0 }
	local playersLeft = playerCount

	while playersLeft > 0 do
		local maxSize = math.min(3, playersLeft)
		local groupSize = math.random(1, maxSize)
		local members = {}
		for _ = 1, groupSize do
			local p = makePlayer(randomMMR())
			table.insert(members, {
				userId = p.userId, displayName = p.displayName,
				mmr = p.mmr, rank = p.rank, region = p.region,
			})
		end
		-- queueType is the match type the group chose, independently of group size.
		-- A solo (size=1) can queue for 1v1, 2v2, or 3v3.
		-- A duo (size=2) can queue for 2v2 or 3v3 (can't fit two people in a 1v1 team).
		local queueType = math.random(groupSize, 3)
		table.insert(groups, makeGroup(members, queueType))
		sizeCounts[groupSize] += 1
		playersLeft -= groupSize
	end

	print(string.format(
		"[MockProvider] Seeded %d groups from %d players (%d solo, %d duo, %d trio)",
		#groups, playerCount, sizeCounts[1], sizeCounts[2], sizeCounts[3]
	))
	return groups
end

return MockPlayerProvider
