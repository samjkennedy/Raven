package raven

import "core:testing"
import "core:fmt"
import "../"


create_cpu :: proc() -> CPU {
	return CPU{}
}

@(test)
res_returns_right_value :: proc(t: ^testing.T) {
	cpu := create_cpu()

	set_register(&cpu, Register.A, u8(0xFF))
	res(&cpu, 0, Register.A)
	val := get_register(&cpu, Register.A)

	testing.expect(t, val == 0b11111110)

	set_register(&cpu, Register.A, u8(0xFF))
	res(&cpu, 1, Register.A)
	val = get_register(&cpu, Register.A)

	testing.expect(t, val == 0b11111101)
}

@(test)
set_returns_right_value :: proc(t: ^testing.T) {
	cpu := create_cpu()

	set_register(&cpu, Register.A, u8(0x00))
	set_bit(&cpu, 0, Register.A)
	val := get_register(&cpu, Register.A)

	testing.expect(t, val == 0b00000001)

	set_register(&cpu, Register.A, u8(0x00))
	set_bit(&cpu, 1, Register.A)
	val = get_register(&cpu, Register.A)

	testing.expect(t, val == 0b00000010)
}

@(test)
rr_carry_set_returns_right_value :: proc(t: ^testing.T) {
	cpu := create_cpu()
	set_register(&cpu, Register.A, u8(0b10101010))
	set_flag(&cpu, .C, true)

	rr(&cpu, Register.A)

	after := get_register(&cpu, Register.A)
	carry := get_flag(&cpu, .C)

	testing.expect(t, after == 0b11010101)
	testing.expect(t, carry == false)
}
@(test)
rr_carry_not_set_returns_right_value :: proc(t: ^testing.T) {
	cpu := create_cpu()
	set_register(&cpu, Register.A, u8(0b10101011))
	set_flag(&cpu, .C, false)

	rr(&cpu, Register.A)

	after := get_register(&cpu, Register.A)
	carry := get_flag(&cpu, .C)

	testing.expect(t, after == 0b01010101)
	testing.expect(t, carry == true)
}
