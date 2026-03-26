-- RankCalculator.luau
-- Pure functions only. No state, no side effects.
-- Same code path regardless of mock or live data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local RankCalculator = {}

-- Maps MMR to the highest tier the player qualifies for
function RankCalculator.getRankTier(mmr: number): string
	local thresholds = {
		{ tier = "Diamond", threshold = Constants.RANK_THRESHOLDS.Diamond },
		{ tier = "Platinum", threshold = Constants.RANK_THRESHOLDS.Platinum },
		{ tier = "Gold", threshold = Constants.RANK_THRESHOLDS.Gold },
		{ tier = "Silver", threshold = Constants.RANK_THRESHOLDS.Silver },
		{ tier = "Bronze", threshold = Constants.RANK_THRESHOLDS.Bronze },
	}
	for _, entry in thresholds do
		if mmr >= entry.threshold then
			return entry.tier
		end
	end
	return "Bronze"
end

-- Current eligible MMR spread for a player based on how long they've waited
function RankCalculator.getMMRSpread(queueJoinTime: number): number
	local waitSeconds = os.time() - queueJoinTime
	local spread = Constants.BASE_MMR_SPREAD + (waitSeconds * Constants.SPREAD_PER_SECOND)
	return math.min(spread, Constants.MAX_MMR_SPREAD)
end

-- Returns true if two queued players are eligible to be matched right now
function RankCalculator.isEligibleMatch(playerA: any, playerB: any): boolean
	if playerA.userId == playerB.userId then return false end
	-- Use the spread of whichever player has waited longer (more flexible match window)
	local olderJoinTime = math.min(playerA.queueJoinTime, playerB.queueJoinTime)
	local spread = RankCalculator.getMMRSpread(olderJoinTime)
	return math.abs(playerA.mmr - playerB.mmr) <= spread
end

-- ELO expected score for playerA against playerB
local function expectedScore(mmrA: number, mmrB: number): number
	return 1 / (1 + 10 ^ ((mmrB - mmrA) / 400))
end

-- Returns (deltaForWinner, deltaForLoser) — loser delta is always negative
function RankCalculator.calculateMMRDelta(winner: any, loser: any, kFactor: number?): (number, number)
	local k = kFactor or Constants.K_FACTOR
	local expected = expectedScore(winner.mmr, loser.mmr)
	local delta = math.round(k * (1 - expected))
	return delta, -delta
end

return RankCalculator
