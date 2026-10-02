<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

VGA Jump Game is a small endless-runner game for the TinyVGA PMOD (640x480 @ 60 Hz). A pink blob runs across a scrolling landscape and jumps over cacti. The design has no framebuffer: the color of every pixel is computed on the fly from the current beam position (`hpos`, `vpos`) and a handful of game registers.

**Game state.** All game logic runs once per frame, at the start of vertical blanking (line 480):

- **Player physics:** jumping sets the vertical velocity to 14 px/frame, gravity subtracts 1 px/frame every frame, and the player lands when the height reaches 0.
- **Obstacles:** a cactus moves left at 4 px/frame. When it leaves the screen, a 10-bit LFSR picks a new spawn distance and height (40 or 56 px).
- **Collisions:** a bounding-box check between the player and the cactus. A hit resets the score and gives 60 frames of invulnerability, during which the player blinks and turns red.
- **Score:** a 2-digit BCD counter shown as seven-segment digits in the top-left corner. It increases by one for every cactus that passes.
- **Autopilot:** by default the game plays itself, jumping when the cactus enters a fixed window in front of the player.

**Graphics.** Layers are drawn in priority order: score, player, cactus, ground, near hills, far mountains, clouds, sun/moon, stars, sky.

- **Parallax:** every layer uses the same `scroll` counter shifted by a different amount. The scroll position is derived from the frame counter (`scroll = frame * 4`). Mountains use `scroll>>2`, hills `>>1`, the cloud `>>3`, and the ground uses full speed. Mountain and hill profiles are triangle waves made by conditionally inverting the low bits of the x coordinate.
- **Sprite:** the player is a 16x16 sprite with 2 bits per pixel, stored as a ROM and drawn at 2x scale. It has two running frames and one jumping frame, and it blinks every few seconds.
- **Day/night cycle:** bits [11:10] of the frame counter select day, sunset, night or dawn, so each phase lasts about 17 seconds. The sun sets and rises behind the mountains, and at night a full moon and twinkling stars appear.
- **Sky gradient:** a 2x2 Bayer dither blends neighbouring sky bands, which gives a smoother gradient than the 64 colors of the PMOD.

## How to test

1. Connect the TinyVGA PMOD to the dedicated outputs and plug in a VGA monitor.
2. Set the clock to 25.175 MHz (25 MHz also works on most monitors) and release reset.
3. With all inputs low, the game runs in autopilot mode and never crashes.
4. Set `ui[1]` high to switch to manual mode, then press the button on `ui[0]` to jump.

| Input   | Function                              |
|---------|---------------------------------------|
| `ui[0]` | Jump (sampled once per frame)         |
| `ui[1]` | Manual mode: 0 = autopilot, 1 = manual |

## External hardware

- [TinyVGA PMOD](https://github.com/mole99/tiny-vga) on the dedicated outputs
- A VGA monitor
- A push button (or switch) on `ui[0]` and a switch on `ui[1]`
