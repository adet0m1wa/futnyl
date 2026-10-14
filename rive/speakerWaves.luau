-- The turntable's living parts: the records' spin, the sound waves rippling
-- out of the speakers, the music notes rising from them, and when a record's
-- cover may show.
--
-- Inputs: `playing` is bound to the view model's isPlaying; `quiet` is keyed
-- to 1 by the record-change animations so everything rests while a song
-- changes. Everything else comes from the view model (see init).
--
-- Sound (waves, notes, spin) needs isPlaying and spotifyOpen: while Spotify is
-- still launching the record waits. Motion only advances while there is
-- sound, so pausing freezes the waves and notes where they are and playing
-- again carries on; after a song change they start from the beginning.
--
-- Spin: 33⅓ RPM, easing up and down like a platter. The spinning record also
-- turns with `progress`, so a seek or a restart scrubs it forwards or back.
--
-- Song changes take as long as Spotify does: whoever starts one (a key, or
-- the host for changes made in Spotify) sets `awaitingTrack`, the old record
-- leaves, and the new one waits off the platter until the host has put the
-- new song's art on it and cleared the flag. Its cover is hidden until then,
-- so a stale cover never shows. If the host never answers, the record comes
-- in after a few seconds with the plain label.
--
-- If the host cannot give us a GPU canvas (or the shader is missing), the
-- waves are drawn with plain stroked rings so the effect never vanishes.

-- Geometry, in artboard units (the drawable sits at the artboard origin).
local ARTBOARD = Vector.xy(270, 270)
local LEFT_SPEAKER = Vector.xy(35.6, 235.2)
local RIGHT_SPEAKER = Vector.xy(237.6, 235.2)
local SPEAKER_RADIUS = 18
local BODY_CENTRE = Vector.xy(136.6, 134.3)
local BODY_HALF = Vector.xy(133.4, 133.4)
local BODY_RADIUS = 36.8
-- Render the shader at twice artboard resolution so it stays crisp on Retina.
local RESOLUTION = 2
-- 0x3FAF7C, the same green as the PLAYING indicator.
local WAVE_COLOR = { 63 / 255, 175 / 255, 124 / 255, 0.6 }
-- What single notes are lightened towards, and their colour before any cover.
local NOTE_LIGHT = Color.rgb(255, 255, 255)
local NOTE_GREY = Color.rgb(142, 142, 142)
local NOTE_DEFAULT_ACCENT = Color.rgb(63, 175, 124)

-- Seconds for one note to rise and fade: calm, not hurried.
local NOTE_CYCLE = 4.2
-- How fast the waves travel, relative to real time.
local WAVE_PACE = 0.55

-- 33⅓ RPM in degrees per second.
local SPIN_SPEED = 200
-- How far the record turns over a whole song when it is scrubbed.
local SCRUB_DEGREES = 1080
-- After the record on the platter changes, `progress` jumps for the new song;
-- that is not a seek, so it is followed directly for this long.
local CHANGE_SETTLE = 1.5

type Note = {
    x0: number,
    y0: number,
    dir: number,
    phase: number,
    seed: number,
    double: boolean,
}

type Waves = {
    playing: Input<boolean>,
    quiet: Input<number>,
    canvas: GPUCanvas?,
    pipeline: GPUPipeline?,
    uniforms: GPUBuffer?,
    bindGroup: GPUBindGroup?,
    data: buffer,
    sampler: ImageSampler,
    ringPaint: Paint,
    notePaint: Paint,
    singleNote: Path,
    doubleNote: Path,
    bodyClip: Path,
    triedGpu: boolean,

    -- view model
    context: Context?,
    vm: ViewModel?,
    spotifyOpen: Property<boolean>?,
    showingB: Property<boolean>?,
    progress: Property<number>?,
    accent: Property<Color>?,
    rotationA: Property<number>?,
    rotationB: Property<number>?,
    awaiting: Property<boolean>?,
    coverAOpacity: Property<number>?,
    coverBOpacity: Property<number>?,

    -- waves and notes
    time: number,
    amp: number,
    cycles: number,
    changing: boolean,

    -- spin
    clock: number,
    spin: number,
    angleA: number,
    angleB: number,
    smoothProgress: number,
    settleUntil: number,
    lastShowingB: boolean,

    -- covers: hidden on a record that arrives before its art
    wasAwaiting: boolean,
    awaitingSince: number,
    gaveUp: boolean,
    shownA: number,
    shownB: number,
}

local function setupGpu(self: Waves, context: Context)
    self.triedGpu = true
    local shader = context:shader('waves')
    if shader == nil then
        print('waves: shader not found, using vector rings')
        return
    end
    local ok, err = pcall(function()
        local canvas = context:gpuCanvas({
            width = ARTBOARD.x * RESOLUTION,
            height = ARTBOARD.y * RESOLUTION,
        })
        local pipeline = GPUPipeline.new({
            vertex = shader,
            fragment = shader,
            vertexLayout = {},
            colorTargets = { { format = canvas.format } },
        })
        local uniforms = GPUBuffer.new({ size = buffer.len(self.data), usage = 'uniform' })
        self.bindGroup = GPUBindGroup.new({
            layout = pipeline:getBindGroupLayout(0),
            ubos = { { slot = 0, buffer = uniforms } },
        })
        self.canvas = canvas
        self.pipeline = pipeline
        self.uniforms = uniforms
    end)
    if not ok then
        print('waves: GPU canvas unavailable, using vector rings:', err)
        self.canvas = nil
        self.pipeline = nil
        self.uniforms = nil
        self.bindGroup = nil
    end
end

-- Takes hold of the view model's properties. A host app binds its own view
-- model after the file loads, so this runs again whenever the bound one
-- changes (see advance); holding on to the first one would leave the record
-- spinning, scrubbing and colouring a view model nobody shows.
local function bind(self: Waves, vm: ViewModel)
        self.vm = vm
        self.spotifyOpen = vm:getBoolean('spotifyOpen')
        self.showingB = vm:getBoolean('showingRecordB')
        self.progress = vm:getNumber('progress')
        self.accent = vm:getColor('accentColor')
        self.rotationA = vm:getNumber('rotationPanicIsland')
        self.rotationB = vm:getNumber('rotationFinalChampion')
        self.coverAOpacity = vm:getNumber('coverAOpacity')
        self.coverBOpacity = vm:getNumber('coverBOpacity')
        self.awaiting = vm:getBoolean('awaitingTrack')
        local showingB = self.showingB
        self.lastShowingB = if showingB ~= nil then showingB.value else false
        local progress = self.progress
        self.smoothProgress = if progress ~= nil then progress.value else 0
        local rotationA = self.rotationA
        local rotationB = self.rotationB
        self.angleA = if rotationA ~= nil then rotationA.value else 0
        self.angleB = if rotationB ~= nil then rotationB.value else 0
        -- The host's first position is where the song is, not a seek.
        self.settleUntil = self.clock + CHANGE_SETTLE
end

local function init(self: Waves, context: Context): boolean
    self.context = context
    -- init runs twice; the view model only exists on the second call.
    local vm = context:viewModel()
    if vm ~= nil and self.vm == nil then
        bind(self, vm)
    end
    if not self.triedGpu then
        setupGpu(self, context)
    end
    return true
end

local function approach(current: number, target: number, rate: number, seconds: number): number
    return current + (target - current) * math.min(1, seconds * rate)
end

-- If the host has not answered by then, the change finishes without it.
local GIVE_UP_AFTER = 6

-- The record on the platter changed. The one arriving hides its cover if its
-- song is still on the way.
local function recordChanged(self: Waves, showingB: boolean, awaiting: boolean)
    self.settleUntil = self.clock + CHANGE_SETTLE
    local shown = if awaiting then 0 else 1
    if showingB then
        self.shownB = shown
    else
        self.shownA = shown
    end
end

-- Follows awaitingTrack: reveals the cover once the host is done, and gives
-- up on a host that never answers.
local function advanceAwaiting(self: Waves, showingB: boolean): boolean
    local prop = self.awaiting
    local awaiting = prop ~= nil and prop.value
    if awaiting and not self.wasAwaiting then
        self.awaitingSince = self.clock
        self.gaveUp = false
    end
    if awaiting and prop ~= nil and self.clock - self.awaitingSince > GIVE_UP_AFTER then
        self.gaveUp = true
        prop.value = false
        awaiting = false
    end
    if self.wasAwaiting and not awaiting and not self.gaveUp then
        if showingB then
            self.shownB = 1
        else
            self.shownA = 1
        end
    end
    self.wasAwaiting = awaiting
    if awaiting then
        -- The new song's position is not a seek, however long it takes.
        self.settleUntil = self.clock + CHANGE_SETTLE
    end
    return awaiting
end

local function advanceSpin(self: Waves, seconds: number, sounding: boolean, quiet: number)
    local showingB = false
    local showingProp = self.showingB
    if showingProp ~= nil then
        showingB = showingProp.value
    end
    local awaitingProp = self.awaiting
    if showingB ~= self.lastShowingB then
        self.lastShowingB = showingB
        recordChanged(self, showingB, awaitingProp ~= nil and awaitingProp.value)
    end
    advanceAwaiting(self, showingB)

    -- Platter speed eases up quickly and runs down a little slower.
    local target = if sounding and quiet < 0.5 then 1 else 0
    local rate = if target > self.spin then 4 else 2.5
    self.spin = approach(self.spin, target, rate, seconds)
    if target == 0 and self.spin < 0.002 then
        self.spin = 0
    end
    local turn = SPIN_SPEED * self.spin * seconds

    -- Scrub with the song position: a seek turns the record with it.
    local progressProp = self.progress
    if progressProp ~= nil then
        local p = progressProp.value
        if self.clock < self.settleUntil then
            self.smoothProgress = p
        else
            local before = self.smoothProgress
            self.smoothProgress = approach(before, p, 14, seconds)
            if math.abs(p - self.smoothProgress) < 0.0005 then
                self.smoothProgress = p
            end
            turn += (self.smoothProgress - before) * SCRUB_DEGREES
        end
    end

    if turn ~= 0 then
        if showingB then
            self.angleB = (self.angleB + turn) % 360
            local rotationB = self.rotationB
            if rotationB ~= nil then
                rotationB.value = self.angleB
            end
        else
            self.angleA = (self.angleA + turn) % 360
            local rotationA = self.rotationA
            if rotationA ~= nil then
                rotationA.value = self.angleA
            end
        end
    end

    local coverAOpacity = self.coverAOpacity
    local coverBOpacity = self.coverBOpacity
    if coverAOpacity ~= nil and math.abs(coverAOpacity.value - self.shownA) > 0.001 then
        coverAOpacity.value = self.shownA
    end
    if coverBOpacity ~= nil and math.abs(coverBOpacity.value - self.shownB) > 0.001 then
        coverBOpacity.value = self.shownB
    end
end

local function advance(self: Waves, seconds: number): boolean
    self.clock += seconds
    local context = self.context
    if context ~= nil then
        local vm = context:viewModel()
        if vm ~= nil and not rawequal(vm, self.vm) then
            bind(self, vm)
        end
    end
    local quiet = math.clamp(self.quiet, 0, 1)
    local open = true
    local openProp = self.spotifyOpen
    if openProp ~= nil then
        open = openProp.value
    end
    local sounding = self.playing and open
    local target = if sounding then 1 - quiet else 0

    -- A song change fades everything out quickly, then restarts it.
    if quiet > 0.5 and not self.changing then
        self.changing = true
    elseif quiet <= 0.5 and self.changing then
        self.changing = false
        self.time = 0
        self.cycles = 0
    end

    -- Ease in calmly; ease out a little quicker, and quickest during a change.
    local rate = if target > self.amp then 1.1 elseif self.changing then 5 else 2.2
    self.amp = approach(self.amp, target, rate, seconds)
    if self.amp < 0.002 and target == 0 then
        self.amp = 0
    end

    -- Motion follows the sound: it slows as it fades and stops when silent.
    self.time += seconds * WAVE_PACE * self.amp
    self.cycles += seconds / NOTE_CYCLE * self.amp

    advanceSpin(self, seconds, sounding, quiet)
    return true
end

local function writeUniforms(self: Waves)
    local b = self.data
    local values = {
        ARTBOARD.x, ARTBOARD.y, self.time, self.amp,
        LEFT_SPEAKER.x, LEFT_SPEAKER.y, RIGHT_SPEAKER.x, RIGHT_SPEAKER.y,
        BODY_CENTRE.x, BODY_CENTRE.y, BODY_HALF.x, BODY_HALF.y,
        WAVE_COLOR[1], WAVE_COLOR[2], WAVE_COLOR[3], WAVE_COLOR[4],
        BODY_RADIUS, SPEAKER_RADIUS, 9, 16,
    }
    for i, v in values do
        buffer.writef32(b, (i - 1) * 4, v)
    end
end

-- Approximates a circle with four cubic arcs.
local function addCircle(path: Path, centre: Vector, r: number)
    local k = 0.5522847 * r
    local x, y = centre.x, centre.y
    path:moveTo(Vector.xy(x + r, y))
    path:cubicTo(Vector.xy(x + r, y + k), Vector.xy(x + k, y + r), Vector.xy(x, y + r))
    path:cubicTo(Vector.xy(x - k, y + r), Vector.xy(x - r, y + k), Vector.xy(x - r, y))
    path:cubicTo(Vector.xy(x - r, y - k), Vector.xy(x - k, y - r), Vector.xy(x, y - r))
    path:cubicTo(Vector.xy(x + k, y - r), Vector.xy(x + r, y - k), Vector.xy(x + r, y))
    path:close()
end

-- An ellipse rotated by `angle`, for note heads.
local function addEllipse(path: Path, centre: Vector, rx: number, ry: number, angle: number)
    local c, s = math.cos(angle), math.sin(angle)
    local function at(px: number, py: number): Vector
        return Vector.xy(centre.x + px * c - py * s, centre.y + px * s + py * c)
    end
    local kx, ky = 0.5522847 * rx, 0.5522847 * ry
    path:moveTo(at(rx, 0))
    path:cubicTo(at(rx, ky), at(kx, ry), at(0, ry))
    path:cubicTo(at(-kx, ry), at(-rx, ky), at(-rx, 0))
    path:cubicTo(at(-rx, -ky), at(-kx, -ry), at(0, -ry))
    path:cubicTo(at(kx, -ry), at(rx, -ky), at(rx, 0))
    path:close()
end

local function addPolygon(path: Path, points: { Vector })
    path:moveTo(points[1])
    for i = 2, #points do
        path:lineTo(points[i])
    end
    path:close()
end

-- The glyphs from the original notes artwork, around the note's origin.
local function singleNotePath(): Path
    local path = Path.new()
    addEllipse(path, Vector.xy(0, 0), 2.3, 1.7, -0.4)
    addPolygon(path, { Vector.xy(1.4, -8.8), Vector.xy(2.3, -8.8), Vector.xy(2.3, 0.2), Vector.xy(1.4, 0.2) })
    addPolygon(path, { Vector.xy(2.3, -8.8), Vector.xy(4.8, -5.8), Vector.xy(4.3, -5), Vector.xy(2.3, -6.8) })
    return path
end

local function doubleNotePath(): Path
    local path = Path.new()
    addEllipse(path, Vector.xy(0, 0), 2.3, 1.7, -0.4)
    addEllipse(path, Vector.xy(6.2, -1), 2.3, 1.7, -0.4)
    addPolygon(path, { Vector.xy(1.4, -8.9), Vector.xy(2.3, -8.9), Vector.xy(2.3, 0.1), Vector.xy(1.4, 0.1) })
    addPolygon(path, { Vector.xy(7.6, -9.9), Vector.xy(8.5, -9.9), Vector.xy(8.5, -0.9), Vector.xy(7.6, -0.9) })
    addPolygon(path, { Vector.xy(1.4, -8.9), Vector.xy(8.5, -10.3), Vector.xy(8.5, -8.4), Vector.xy(1.4, -7) })
    return path
end

-- Three notes per speaker, each rising, drifting outward and fading.
local function makeNotes(): { Note }
    local notes: { Note } = {}
    local sides = {
        { centre = LEFT_SPEAKER, dir = -1, offsets = { -4, 3, -1 }, shift = 0 },
        { centre = RIGHT_SPEAKER, dir = 1, offsets = { 3, -4, 1 }, shift = 1 / 6 },
    }
    for _, side in sides do
        for i = 1, 3 do
            local index = #notes + 1
            table.insert(notes, {
                x0 = side.centre.x + side.offsets[i],
                y0 = side.centre.y - 7,
                dir = side.dir,
                phase = (i - 1) / 3 + side.shift,
                seed = 0.17 * index,
                -- Alternate single (grey) and double (cover-coloured) notes.
                double = index % 2 == 0,
            })
        end
    end
    return notes
end

local NOTES = makeNotes()

local function smoothstep(a: number, b: number, x: number): number
    local t = math.clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
end

local function drawNotes(self: Waves, renderer: Renderer)
    local accent = NOTE_DEFAULT_ACCENT
    local accentProp = self.accent
    if accentProp ~= nil then
        accent = accentProp.value
    end
    for _, n in NOTES do
        -- The first pass is the intro: each note waits its turn before rising.
        if self.cycles >= (1 - n.phase) % 1 then
            local u = (self.cycles + n.phase) % 1
            local opacity = smoothstep(0, 0.12, u) * (1 - smoothstep(0.6, 1, u)) * self.amp
            if opacity > 0.003 then
                local x = n.x0 + n.dir * 6 * u + 3.2 * math.sin(2 * math.pi * (u * 1.25 + n.seed))
                local y = n.y0 - 42 * u
                local rotation = 0.32 * math.sin(2 * math.pi * (u * 1.5 + n.seed))
                local scale = 0.5 + 0.5 * smoothstep(0, 0.3, u)
                -- Every note takes the cover's colour; single notes a lighter
                -- shade of it, so the two kinds still read apart.
                local color = if n.double then accent else Color.lerp(accent, NOTE_LIGHT, 0.35)
                self.notePaint.color = Color.opacity(color, opacity) :: Color
                renderer:save()
                renderer:transform(Mat2D.withTranslation(x, y) * Mat2D.withRotation(rotation) * Mat2D.withScale(scale, scale))
                renderer:drawPath(if n.double then self.doubleNote else self.singleNote, self.notePaint)
                renderer:restore()
            end
        end
    end
end

-- The device body as a rounded rectangle, so rings never spill past its edge.
local function bodyPath(): Path
    local path = Path.new()
    local l, t = BODY_CENTRE.x - BODY_HALF.x, BODY_CENTRE.y - BODY_HALF.y
    local r, b = BODY_CENTRE.x + BODY_HALF.x, BODY_CENTRE.y + BODY_HALF.y
    local c = BODY_RADIUS
    local k = c * (1 - 0.5522847)
    path:moveTo(Vector.xy(l + c, t))
    path:lineTo(Vector.xy(r - c, t))
    path:cubicTo(Vector.xy(r - k, t), Vector.xy(r, t + k), Vector.xy(r, t + c))
    path:lineTo(Vector.xy(r, b - c))
    path:cubicTo(Vector.xy(r, b - k), Vector.xy(r - k, b), Vector.xy(r - c, b))
    path:lineTo(Vector.xy(l + c, b))
    path:cubicTo(Vector.xy(l + k, b), Vector.xy(l, b - k), Vector.xy(l, b - c))
    path:lineTo(Vector.xy(l, t + c))
    path:cubicTo(Vector.xy(l, t + k), Vector.xy(l + k, t), Vector.xy(l + c, t))
    path:close()
    return path
end

local function drawFallback(self: Waves, renderer: Renderer)
    renderer:save()
    renderer:clipPath(self.bodyClip)
    for _, centre in { LEFT_SPEAKER, RIGHT_SPEAKER } do
        for ring = 0, 2 do
            local t = (self.time * 0.6 + ring / 3) % 1
            local path = Path.new()
            addCircle(path, centre, SPEAKER_RADIUS + 2 + t * 26)
            renderer:save()
            renderer:modulateOpacity((1 - t) * self.amp * 0.5)
            renderer:drawPath(path, self.ringPaint)
            renderer:restore()
        end
    end
    renderer:restore()
end

local function drawWaves(self: Waves, renderer: Renderer)
    local canvas = self.canvas
    local pipeline = self.pipeline
    local uniforms = self.uniforms
    local bindGroup = self.bindGroup
    if canvas == nil or pipeline == nil or uniforms == nil or bindGroup == nil then
        drawFallback(self, renderer)
        return
    end

    writeUniforms(self)
    uniforms:write(self.data)
    local pass = canvas:beginRenderPass({
        color = { { loadOp = 'clear', storeOp = 'store', clearColor = { 0, 0, 0, 0 } } },
        label = 'speaker waves',
    })
    pass:setPipeline(pipeline)
    pass:setBindGroup(0, bindGroup)
    pass:draw(3)
    pass:finish()

    renderer:save()
    renderer:transform(Mat2D.withScale(1 / RESOLUTION, 1 / RESOLUTION))
    renderer:drawImage(canvas.image, self.sampler, 'srcOver', 1)
    renderer:restore()
end

local function draw(self: Waves, renderer: Renderer)
    if self.amp <= 0 then
        return
    end
    drawWaves(self, renderer)
    drawNotes(self, renderer)
end

return function(): Node<Waves>
    return {
        playing = false,
        quiet = 0,
        canvas = nil,
        pipeline = nil,
        uniforms = nil,
        bindGroup = nil,
        data = buffer.create(80),
        sampler = ImageSampler('clamp', 'clamp', 'bilinear'),
        ringPaint = Paint.with({
            style = 'stroke',
            thickness = 1,
            color = Color.rgba(63, 175, 124, 255),
        }),
        notePaint = Paint.with({ style = 'fill', color = NOTE_GREY }),
        singleNote = singleNotePath(),
        doubleNote = doubleNotePath(),
        bodyClip = bodyPath(),
        triedGpu = false,

        context = nil,
        vm = nil,
        spotifyOpen = nil,
        showingB = nil,
        progress = nil,
        accent = nil,
        rotationA = nil,
        rotationB = nil,
        awaiting = nil,
        coverAOpacity = nil,
        coverBOpacity = nil,

        time = 0,
        amp = 0,
        cycles = 0,
        changing = false,

        clock = 0,
        spin = 0,
        angleA = 0,
        angleB = 0,
        smoothProgress = 0,
        settleUntil = 0,
        lastShowingB = false,

        wasAwaiting = false,
        awaitingSince = 0,
        gaveUp = false,
        shownA = 1,
        shownB = 1,

        init = init,
        advance = advance,
        draw = draw,
    }
end
