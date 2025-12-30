local PlayerData = require('PlayerData')

-- ===========================================================================
-- SECTION 1: TYPE DEFINITIONS
-- ===========================================================================

type StatusEffect = {
  kind: string,
  timer: number,
  duration: number,
}

type Entity = {
  x: number,
  y: number,
  vx: number,
  vy: number,
  mass: number,
  radius: number,
  friction: number,
  baseRadius: number,
  baseFriction: number,
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

-- Main Game Type
type IceHockeyV1 = {
  -- Config Inputs
  fieldWidth: Input<number>,
  fieldHeight: Input<number>,
  maxPuckSpeed: Input<number>,

  -- Rules Inputs
  maxPowerups: Input<number>,
  spawnRate: Input<number>,
  maxZoneTime: Input<number>,
  pointsToWin: Input<number>,

  -- Player Inputs
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

  -- Physics State
  puck: Entity,
  p1: Entity,
  p2: Entity,

  -- Game State
  lastTouchedBy: number,
  dragTarget: Entity?,

  -- Player Data (Loaded via Require)
  p1Data: any, -- Typed as 'any' because strict typing cross-file can be tricky in some envs
  p2Data: any,

  -- Systems
  powerups: { Powerup },
  spawnTimer: number,
  nextId: number,
  activeG1Height: number,
  activeG2Height: number,
  zoneTimer: number,
  currentZone: number,
}

-- ===========================================================================
-- SECTION 2: MATH & PHYSICS
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
  local minDist = player.radius + puck.radius

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

-- ===========================================================================
-- SECTION 3: STATUS EFFECTS & POWERUPS
-- ===========================================================================

local function addStatusEffect(entity: Entity, kind: string, duration: number)
  for _, fx in ipairs(entity.effects) do
    if fx.kind == kind then
      fx.timer = duration
      return
    end
  end
  table.insert(
    entity.effects,
    { kind = kind, timer = duration, duration = duration }
  )
end

local function manageStatusEffects(entity: Entity, seconds: number)
  entity.radius = entity.baseRadius
  entity.friction = entity.baseFriction
  for i = #entity.effects, 1, -1 do
    local fx = entity.effects[i]
    if fx.kind == 'giantPaddle' then
      entity.radius = entity.baseRadius * 1.5
    elseif fx.kind == 'tinyPaddle' then
      entity.radius = entity.baseRadius * 0.7
    end
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

  if kind == 'smallerGoal' then
    if recipientId == 1 then
      self.activeG1Height = clamp(self.activeG1Height - 5, 5, 90)
    else
      self.activeG2Height = clamp(self.activeG2Height - 5, 5, 90)
    end
  elseif kind == 'biggerGoal' then
    if recipientId == 1 then
      self.activeG2Height = clamp(self.activeG2Height + 5, 5, 90)
    else
      self.activeG1Height = clamp(self.activeG1Height + 5, 5, 90)
    end
  elseif kind == 'giantPaddle' then
    local target = (recipientId == 1) and self.p1 or self.p2
    addStatusEffect(target, 'giantPaddle', 8.0)
  elseif kind == 'tinyPaddle' then
    local target = (recipientId == 1) and self.p2 or self.p1
    addStatusEffect(target, 'tinyPaddle', 8.0)
  end
end

local function spawnPowerup(self: IceHockeyV1)
  if #self.powerups >= self.maxPowerups then
    return
  end
  local padding = 50
  local fW, fH = self.fieldWidth, self.fieldHeight
  local px = math.random(padding, fW - padding)
  local py = math.random(padding, fH - padding)
  local kinds = { 'smallerGoal', 'biggerGoal', 'giantPaddle', 'tinyPaddle' }
  local kind = kinds[math.random(1, #kinds)]

  local inst = nil
  if self.powerupArtboard then
    inst = self.powerupArtboard:instance()
  end
  if inst and inst.data then
    if inst.data.sizeX then
      inst.data.sizeX.value = 60
    end
    if inst.data.sizeY then
      inst.data.sizeY.value = 60
    end
    if inst.data.lifecycle then
      inst.data.lifecycle.value = 100
    end
    if inst.data.kind then
      inst.data.kind.value = kind
    end
  end

  table.insert(self.powerups, {
    id = self.nextId,
    x = px,
    y = py,
    radius = 30,
    kind = kind,
    lifespan = 10.0,
    maxLifespan = 10.0,
    instance = inst,
  })
  self.nextId = self.nextId + 1
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
          p.instance.data.lifecycle.value = (p.lifespan / p.maxLifespan) * 100
        end
      end
      if
        dist(p.x, p.y, self.puck.x, self.puck.y) < (p.radius + self.puck.radius)
      then
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
      if inst.data then
        if inst.data.sizeX then
          inst.data.sizeX.value = self.p1.baseRadius * 2
        end
        if inst.data.sizeY then
          inst.data.sizeY.value = self.p1.baseRadius * 2
        end
        -- Use Data from External Module
        if inst.data.color then
          inst.data.color.value = self.p1Data.color
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
          inst.data.color.value = self.p2Data.color
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
  if
    dist(event.position.x, event.position.y, self.p1.x, self.p1.y)
    < self.p1.radius * 1.5
  then
    self.dragTarget = self.p1
  elseif
    dist(event.position.x, event.position.y, self.p2.x, self.p2.y)
    < self.p2.radius * 1.5
  then
    self.dragTarget = self.p2
  end
end

function pointerMove(self: IceHockeyV1, event: PointerEvent)
  if self.dragTarget then
    local oldX, oldY = self.dragTarget.x, self.dragTarget.y
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
  local fW, fH = self.fieldWidth, self.fieldHeight

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

  self.lastTouchedBy = 0
  self.dragTarget = nil
  self.powerups = {}
  self.spawnTimer = 0
  self.nextId = 1
  self.activeG1Height = 30
  self.activeG2Height = 30
  self.zoneTimer = 0
  self.currentZone = 0

  -- Init Player Data using the Helper
  self.p1Data = PlayerData.new(self.player1Name, 0xFF3333CC)
  self.p2Data = PlayerData.new(self.player2Name, 0xFFCC3333)

  createMainArtboards(self)
  resetPuck(self)
  return true
end

function advance(self: IceHockeyV1, seconds: number): boolean
  createMainArtboards(self)
  local fW, fH = self.fieldWidth, self.fieldHeight

  -- 1. APPLY EFFECTS
  manageStatusEffects(self.p1, seconds)
  manageStatusEffects(self.p2, seconds)

  -- Sync Visuals
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

  -- 3. ZONE
  local mid = fW / 2
  local newZone = (self.puck.x < mid) and 1 or 2
  if newZone ~= self.currentZone then
    self.currentZone = newZone
    self.zoneTimer = 0
  else
    self.zoneTimer = self.zoneTimer + seconds
    if self.zoneTimer > self.maxZoneTime then
      local zOwner = (self.currentZone == 1) and self.p1Data.name
        or self.p2Data.name
      print('TIME LIMIT: ' .. zOwner .. '\'s Zone!')
      self.zoneTimer = 0
    end
  end

  -- 4. CONSTRAINTS
  self.p1.x = clamp(self.p1.x, self.p1.radius, (fW / 2) - self.p1.radius)
  self.p1.y = clamp(self.p1.y, self.p1.radius, fH - self.p1.radius)
  self.p2.x = clamp(self.p2.x, (fW / 2) + self.p2.radius, fW - self.p2.radius)
  self.p2.y = clamp(self.p2.y, self.p2.radius, fH - self.p2.radius)

  -- 5. GOAL SYNC
  if self.player1Goal and self.player1Goal.height then
    self.player1Goal.height.value = self.activeG1Height
  end
  if self.player2Goal and self.player2Goal.height then
    self.player2Goal.height.value = self.activeG2Height
  end

  -- 6. WALLS
  if self.puck.y < self.puck.radius then
    self.puck.y = self.puck.radius
    self.puck.vy = math.abs(self.puck.vy)
  elseif self.puck.y > fH - self.puck.radius then
    self.puck.y = fH - self.puck.radius
    self.puck.vy = -math.abs(self.puck.vy)
  end

  local p1G = fH * (self.activeG1Height / 100)
  local p2G = fH * (self.activeG2Height / 100)

  if self.puck.x < self.puck.radius then
    if
      not (
        self.puck.y > (fH / 2 - p1G / 2) and self.puck.y < (fH / 2 + p1G / 2)
      )
    then
      self.puck.x = self.puck.radius
      self.puck.vx = math.abs(self.puck.vx) * 0.8
    end
  end
  if self.puck.x > fW - self.puck.radius then
    if
      not (
        self.puck.y > (fH / 2 - p2G / 2) and self.puck.y < (fH / 2 + p2G / 2)
      )
    then
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
  if self.puck.x < -30 then
    self.p2Data.score = self.p2Data.score + 1
    if self.p2Data.score >= self.pointsToWin then
      print('GAME OVER! ' .. self.p2Data.name .. ' Wins!')
      self.p1Data.score = 0
      self.p2Data.score = 0
      self.activeG1Height = 30
      self.activeG2Height = 30
    else
      local msg = (self.lastTouchedBy == 1)
          and ('OWN GOAL! ' .. self.p1Data.name)
        or ('GOAL! ' .. self.p2Data.name)
      print(msg .. ' (' .. self.p1Data.score .. '-' .. self.p2Data.score .. ')')
    end
    resetPuck(self)
  elseif self.puck.x > fW + 30 then
    self.p1Data.score = self.p1Data.score + 1
    if self.p1Data.score >= self.pointsToWin then
      print('GAME OVER! ' .. self.p1Data.name .. ' Wins!')
      self.p1Data.score = 0
      self.p2Data.score = 0
      self.activeG1Height = 30
      self.activeG2Height = 30
    else
      local msg = (self.lastTouchedBy == 2)
          and ('OWN GOAL! ' .. self.p2Data.name)
        or ('GOAL! ' .. self.p1Data.name)
      print(msg .. ' (' .. self.p1Data.score .. '-' .. self.p2Data.score .. ')')
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
  local fW, fH = self.fieldWidth, self.fieldHeight
  self.p1.x = clamp(self.p1.x, self.p1.radius, (fW / 2) - self.p1.radius)
  self.p1.y = clamp(self.p1.y, self.p1.radius, fH - self.p1.radius)
  self.p2.x = clamp(self.p2.x, (fW / 2) + self.p2.radius, fW - self.p2.radius)
  self.p2.y = clamp(self.p2.y, self.p2.radius, fH - self.p2.radius)
  self.puck.x = clamp(self.puck.x, self.puck.radius, fW - self.puck.radius)
  self.puck.y = clamp(self.puck.y, self.puck.radius, fH - self.puck.radius)

  -- Sync Input Names
  self.p1Data.name = self.player1Name
  self.p2Data.name = self.player2Name
end

function draw(self: IceHockeyV1, renderer: Renderer)
  local function drawEnt(inst: Artboard<any>?, e: Entity)
    if inst then
      renderer:save()
      renderer:transform(Mat2D.withTranslation(e.x - e.radius, e.y - e.radius))
      inst:draw(renderer)
      renderer:restore()
    end
  end

  for _, p in ipairs(self.powerups) do
    if p.instance then
      renderer:save()
      renderer:transform(Mat2D.withTranslation(p.x - p.radius, p.y - p.radius))
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

    -- These are just placeholders to satisfy the Type definition initially
    -- They get overwritten by PlayerData.new() in init()
    p1Data = { name = 'P1', color = 0, score = 0 },
    p2Data = { name = 'P2', color = 0, score = 0 },
  }
end
