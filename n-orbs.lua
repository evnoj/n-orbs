-- nbody: nbody sim
-- by Evan Johnson
-- implementation follows https://github.com/DeadlockCode/n-body
Simulation = include("nbody-lua-lib/init")

show_tps = true
tps = 0
-- max_tps = 5000
sim = Simulation:new()
max_tps = 200
fade_counter = 0
ready_draw = true
ready_sim = true
prev_time = os.time()
auto_damp = false
ticks = 0
frames = 0

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

    lit_pixels = {}
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

    params:add{
        id="init_sim",
        name="init sim",
        type="binary",
        behavior="trigger",
        action=function()
            initSim()
        end
    }

    params:add{
        id="viewport_zoom",
        name="zoom",
        type="control",
        controlspec=controlspec.def{
            min = 0.1,
            max = 5,
            warp = 'lin',
            step = 0.1,
            default = 1,
            quantum = 0.1/(5-0.1),
            wrap = false
        },
        action=function(v)
            zoom = v * 26
        end
    }

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

    params:add{
        id="sim_dt",
        name="time step",
        type="control",
        controlspec=controlspec.def{
            min = 0.001,
            max = 0.1,
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

    params:add{
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

    params:add{
        id="sim_softening",
        name="softening",
        type="control",
        controlspec=controlspec.def{
            min = 0.001,
            max = 0.1,
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

    params:add{
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
    draw_ready_metro = metro.init(readyDraw,1/60)
    draw_ready_metro:start()
    screen_ping_metro = metro.init(function()
        if redraw == my_redraw then
            screen.ping()
        end
    end, 899)
    screen_ping_metro:start()

    initSim()
    start_time = os.time()
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

    for i, body in ipairs(sim.bodies) do
        drawBody.ring(body)
        local x = body.pos[1] * zoom + 63
        local y = body.pos[2] * zoom + 31
        local r = 2
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

-- for all pixels in defined area, add them to lit_pixels
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
        -- if fade_counter == 0 then
        local remove_pixels = {}
            for c,level in pairs(lit_pixels) do
                local level_d = level - 1
                local x = c % 128
                local y = math.floor(c / 128)
                screen.level(level_d)
                screen.pixel(x, y)
                screen.fill()
                if level_d > 0 then
                    lit_pixels[c] = level_d
                else
                    -- lit_pixels[c] = nil
                    table.insert(remove_pixels, c)
                end
            end

            for _,c in ipairs(remove_pixels) do
                lit_pixels[c] = nil
            end
        -- end
        -- fade_counter = (fade_counter + 1) % 2
    end
}

drawBodies = {
    eachBody = function(draw)
        for i, body in ipairs(sim.bodies) do
            draw(body)
        end
    end,
    connectedPoints = function()
        for i=1, #sim.bodies - 1 do
            local bi = sim.bodies[i]
            screen.move(bi.pos[1] * zoom + 63, bi.pos[2] * zoom + 31)
            screen.line(63,31)
            screen.close()
            screen.stroke()
            for j=i+1, #sim.bodies do
                local bj = sim.bodies[j]
                screen.move(bi.pos[1] * zoom + 63, bi.pos[2] * zoom + 31)
                screen.line(bj.pos[1] * zoom + 63, bj.pos[2] * zoom + 31)
                screen.close()
                screen.stroke()
            end
        end
        screen.move(sim.bodies[#sim.bodies].pos[1] * zoom + 63, sim.bodies[#sim.bodies].pos[2] * zoom + 31)
        screen.line(63,31)
        screen.close()
        screen.stroke()
    end
}

drawBody = {
    circle = function(body)
        screen.level(15)
        screen.circle(body.pos[1] * zoom + 63, body.pos[2] * zoom + 31, 2)
        screen.close()
        screen.fill()
        screen.stroke()
    end,
    ring = function(body)
        screen.level(15)
        screen.circle(body.pos[1] * zoom + 63, body.pos[2] * zoom + 31, 2.7)
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

    if sim_energy_metro then
        metro.free(sim_energy_metro.id)
    end

    energy_readings = {}
    energy_baseline_readings = {}
    energy_sum = 0
    energy_avg = 0
    energy_baseline = 0
    energy_baseline_sum = 0
    sim_energy_metro = metro.init(calculateSimEnergy, 1)
    sim_energy_baseline_metro = metro.init(calculateSimEnergyBaseline, 1/20)
    sim_energy_metro:start()
    sim_energy_baseline_metro:start()
end

function updateSim()
    sim:update()
    ticks = ticks + 1

    for n,callbacks in pairs(body_callbacks) do
        for _,callback in pairs(callbacks) do
            callback(sim.bodies[n])
        end
    end
end

function calculateSimEnergy()
    local energy = sim:getTotalEnergy()
    energy_sum = energy_sum + energy
    table.insert(energy_readings, energy)

    if #energy_readings > 10 then
        energy_sum = energy_sum - table.remove(energy_readings,1)
        energy_avg = energy_sum / 10

        if auto_damp then
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
    end
end

function calculateSimEnergyBaseline()
    local energy = sim:getTotalEnergy()
    energy_baseline_sum = energy_baseline_sum + energy
    table.insert(energy_baseline_readings, energy)

    if #energy_baseline_readings == 20 then
        energy_baseline = energy_baseline_sum / 20
        metro.free(sim_energy_baseline_metro.id)
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

