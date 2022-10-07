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

DELAY_THRESHOLD_MS :: 16

run :: proc(emulator: ^Emulator, ppu: ^PPU, debugger: ^Debugger) -> bool {

	e: sdl2.Event

	cpu := emulator.cpu

	ns_per_clock: i64 : 239

	previous_clock: u64 = 0
	accumulated_delay_ns: NS = 0

	for {
		time_before := time.tick_now()
		clocks_before := cpu.clock

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
					fmt.printf("Execution failed just before %4x\n", cpu.pc)
					return false
				}
			}
		}

		clock_cycles_elapsed := cpu.clock - clocks_before
		step_ppu_clock(ppu, &cpu, clock_cycles_elapsed)

		actual_clock_time_ns := time.duration_nanoseconds(time.tick_since(time_before))
		expected_clock_time_ns := NS(clock_cycles_elapsed) * ns_per_clock

		if (actual_clock_time_ns < expected_clock_time_ns) {
			accumulated_delay_ns += expected_clock_time_ns - actual_clock_time_ns
		} else {
			accumulated_delay_ns -= actual_clock_time_ns - expected_clock_time_ns
		}

		//We can only delay with ms precision, so accumulate the delay until we hit the threshold
		if accumulated_delay_ns >= NS_PER_MS * DELAY_THRESHOLD_MS {
			delay_ms := accumulated_delay_ns / NS_PER_MS
			if (delay_ms > 0) {
				sdl2.Delay(u32(delay_ms))
				accumulated_delay_ns = 0
			}
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

	run(&emulator, &ppu, &debugger)
}
