# stable configurations
- dt 0.01, g exp 1.5, softening 0.01
- dt 0.05, g exp 0.4, softening 0.01

# tasks
## visual effects
- [ ] "offset" where two different sets of circles are drawn at different zoom scales

ex. on `32046cc`, not scaled in `drawBody.ring(body)`
```lua
  for i, body in ipairs(sim.bodies) do
      drawBody.ring(body)
      local x = body.pos[1] * 2 * 26 + 63
      local y = body.pos[2] * 2 * 26 + 31
      local r = 2
      screen.circle(x, y, r)
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
```
