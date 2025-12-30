-- ===========================================================================
-- SECTION 1: TYPE DEFINITIONS
-- ===========================================================================

-- Temporary Effect applied to a player
type StatusEffect = {
  kind: string, -- "giantPaddle", "tinyPaddle", etc.
  timer: number, -- Seconds remaining
  duration: number, -- Total duration (for potential UI bars)
}

-- Updated Entity with Base vs Current separation
type Entity = {
  x: number,
  y: number,
  vx: number,
  vy: number,
  mass: number,

  -- Current (Calculated every frame)
  radius: number,
  friction: number,

  -- Base (Defaults)
  baseRadius: number,
  baseFriction: number,

  -- Active Effects
  effects: { StatusEffect },
}

type Powerup = {
  id: number,
  x: number,
  y: number,
  radius: number,
  kind: string,
  lifespan: number,
  maxLifespan: number,
  instance: Artboard<Data.PowerupVM>?,
}

type IceHockeyV1 = {
  -- Configuration Inputs
  fieldWidth: Input<number>,
  fieldHeight: Input<number>,
  maxPuckSpeed: Input<number>,

  -- Game Rules
  maxPowerups: Input<number>,
  spawnRate: Input<number>,
  maxZoneTime: Input<number>,
  pointsToWin: Input<number>,

  -- Names
  player1Name: Input<string>,
  player2Name: Input<string>,

  -- Assets
  playerArtboard: Input<Artboard<Data.PlayerVM>>,
  puckArtboard: Input<Artboard<Data.PuckVM>>,
  powerupArtboard: Input<Artboard<Data.PowerupVM>>,
  player1Goal: Input<Data.GoalVM>,
  player2Goal: Input<Data.GoalVM>,

  -- Instances
  p1Instance: Artboard<Data.PlayerVM>?,
  p2Instance: Artboard<Data.PlayerVM>?,
  puckInstance: Artboard<Data.PuckVM>?,

  -- State
  puck: Entity,
  p1: Entity,
  p2: Entity,

  score1: number,
  score2: number,
  lastTouchedBy: number,
  dragTarget: Entity?,

  p1Data: { name: string, color: number },
  p2Data: { name: string, color: number },

  powerups: { Powerup },
  spawnTimer: number,
  nextId: number,

  activeG1Height: number,
  activeG2Height: number,
  zoneTimer: number,
  currentZone: number,
}

-- ===========================================================================
-- SECTION 2: MATH & PHYSICS HELPERS
-- ===========================================================================

local function dist(x1: number, y1: number, x2: number, y2: number): number
  return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
end

local function clamp(val: number, min: number, max: number): number
  return math.max(min, math.min(max, val))
end

local function resolveCollision(
  self: IceHockeyV1,
  player: Entity,
  puck: Entity,
  playerId: number
)
  local dx = puck.x - player.x
  local dy = puck.y - player.y
  local distance = math.sqrt(dx * dx + dy * dy)
  local minDist = player.radius + puck.radius -- Uses dynamic radius

  if distance < minDist then
    self.lastTouchedBy = playerId

    local nx = dx / distance
    local ny = dy / distance
    local overlap = minDist - distance
    puck.x = puck.x + (nx * overlap)
    puck.y = puck.y + (ny * overlap)

    local dvx = puck.vx - player.vx
    local dvy = puck.vy - player.vy

    local dot = (dvx * nx) + (dvy * ny)
    if dot < 0 then
      local restitution = 0.8
      local impulse = -(1 + restitution) * dot

      puck.vx = puck.vx + (impulse * nx)
      puck.vy = puck.vy + (impulse * ny)

      local hitPower = 0.5
      puck.vx = puck.vx + (player.vx * hitPower)
      puck.vy = puck.vy + (player.vy * hitPower)

      local currentSpeed = math.sqrt(puck.vx ^ 2 + puck.vy ^ 2)
      if currentSpeed > self.maxPuckSpeed then
        local scale = self.maxPuckSpeed / currentSpeed
        puck.vx = puck.vx * scale
        puck.vy = puck.vy * scale
      end
    end
  end
end

local function resetPuck(self: IceHockeyV1)
  self.puck.x = self.fieldWidth / 2
  self.puck.y = self.fieldHeight / 2
  self.lastTouchedBy = 0
  self.zoneTimer = 0
  self.currentZone = 0

  local dir = (math.random() > 0.5) and 1 or -1
  self.puck.vx = 300 * dir
  self.puck.vy = (math.random() * 200) - 100
end

-- Color Helper: Convert Hex to Signed Integer
local function toColor(hex: number): number
  if hex > 0x7FFFFFFF then
    return hex - 0x100000000
  end
  return hex
end

-- ===========================================================================
-- SECTION 3: STATUS EFFECTS & POWERUPS
-- ===========================================================================

-- 1. Helper to add or refresh an effect
local function addStatusEffect(entity: Entity, kind: string, duration: number)
  -- Check if effect exists
  for _, fx in ipairs(entity.effects) do
    if fx.kind == kind then
      fx.timer = duration -- Refresh timer
      return
    end
  end
  -- Add new
  table.insert(
    entity.effects,
    { kind = kind, timer = duration, duration = duration }
  )
end

-- 2. System to recalculate stats every frame
local function manageStatusEffects(entity: Entity, seconds: number)
  -- Reset to Base
  entity.radius = entity.baseRadius
  entity.friction = entity.baseFriction

  -- Process Effects
  for i = #entity.effects, 1, -1 do
    local fx = entity.effects[i]

    -- Apply Modifiers
    if fx.kind == 'giantPaddle' then
      entity.radius = entity.baseRadius * 1.5
    elseif fx.kind == 'tinyPaddle' then
      entity.radius = entity.baseRadius * 0.7
    end

    -- Tick Timer
    fx.timer = fx.timer - seconds
    if fx.timer <= 0 then
      table.remove(entity.effects, i)
    end
  end
end

local function applyPowerup(
  self: IceHockeyV1,
  kind: string,
  recipientId: number
)
  local recipientName = (recipientId == 1) and self.p1Data.name
    or self.p2Data.name
  print('Applying Powerup: ' .. kind .. ' to ' .. recipientName)

  -- GOAL MODIFIERS (Permanent)
  if kind == 'smallerGoal' then
    if recipientId == 1 then
      self.activeG1Height = clamp(self.activeG1Height - 5, 5, 90)
    elseif recipientId == 2 then
      self.activeG2Height = clamp(self.activeG2Height - 5, 5, 90)
    end
  elseif kind == 'biggerGoal' then
    if recipientId == 1 then
      self.activeG2Height = clamp(self.activeG2Height + 5, 5, 90)
    elseif recipientId == 2 then
      self.activeG1Height = clamp(self.activeG1Height + 5, 5, 90)
    end

  -- ENTITY MODIFIERS (Temporary)
  -- Logic: Some buffs go to self, debuffs go to opponent
  elseif kind == 'giantPaddle' then
    local target = (recipientId == 1) and self.p1 or self.p2
    addStatusEffect(target, 'giantPaddle', 8.0)
  elseif kind == 'tinyPaddle' then
    -- Debuff: Apply to opponent
    local target = (recipientId == 1) and self.p2 or self.p1
    addStatusEffect(target, 'tinyPaddle', 8.0)
  end
end

local function spawnPowerup(self: IceHockeyV1)
  if #self.powerups >= self.maxPowerups then
    return
  end

  local padding = 50
  local fW = self.fieldWidth
  local fH = self.fieldHeight
  local px = math.random(padding, fW - padding)
  local py = math.random(padding, fH - padding)

  -- Updated Pool
  local possibleKinds =
    { 'smallerGoal', 'biggerGoal', 'giantPaddle', 'tinyPaddle' }
  local chosenKind = possibleKinds[math.random(1, #possibleKinds)]

  local inst = nil
  if self.powerupArtboard then
    inst = self.powerupArtboard:instance()
  end

  local radius = 30

  if inst and inst.data then
    if inst.data.sizeX then
      inst.data.sizeX.value = radius * 2
    end
    if inst.data.sizeY then
      inst.data.sizeY.value = radius * 2
    end
    if inst.data.lifecycle then
      inst.data.lifecycle.value = 100
    end
    if inst.data.kind then
      inst.data.kind.value = chosenKind
    end
  end

  local newPowerup = {
    id = self.nextId,
    x = px,
    y = py,
    radius = radius,
    kind = chosenKind,
    lifespan = 10.0,
    maxLifespan = 10.0,
    instance = inst,
  }

  self.nextId = self.nextId + 1
  table.insert(self.powerups, newPowerup)
end

local function updatePowerups(self: IceHockeyV1, seconds: number)
  self.spawnTimer = self.spawnTimer + seconds
  if self.spawnTimer >= self.spawnRate then
    self.spawnTimer = 0
    if math.random() > 0.5 then
      spawnPowerup(self)
    end
  end

  for i = #self.powerups, 1, -1 do
    local p = self.powerups[i]
    p.lifespan = p.lifespan - seconds

    if p.lifespan <= 0 then
      table.remove(self.powerups, i)
    else
      if p.instance then
        p.instance:advance(seconds)
        if p.instance.data and p.instance.data.lifecycle then
          local pct = (p.lifespan / p.maxLifespan) * 100
          p.instance.data.lifecycle.value = pct
        end
      end

      local distToPuck = dist(p.x, p.y, self.puck.x, self.puck.y)
      if distToPuck < (p.radius + self.puck.radius) then
        if self.lastTouchedBy ~= 0 then
          applyPowerup(self, p.kind, self.lastTouchedBy)
          table.remove(self.powerups, i)
        end
      end
    end
  end
end

-- ===========================================================================
-- SECTION 4: ARTBOARD MANAGEMENT
-- ===========================================================================

local function createMainArtboards(self: IceHockeyV1)
  -- Player 1
  if self.playerArtboard and not self.p1Instance then
    local inst = self.playerArtboard:instance()
    if inst then
      self.p1Instance = inst
      -- Initial setup
      if inst.data then
        if inst.data.sizeX then
          inst.data.sizeX.value = self.p1.baseRadius * 2
        end
        if inst.data.sizeY then
          inst.data.sizeY.value = self.p1.baseRadius * 2
        end
        if inst.data.color then
          inst.data.color.value = toColor(0xFF0000FF)
        end
      end
    end
  end
  -- Player 2
  if self.playerArtboard and not self.p2Instance then
    local inst = self.playerArtboard:instance()
    if inst then
      self.p2Instance = inst
      if inst.data then
        if inst.data.sizeX then
          inst.data.sizeX.value = self.p2.baseRadius * 2
        end
        if inst.data.sizeY then
          inst.data.sizeY.value = self.p2.baseRadius * 2
        end
        if inst.data.color then
          inst.data.color.value = toColor(0xFFFF0000)
        end
      end
    end
  end
  -- Puck
  if self.puckArtboard and not self.puckInstance then
    local inst = self.puckArtboard:instance()
    if inst then
      self.puckInstance = inst
      if inst.data then
        if inst.data.sizeX then
          inst.data.sizeX.value = self.puck.baseRadius * 2
        end
        if inst.data.sizeY then
          inst.data.sizeY.value = self.puck.baseRadius * 2
        end
      end
    end
  end
end

-- ===========================================================================
-- SECTION 5: INTERACTION & LIFECYCLE
-- ===========================================================================

function pointerDown(self: IceHockeyV1, event: PointerEvent)
  local x = event.position.x
  local y = event.position.y
  if dist(x, y, self.p1.x, self.p1.y) < self.p1.radius * 1.5 then
    self.dragTarget = self.p1
  elseif dist(x, y, self.p2.x, self.p2.y) < self.p2.radius * 1.5 then
    self.dragTarget = self.p2
  end
end

function pointerMove(self: IceHockeyV1, event: PointerEvent)
  if self.dragTarget then
    local oldX = self.dragTarget.x
    local oldY = self.dragTarget.y
    self.dragTarget.x = event.position.x
    self.dragTarget.y = event.position.y
    self.dragTarget.vx = (self.dragTarget.x - oldX) / 0.016
    self.dragTarget.vy = (self.dragTarget.y - oldY) / 0.016
  end
end

function pointerUp(self: IceHockeyV1, event: PointerEvent)
  self.dragTarget = nil
end

function init(self: IceHockeyV1): boolean
  local fW = self.fieldWidth
  local fH = self.fieldHeight

  -- Initialize Entities with Base Stats
  self.puck = {
    x = fW / 2,
    y = fH / 2,
    vx = 0,
    vy = 0,
    mass = 1,
    radius = 15,
    baseRadius = 15,
    friction = 0.99,
    baseFriction = 0.99,
    effects = {},
  }
  self.p1 = {
    x = 100,
    y = fH / 2,
    vx = 0,
    vy = 0,
    mass = 10,
    radius = 30,
    baseRadius = 30,
    friction = 0.92,
    baseFriction = 0.92,
    effects = {},
  }
  self.p2 = {
    x = fW - 100,
    y = fH / 2,
    vx = 0,
    vy = 0,
    mass = 10,
    radius = 30,
    baseRadius = 30,
    friction = 0.92,
    baseFriction = 0.92,
    effects = {},
  }

  self.score1 = 0
  self.score2 = 0
  self.lastTouchedBy = 0
  self.dragTarget = nil
  self.powerups = {}
  self.spawnTimer = 0
  self.nextId = 1
  self.activeG1Height = 30
  self.activeG2Height = 30

  self.zoneTimer = 0
  self.currentZone = 0

  self.p1Data = { name = self.player1Name, color = toColor(0xFF0000FF) }
  self.p2Data = { name = self.player2Name, color = toColor(0xFFFF0000) }

  createMainArtboards(self)
  resetPuck(self)
  return true
end

function advance(self: IceHockeyV1, seconds: number): boolean
  createMainArtboards(self)

  local fW = self.fieldWidth
  local fH = self.fieldHeight

  -- 1. APPLY STATUS EFFECTS (Recalculate dynamic stats)
  manageStatusEffects(self.p1, seconds)
  manageStatusEffects(self.p2, seconds)

  -- Sync visual size for dynamic effects
  if self.p1Instance and self.p1Instance.data then
    self.p1Instance.data.sizeX.value = self.p1.radius * 2
    self.p1Instance.data.sizeY.value = self.p1.radius * 2
  end
  if self.p2Instance and self.p2Instance.data then
    self.p2Instance.data.sizeX.value = self.p2.radius * 2
    self.p2Instance.data.sizeY.value = self.p2.radius * 2
  end

  -- 2. PHYSICS
  local entities = { self.p1, self.p2, self.puck }
  for _, e in ipairs(entities) do
    if self.dragTarget ~= e then
      e.x = e.x + (e.vx * seconds)
      e.y = e.y + (e.vy * seconds)
      e.vx = e.vx * (1 - (1 - e.friction))
      e.vy = e.vy * (1 - (1 - e.friction))
      if math.abs(e.vx) < 1 then
        e.vx = 0
      end
      if math.abs(e.vy) < 1 then
        e.vy = 0
      end
    end
  end

  -- 3. ZONE DETECTION
  local midField = fW / 2
  local newZone = (self.puck.x < midField) and 1 or 2

  if newZone ~= self.currentZone then
    self.currentZone = newZone
    self.zoneTimer = 0
  else
    self.zoneTimer = self.zoneTimer + seconds
    if self.zoneTimer > self.maxZoneTime then
      local zOwner = (self.currentZone == 1) and self.p1Data.name
        or self.p2Data.name
      print('TIME LIMIT: Puck stuck in ' .. zOwner .. '\'s Zone!')
      self.zoneTimer = 0
    end
  end

  -- 4. CONSTRAINTS (Using dynamic radius)
  self.p1.x = clamp(self.p1.x, self.p1.radius, (fW / 2) - self.p1.radius)
  self.p1.y = clamp(self.p1.y, self.p1.radius, fH - self.p1.radius)
  self.p2.x = clamp(self.p2.x, (fW / 2) + self.p2.radius, fW - self.p2.radius)
  self.p2.y = clamp(self.p2.y, self.p2.radius, fH - self.p2.radius)

  -- 5. GOAL SYNC
  local g1Px = fH * (self.activeG1Height / 100)
  local g2Px = fH * (self.activeG2Height / 100)

  if self.player1Goal and self.player1Goal.height then
    self.player1Goal.height.value = self.activeG1Height
  end
  if self.player2Goal and self.player2Goal.height then
    self.player2Goal.height.value = self.activeG2Height
  end

  -- 6. WALLS & GOALS
  if self.puck.y < self.puck.radius then
    self.puck.y = self.puck.radius
    self.puck.vy = math.abs(self.puck.vy)
  elseif self.puck.y > fH - self.puck.radius then
    self.puck.y = fH - self.puck.radius
    self.puck.vy = -math.abs(self.puck.vy)
  end

  if self.puck.x < self.puck.radius then
    local inGoal = (self.puck.y > (fH / 2 - g1Px / 2))
      and (self.puck.y < (fH / 2 + g1Px / 2))
    if not inGoal then
      self.puck.x = self.puck.radius
      self.puck.vx = math.abs(self.puck.vx) * 0.8
    end
  end

  if self.puck.x > fW - self.puck.radius then
    local inGoal = (self.puck.y > (fH / 2 - g2Px / 2))
      and (self.puck.y < (fH / 2 + g2Px / 2))
    if not inGoal then
      self.puck.x = fW - self.puck.radius
      self.puck.vx = -math.abs(self.puck.vx) * 0.8
    end
  end

  -- 7. COLLISIONS
  resolveCollision(self, self.p1, self.puck, 1)
  resolveCollision(self, self.p2, self.puck, 2)

  -- 8. POWERUPS
  updatePowerups(self, seconds)

  -- 9. SCORING
  if self.puck.x < -self.puck.radius * 2 then
    self.score2 = self.score2 + 1
    if self.score2 >= self.pointsToWin then
      print(
        'GAME OVER! '
          .. self.p2Data.name
          .. ' Wins! (Final: '
          .. self.score1
          .. '-'
          .. self.score2
          .. ')'
      )
      self.score1 = 0
      self.score2 = 0
      self.activeG1Height = 30
      self.activeG2Height = 30
    else
      local msg = (self.lastTouchedBy == 1)
          and ('OWN GOAL! ' .. self.p1Data.name .. ' Self-Scored')
        or ('GOAL! ' .. self.p2Data.name .. ' Scored!')
      print(msg .. ' (Score: ' .. self.score1 .. '-' .. self.score2 .. ')')
    end
    resetPuck(self)
  elseif self.puck.x > fW + self.puck.radius * 2 then
    self.score1 = self.score1 + 1
    if self.score1 >= self.pointsToWin then
      print(
        'GAME OVER! '
          .. self.p1Data.name
          .. ' Wins! (Final: '
          .. self.score1
          .. '-'
          .. self.score2
          .. ')'
      )
      self.score1 = 0
      self.score2 = 0
      self.activeG1Height = 30
      self.activeG2Height = 30
    else
      local msg = (self.lastTouchedBy == 2)
          and ('OWN GOAL! ' .. self.p2Data.name .. ' Self-Scored')
        or ('GOAL! ' .. self.p1Data.name .. ' Scored!')
      print(msg .. ' (Score: ' .. self.score1 .. '-' .. self.score2 .. ')')
    end
    resetPuck(self)
  end

  -- 10. ANIMATIONS
  if self.p1Instance then
    self.p1Instance:advance(seconds)
  end
  if self.p2Instance then
    self.p2Instance:advance(seconds)
  end
  if self.puckInstance then
    self.puckInstance:advance(seconds)
  end

  return true
end

function update(self: IceHockeyV1)
  -- Enforce Boundaries
  local fW = self.fieldWidth
  local fH = self.fieldHeight
  self.p1.x = clamp(self.p1.x, self.p1.radius, (fW / 2) - self.p1.radius)
  self.p1.y = clamp(self.p1.y, self.p1.radius, fH - self.p1.radius)
  self.p2.x = clamp(self.p2.x, (fW / 2) + self.p2.radius, fW - self.p2.radius)
  self.p2.y = clamp(self.p2.y, self.p2.radius, fH - self.p2.radius)
  self.puck.x = clamp(self.puck.x, self.puck.radius, fW - self.puck.radius)
  self.puck.y = clamp(self.puck.y, self.puck.radius, fH - self.puck.radius)

  self.p1Data.name = self.player1Name
  self.p2Data.name = self.player2Name
end

function draw(self: IceHockeyV1, renderer: Renderer)
  local function drawEnt(inst: Artboard<any>?, e: Entity)
    if inst then
      renderer:save()
      local m = Mat2D.withTranslation(e.x - e.radius, e.y - e.radius)
      renderer:transform(m)
      inst:draw(renderer)
      renderer:restore()
    end
  end

  for _, p in ipairs(self.powerups) do
    if p.instance then
      renderer:save()
      local m = Mat2D.withTranslation(p.x - p.radius, p.y - p.radius)
      renderer:transform(m)
      p.instance:draw(renderer)
      renderer:restore()
    end
  end

  drawEnt(self.p1Instance, self.p1)
  drawEnt(self.p2Instance, self.p2)
  drawEnt(self.puckInstance, self.puck)
end

return function(): Node<IceHockeyV1>
  return {
    init = init,
    advance = advance,
    update = update,
    draw = draw,
    pointerDown = pointerDown,
    pointerMove = pointerMove,
    pointerUp = pointerUp,

    fieldWidth = 500,
    fieldHeight = 300,
    maxPuckSpeed = 1000,
    maxPowerups = 5,
    spawnRate = 3.0,
    maxZoneTime = 7.0,
    pointsToWin = 5,

    player1Name = 'Player 1',
    player2Name = 'Player 2',

    playerArtboard = late(),
    puckArtboard = late(),
    powerupArtboard = late(),
    player1Goal = late(),
    player2Goal = late(),

    p1Instance = nil,
    p2Instance = nil,
    puckInstance = nil,
    dragTarget = nil,

    puck = {
      x = 0,
      y = 0,
      vx = 0,
      vy = 0,
      radius = 0,
      mass = 0,
      friction = 0,
      baseRadius = 0,
      baseFriction = 0,
      effects = {},
    },
    p1 = {
      x = 0,
      y = 0,
      vx = 0,
      vy = 0,
      radius = 0,
      mass = 0,
      friction = 0,
      baseRadius = 0,
      baseFriction = 0,
      effects = {},
    },
    p2 = {
      x = 0,
      y = 0,
      vx = 0,
      vy = 0,
      radius = 0,
      mass = 0,
      friction = 0,
      baseRadius = 0,
      baseFriction = 0,
      effects = {},
    },

    score1 = 0,
    score2 = 0,
    lastTouchedBy = 0,
    powerups = {},
    spawnTimer = 0,
    nextId = 1,

    activeG1Height = 30,
    activeG2Height = 30,

    zoneTimer = 0,
    currentZone = 0,

    p1Data = { name = 'P1', color = 0xFF999999 },
    p2Data = { name = 'P2', color = 0xFF999999 },
  }
end
