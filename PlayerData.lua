-- PlayerData.lua
local PlayerData = {}

-- Helper: Convert Hex (0xFF0000FF) to Rive's Signed Int Color
function PlayerData.toColor(hex: number): number
  if hex > 0x7FFFFFFF then
    return hex - 0x100000000
  end
  return hex
end

-- Factory Function to create a default player data object
function PlayerData.new(name: string, colorHex: number)
  return {
    name = name,
    color = PlayerData.toColor(colorHex),
    -- Future scalability: Add level, xp, avatarId, etc. here
    score = 0, -- Moving score here makes sense for data encapsulation
  }
end

return PlayerData
