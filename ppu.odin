package raven

import "vendor:sdl2"

import "core:fmt"
import "core:strings"
import "core:time"

SCY :: 0xFF42
SCX :: 0xFF43

PPU :: struct {
	//sdl
	window:   ^sdl2.Window,
	renderer: ^sdl2.Renderer,
	texture:  ^sdl2.Texture,
	//internals
	palette:  Palette,
}

//So as to not be passing this thicc lad around
buffer: [256 * 256]u32

Color :: struct {
	r: u8,
	g: u8,
	b: u8,
	a: u8,
}

Palette :: struct {
	white: Color,
	light: Color,
	dark:  Color,
	black: Color,
}

color_from_hex :: proc(hex: u32) -> Color {
	return Color{u8(hex >> 24), u8(hex >> 16), u8(hex >> 8), u8(hex >> 0)}
}

color_to_hex :: proc(color: Color) -> u32 {
	return u32(color.r) << 24 | u32(color.g) << 16 | u32(color.b) << 8 | u32(color.a) << 0
}

default_palette := Palette{
	color_from_hex(0xE0F8D0FF),
	color_from_hex(0x88C070FF),
	color_from_hex(0x346856FF),
	color_from_hex(0x081820FF),
}

//Pretty
coral_palette := Palette{
	color_from_hex(0xffd0a4ff),
	color_from_hex(0xf4949cff),
	color_from_hex(0x7c9aacff),
	color_from_hex(0x68518aff),
}
//https://lospec.com/palette-list/galactic-pizza
galactic_pizza_palette := Palette{
	color_from_hex(0xffffffff),
	color_from_hex(0xf2f18bff),
	color_from_hex(0xc477a2ff),
	color_from_hex(0x3a0041ff),
}
//https://lospec.com/palette-list/kirokaze-gameboy
kirokaze_gameboy_palette := Palette{
	color_from_hex(0xe2f3e4ff),
	color_from_hex(0x94e344ff),
	color_from_hex(0x46878fff),
	color_from_hex(0x332c50ff),
}
//https://lospec.com/palette-list/lava-gb
lava_gb_palette := Palette{
	color_from_hex(0xff8e80ff),
	color_from_hex(0xc53a9dff),
	color_from_hex(0x4a2480ff),
	color_from_hex(0x051f39ff),
}
//https://lospec.com/palette-list/hollow
hollow_palette := Palette{
	color_from_hex(0xfafbf6ff),
	color_from_hex(0xc6b7beff),
	color_from_hex(0x565a75ff),
	color_from_hex(0x0f0f1bff),
}
//https://lospec.com/palette-list/moonlight-gb
moonlight_gb_palette := Palette{
	color_from_hex(0x5fc75dff),
	color_from_hex(0x36868fff),
	color_from_hex(0x203671ff),
	color_from_hex(0x0f052dff),
}

init_ppu :: proc(window: ^sdl2.Window, renderer: ^sdl2.Renderer) -> PPU {
	//RGBA8888    = 1<<28 | PIXELTYPE_PACKED32<<24 | PACKEDORDER_RGBA<<20 | PACKEDLAYOUT_8888<<16 | 32<<8 | 4<<0,
	format := 1 << 28 | 6 << 24 | 2 << 20 | 6 << 16 | 32 << 8 | 4 << 0

	texture := sdl2.CreateTexture(renderer, u32(format), .STREAMING, WIDTH, HEIGHT)

	ppu := PPU{}
	ppu.window = window
	ppu.renderer = renderer
	ppu.texture = texture
	ppu.palette = default_palette

	buffer = {}
	last_frame_time = time.tick_now()

	return ppu
}

DOTS_PER_SCANLINE :: 456
dots_remaining: i16 = DOTS_PER_SCANLINE
dots_in_current_mode: i16 = 0

last_frame_time: time.Tick

step_ppu_clock :: proc(this: ^PPU, cpu: ^CPU, cycles: u64) {

	dots_remaining -= i16(cycles)
	dots_in_current_mode += i16(cycles)

	current_line := read_from_memory(cpu, 0xFF44)

	if dots_remaining <= 0 {
		write_to_memory(cpu, 0xFF44, current_line + 1)

		dots_remaining = DOTS_PER_SCANLINE //Reset counter

		if (current_line == 144) { 	//are we in VBLANK?

			set_interrupt_flag(cpu, .VBLANK, 1)
			write_to_memory(cpu, 0xFF85, 1) //Tetris hack

		} else if current_line == 153 { 	//Did we just finish a frame?

			write_to_memory(cpu, 0xFF44, 0)
			draw_frame(this, cpu)

			time_since_last_frame_ms := time.duration_milliseconds(
				time.tick_since(last_frame_time),
			)
			fps := MS_PER_S / time_since_last_frame_ms

			last_frame_time = time.tick_now()
		}
	}

	scanline := read_from_memory(cpu, 0xFF44)
	set_lcd_status(cpu, scanline)
}

STAT_REGISTER :: 0xFF41
LYC_REGISTER :: 0xFF45

Stat_Bits :: enum u8 {
	LYC_LY_STAT_Interrupt     = 6,
	Mode_2_OAM_STAT_Interrupt = 5,
	Mode_1_VBlank_Interrupt   = 4,
	Mode_0_HBlank_Interrupt   = 3,
	LYC_LY_Flag               = 2,
}

set_lcd_status :: proc(cpu: ^CPU, scanline: u8) {

	stat := read_from_memory(cpu, STAT_REGISTER)
	lyc := read_from_memory(cpu, LYC_REGISTER)

	//LYC = LY Flag
	if lyc == scanline {
		stat = set_bit(stat, u8(Stat_Bits.LYC_LY_Flag))
		write_to_memory(cpu, STAT_REGISTER, stat)

		if read_bit(stat, u8(Stat_Bits.LYC_LY_STAT_Interrupt)) {
			//LYC = LY interrupt
			set_interrupt_flag(cpu, .LCD_STAT, 1)
		}
	} else {
		stat = set_bit(stat, u8(Stat_Bits.LYC_LY_Flag), false)
		write_to_memory(cpu, STAT_REGISTER, stat)
	}

	//Mode flag
	mode: u8 = read_from_memory(cpu, STAT_REGISTER) & 3 //Select only the mode bits
	if scanline >= 144 && scanline <= 153 { 	//VBLANK

		mode = 0b00000001
		//Set manually by ppu
		cpu.io_ports[41] = cpu.io_ports[41] | mode
	} else {
		switch mode {
		case 0:
		case 1:
		case 2:
		case 3:
		}
	}

	// fmt.printf("LCD STAT Mode: %8b\n", mode)
}

draw_scanline :: proc(this: ^PPU, cpu: ^CPU) {

	//TODO: This is the better way to do sprites but for now write all in one go
}

draw_frame :: proc(this: ^PPU, cpu: ^CPU) {

	buffer = build_frame(this, cpu)
	visible_frame := apply_scroll(this, cpu)

	sdl2.UpdateTexture(this.texture, nil, raw_data(&visible_frame), WIDTH * 4)

	sdl2.RenderCopy(
		this.renderer,
		this.texture,
		&{0, 0, WIDTH, HEIGHT},
		&{0, 0, WIDTH * SCALE, HEIGHT * SCALE},
	)
	sdl2.RenderPresent(this.renderer)
}

LCDC_REGISTER :: 0xFF40

Addressing_Mode :: enum {
	Addressing_8000,
	Addressing_9000,
}

build_frame :: proc(this: ^PPU, cpu: ^CPU) -> (pixels: [256 * 256]u32) {

	//Background

	//Work out addressing method
	lcdc := read_from_memory(cpu, LCDC_REGISTER)
	addressing_mode :=
		read_bit(lcdc, 4) ? Addressing_Mode.Addressing_8000 : Addressing_Mode.Addressing_9000

	tile_id := 0
	for address in 0x9800 ..< 0x9BFF {

		tile_idx := read_from_memory(cpu, u16(address))

		tile := get_tile(this, cpu, tile_idx, tile_id, addressing_mode)

		tile_x := i32(tile_id % 0x20) * 0x08
		tile_y := i32(tile_id / 0x20) * 0x08

		for x: i32 = 0; x < 8; x += 1 {
			for y: i32 = 0; y < 8; y += 1 {

				pixel_x := tile_x + x
				pixel_y := tile_y + y

				pixels[pixel_x + pixel_y * 256] = tile[x][y]
			}
		}

		tile_id = tile_id + 1
	}

	//Sprites
	sprite_id := 0
	for address: u16 = 0xFE00; address < 0xFE9F; address += 4 {

		sprite_y := read_from_memory(cpu, u16(address + 0)) - 16
		sprite_x := read_from_memory(cpu, u16(address + 1)) - 8
		sprite_idx := read_from_memory(cpu, u16(address + 2))
		sprite_attributes := read_from_memory(cpu, u16(address + 3))

		sprite := get_sprite(this, cpu, sprite_idx)

		//TODO: Attributes

		for x: i32 = 0; x < 8; x += 1 {
			for y: i32 = 0; y < 8; y += 1 {

				pixel_x := i32(sprite_x) + x
				pixel_y := i32(sprite_y) + y

				//Bad hack to not overwrite with transparent pixels
				if (sprite[x][y] & 0x000F > 0) {
					pixel_idx := u16(pixel_x + pixel_y * 256)
					pixels[pixel_idx] = sprite[x][y]
				}
			}
		}
		sprite_id = sprite_id + 1
	}
	return
}

apply_scroll :: proc(this: ^PPU, cpu: ^CPU) -> (pixels: [160 * 144]u32) {

	scroll_y := int(read_from_memory(cpu, SCY))
	scroll_x := int(read_from_memory(cpu, SCX))

	for x := 0; x < 160; x += 1 {
		for y := 0; y < 144; y += 1 {
			buffer_idx := u16(x + scroll_x + (y + scroll_y) * 256)
			pixels[x + y * 160] = buffer[buffer_idx]
		}
	}
	return
}

get_tile :: proc(
	this: ^PPU,
	cpu: ^CPU,
	tile_idx: u8,
	tile_id: int,
	addressing_mode: Addressing_Mode,
) -> (
	tile: [8][8]u32,
) {

	root_address: u16
	switch addressing_mode {
	case .Addressing_8000:
		root_address = u16(0x8000) + u16(tile_idx) * 0x10
	case .Addressing_9000:
		root_address = u16(0x9000) + u16(i8(tile_idx)) * 0x10
	}

	pixel_x := 0
	pixel_y := 0
	for byt := 0; byt < 0x10; byt += 2 {

		lo := read_from_memory(cpu, root_address + u16(byt))
		hi := read_from_memory(cpu, root_address + u16(byt) + u16(1))

		for bit := 7; bit >= 0; bit -= 1 {
			pixel := get_bit(hi, u8(bit)) << 1 | get_bit(lo, u8(bit))

			color: Color
			switch pixel {
			case 0b00:
				color = this.palette.white
			case 0b01:
				color = this.palette.light
			case 0b10:
				color = this.palette.dark
			case 0b11:
				color = this.palette.black
			}

			tile[pixel_x][pixel_y] = color_to_hex(color)

			pixel_x += 1
		}
		pixel_x = 0
		pixel_y += 1
	}

	return
}

get_sprite :: proc(this: ^PPU, cpu: ^CPU, sprite_idx: u8) -> (sprite: [8][8]u32) {

	root_address := u16(0x8000) + u16(sprite_idx) * 0x10

	pixel_x := 0
	pixel_y := 0
	for byt := 0; byt < 0x10; byt += 2 {

		lo := read_from_memory(cpu, root_address + u16(byt))
		hi := read_from_memory(cpu, root_address + u16(byt) + u16(1))

		for bit := 7; bit >= 0; bit -= 1 {
			pixel := get_bit(hi, u8(bit)) << 1 | get_bit(lo, u8(bit))

			color: Color
			switch pixel {
			case 0b00:
				color = Color{0, 0, 0, 0} //Transparent
			case 0b01:
				color = this.palette.light
			case 0b10:
				color = this.palette.dark
			case 0b11:
				color = this.palette.black
			}

			sprite[pixel_x][pixel_y] = color_to_hex(color)

			pixel_x += 1
		}
		pixel_x = 0
		pixel_y += 1
	}

	return
}
