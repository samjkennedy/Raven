package raven

import "core:testing"
import "core:fmt"
import "core:os"
import "core:strings"
import "../"

import "core:encoding/json"

CPU_State :: struct {
	a:  u8,
	b:  u8,
	c:  u8,
	d:  u8,
	e:  u8,
	f:  u8,
	h:  u8,
	l:  u8,
	pc: u16,
	sp: u16,
}


System_State :: struct {
	cpu: CPU_State,
	ram: [dynamic][2]u16,
}

Test_Case :: struct {
	name:    string,
	initial: System_State,
	final:   System_State,
	cycles:  [dynamic][3]string,
}

load_test_cases :: proc(filepath: string) -> (cases: []Test_Case, ok: bool) {
	raw_data: []u8

	raw_data, ok = os.read_entire_file(filepath, context.allocator)
	if !ok {
		// could not read file
		fmt.printf("Couldn't load file %v\n", filepath)
		return nil, false
	}
	error := json.unmarshal(raw_data, &cases)
	if (error != nil) {
		fmt.printf("Couldn't unmarshall json: %#v\n", error)
		return nil, false
	}
	return cases, true
}

// @(test)
// test_case_isolated :: proc(t: ^testing.T) {
// 	cases, ok := load_test_cases("tests/gameboy-test-data-master/cpu_tests/test.json")

// 	testing.expect(t, ok, "Could not load test cases")

// 	failed := 0
// 	skipped := 0
// 	passed := 0
// 	for test_case in cases {
// 		//fmt.printf("Running test case \"%v\"\n", test_case.name)
// 		result := execute_test_case(t, test_case)

// 		testing.expect(t, result != .Failed, fmt.aprintf("Test %v failed", test_case.name))

// 		switch result {
// 		case .Failed:
// 			{
// 				fmt.printf("Test case \"%#v\" failed\n", test_case.name)
// 				failed += 1
// 			}
// 		case .Skipped:
// 			skipped += 1
// 		case .Passed:
// 			passed += 1
// 		}
// 	}

// 	fmt.printf("%v/%v tests passed\n", passed, len(cases))
// 	fmt.printf("%v/%v tests skipped\n", skipped, len(cases))
// 	fmt.printf("%v/%v tests failed\n", failed, len(cases))

// 	if (failed > 0) {
// 		return
// 	}
// }

@(test)
test_cases :: proc(t: ^testing.T) {
	for file in 0xF8 ..< 0xFF {
		if file == 0x10 {
			continue //STOP instruction
		}
		if file == 0x76 {
			continue //HALT instruction
		}
		filename := fmt.aprintf("tests/gameboy-test-data-master/cpu_tests/v1/%2x.json", file)
		cases, ok := load_test_cases(filename)

		if !ok {
			fmt.printf("Could not load test case %v\n", filename)
			continue
		}

		fmt.printf("Running test %v\n", filename)
		failed := 0
		skipped := 0
		passed := 0
		for test_case in cases {
			//fmt.printf("Running test case \"%v\"\n", test_case.name)
			result := execute_test_case(t, test_case)

			testing.expect(
				t,
				result != .Failed,
				fmt.aprintf("Test %v failed in file %2x.json", test_case.name, file),
			)

			switch result {
			case .Failed:
				{
					fmt.printf("Test case \"%#v\" failed\n", test_case.name)
					failed += 1
				}
			case .Skipped:
				skipped += 1
			case .Passed:
				passed += 1
			}
		}

		fmt.printf("%v/%v tests passed\n", passed, len(cases))
		fmt.printf("%v/%v tests skipped\n", skipped, len(cases))
		fmt.printf("%v/%v tests failed\n", failed, len(cases))

		if (failed > 0) {
			return
		}
	}
}

Test_Result :: enum {
	Passed,
	Skipped,
	Failed,
}

execute_test_case :: proc(t: ^testing.T, test_case: Test_Case) -> Test_Result {
	cpu := new(CPU)

	header := ROM_Header{}
	rom: [0x8000]u8
	cart := Cart{header, rom[:]}
	cpu.cart = &cart

	//Initial state
	initial := test_case.initial

	//CPU
	set_register(cpu, Register.A, initial.cpu.a)
	set_register(cpu, Register.B, initial.cpu.b)
	set_register(cpu, Register.C, initial.cpu.c)
	set_register(cpu, Register.D, initial.cpu.d)
	set_register(cpu, Register.E, initial.cpu.e)
	set_register(cpu, Register.F, initial.cpu.f)
	set_register(cpu, Register.H, initial.cpu.h)
	set_register(cpu, Register.L, initial.cpu.l)

	cpu.pc = initial.cpu.pc
	cpu.sp = initial.cpu.sp

	//RAM
	for ram in initial.ram {
		address := ram[0]
		if (address > 0xC000) {
			return .Skipped
		}
		value := u8(ram[1])
		write_to_memory(cpu, address, value)
	}

	//Run cycles
	expected_clock_cycles := u64(4 * len(test_case.cycles))
	for cpu.clock < expected_clock_cycles {
		// debug_cpu_print(cpu)
		run_instruction(cpu)
	}
	// debug_cpu_print(cpu)

	//Compare final state
	final := test_case.final
	if pass := expect_register_equals(t, test_case, cpu, Register.A, final.cpu.a); !pass {
		return .Failed
	}
	if pass := expect_register_equals(t, test_case, cpu, Register.B, final.cpu.b); !pass {
		return .Failed
	}
	if pass := expect_register_equals(t, test_case, cpu, Register.C, final.cpu.c); !pass {
		return .Failed
	}
	if pass := expect_register_equals(t, test_case, cpu, Register.D, final.cpu.d); !pass {
		return .Failed
	}
	if pass := expect_register_equals(t, test_case, cpu, Register.E, final.cpu.e); !pass {
		return .Failed
	}
	if pass := expect_register_equals(t, test_case, cpu, Register.F, final.cpu.f); !pass {
		return .Failed
	}
	if pass := expect_register_equals(t, test_case, cpu, Register.H, final.cpu.h); !pass {
		return .Failed
	}
	if pass := expect_register_equals(t, test_case, cpu, Register.L, final.cpu.l); !pass {
		return .Failed
	}

	if pass := testing.expect(
		t,
		cpu.pc == final.cpu.pc,
		fmt.aprintf(
			"%v: Expected PC to equal 0x%4x, but instead got 0x%4x",
			test_case.name,
			final.cpu.pc,
			cpu.pc,
		),
	); !pass {
		return .Failed
	}
	if pass := testing.expect(
		t,
		cpu.sp == final.cpu.sp,
		fmt.aprintf(
			"%v: Expected SP to equal 0x%4x, but instead got 0x%4x",
			test_case.name,
			final.cpu.sp,
			cpu.sp,
		),
	); !pass {
		return .Failed
	}

	for ram in final.ram {
		address := ram[0]
		if (address > 0xC000) {
			return .Skipped
		}
		expected := u8(ram[1])

		actual := read_from_memory(cpu, address)

		if pass := testing.expect(
			t,
			actual == expected,
			fmt.aprintf(
				"%v: Expected address 0x%4x to contain 0x%2x, but instead got 0x%2x",
				test_case.name,
				address,
				expected,
				actual,
			),
		); !pass {
			return .Failed
		}
	}

	return .Passed
}

expect_register_equals :: proc(
	t: ^testing.T,
	test_case: Test_Case,
	cpu: ^CPU,
	register: Register,
	expected: u8,
) -> bool {
	actual := get_register(cpu, register)
	return testing.expect(
		t,
		actual == expected,
		fmt.aprintf(
			"%v: Expected %v to equal 0x%2x, but instead got 0x%2x",
			test_case.name,
			register,
			expected,
			actual,
		),
	)
}

debug_cpu_print :: proc(cpu: ^CPU) {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)

	//zero flag
	if (get_flag(cpu, .Z)) {
		strings.write_string(&b, "z")
	} else {
		strings.write_string(&b, "-")
	}
	//Subtraction flag (BCD)
	if (get_flag(cpu, .N)) {
		strings.write_string(&b, "n")
	} else {
		strings.write_string(&b, "-")
	}
	//Half Carry flag (BCD)
	if (get_flag(cpu, .H)) {
		strings.write_string(&b, "h")
	} else {
		strings.write_string(&b, "-")
	}
	//Carry flag (BCD)
	if (get_flag(cpu, .C)) {
		strings.write_string(&b, "c")
	} else {
		strings.write_string(&b, "-")
	}
	flags := strings.to_string(b)

	ime := cpu.ime

	str := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&str)

	ins_str := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&ins_str)

	strings.write_string(&ins_str, fmt.aprintf("%2x", cpu.ins[0]))
	op := lookup(cpu.ins, cpu)
	tabs := 2

	if (cpu.ins[1] != 0) {
		strings.write_string(&ins_str, fmt.aprintf(" %2x", cpu.ins[1]))
		tabs -= 1
	}
	if (cpu.ins[2] != 0) {
		strings.write_string(&ins_str, fmt.aprintf(" %2x", cpu.ins[2]))
		tabs -= 1
	}
	for i in 1 ..= tabs {
		strings.write_string(&ins_str, "   ")
	}
	strings.write_string(&ins_str, " ; ")
	strings.write_string(&ins_str, op)

	ins := strings.to_string(ins_str)

	fmt.printf(
		"timer: %2x, div: %2x, pc: %4x: sp: %4x, ime: %v, ie: %8b, if: %8b, A: %2x, B: %2x, C: %2x, D: %2x, E: %2x, H: %2x, L: %2x, flags: %v, clock: %4d, ins: %v\n",
		read_from_memory(cpu, TIMA_REGISTER),
		read_from_memory(cpu, DIV_REGISTER),
		cpu.pc,
		cpu.sp,
		ime,
		read_from_memory(cpu, IE_REGISTER),
		read_from_memory(cpu, IF_REGISTER),
		cpu.AF & 0xFF00 >> 8,
		cpu.BC & 0xFF00 >> 8,
		cpu.BC & 0x00FF,
		cpu.DE & 0xFF00 >> 8,
		cpu.DE & 0x00FF,
		cpu.HL & 0xFF00 >> 8,
		cpu.HL & 0x00FF,
		flags,
		cpu.clock,
		ins,
	)
}
