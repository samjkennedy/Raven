package raven

import "vendor:sdl2"

import "core:fmt"
import "core:os"
import "core:time"
import "core:strings"
import "core:log"

Emulator :: struct {
	window:          ^sdl2.Window,
	renderer:        ^sdl2.Renderer,
	pause_execution: bool,
	cpu:             CPU,
}

//======PPU/Screen======//

WIDTH :: i32(160)
HEIGHT :: i32(144)
SCALE :: i32(5)

init_window :: proc(emulator: ^Emulator) -> bool { 	//TODO: Return window handle
	WINDOW_WIDTH :: WIDTH * SCALE
	WINDOW_HEIGHT :: HEIGHT * SCALE

	//TODO: Don't hardcode the centrepoint
	WINDOW_X :: i32(2560 / 2 - (WINDOW_WIDTH / 2))
	WINDOW_Y :: i32(200)

	emulator.window = sdl2.CreateWindow(
		"Raven",
		WINDOW_X,
		WINDOW_Y,
		WIDTH * SCALE,
		HEIGHT * SCALE,
		sdl2.WindowFlags{.SHOWN},
	)
	if emulator.window == nil {
		fmt.println("sdl2.CreateWindow failed.")
		return false
	}
	emulator.renderer = sdl2.CreateRenderer(emulator.window, -1, {.ACCELERATED, .PRESENTVSYNC})
	if emulator.renderer == nil {
		fmt.println("sdl2.CreateRenderer failed.")
		return false
	}

	return true
}

run :: proc(emulator: ^Emulator, ppu: ^PPU, debugger: ^Debugger) -> bool {

	e: sdl2.Event

	cpu := emulator.cpu

	target_fps :: 59.727500569606 //TODO: use clock cycles over this
	ms_per_frame := 1000.0 / target_fps

	//TODO: Replace with boot program to show the Nintendo logo
	draw_frame(ppu, &cpu)

	previous_clock: u64 = 0

	tick := time.tick_now()
	for {
		//CPU
		before := time.tick_now()

		if (!emulator.pause_execution) {
			debug(debugger, &cpu)
		}

		if !emulator.pause_execution {
			for break_point in debugger.break_points {
				if (cpu.pc == break_point) {
					emulator.pause_execution = true
					debugger.enable_debugging = true
					fmt.printf("Pausing execution at break point %4x\n", break_point)
					debug(debugger, &cpu)
				}
			}
			if !emulator.pause_execution {
				if ok := run_instruction(&cpu); !ok {
					//dump CPU to file?
					fmt.printf("Execution failed just before %4x\n", cpu.pc)
					return false
				}
			}
		}
		clock_time := time.duration_nanoseconds(time.tick_since(before))

		//TODO: move to PPU?
		current_clock := cpu.clock
		if (current_clock - previous_clock >= 70224) {
			//draw_vram(debugger, &cpu)

			LY := read_from_memory(&cpu, 0xFF44)
			if (LY == 144) {
				//VBLANK
				set_interrupt_flag(&cpu, .VBLANK, 1)

				write_to_memory(&cpu, 0xFF41, 0x01)
			}
			if (LY == 153) {
				draw_frame(ppu, &cpu)
				write_to_memory(&cpu, 0xFF44, 0)
			} else {
				write_to_memory(&cpu, 0xFF44, LY + 1)
			}

			//Tetris hack
			write_to_memory(&cpu, 0xFF85, 1)
			previous_clock = current_clock

			delta_time := time.duration_milliseconds(time.tick_since(tick))

			time_to_delay := ms_per_frame - delta_time
			if (time_to_delay > 0) {
				sdl2.Delay(u32(time_to_delay))
			}

			fps := 1000.0 / time.duration_milliseconds(time.tick_since(tick))

			//strings.trim_right_null(emulator.cpu.cart.header.title)
			sdl2.SetWindowTitle(
				ppu.window,
				strings.unsafe_string_to_cstring(fmt.aprintf("Raven: %.0f FPS", fps)),
			)

			tick = time.tick_now()
		}

		for sdl2.PollEvent(&e) {
			#partial switch (e.type) {
			case .QUIT:
				return false
			case .KEYDOWN:
				handle_input(&e, &cpu, false)
				#partial switch (e.key.keysym.sym) {
				case .SPACE:
					emulator.pause_execution = !emulator.pause_execution
					fmt.printf("Emulation %v\n", emulator.pause_execution ? "paused" : "unpaused")
				case .F1:
					debugger.enable_debugging = !debugger.enable_debugging
					fmt.printf(
						"Debugging %v\n",
						debugger.enable_debugging ? "ENABLED" : "DISABLED",
					)
				case .F3:
					if (emulator.pause_execution) {
						//Step
						if ok := run_instruction(&cpu); !ok {
							return false
						}
						debug(debugger, &cpu)
					}
				case .F5:
					fmt.printf("OAM: %v\n", cpu.oam)
				}
			case .KEYUP:
				handle_input(&e, &cpu, true)
			case .WINDOWEVENT:
				#partial switch (e.window.event) {
				case .CLOSE:
					return false
				}
			}
		}
	}
	return true
}

//======Emu======//

main :: proc() {

	args := os.args

	if (len(args) <= 1 || len(args) > 2) {
		fmt.println("Incorrect number of arguments, please provide one ROM file.")
		return
	}
	filepath := args[1]

	cart, ok := load_cart_from_file(filepath)
	if (!ok) {
		return
	}

	emulator := Emulator{}
	if res := init_window(&emulator); !res {
		fmt.println("sdl2 window initialisation failed.")
		return
	}

	cpu := init_cpu(&cart)
	//TODO: Maybe move the sdl2 stuff out of emulator?
	ppu := init_ppu(emulator.window, emulator.renderer)

	emulator.cpu = cpu

	//Debug window
	debugger := Debugger{}
	debugger.emulator = &emulator
	debugger.break_points = make([dynamic]u16, 0, 1024)
	debugger.enable_debugging = false

	//append(&debugger.break_points, 0x03F9) //Begin writing into RAM for the OAM transfer
	// append(&debugger.break_points, 0x017E) //beginning of call block
	// append(&debugger.break_points, 0x0185) //beginning of call block
	// append(&debugger.break_points, 0x0197) //beginning of call block
	// append(&debugger.break_points, 0x01D5) //call to OAM transfer
	// append(&debugger.break_points, 0xFFB8) //OAM transfer

	//init_vram_window(&debugger)

	emulator.pause_execution = false

	run(&emulator, &ppu, &debugger)
}
