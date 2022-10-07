package raven

import "vendor:sdl2"
import "core:fmt"

Keymap :: struct {} //TODO: map SDL2 events to buttons to allow custom keybinds

Joypad :: struct {
	action_buttons:    u8,
	direction_buttons: u8,
}

joypad_state := Joypad{0x0F, 0x0F}

JOYPAD_ADDRESS :: 0xFF00

Select :: enum u8 {
	ACTION    = 5,
	DIRECTION = 4,
}

Direction_Button :: enum u8 {
	DOWN  = 3,
	UP    = 2,
	LEFT  = 1,
	RIGHT = 0,
}

Action_Button :: enum u8 {
	START  = 3,
	SELECT = 2,
	B      = 1,
	A      = 0,
}

get_joypad_state :: proc(select: Select) -> (state: u8) {
	switch select {
	case .ACTION:
		state = joypad_state.action_buttons
	case .DIRECTION:
		state = joypad_state.direction_buttons
	}
	//fmt.printf("%8b\n", state)
	return
}

set_joypad_bit :: proc {
	set_joypad_bit_act,
	set_joypad_bit_dir,
}

set_joypad_bit_dir :: proc(button: Direction_Button, value: bool) {
	if (value) {
		joypad_state.direction_buttons |= (1 << u8(button))
	} else {
		joypad_state.direction_buttons &= ~(1 << u8(button))
	}
	fmt.printf("%8b\n", joypad_state.direction_buttons)
}

set_joypad_bit_act :: proc(button: Action_Button, value: bool) {
	if (value) {
		joypad_state.action_buttons |= (1 << u8(button))
	} else {
		joypad_state.action_buttons &= ~(1 << u8(button))
	}
	//fmt.printf("%8b\n", joypad_state.action_buttons)
}

handle_button :: proc {
	handle_button_dir,
	handle_button_act,
}

handle_button_dir :: proc(button: Direction_Button, cpu: ^CPU, released: bool) {

	joypad_ram := read_from_memory(cpu, JOYPAD_ADDRESS)
	already_pressed := joypad_state.direction_buttons & (1 << u8(button)) == 0

	if released || !already_pressed {
		set_joypad_bit(button, released)
	}

	if !released && (joypad_ram & u8(Select.DIRECTION) > 0) && !already_pressed {
		set_interrupt_flag(cpu, Interrupt.JOYPAD, 1)
	}
}

handle_button_act :: proc(button: Action_Button, cpu: ^CPU, released: bool) {

	joypad_ram := read_from_memory(cpu, JOYPAD_ADDRESS)
	already_pressed := joypad_state.action_buttons & (1 << u8(button)) == 0

	if released || !already_pressed {
		set_joypad_bit(button, released)
	}

	if !released && (joypad_ram & u8(Select.ACTION) > 0) && !already_pressed {
		set_interrupt_flag(cpu, Interrupt.JOYPAD, 1)
	}
}

handle_input :: proc(e: ^sdl2.Event, cpu: ^CPU, released: bool) {

	#partial switch (e.key.keysym.sym) {
	case .UP:
		handle_button(Direction_Button.UP, cpu, released)
	case .DOWN:
		handle_button(Direction_Button.DOWN, cpu, released)
	case .LEFT:
		handle_button(Direction_Button.LEFT, cpu, released)
	case .RIGHT:
		handle_button(Direction_Button.RIGHT, cpu, released)
	case .Z:
		handle_button(Action_Button.A, cpu, released)
	case .X:
		handle_button(Action_Button.B, cpu, released)
	case .RETURN:
		handle_button(Action_Button.START, cpu, released)
	case .BACKSPACE:
		handle_button(Action_Button.SELECT, cpu, released)
	}
}
