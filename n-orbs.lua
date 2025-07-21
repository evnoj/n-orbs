-- nbody: nbody sim
-- by Evan Johnson
-- implementation follows https://github.com/DeadlockCode/n-body
local Simulation = include("nbody-lua-lib/init")

local show_tps = true
local tps = 0
local sim = Simulation:new()
local ready_draw = true
local ready_sim = true
local auto_damp = false
local fade_rate = 1
auto_adjust_funcs = {}
local lit_pixels = {}
local lit_pixel_count = 0

function init()
    -- available traits to map outputs to
    -- key is dest name
    -- value is either an array-style table of "outputs", or boolean true if it stands alone
    mod_dests = {
        crow = {1, 2, 3, 4},
        txo = {1, 2, 3, 4}
    }
    traits = {"x", "y", "r", "vel", "acc"}
    mod_scale_traits = {"xy", "r", "speed"}
    -- mod_scale_types = {"v_5pp_uni", "v_10pp_uni", "v_10pp_bi"}
    -- mod_scale_matrix = {}

    -- for _,trait in ipairs(mod_scale_traits) do
    --     mod_scale_matrix[trait] = {}
    --     for _,type in ipairs(mod_scale_types) do
    --         mod_scale_matrix[trait][type] = params:get(trait.."_mod_scale") *
    --     end
    -- end

    -- given a body, take some action based on one of its traits
    trait_handlers = {
        crow = {
            x = function(body, out)
                crow.output[out].volts = body.pos[1] * params:get("xy_mod_scale") * 5
            end,
            y = function(body, out)
                crow.output[out].volts = body.pos[2] * params:get("xy_mod_scale") * 5
            end,
            r = function(body, out)
                crow.output[out].volts = body.pos:length() * params:get("r_mod_scale") * 5
            end,
            vel = function(body, out)
                crow.output[out].volts = body.vel:length() * params:get("speed_mod_scale")
            end,
            acc = function(body, out)
                -- print(body.acc:length())
                crow.output[out].volts = body.acc:length() * params:get("speed_mod_scale")
            end
        },
        txo = {
            x = function(body, out)
                crow.ii.txo.cv(out, body.pos[1] * params:get("xy_mod_scale") * 5)
            end,
            y = function(body, out)
                crow.ii.txo.cv(out, body.pos[2] * params:get("xy_mod_scale") * 5)
            end,
            r = function(body, out)
                crow.ii.txo.cv(out, body.pos:length() * params:get("r_mod_scale"), 5)
            end,
            vel = function(body, out)
                crow.ii.txo.cv(out, body.vel:length() * params:get("speed_mod_scale"))
            end,
            acc = function(body, out)
                crow.ii.txo.cv(out, body.acc:length() * params:get("speed_mod_scale"))
            end
        }
    }
    -- key is body number, value is another table
    -- subtable has destination ids as keys (ex. dest_crow_1), and function that takes the body table as the first arg and an optional "output" (like a sub-dest) as a 2nd arg, ex. crow functions treat the output arg as which crow output to send to
    -- callback on every tick
    body_callbacks = {}

    local enc_params = {}

    -- allows keys and encoders to be mapped to nothing
    local empty_param = {
        id="empty_param",
        name="none",
        type="number",
        min=0,
        max=0
    }
    params:add(empty_param)
    table.insert(enc_params, empty_param)
    params:hide(empty_param.id)
    _menu.rebuild_params()

    params:add{
        id="init_sim",
        name="init sim",
        type="binary",
        behavior="trigger",
        action=function()
            initSim()
        end
    }

    local viewport_zoom = {
        id="viewport_zoom",
        name="zoom",
        type="control",
        controlspec=controlspec.def{
            min = 0.01,
            max = 10,
            warp = 'exp',
            step = 0.01,
            default = 1,
            quantum = 0.01/(10-0.01),
            wrap = false
        },
        action=function(v)
            zoom = v * 26
        end
    }
    table.insert(enc_params, viewport_zoom)
    params:add(viewport_zoom)

    local auto_fade_param = {
        id = "auto_fade",
        name = "auto adjust fade",
        type = "binary",
        behavior = "toggle",
        default = 1,
        action = function(z)
            if z == 1 then
                auto_adjust_funcs["auto_fade"] = autoFadeUpdate
                params:hide("fade_rate")
                _menu.rebuild_params()
            else
                auto_adjust_funcs["auto_fade"] = nil
                params:show("fade_rate")
                _menu.rebuild_params()
            end
        end
    }
    params:add(auto_fade_param)

    local fade_rate_param = {
        id = "fade_rate",
        name = "fade rate",
        type = "number",
        min = 1,
        max = 3,
        default = 1,
        action = function(v)
            fade_rate = v
        end
    }
    table.insert(enc_params, fade_rate_param)
    params:add(fade_rate_param)
    if params:get("auto_fade") == 1 then
        params:hide("fade_rate")
        _menu.rebuild_params()
    end

    params:add{
        id="sim_tps",
        name="ticks per second",
        type="number",
        min=1,
        max=600,
        default=120,
        action=function(tps)
            if sim_metro_id then
                metro.free(sim_metro_id)
                sim_metro_id = nil
                sim_metro = metro.init(updateSim,1/tps)
                sim_metro_id = sim_metro.id
                sim_metro:start()
            end
        end
    }

    local sim_dt = {
        id="sim_dt",
        name="time step",
        type="control",
        controlspec=controlspec.def{
            min = 0.001,
            max = 0.5,
            warp = 'exp',
            step = 0.001,
            default = 0.01,
            -- quantum = 0.005,
            wrap = false
        },
        formatter=function(param) return string.format("%.3f", param:get()) end,
        action=function(dt)
            sim.dt = dt
        end
    }
    table.insert(enc_params, sim_dt)
    params:add(sim_dt)


    local sim_grav_exponent = {
        id="sim_grav_exponent",
        name="gravity exponent",
        type="control",
        controlspec=controlspec.def{
            min = 0.1,
            max = 5,
            warp = 'lin',
            step = 0.1,
            default = 1.5,
            quantum = 0.1/(5-0.1),
            wrap = false
        },
        -- formatter=function(param) return string.format("%.3f", param:get()) end,
        action=function(v)
            sim.gravExponent = v
        end
    }
    table.insert(enc_params, sim_grav_exponent)
    params:add(sim_grav_exponent)

    integrator_choices = tab.sort(sim.integrators)
    params:add{
        id="sim_integrator",
        name="integrator",
        type="option",
        options=integrator_choices,
        default=3, -- leapfrog
        action=function(integrator)
            sim.integrator = integrator_choices[integrator]
        end
    }

    local sim_softening = {
        id="sim_softening",
        name="softening",
        type="control",
        controlspec=controlspec.def{
            min = 0.001,
            max = 1,
            warp = 'exp',
            step = 0.001,
            default = 0.01,
            -- quantum = 0.005,
            wrap = false
        },
        formatter=function(param) return string.format("%.3f", param:get()) end,
        action=function(v)
            sim.softening = v
        end
    }
    table.insert(enc_params, sim_softening)
    params:add(sim_softening)

    local sim_dampening = {
        id="sim_dampening",
        name="dampening",
        type="control",
        controlspec=controlspec.def{
            min = -0.1,
            max = 0.1,
            warp = 'lin',
            step = 0.0001,
            default = 0,
            quantum = 0.0001 / (0.2),
            wrap = false
        },
        formatter=function(param) return string.format("%.4f", param:get()) end,
        action=function(v)
            sim.dampening = v
        end
    }
    table.insert(enc_params, sim_dampening)
    params:add(sim_dampening)

    params:add{
        id="auto_damp",
        name="auto damp",
        type="binary",
        behavior="toggle",
        default=0,
        action=function(z)
            if z == 1 then
                auto_damp = true
            else
                auto_damp = false
            end
        end
    }

    local enc_options = {}
    enc_option_to_id = {}
    for i,p in ipairs(enc_params) do
        table.insert(enc_options, p.name)
        enc_option_to_id[i] = p.id
    end

    local e1_action = {
        id="e1_action",
        name="e1",
        type="option",
        options=enc_options,
        default = 1, -- none
    }
    params:add(e1_action)
    local e2_action = {
        id="e2_action",
        name="e2",
        type="option",
        options=enc_options,
        default = 1, -- none
    }
    params:add(e2_action)
    local e3_action = {
        id="e3_action",
        name="e3",
        type="option",
        options=enc_options,
        default = 1, -- none
    }
    params:add(e3_action)

    params:add_separator("mod_dests", "modulation destinations")

    for _,trait in ipairs(mod_scale_traits) do
        params:add{
            id=trait.."_mod_scale",
            name=trait.." scale",
            type="control",
            controlspec=controlspec.def{
                min = 0.1,
                max = 5,
                warp = 'lin',
                step = 0.1,
                default = 1,
                quantum = 0.1/(5-0.1),
                wrap = false
            }
        }
    end

    for dest,outs in pairs(mod_dests) do
        if type(outs) == 'table' then
            for _,out in ipairs(outs) do
                addDestParam(dest, out)
            end
        else
           addDestParam(dest)
        end
    end

    params:bang()

    screen.aa(1)
    screen.line_width(.1)
    screen.clear()
    screen.update()
    draw_ready_metro = metro.init(readyDraw,1/60)
    draw_ready_metro:start()
    screen_ping_metro = metro.init(function()
        if redraw == my_redraw then
            screen.ping()
        end
    end, 899)
    screen_ping_metro:start()

    -- for automatically adjusting parameters like energy damping and fade rate
    auto_adjust_metro = metro.init(function()
       for _,func in pairs(auto_adjust_funcs) do
           func()
       end
    end, 1/2)
    auto_adjust_metro:start()

    initSim()
    start_time = os.time()
end

function auto_adjust()
    for i,v in pairs(auto_adjust_funcs) do
        v()
    end
end

function newTraitHandler(trait, target, out)
    return function(body)
        trait_handlers[target][trait](body, out)
    end
end

-- returns 1 for true, 0 for false
function isDestActive(dest)
    local outs = mod_dests[dest]

    if type(outs) == "table" then
        for _,out in ipairs(outs) do
           if params:get("dest_"..dest.."_"..out) == 1 then
               return 1
           end
        end
    else
        if params:get("dest_"..dest) == 1 then
            return 1
        end
    end

    return 0
end

function addDestHeader(dest)
    local base_id = "dest_"..dest
    local header_id = base_id.."_header"
    local base_name = dest

    params:add{
        id=header_id,
        name="▶ "..base_name,
        type="binary",
        behavior="toggle",
        default=isDestActive(dest),
        action=function(z)
            local outs = mod_dests[dest]

            if z == 1 then
                params:lookup_param(header_id).name = "▼ "..base_name

                if type(outs) == "table" then
                    for _,out in ipairs(outs) do
                       if params:get("dest_"..dest.."_"..out) == 1 then
                           return 1
                       end
                    end
                else
                    if params:get("dest_"..dest) == 1 then
                        return 1
                    end
                end

            end
        end
    }
end

function addDestParam(dest, out)
    local base_id = "dest_"..dest
    local base_name = dest
    if out then
        base_id = base_id.."_"..out
        base_name = base_name.." "..out
    end

    params:add{
        id=base_id,
        name="○ "..base_name,
        type="binary",
        behavior="toggle",
        default=0,
        action=function(z)
            local n = params:get(base_id.."_body")

            if (z == 1) then
                local trait = traits[params:get(base_id.."_trait")]
                body_callbacks[n] = body_callbacks[n] or {}
                body_callbacks[n][base_id] = newTraitHandler(trait, dest, out)

                params:lookup_param(base_id).name = "● "..base_name
                params:show(base_id.."_body")
                params:show(base_id.."_trait")
                _menu.rebuild_params()
            else
                if (body_callbacks[n]) then
                    body_callbacks[n][base_id] = nil
                    if (tableSize(body_callbacks[n]) == 0) then
                        body_callbacks[n] = nil
                    end
                end

                params:lookup_param(base_id).name = "○ "..base_name
                params:hide(base_id.."_body")
                params:hide(base_id.."_trait")
                _menu.rebuild_params()
            end
        end
    }

    params:add{
        id=base_id.."_body",
        name="   body",
        type="number",
        default=1,
        min=1,
        action=function(n)
            -- remove previous callbacks
            local prev_n = params:get(base_id.."_body_save")
            if (body_callbacks[prev_n]) then
                body_callbacks[prev_n][base_id] = nil
                if (tableSize(body_callbacks[prev_n]) == 0) then
                    body_callbacks[prev_n] = nil
                end
            end
            params:set(base_id.."_body_save", n)

            if (params:get(base_id) == 1) then
                local trait = traits[params:get(base_id.."_trait")]
                -- shouldn't need to check this
                body_callbacks[n] = body_callbacks[n] or {}
                body_callbacks[n][base_id] = newTraitHandler(trait, dest, out)
            end
        end
    }
    if params:get(base_id) == 0 then
        params:hide(base_id.."_body")
        _menu.rebuild_params()
    end

    -- utility parameter to be able to remove previous callback when changing body
    params:add{
        id=base_id.."_body_save",
        type="number",
        default=params:get(base_id.."_body"),
        min=1,
    }
    params:hide(base_id.."_body_save")
    _menu.rebuild_params()

    params:add{
        id=base_id.."_trait",
        name="   trait",
        type="option",
        options=traits,
        default = 1,
        action=function(x)
            if (params:get(base_id) == 1) then
                local n = params:get(base_id.."_body")
                -- shouldn't need to check this
                body_callbacks[n] = body_callbacks[n] or {}
                body_callbacks[n][base_id] = newTraitHandler(traits[x], dest, out)
            end
        end
    }
    if params:get(base_id) == 0 then
        params:hide(base_id.."_trait")
        _menu.rebuild_params()
    end
end

function redraw()
    screen.stroke()
    fadeEffect.darkenPixels()
    -- screen.clear()

    -- drawBodies.eachBody(drawBody.ring)
    -- drawBodies.connectedPoints()
    drawBodies.eachBodyLitPixels(drawBody.ring)

    -- if show_tps then
    --     if sim.ticks % 100 == 0 then
    --         tps = sim.ticks/(os.time() - start_time)
    --     end
    --     -- screen.move(10,10)
    --     -- screen.text("tps:"..tps)
    -- end

    screen.stroke()
    screen.update()
end
my_redraw = redraw -- provides a way to check if in system menu

-- for all pixels in defined area, add them to lit_pixels with their current level
function addToLitPixels(x,y,l,w)
    local buf = screen.peek(x, y, l, w)

    for i = 1, #buf do
        local rel_x = (i - 1) % (l)
        local rel_y = math.floor((i - 1) / l)
        local c = 128 * (y + rel_y) + rel_x + x
        local level = buf:byte(i)
        lit_pixels[c] = level
    end
end

fadeEffect = {
    alphaRectangle = function()
        screen.blend_mode('dest_out')
        screen.level_a(0, .91)
        screen.rect (0, 0, 128, 64)
        screen.close()
        screen.fill()
        screen.blend_mode(0)
    end,
    darkenBuffer = function()
        -- if sim.ticks % 4 == 0 then
        -- if fade_counter == 0 then
            local buf = screen.peek(0,0,128,64)
            -- local debuf = buf:gsub(".", function(c)
            --     local byte = c:byte() - 1
            --     return string.char(byte < 0 and 0 or byte)
            -- end)
            local t = {}
            for i = 1, #buf do
                local byte = buf:byte(i) - 1
                -- local byte = 1
                t[i] = string.char(byte < 0 and 0 or byte)  -- Clamp at 0
            end
            local debuf = table.concat(t)
            screen.poke(0,0,128,64,debuf)
        -- end
        fade_counter = (fade_counter + 1) % 2
    end,
    darkenPixels = function()
        local remove_pixels = {}
        lit_pixel_count = 0

        for c,level in pairs(lit_pixels) do
            local level_d = level - fade_rate
            local x = c % 128
            local y = math.floor(c / 128)
            screen.level(level_d)
            screen.pixel(x, y)
            screen.fill()
            if level_d > 0 then
                lit_pixel_count = lit_pixel_count + 1
                lit_pixels[c] = level_d
            else
                table.insert(remove_pixels, c)
            end
        end

        for _,c in ipairs(remove_pixels) do
            lit_pixels[c] = nil
        end
    end
}

function autoFadeUpdate()
    if lit_pixel_count > 250 and fade_rate < 3 then
        params:delta("fade_rate", 1)
    elseif lit_pixel_count < 75 and fade_rate > 1 then
        params:delta("fade_rate", -1)
    end
end

local function getDisplayCoords(body)
    local x = body.pos[1] * zoom + 63
    local y = body.pos[2] * zoom + 31
    return x,y
end

drawBodies = {
    eachBody = function(draw)
        for i, body in ipairs(sim.bodies) do
            local x,y = getDisplayCoords(body)
            draw(body, x, y)
        end
    end,
    eachBodyLitPixels = function(draw)
        for i, body in ipairs(sim.bodies) do
            local x,y = getDisplayCoords(body)
            local r = 2
            draw(body, x, y)
            -- screen.circle(x, y, r)
            screen.close()
            screen.stroke()

            local width = r*4
            local ix = math.floor(x+0.5)
            local iy = math.floor(y+0.5)
            local wx = math.max(0, math.min(127, ix-(r*2)))
            local wy = math.max(0, math.min(63, iy-(r*2)))
            -- print("wx:"..wx..", wy:"..wy..", w:"..width)
            addToLitPixels(wx, wy, width, width)
        end
    end,
    connectedPoints = function()
        for i=1, #sim.bodies - 1 do
            local bi = sim.bodies[i]
            local xi,yi = getDisplayCoords(bi)
            screen.move(xi, yi)
            screen.line(63,31)
            screen.close()
            screen.stroke()
            for j=i+1, #sim.bodies do
                local bj = sim.bodies[j]
                local xj,yj = getDisplayCoords(bj)
                screen.move(xi, yi)
                screen.line(xj, yj)
                screen.close()
                screen.stroke()
            end
        end
        local x,y = getDisplayCoords(sim.bodies[#sim.bodies])
        screen.move(x, y)
        screen.line(63,31)
        screen.close()
        screen.stroke()
    end,
}

drawBody = {
    circle = function(body, x, y)
        screen.level(15)
        screen.circle(x, y, 2)
        screen.close()
        screen.fill()
        screen.stroke()
    end,
    ring = function(body, x, y)
        screen.level(15)
        screen.circle(x, y, 2.7)
        screen.close()
        screen.stroke()
    end
}

function initSim()
    if sim_metro_id then
        metro.free(sim_metro_id)
        sim_metro_id = nil
    end

    sim = Simulation:new_rand(3)
    sim.dt = params:get("sim_dt")
    sim.gravExponent = params:get("sim_grav_exponent")
    sim.integrator = integrator_choices[params:get("sim_integrator")]
    sim.softening = params:get("sim_softening")
    sim.dampening = params:get("sim_dampening")
    sim_metro = metro.init(updateSim,1/params:get("sim_tps"))
    sim_metro_id = sim_metro.id
    sim_metro:start()
end

function updateSim()
    sim:update()

    for n,callbacks in pairs(body_callbacks) do
        for _,callback in pairs(callbacks) do
            callback(sim.bodies[n])
        end
    end
end

function startMeasuringEnergy()
    if sim_energy_metro == nil then
        energy_readings = {}
        energy_sum = 0
        energy_avg = 0

        sim_energy_metro = metro.init(calculateSimEnergy, 1)
        sim_energy_metro:start()
    else
        print("sim energy metro already exists")
    end
end

function stopMeasuringEnergy()
    if sim_energy_metro ~= nil then
        metro.free(sim_energy_metro.id)
        energy_readings = nil
        energy_sum = nil
        energy_avg = nil
    else
        print("sim energy metro does not exist")
    end
end

function calculateSimEnergy()
    local energy = sim:getTotalEnergy()
    energy_sum = energy_sum + energy
    table.insert(energy_readings, energy)

    if #energy_readings > 10 then
        energy_sum = energy_sum - table.remove(energy_readings,1)
        energy_avg = energy_sum / 10
    end
end

function adjustEnergyDamping(energy_avg, energy_baseline)
    if energy_avg < energy_baseline * 1.75 and sim.dampening > -0.0010 then
        sim.dampening = sim.dampening - 0.0001
    elseif energy_avg > energy_baseline * 0.75 and sim.dampening < 0.0010 then
        sim.dampening = sim.dampening + 0.0001
    elseif sim.dampening > 0 then
        sim.dampening = sim.dampening - 0.0001
    elseif sim.dampening < 0 then
        sim.dampening = sim.dampening + 0.0001
    end
end

function getEnergyBaseline()
    if sim_energy_baseline_metro == nil then
        energy_baseline_readings = {}
        energy_baseline = 0
        energy_baseline_sum = 0
        sim_energy_baseline_metro = metro.init(calculateSimEnergyBaseline, 1/20)
        sim_energy_baseline_metro:start()
    else
        print("sim baseline energy metro already exists")
    end
end

function calculateSimEnergyBaseline()
    local energy = sim:getTotalEnergy()
    energy_baseline_sum = energy_baseline_sum + energy
    table.insert(energy_baseline_readings, energy)

    if #energy_baseline_readings == 20 then
        energy_baseline = energy_baseline_sum / 20
        metro.free(sim_energy_baseline_metro.id)
        sim_energy_baseline_metro = nil
    end
end

function refresh()
    if ready_draw then
        redraw()
        ready_draw = false
    end
end

function readyDraw()
    ready_draw = true
end

function readySim()
    ready_sim = true
end

function tableSize(t)
    local n = 0
    for _,_ in pairs(t) do
        n = n + 1
    end
    return n
end

function enc(n, delta)
    local id = enc_option_to_id[params:get("e"..n.."_action")]
    params:delta(id, delta)
end
