package raven

import "core:fmt"
import "core:strings"
import "core:log"

CPU :: struct {
	clock:        u64,
	//Registers
	AF:           u16,
	BC:           u16,
	DE:           u16,
	HL:           u16,

	//Stack pointer
	sp:           u16,
	//Program counter
	pc:           u16,

	//memory
	//Interrupt Master Enable
	ime:          bool,
	//Interrupt enable
	ie:           u8,
	//High RAM   
	hram:         [0x80]u8, //FF80-FFFE
	io_ports:     [0x80]u8, //FF00-FF7F
	//Sprite attribute memory
	oam:          [0x1EA0]u8, //FE00-FE9F
	echoed_ram:   [0x2000]u8, //E000-FDFF
	//WRAM
	ram:          [0x2000]u8, //C000-DFFF

	//Video RAM
	vram:         [0x2000]u8, //8000-9FFF
	cart:         ^Cart, //0000-4000/8000
	in_interrupt: bool,

	//Debugging
	ins_pc:       u16,
	ins_idx:      u8,
	ins:          [3]u8,
}

init_cpu :: proc(cart: ^Cart) -> (cpu: CPU) {
	cpu = CPU{}

	cpu.pc = 0x0100
	cpu.sp = 0xFFFE
	cpu.cart = cart

	//Set joypad byte to all unpressed
	cpu.io_ports[0] = 0x0F

	return
}

//Special Registers

IE_REGISTER: u16 = 0xFFFF
IF_REGISTER: u16 = 0xFF0F

//=====Memory Bus=====//

write_to_memory :: proc(this: ^CPU, address: u16, value: u8) {

	//determine where we're writing
	if (address == 0xff80) {
		//fmt.println("Blocking write to 0xFF80 - tetris hack")
		return
	}

	switch address {
	case IE_REGISTER:
		{
			this.ie = value
		}
	case IF_REGISTER:
		{
			//Shouldn't be written to manually
		}
	case 0xFF80 ..< 0xFFFF:
		{
			this.hram[address - 0xFF80] = value
		}
	case 0xFF00 ..< 0xFF80:
		{
			_value := value
			if address == 0xFF46 {
				//DMA to OAM transfer
				run_dma_transfer(this, _value)
			}

			switch address {
			case 0xFF00:
				{
					//don't overwrite joypad inputs
					_value &= 0xF0
					_value |= (this.io_ports[0] & 0x0F)
				}
			}
			this.io_ports[address - 0xFF00] = _value
		}
	case 0xFEA0 ..< 0xFF00:
		{} 	//Not usable
	case 0xFE00 ..< 0xFEA0:
		{
			this.oam[address - 0xFE00] = value
		}
	case 0xE000 ..< 0xFE00:
		{
			this.ram[address - 0xE000] = value
			this.echoed_ram[address - 0xE000] = value
		}
	case 0xC000 ..< 0xE000:
		{
			// if address >= 0xC000 && address < 0xC004 {
			// 	fmt.printf("PC: %4x, Wrote %2x to %4x\n", this.pc, value, address)
			// }
			this.ram[address - 0xC000] = value
			this.echoed_ram[address - 0xC000] = value
		}
	case 0x8000 ..< 0xA000:
		{
			this.vram[address - 0x8000] = value
		}
	case 0x0000 ..< 0x8000:
		{
			this.cart.rom[address] = value
		}
	case:
		log.logf(.Warning, "Attempted to write to unhandled memory region 0x%4x", address)
	}
	//fmt.printf("Wrote %2x to address %4x\n", value, address)
}

read_from_memory :: proc(this: ^CPU, address: u16) -> (value: u8) {

	switch address {
	case IE_REGISTER:
		{
			value = this.ie
		}
	case 0xFF80 ..< 0xFFFF:
		{
			value = this.hram[address - 0xFF80]
		}
	case 0xFF00 ..< 0xFF80:
		{
			value = this.io_ports[address - 0xFF00]

			if (address == JOYPAD_ADDRESS) {
				if (this.io_ports[0] & u8(Select.DIRECTION) > 0) {
					value = get_joypad_state(.DIRECTION) | u8(Select.DIRECTION)
				} else if (this.io_ports[0] & u8(Select.ACTION) > 0) {
					value = get_joypad_state(.ACTION) | u8(Select.ACTION)
				}
				//fmt.printf("Read joypad state: %8b\n", value)
			}
		}
	case 0xFEA0 ..< 0xFF00:
		{} 	//Not usable
	case 0xFE00 ..< 0xFEA0:
		{
			value = this.oam[address - 0xFE00]
		}
	case 0xE000 ..< 0xFE00:
		{
			value = this.echoed_ram[address - 0xE000]
		}
	case 0xC000 ..< 0xE000:
		{
			value = this.ram[address - 0xC000]
		}
	case 0x8000 ..< 0xA000:
		{
			value = this.vram[address - 0x8000]
		}
	case 0x0000 ..< 0x8000:
		{
			value = this.cart.rom[address]
		}
	case:
		log.logf(.Warning, "Attempted to read from unhandled memory region 0x%4x", address)
	}
	return
}

run_dma_transfer :: proc(this: ^CPU, value: u8) {
	source := u16(value) << 0x8
	fmt.printf("Running DMA transfer from %4x\n", source)

	for offset: u16 = 0; offset <= 0x9F; offset += 1 {

		address := source + offset
		val := read_from_memory(this, address)

		fmt.printf("Writing %2x from %4x to %4x\n", val, source, 0xFE00 + offset)

		write_to_memory(this, 0xFE00 + offset, val)
	}
}

Interrupt :: enum u8 {
	VBLANK   = 0,
	LCD_STAT = 1,
	TIMER    = 2,
	SERIAL   = 3,
	JOYPAD   = 4,
}

interrupt_enabled :: proc(this: ^CPU, interrupt: Interrupt) -> bool {
	return this.ime && this.ie & (1 << u8(interrupt)) > 0
}

set_interrupt_flag :: proc(this: ^CPU, interrupt: Interrupt, value: u8) {
	interrupt_flags := read_from_memory(this, IF_REGISTER)

	if (value > 0) {
		interrupt_flags |= (1 << u8(interrupt))
	} else {
		interrupt_flags &= ~(1 << u8(interrupt))
	}

	this.io_ports[IF_REGISTER - 0xFF00] = interrupt_flags
}

get_interrupt_flag :: proc(this: ^CPU, interrupt: Interrupt) -> bool {
	interrupt_flags := read_from_memory(this, IF_REGISTER)
	return interrupt_flags & (1 << u8(interrupt)) > 0
}

//Register helpers

Flag :: enum u8 {
	Z = 0x0080,
	N = 0x0040,
	H = 0x0020,
	C = 0x0010,
}

Register :: enum u8 {
	A,
	B,
	C,
	D,
	E,
	H,
	L,
}

Wide_Register :: enum {
	AF,
	BC,
	DE,
	HL,
	SP,
}

set_flag :: proc(this: ^CPU, flag: Flag, value: bool) {
	if value {
		this.AF |= u16(flag)
	} else {
		this.AF &= ~u16(flag)
	}
}

get_flag :: proc(this: ^CPU, flag: Flag) -> bool {
	return this.AF & u16(flag) == u16(flag)
}

get_register :: proc {
	get_narrow_register,
	get_wide_register,
}
set_register :: proc {
	set_narrow_register,
	set_wide_register,
}

get_wide_register :: proc(this: ^CPU, register: Wide_Register) -> u16 {
	value: u16
	switch register {
	case .AF:
		value = this.AF
	case .BC:
		value = this.BC
	case .DE:
		value = this.DE
	case .HL:
		value = this.HL
	case .SP:
		value = this.sp
	}
	return value
}

set_wide_register :: proc(this: ^CPU, register: Wide_Register, value: u16) {
	switch register {
	case .AF:
		this.AF = value
	case .BC:
		this.BC = value
	case .DE:
		this.DE = value
	case .HL:
		this.HL = value
	case .SP:
		this.sp = value
	}
}

get_narrow_register :: proc(this: ^CPU, register: Register) -> u8 {
	value: u8
	switch register {
	case .A:
		value = u8(this.AF >> 8)
	case .B:
		value = u8(this.BC >> 8)
	case .C:
		value = u8(this.BC & 0x00FF)
	case .D:
		value = u8(this.DE >> 8)
	case .E:
		value = u8(this.DE & 0x00FF)
	case .H:
		value = u8(this.HL >> 8)
	case .L:
		value = u8(this.HL & 0x00FF)
	}
	return value
}

set_narrow_register :: proc(this: ^CPU, register: Register, value: u8) {
	switch register {
	case .A:
		{
			this.AF &= ~u16(0xFF00)
			this.AF |= (u16(value) << 8)
		}
	case .B:
		{
			this.BC &= ~u16(0xFF00)
			this.BC |= (u16(value) << 8)
		}
	case .C:
		{
			this.BC &= ~u16(0x00FF)
			this.BC |= (u16(value))
		}
	case .D:
		{
			this.DE &= ~u16(0xFF00)
			this.DE |= (u16(value) << 8)
		}
	case .E:
		{
			this.DE &= ~u16(0x00FF)
			this.DE |= (u16(value))
		}
	case .H:
		{
			this.HL &= ~u16(0xFF00)
			this.HL |= (u16(value) << 8)
		}
	case .L:
		{
			this.HL &= ~u16(0x00FF)
			this.HL |= (u16(value))
		}
	}
}

fetch :: proc(this: ^CPU) -> u8 {
	op := read_from_memory(this, this.pc)

	this.ins[this.ins_idx] = op
	this.ins_idx += 1

	this.pc += 1

	return op
}

run_instruction :: proc(this: ^CPU) -> (ok: bool) {

	this.ins[0] = 0
	this.ins[1] = 0
	this.ins[2] = 0
	this.ins_idx = 0
	this.ins_pc = this.pc

	//fetch
	instruction := fetch(this)
	opcode := instruction & 0xF0
	operand := instruction & 0x0F

	clk_before := this.clock

	//decode + execute
	switch opcode {
	case 0x00:
		switch operand {
		case 0x00:
			nop(this)
		case 0x01:
			ld(this, Wide_Register.BC)
		case 0x02:
			ld(this, Wide_Register.BC, Register.A)
		case 0x03:
			inc(this, Wide_Register.BC)
		case 0x04:
			inc(this, Register.B)
		case 0x05:
			dec(this, Register.B)
		case 0x06:
			ld_n(this, Register.B)
		case 0x07:
			rlca(this)
		case 0x08:
			dec(this, Wide_Register.BC)

		case 0x09:
			add(this, Wide_Register.HL, Wide_Register.BC)
		case 0x0A:
			ld(this, Register.A, Wide_Register.BC)
		case 0x0B:
			dec(this, Wide_Register.BC)
		case 0x0C:
			inc(this, Register.C)
		case 0x0D:
			dec(this, Register.C)
		case 0x0E:
			ld_n(this, .C)
		case 0x0F:
			rrca(this)
		case:
			{
				fmt.eprintf("Unknown operand in 0x00: %2x\n", operand)
				return false
			}
		}
	case 0x10:
		switch operand {
		case 0x08:
			jr(this)
		case 0x01:
			ld(this, Wide_Register.DE)
		case 0x02:
			ld(this, Wide_Register.DE, Register.A)
		case 0x03:
			inc(this, Wide_Register.DE)
		case 0x04:
			inc(this, Register.D)
		case 0x05:
			dec(this, Register.D)
		case 0x06:
			ld_n(this, Register.D)
		case 0x07:
			rla(this)
		case 0x09:
			add(this, Wide_Register.HL, Wide_Register.DE)
		case 0x0A:
			ld(this, Register.A, Wide_Register.DE)
		case 0x0B:
			dec(this, Wide_Register.DE)
		case 0x0C:
			inc(this, Register.E)
		case 0x0D:
			dec(this, Register.E)
		case 0x0E:
			ld_n(this, .E)
		case:
			{
				fmt.eprintf("Unknown operand in 0x10: %2x\n", operand)
				return false
			}
		}
	case 0x20:
		{
			switch operand {
			case 0x00:
				jr(this, Flag.Z, false)
			case 0x01:
				ld(this, Wide_Register.HL)
			case 0x02:
				ldi(this, Wide_Register.HL, Register.A)
			case 0x03:
				inc(this, Wide_Register.HL)
			case 0x04:
				inc(this, Register.H)
			case 0x05:
				dec(this, Register.H)
			case 0x06:
				ld_n(this, Register.H)
			case 0x07:
				daa(this)
			case 0x08:
				jr(this, Flag.Z, true)
			case 0x09:
				add(this, Wide_Register.HL, Wide_Register.HL)
			case 0x0A:
				ldi(this, Register.A, Wide_Register.HL)
			case 0x0B:
				dec(this, Wide_Register.HL)
			case 0x0C:
				inc(this, Register.L)
			case 0x0D:
				dec(this, Register.L)
			case 0x0E:
				ld_n(this, .L)
			case 0x0F:
				cpl(this)
			case:
				{
					fmt.eprintf("Unknown operand in 0x20: %2x\n", operand)
					return false
				}
			}
		}
	case 0x30:
		switch operand {
		case 0x00:
			jr(this, Flag.C, false)
		case 0x01:
			ld(this, Wide_Register.SP)
		case 0x02:
			ldd(this, Wide_Register.HL, Register.A)
		case 0x03:
			inc(this, Wide_Register.SP)
		case 0x04:
			inc_ind(this, Wide_Register.HL)
		case 0x05:
			dec_ind(this, Wide_Register.HL)
		case 0x06:
			{
				n := fetch(this)
				ld(this, Wide_Register.HL, n)
			}
		case 0x07:
			{
				set_flag(this, Flag.N, false)
				set_flag(this, Flag.H, false)
				set_flag(this, Flag.C, true)
				this.clock += 4
			}
		case 0x08:
			jr(this, Flag.C, true)
		case 0x09:
			add(this, Wide_Register.HL, Wide_Register.SP)
		case 0x0A:
			ldd(this, Register.A, Wide_Register.HL)
		case 0x0B:
			dec(this, Wide_Register.SP)
		case 0x0C:
			inc(this, Register.A)
		case 0x0D:
			dec(this, Register.A)
		case 0x0E:
			ld_n(this, .A)
		case:
			{
				fmt.eprintf("Unknown operand in 0x30: %2x\n", operand)
				return false
			}
		}
	case 0x40:
		switch operand {
		case 0x00:
			ld(this, Register.B, Register.B)
		case 0x01:
			ld(this, Register.B, Register.C)
		case 0x02:
			ld(this, Register.B, Register.D)
		case 0x03:
			ld(this, Register.B, Register.E)
		case 0x04:
			ld(this, Register.B, Register.H)
		case 0x05:
			ld(this, Register.B, Register.L)
		case 0x06:
			ld(this, Register.B, Wide_Register.HL)
		case 0x07:
			ld(this, Register.B, Register.A)

		case 0x08:
			ld(this, Register.C, Register.B)
		case 0x09:
			ld(this, Register.C, Register.C)
		case 0x0A:
			ld(this, Register.C, Register.D)
		case 0x0B:
			ld(this, Register.C, Register.E)
		case 0x0C:
			ld(this, Register.C, Register.H)
		case 0x0D:
			ld(this, Register.C, Register.L)
		case 0x0E:
			ld(this, Register.C, Wide_Register.HL)
		case 0x0F:
			ld(this, Register.C, Register.A)
		}
	case 0x50:
		switch operand {
		case 0x00:
			ld(this, Register.D, Register.B)
		case 0x01:
			ld(this, Register.D, Register.C)
		case 0x02:
			ld(this, Register.D, Register.D)
		case 0x03:
			ld(this, Register.D, Register.E)
		case 0x04:
			ld(this, Register.D, Register.H)
		case 0x05:
			ld(this, Register.D, Register.L)
		case 0x06:
			ld(this, Register.D, Wide_Register.HL)
		case 0x07:
			ld(this, Register.D, Register.A)

		case 0x08:
			ld(this, Register.E, Register.B)
		case 0x09:
			ld(this, Register.E, Register.C)
		case 0x0A:
			ld(this, Register.E, Register.D)
		case 0x0B:
			ld(this, Register.E, Register.E)
		case 0x0C:
			ld(this, Register.E, Register.H)
		case 0x0D:
			ld(this, Register.E, Register.L)
		case 0x0E:
			ld(this, Register.E, Wide_Register.HL)
		case 0x0F:
			ld(this, Register.E, Register.A)
		}
	case 0x60:
		switch operand {
		case 0x00:
			ld(this, Register.H, Register.B)
		case 0x01:
			ld(this, Register.H, Register.C)
		case 0x02:
			ld(this, Register.H, Register.D)
		case 0x03:
			ld(this, Register.H, Register.E)
		case 0x04:
			ld(this, Register.H, Register.H)
		case 0x05:
			ld(this, Register.H, Register.L)
		case 0x06:
			ld(this, Register.H, Wide_Register.HL)
		case 0x07:
			ld(this, Register.H, Register.A)

		case 0x08:
			ld(this, Register.L, Register.B)
		case 0x09:
			ld(this, Register.L, Register.C)
		case 0x0A:
			ld(this, Register.L, Register.D)
		case 0x0B:
			ld(this, Register.L, Register.E)
		case 0x0C:
			ld(this, Register.L, Register.H)
		case 0x0D:
			ld(this, Register.L, Register.L)
		case 0x0E:
			ld(this, Register.L, Wide_Register.HL)
		case 0x0F:
			ld(this, Register.L, Register.A)
		}
	case 0x70:
		switch operand {
		case 0x00:
			ld(this, Wide_Register.HL, Register.B)
		case 0x01:
			ld(this, Wide_Register.HL, Register.C)
		case 0x02:
			ld(this, Wide_Register.HL, Register.D)
		case 0x03:
			ld(this, Wide_Register.HL, Register.E)
		case 0x04:
			ld(this, Wide_Register.HL, Register.H)
		case 0x05:
			ld(this, Wide_Register.HL, Register.L)
		case 0x06:
			this.clock += 4
		case 0x07:
			ld(this, Wide_Register.HL, Register.A)

		case 0x08:
			ld(this, Register.A, Register.B)
		case 0x09:
			ld(this, Register.A, Register.C)
		case 0x0A:
			ld(this, Register.A, Register.D)
		case 0x0B:
			ld(this, Register.A, Register.E)
		case 0x0C:
			ld(this, Register.A, Register.H)
		case 0x0D:
			ld(this, Register.A, Register.L)
		case 0x0E:
			ld(this, Register.A, Wide_Register.HL)
		case 0x0F:
			ld(this, Register.A, Register.A)
		}
	case 0x80:
		switch operand {
		case 0x00:
			add(this, Register.B)
		case 0x01:
			add(this, Register.C)
		case 0x02:
			add(this, Register.D)
		case 0x03:
			add(this, Register.E)
		case 0x04:
			add(this, Register.H)
		case 0x05:
			add(this, Register.L)
		case 0x06:
			add(this, Wide_Register.HL)
		case 0x07:
			add(this, Register.A)

		case 0x08:
			adc(this, Register.B)
		case 0x09:
			adc(this, Register.C)
		case 0x0A:
			adc(this, Register.D)
		case 0x0B:
			adc(this, Register.E)
		case 0x0C:
			adc(this, Register.H)
		case 0x0D:
			adc(this, Register.L)
		case 0x0E:
			adc(this, Wide_Register.HL)
		case 0x0F:
			adc(this, Register.A)
		}
	case 0x90:
		switch operand {
		case 0x00:
			sub(this, Register.B)
		case 0x01:
			sub(this, Register.C)
		case 0x02:
			sub(this, Register.D)
		case 0x03:
			sub(this, Register.E)
		case 0x04:
			sub(this, Register.H)
		case 0x05:
			sub(this, Register.L)
		case 0x06:
			sub(this, Wide_Register.HL)
		case 0x07:
			sub(this, Register.A)

		case 0x08:
			sbc(this, Register.B)
		case 0x09:
			sbc(this, Register.C)
		case 0x0A:
			sbc(this, Register.D)
		case 0x0B:
			sbc(this, Register.E)
		case 0x0C:
			sbc(this, Register.H)
		case 0x0D:
			sbc(this, Register.L)
		case 0x0E:
			sbc(this, Wide_Register.HL)
		case 0x0F:
			sbc(this, Register.A)
		}
	case 0xA0:
		switch operand {
		case 0x00:
			and(this, Register.B)
		case 0x01:
			and(this, Register.C)
		case 0x02:
			and(this, Register.D)
		case 0x03:
			and(this, Register.E)
		case 0x04:
			and(this, Register.H)
		case 0x05:
			and(this, Register.L)
		case 0x06:
			and(this, Wide_Register.HL)
		case 0x07:
			and(this, Register.A)

		case 0x08:
			xor(this, Register.B)
		case 0x09:
			xor(this, Register.C)
		case 0x0A:
			xor(this, Register.D)
		case 0x0B:
			xor(this, Register.E)
		case 0x0C:
			xor(this, Register.H)
		case 0x0D:
			xor(this, Register.L)
		case 0x0E:
			xor(this, Wide_Register.HL)
		case 0x0F:
			xor(this, Register.A)
		}
	case 0xB0:
		switch operand {
		case 0x00:
			or(this, Register.B)
		case 0x01:
			or(this, Register.C)
		case 0x02:
			or(this, Register.D)
		case 0x03:
			or(this, Register.E)
		case 0x04:
			or(this, Register.H)
		case 0x05:
			or(this, Register.L)
		case 0x06:
			or(this, Wide_Register.HL)
		case 0x07:
			or(this, Register.A)

		case 0x08:
			cp(this, Register.B)
		case 0x09:
			cp(this, Register.C)
		case 0x0A:
			cp(this, Register.D)
		case 0x0B:
			cp(this, Register.E)
		case 0x0C:
			cp(this, Register.H)
		case 0x0D:
			cp(this, Register.L)
		case 0x0E:
			cp(this, Wide_Register.HL)
		case 0x0F:
			cp(this, Register.A)
		}
	case 0xC0:
		switch operand {
		case 0x00:
			ret(this, Flag.Z, false)
		case 0x01:
			pop(this, .BC)
		case 0x02:
			jp(this, Flag.Z, false)
		case 0x03:
			{
				lo := fetch(this)
				hi := fetch(this)

				address := (u16(hi) << 8 | u16(lo))

				jp(this, address)
			}
		case 0x04:
			call(this, Flag.N, false)
		case 0x05:
			push(this, .BC)
		case 0x06:
			{
				value := fetch(this)
				add_imm(this, .A, value)
			}
		case 0x08:
			ret(this, Flag.Z)
		case 0x09:
			ret(this)
		case 0x0a:
			jp(this, Flag.Z)
		case 0x0B:
			prefix_cb(this)
		case 0x07:
			rst(this, 0x0000)
		case 0x0C:
			call(this, Flag.Z)
		case 0x0D:
			call(this)
		case 0x0E:
			adc(this)
		case 0x0F:
			rst(this, 0x0008)
		case:
			{
				fmt.eprintf("Unknown operand in 0xC0: %2x\n", operand)
				return false
			}
		}
	case 0xD0:
		switch operand {
		case 0x00:
			ret(this, Flag.C, false)
		case 0x01:
			pop(this, .DE)
		case 0x02:
			jp(this, Flag.C, false)
		case 0x03:
			{ /*Not an instruction*/}
		case 0x04:
			call(this, Flag.C, false)
		case 0x05:
			push(this, .DE)
		case 0x06:
			{
				value := fetch(this)
				sub_imm(this, .A, value)
			}
		case 0x07:
			rst(this, 0x0010)
		case 0x08:
			ret(this, Flag.C)
		case 0x09:
			reti(this)
		case 0x0A:
			jp(this, Flag.C)
		case 0x0B:
			{ /*Not an instruction*/}
		case 0x0C:
			call(this, Flag.C)
		case 0x0D:
			{ /*Not an instruction*/}
		case 0x0E:
			sbc(this)
		case 0x0F:
			rst(this, 0x0018)
		case:
			{
				fmt.eprintf("Unknown operand in 0xD0: %2x\n", operand)
				return false
			}
		}
	case 0xE0:
		switch operand {
		case 0x00:
			{
				//write to io-port n
				n := fetch(this)

				write_to_memory(this, 0xFF00 + u16(n), get_register(this, Register.A))

				this.clock += 12
			}
		case 0x01:
			pop(this, .HL)
		case 0x02:
			{
				//write to io-port (c)
				n := get_register(this, Register.C)

				write_to_memory(this, 0xFF00 + u16(n), get_register(this, Register.A))

				this.clock += 8
			}
		case 0x03:
			{ /*Not an instruction*/}
		case 0x04:
			{ /*Not an instruction*/}
		case 0x05:
			push(this, .HL)
		case 0x06:
			and(this, Register.A, fetch(this))
		case 0x07:
			rst(this, 0x0020)
		case 0x08:
			add_sp_r8(this)
		case 0x09:
			jp_hl(this)
		case 0x0A:
			ld_from(this, .A)
		case 0x0B:
			{ /*Not an instruction*/}
		case 0x0C:
			{ /*Not an instruction*/}
		case 0x0D:
			{ /*Not an instruction*/}
		case 0x0E:
			xor(this)
		case 0x0F:
			rst(this, 0x0028)
		case:
			{
				fmt.eprintf("Unknown operand in 0xE0: %2x\n", operand)
				return false
			}
		}
	case 0xF0:
		switch operand {
		case 0x00:
			{
				//read from io port n
				n := fetch(this)

				set_register(this, Register.A, read_from_memory(this, 0xFF00 + u16(n)))

				this.clock += 12
			}
		case 0x01:
			pop(this, .AF)
		case 0x02:
			{
				c := get_register(this, Register.C)
				set_register(this, Register.A, read_from_memory(this, 0xFF00 + u16(c)))

				this.clock += 8
			}
		case 0x03:
			di(this)
		case 0x05:
			push(this, .AF)
		case 0x06:
			or(this)
		case 0x07:
			rst(this, 0x0030)
		case 0x08:
			ld_hl_sp_d8(this)
		case 0x0A:
			ld(this, Register.A)
		case 0x0B:
			ei(this)
		case 0x0C:
			{ /*Not an instruction*/}
		case 0x0D:
			{ /*Not an instruction*/}
		case 0x0E:
			cp(this)
		case 0x0F:
			rst(this, 0x0038)
		case:
			{
				fmt.eprintf("Unknown operand in 0xF0: %2x\n", operand)
				return false
			}
		}
	case:
		{
			fmt.eprintf("Unknown opcode %2x\n", opcode)
			return false
		}
	}

	//Check for interrupts
	//Interrupts must be handled in the order they appear in the Interrupt struct
	if get_interrupt_flag(this, .VBLANK) && interrupt_enabled(this, .VBLANK) {

		this.in_interrupt = true

		write_to_memory(this, IE_REGISTER, 0)
		set_interrupt_flag(this, .VBLANK, 0)

		this.sp -= 2
		write_to_memory(this, this.sp, u8(this.pc & 0x00FF))
		write_to_memory(this, this.sp + 1, u8(this.pc & 0xFF00 >> 8))

		this.pc = 0x0040

		this.clock += 24
	}

	if get_interrupt_flag(this, .JOYPAD) && interrupt_enabled(this, .JOYPAD) {

		fmt.println("JOYPAD INTERRUPT")

		this.in_interrupt = true

		write_to_memory(this, IE_REGISTER, 0)
		set_interrupt_flag(this, .JOYPAD, 0)

		this.sp -= 2
		write_to_memory(this, this.sp, u8(this.pc & 0x00FF))
		write_to_memory(this, this.sp + 1, u8(this.pc & 0xFF00 >> 8))

		this.pc = 0x0060

		this.clock += 24
	}

	return true
}

nop :: proc(this: ^CPU) {
	this.clock += 4
}

//8-bit Load instructions

ld :: proc {
	ld_imm,
	ld_wide,
	ld_wide_imm,
	ld_indirect_wide,
	ld_addr_indirect,
	ld_into_reg_indirect,
}

ld_hl_sp_d8 :: proc(this: ^CPU) {
	offset := i8(fetch(this))

	before := get_register(this, Wide_Register.HL)
	after := this.sp + u16(offset)

	set_register(this, Wide_Register.HL, after)

	set_flag(this, .Z, false)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 12
}

ld_wide_imm :: proc(this: ^CPU, register: Wide_Register) {

	lo := fetch(this)
	hi := fetch(this)

	value := (u16(hi) << 8 | u16(lo))

	set_register(this, register, value)

	this.clock += 12
}

ld_imm :: proc(this: ^CPU, r1: Register, r2: Register) {

	set_register(this, r1, get_register(this, r2))

	this.clock += 4
}

ld_n :: proc(this: ^CPU, r: Register) {
	n := fetch(this)

	set_register(this, r, n)

	this.clock += 8
}

ld_wide :: proc(this: ^CPU, destination: Wide_Register, source: Register) {

	write_to_memory(this, get_register(this, destination), get_register(this, source))

	this.clock += 8
}

ld_indirect_wide :: proc(this: ^CPU, r1: Register, r2: Wide_Register) {

	set_register(this, r1, read_from_memory(this, get_register(this, r2)))

	this.clock += 8
}

ld_addr_indirect :: proc(this: ^CPU, register: Register) {
	lo := fetch(this)
	hi := fetch(this)

	address := (u16(hi) << 8 | u16(lo))

	set_register(this, register, read_from_memory(this, address))

	this.clock += 16
}

ld_from :: proc(this: ^CPU, register: Register) {
	lo := fetch(this)
	hi := fetch(this)

	address := (u16(hi) << 8 | u16(lo))

	write_to_memory(this, address, get_register(this, Register.A))

	this.clock += 16
}

ld_into_reg_indirect :: proc(this: ^CPU, register: Wide_Register, value: u8) {

	write_to_memory(this, get_register(this, register), value)

	this.clock += 12
}

ldi :: proc {
	ldi_W_N,
	ldi_N_W,
}

ldi_W_N :: proc(this: ^CPU, wide: Wide_Register, narrow: Register) {

	address := get_register(this, wide)

	write_to_memory(this, address, get_register(this, narrow))

	set_register(this, wide, address + u16(1))

	this.clock += 8
}

ldi_N_W :: proc(this: ^CPU, narrow: Register, wide: Wide_Register) {

	address := get_register(this, wide)

	set_register(this, narrow, read_from_memory(this, address))

	set_register(this, wide, address + u16(1))

	this.clock += 8
}

ldd :: proc {
	ldd_W_N,
	ldd_N_W,
}

ldd_W_N :: proc(this: ^CPU, wide: Wide_Register, narrow: Register) {

	address := get_register(this, wide)

	write_to_memory(this, address, get_register(this, narrow))

	set_register(this, wide, address - u16(1))

	this.clock += 8
}

ldd_N_W :: proc(this: ^CPU, narrow: Register, wide: Wide_Register) {

	address := get_register(this, wide)

	set_register(this, narrow, read_from_memory(this, address))

	set_register(this, wide, address - u16(1))

	this.clock += 8
}

push :: proc(this: ^CPU, register: Wide_Register) {

	this.sp -= 2

	value := get_register(this, register)

	write_to_memory(this, this.sp, u8(value & 0x00FF))

	write_to_memory(this, this.sp + 1, u8(value & 0xFF00 >> 8))

	this.clock += 16
}

pop :: proc(this: ^CPU, register: Wide_Register) {

	lo := read_from_memory(this, this.sp)
	hi := read_from_memory(this, this.sp + 1)

	value := (u16(hi) << 8 | u16(lo))

	set_register(this, register, value)

	this.sp += 2

	this.clock += 12
}

//8-bit Arithmetic Logic instructions

add :: proc {
	add_r,
	add_hl,
	add_w_w,
}

add_sp_r8 :: proc(this: ^CPU) {
	offset := i8(fetch(this))

	before := this.sp
	this.sp += u16(offset)

	set_flag(this, .Z, false)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (this.sp & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, this.sp < before)

	this.clock += 16
}

add_w_w :: proc(this: ^CPU, r1: Wide_Register, r2: Wide_Register) {
	before := get_register(this, r1)

	after := before + get_register(this, r2)

	set_register(this, r1, after)

	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

add_r :: proc(this: ^CPU, register: Register) {
	before := get_register(this, Register.A)

	after := before + get_register(this, register)

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 4
}

add_hl :: proc(this: ^CPU, register: Wide_Register) {
	before := get_register(this, Register.A)

	after := before + read_from_memory(this, get_register(this, register))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

adc :: proc {
	adc_r,
	adc_hl,
	adc_imm,
}

adc_imm :: proc(this: ^CPU) {
	before := get_register(this, Register.A)

	after := before + fetch(this) + u8(get_flag(this, .C))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

adc_r :: proc(this: ^CPU, register: Register) {
	before := get_register(this, Register.A)

	after := before + get_register(this, register) + u8(get_flag(this, .C))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 4
}

adc_hl :: proc(this: ^CPU, register: Wide_Register) {
	before := get_register(this, Register.A)

	after := before + read_from_memory(this, get_register(this, register)) + u8(get_flag(this, .C))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

cpl :: proc(this: ^CPU) {

	a := get_register(this, Register.A)
	set_register(this, Register.A, a ~ 0xFF)

	set_flag(this, .N, true)
	set_flag(this, .H, true)

	this.clock += 4
}

daa :: proc(this: ^CPU) {
	/*
    // note: assumes a is a uint8_t and wraps from 0xff to 0
    if (!n_flag) {  // after an addition, adjust if (half-)carry occurred or if result is out of bounds
        if (c_flag || a > 0x99) { a += 0x60; c_flag = 1; }
        if (h_flag || (a & 0x0f) > 0x09) { a += 0x6; }
    } else {  // after a subtraction, only adjust if (half-)carry occurred
        if (c_flag) { a -= 0x60; }
        if (h_flag) { a -= 0x6; }
    }
    // these flags are always updated
    z_flag = (a == 0); // the usual z flag
    h_flag = 0; // h flag is always cleared
    */

	a := get_register(this, Register.A)

	if (!get_flag(this, .N)) { 	// after an addition, adjust if (half-)carry occurred or if result is out of bounds
		if (get_flag(this, .C) || a > 0x99) {
			a += 0x60
			set_flag(this, .C, true)
		}
		if (get_flag(this, .H) || a & 0x0F > 0x09) { 	// after a subtraction, only adjust if (half-)carry occurred
			a += 0x06
		}
	} else {
		if (get_flag(this, .C)) {
			a -= 0x60
		}
		if (get_flag(this, .H)) {
			a -= 0x06
		}
	}

	set_flag(this, .Z, a == 0)
	set_flag(this, .H, false)

	set_register(this, Register.A, a)
}

sub :: proc {
	sub_r,
	sub_hl,
}

sub_r :: proc(this: ^CPU, register: Register) {
	before := get_register(this, Register.A)

	after := before - get_register(this, register)

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 4
}

sub_hl :: proc(this: ^CPU, register: Wide_Register) {
	before := get_register(this, Register.A)

	after := before - read_from_memory(this, get_register(this, register))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

sbc :: proc {
	sbc_r,
	sbc_hl,
	sbc_n,
}

sbc_n :: proc(this: ^CPU) {
	before := get_register(this, Register.A)

	after := before - fetch(this) - u8(get_flag(this, .C))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

sbc_r :: proc(this: ^CPU, register: Register) {
	before := get_register(this, Register.A)

	after := before - get_register(this, register) - u8(get_flag(this, .C))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 4
}

sbc_hl :: proc(this: ^CPU, register: Wide_Register) {
	before := get_register(this, Register.A)

	after := before - read_from_memory(this, get_register(this, register)) - u8(get_flag(this, .C))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

add_imm :: proc(this: ^CPU, register: Register, value: u8) {
	before := get_register(this, register)

	after := before + value

	set_register(this, register, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

sub_imm :: proc(this: ^CPU, register: Register, value: u8) {
	before := get_register(this, register)

	after := before - value

	set_register(this, register, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) + (after & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, after < before)

	this.clock += 8
}

and :: proc {
	and_r,
	and_hl,
	and_imm,
	and_r_xx,
}

and_r_xx :: proc(this: ^CPU, register: Register, value: u8) {
	before := get_register(this, register)

	after := before & value

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, true)
	set_flag(this, .C, false)

	this.clock += 8
}

and_r :: proc(this: ^CPU, register: Register) {
	before := get_register(this, Register.A)

	after := before & get_register(this, register)

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, true)
	set_flag(this, .C, false)

	this.clock += 4
}

and_hl :: proc(this: ^CPU, register: Wide_Register) {
	before := get_register(this, Register.A)

	after := before & read_from_memory(this, get_register(this, register))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, true)
	set_flag(this, .C, false)

	this.clock += 8
}

and_imm :: proc(this: ^CPU) {
	a := get_register(this, Register.A)
	n := fetch(this)

	after := a & n
	set_register(this, Register.A, after)

	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, true)
	set_flag(this, .C, false)

	this.clock += 8
}

xor :: proc {
	xor_r,
	xor_hl,
	xor_imm,
}

xor_r :: proc(this: ^CPU, register: Register) {
	before := get_register(this, Register.A)

	after := before ~ get_register(this, register)

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 4
}

xor_hl :: proc(this: ^CPU, register: Wide_Register) {
	before := get_register(this, Register.A)

	after := before ~ read_from_memory(this, get_register(this, register))

	set_register(this, Register.A, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 8
}

xor_imm :: proc(this: ^CPU) {
	a := get_register(this, Register.A)
	n := fetch(this)

	after := a ~ n
	set_register(this, Register.A, after)

	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 8
}

or :: proc {
	or_imm,
	or_r,
	or_hl,
}

or_imm :: proc(this: ^CPU) {
	a := get_register(this, Register.A)
	n := fetch(this)

	after := a | n
	set_register(this, Register.A, after)

	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 8
}

or_r :: proc(this: ^CPU, register: Register) {

	a := get_register(this, Register.A)
	r := get_register(this, register)

	res := a | r

	set_register(this, Register.A, res)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 4
}

or_hl :: proc(this: ^CPU, register: Wide_Register) {

	a := get_register(this, Register.A)
	r := read_from_memory(this, get_register(this, register))

	res := a | r

	set_register(this, Register.A, res)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 8
}

cp :: proc {
	cp_imm,
	cp_r,
	cp_hl,
}

cp_imm :: proc(this: ^CPU) {
	a := get_register(this, Register.A)
	n := fetch(this)

	res := a - n

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((res & 0xf) - (a & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, res > a)

	this.clock += 8
}

cp_r :: proc(this: ^CPU, register: Register) {

	a := get_register(this, Register.A)
	r := get_register(this, register)

	res := a - r

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((res & 0xf) - (a & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, res > a)

	this.clock += 4
}

cp_hl :: proc(this: ^CPU, register: Wide_Register) {

	a := get_register(this, Register.A)
	r := read_from_memory(this, get_register(this, register))

	res := a - r

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((res & 0xf) - (a & 0xf)) & 0x10) == 0x10)
	set_flag(this, .C, res > a)

	this.clock += 8
}

dec :: proc {
	dec_r,
	dec_rr,
}

dec_r :: proc(this: ^CPU, register: Register) {

	before := get_register(this, register)
	after := before - u8(1)

	set_register(this, register, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)

	this.clock += 4
}

dec_rr :: proc(this: ^CPU, register: Wide_Register) {

	before := get_register(this, register)
	after := before - u16(1)

	set_register(this, register, after)

	this.clock += 8
}

dec_ind :: proc(this: ^CPU, register: Wide_Register) {

	address := get_register(this, register)

	before := read_from_memory(this, address)
	after := before - u8(1)

	write_to_memory(this, address, after)

	set_flag(this, .Z, after == 0)
	set_flag(this, .N, true)
	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)

	this.clock += 12
}

inc :: proc {
	inc_r,
	inc_rr,
}

inc_r :: proc(this: ^CPU, register: Register) {
	before := get_register(this, register)
	after := before + u8(1)

	set_register(this, register, after)

	//flags
	set_flag(this, .Z, after == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)

	this.clock += 4
}

inc_rr :: proc(this: ^CPU, register: Wide_Register) {
	before := get_register(this, register)
	after := before + u16(1)

	set_register(this, register, after)

	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)

	this.clock += 8
}

inc_ind :: proc(this: ^CPU, register: Wide_Register) {
	address := get_register(this, register)

	before := read_from_memory(this, address)
	after := before + 1

	write_to_memory(this, address, after)

	set_flag(this, .H, (((before & 0xf) - (after & 0xf)) & 0x10) == 0x10)

	this.clock += 8
}

//Rotate and Shift instructions

rla :: proc(this: ^CPU) {

	a := get_register(this, Register.A)

	old_7 := a & 0x80

	rot := a << 1

	set_register(this, Register.A, rot)

	set_flag(this, .Z, false)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, old_7 > 0)

	this.clock += 4
}

rra :: proc(this: ^CPU) {

	a := get_register(this, Register.A)

	old_0 := a & 0x01

	rot := a >> 1

	set_register(this, Register.A, rot)

	set_flag(this, .Z, false)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, old_0 > 0)

	this.clock += 4
}

rlca :: proc(this: ^CPU) {

	a := get_register(this, Register.A)

	msb := a & 0b10000000
	rot := (a << 1) | (a >> 7)

	set_register(this, Register.A, rot)

	set_flag(this, .Z, false)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, msb > 0)

	this.clock += 4
}

rrca :: proc(this: ^CPU) {

	a := get_register(this, Register.A)

	lsb := a & 0b00000001

	rot := (a >> 1) | (a << 7)

	set_register(this, Register.A, rot)

	set_flag(this, .Z, false)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, lsb > 0)

	this.clock += 4
}

//Single-bit Operation instructions

prefix_cb :: proc(this: ^CPU) {
	opcode := fetch(this)

	switch opcode {

	case 0x00:
		rlc(this, Register.B)
	case 0x01:
		rlc(this, Register.C)
	case 0x02:
		rlc(this, Register.D)
	case 0x03:
		rlc(this, Register.E)
	case 0x04:
		rlc(this, Register.H)
	case 0x05:
		rlc(this, Register.L)
	//case 0x06: rl(this, Wide_Register.HL)
	case 0x07:
		rlc(this, Register.A)

	case 0x08:
		rrc(this, Register.B)
	case 0x09:
		rrc(this, Register.C)
	case 0x0A:
		rrc(this, Register.D)
	case 0x0B:
		rrc(this, Register.E)
	case 0x0C:
		rrc(this, Register.H)
	case 0x0D:
		rrc(this, Register.L)
	//case 0x0E: rr(this, Wide_Register.HL)
	case 0x0F:
		rrc(this, Register.A)

	case 0x10:
		rl(this, Register.B)
	case 0x11:
		rl(this, Register.C)
	case 0x12:
		rl(this, Register.D)
	case 0x13:
		rl(this, Register.E)
	case 0x14:
		rl(this, Register.H)
	case 0x15:
		rl(this, Register.L)
	case 0x16:
		rl(this, Wide_Register.HL)
	case 0x17:
		rl(this, Register.A)

	case 0x18:
		rr(this, Register.B)
	case 0x19:
		rr(this, Register.C)
	case 0x1A:
		rr(this, Register.D)
	case 0x1B:
		rr(this, Register.E)
	case 0x1C:
		rr(this, Register.H)
	case 0x1D:
		rr(this, Register.L)
	case 0x1E:
		rr(this, Wide_Register.HL)
	case 0x1F:
		rr(this, Register.A)

	case 0x20:
		sla(this, Register.B)
	case 0x21:
		sla(this, Register.C)
	case 0x22:
		sla(this, Register.D)
	case 0x23:
		sla(this, Register.E)
	case 0x24:
		sla(this, Register.H)
	case 0x25:
		sla(this, Register.L)
	case 0x26:
		sla(this, Wide_Register.HL)
	case 0x27:
		sla(this, Register.A)

	case 0x28:
		sra(this, Register.B)
	case 0x29:
		sra(this, Register.C)
	case 0x2A:
		sra(this, Register.D)
	case 0x2B:
		sra(this, Register.E)
	case 0x2C:
		sra(this, Register.H)
	case 0x2D:
		sra(this, Register.L)
	case 0x2E:
		sra(this, Wide_Register.HL)
	case 0x2F:
		sra(this, Register.A)

	case 0x30:
		swap(this, Register.B)
	case 0x31:
		swap(this, Register.C)
	case 0x32:
		swap(this, Register.D)
	case 0x33:
		swap(this, Register.E)
	case 0x34:
		swap(this, Register.H)
	case 0x35:
		swap(this, Register.L)
	case 0x36:
		swap(this, Wide_Register.HL)
	case 0x37:
		swap(this, Register.A)

	case 0x38:
		srl(this, Register.B)
	case 0x39:
		srl(this, Register.C)
	case 0x3A:
		srl(this, Register.D)
	case 0x3B:
		srl(this, Register.E)
	case 0x3C:
		srl(this, Register.H)
	case 0x3D:
		srl(this, Register.L)
	case 0x3E:
		srl(this, Wide_Register.HL)
	case 0x3F:
		srl(this, Register.A)

	case 0x40:
		bit(this, 0, Register.B)
	case 0x41:
		bit(this, 0, Register.C)
	case 0x42:
		bit(this, 0, Register.D)
	case 0x43:
		bit(this, 0, Register.E)
	case 0x44:
		bit(this, 0, Register.H)
	case 0x45:
		bit(this, 0, Register.L)
	case 0x46:
		bit(this, 0, Wide_Register.HL)
	case 0x47:
		bit(this, 0, Register.A)

	case 0x48:
		bit(this, 1, Register.B)
	case 0x49:
		bit(this, 1, Register.C)
	case 0x4A:
		bit(this, 1, Register.D)
	case 0x4B:
		bit(this, 1, Register.E)
	case 0x4C:
		bit(this, 1, Register.H)
	case 0x4D:
		bit(this, 1, Register.L)
	case 0x4E:
		bit(this, 1, Wide_Register.HL)
	case 0x4F:
		bit(this, 1, Register.A)

	case 0x50:
		bit(this, 2, Register.B)
	case 0x51:
		bit(this, 2, Register.C)
	case 0x52:
		bit(this, 2, Register.D)
	case 0x53:
		bit(this, 2, Register.E)
	case 0x54:
		bit(this, 2, Register.H)
	case 0x55:
		bit(this, 2, Register.L)
	case 0x56:
		bit(this, 2, Wide_Register.HL)
	case 0x57:
		bit(this, 2, Register.A)

	case 0x58:
		bit(this, 3, Register.B)
	case 0x59:
		bit(this, 3, Register.C)
	case 0x5A:
		bit(this, 3, Register.D)
	case 0x5B:
		bit(this, 3, Register.E)
	case 0x5C:
		bit(this, 3, Register.H)
	case 0x5D:
		bit(this, 3, Register.L)
	case 0x5E:
		bit(this, 3, Wide_Register.HL)
	case 0x5F:
		bit(this, 3, Register.A)

	case 0x60:
		bit(this, 4, Register.B)
	case 0x61:
		bit(this, 4, Register.C)
	case 0x62:
		bit(this, 4, Register.D)
	case 0x63:
		bit(this, 4, Register.E)
	case 0x64:
		bit(this, 4, Register.H)
	case 0x65:
		bit(this, 4, Register.L)
	case 0x66:
		bit(this, 4, Wide_Register.HL)
	case 0x67:
		bit(this, 4, Register.A)

	case 0x68:
		bit(this, 5, Register.B)
	case 0x69:
		bit(this, 5, Register.C)
	case 0x6A:
		bit(this, 5, Register.D)
	case 0x6B:
		bit(this, 5, Register.E)
	case 0x6C:
		bit(this, 5, Register.H)
	case 0x6D:
		bit(this, 5, Register.L)
	case 0x6E:
		bit(this, 5, Wide_Register.HL)
	case 0x6F:
		bit(this, 5, Register.A)

	case 0x70:
		bit(this, 6, Register.B)
	case 0x71:
		bit(this, 6, Register.C)
	case 0x72:
		bit(this, 6, Register.D)
	case 0x73:
		bit(this, 6, Register.E)
	case 0x74:
		bit(this, 6, Register.H)
	case 0x75:
		bit(this, 6, Register.L)
	case 0x76:
		bit(this, 6, Wide_Register.HL)
	case 0x77:
		bit(this, 6, Register.A)

	case 0x78:
		bit(this, 7, Register.B)
	case 0x79:
		bit(this, 7, Register.C)
	case 0x7A:
		bit(this, 7, Register.D)
	case 0x7B:
		bit(this, 7, Register.E)
	case 0x7C:
		bit(this, 7, Register.H)
	case 0x7D:
		bit(this, 7, Register.L)
	case 0x7E:
		bit(this, 7, Wide_Register.HL)
	case 0x7F:
		bit(this, 7, Register.A)

	case 0x80:
		res(this, 0, Register.B)
	case 0x81:
		res(this, 0, Register.C)
	case 0x82:
		res(this, 0, Register.D)
	case 0x83:
		res(this, 0, Register.E)
	case 0x84:
		res(this, 0, Register.H)
	case 0x85:
		res(this, 0, Register.L)
	case 0x86:
		res(this, 0, Wide_Register.HL)
	case 0x87:
		res(this, 0, Register.A)

	case 0x88:
		res(this, 1, Register.B)
	case 0x89:
		res(this, 1, Register.C)
	case 0x8A:
		res(this, 1, Register.D)
	case 0x8B:
		res(this, 1, Register.E)
	case 0x8C:
		res(this, 1, Register.H)
	case 0x8D:
		res(this, 1, Register.L)
	case 0x8E:
		res(this, 1, Wide_Register.HL)
	case 0x8F:
		res(this, 1, Register.A)

	case 0x90:
		res(this, 2, Register.B)
	case 0x91:
		res(this, 2, Register.C)
	case 0x92:
		res(this, 2, Register.D)
	case 0x93:
		res(this, 2, Register.E)
	case 0x94:
		res(this, 2, Register.H)
	case 0x95:
		res(this, 2, Register.L)
	case 0x96:
		res(this, 2, Wide_Register.HL)
	case 0x97:
		res(this, 2, Register.A)

	case 0x98:
		res(this, 3, Register.B)
	case 0x99:
		res(this, 3, Register.C)
	case 0x9A:
		res(this, 3, Register.D)
	case 0x9B:
		res(this, 3, Register.E)
	case 0x9C:
		res(this, 3, Register.H)
	case 0x9D:
		res(this, 3, Register.L)
	case 0x9E:
		res(this, 3, Wide_Register.HL)
	case 0x9F:
		res(this, 3, Register.A)

	case 0xA0:
		res(this, 4, Register.B)
	case 0xA1:
		res(this, 4, Register.C)
	case 0xA2:
		res(this, 4, Register.D)
	case 0xA3:
		res(this, 4, Register.E)
	case 0xA4:
		res(this, 4, Register.H)
	case 0xA5:
		res(this, 4, Register.L)
	case 0xA6:
		res(this, 4, Wide_Register.HL)
	case 0xA7:
		res(this, 4, Register.A)

	case 0xA8:
		res(this, 5, Register.B)
	case 0xA9:
		res(this, 5, Register.C)
	case 0xAA:
		res(this, 5, Register.D)
	case 0xAB:
		res(this, 5, Register.E)
	case 0xAC:
		res(this, 5, Register.H)
	case 0xAD:
		res(this, 5, Register.L)
	case 0xAE:
		res(this, 5, Wide_Register.HL)
	case 0xAF:
		res(this, 5, Register.A)

	case 0xB0:
		res(this, 6, Register.B)
	case 0xB1:
		res(this, 6, Register.C)
	case 0xB2:
		res(this, 6, Register.D)
	case 0xB3:
		res(this, 6, Register.E)
	case 0xB4:
		res(this, 6, Register.H)
	case 0xB5:
		res(this, 6, Register.L)
	case 0xB6:
		res(this, 6, Wide_Register.HL)
	case 0xB7:
		res(this, 6, Register.A)

	case 0xB8:
		res(this, 7, Register.B)
	case 0xB9:
		res(this, 7, Register.C)
	case 0xBA:
		res(this, 7, Register.D)
	case 0xBB:
		res(this, 7, Register.E)
	case 0xBC:
		res(this, 7, Register.H)
	case 0xBD:
		res(this, 7, Register.L)
	case 0xBE:
		res(this, 7, Wide_Register.HL)
	case 0xBF:
		res(this, 7, Register.A)

	case 0xC0:
		set_bit(this, 0, Register.B)
	case 0xC1:
		set_bit(this, 0, Register.C)
	case 0xC2:
		set_bit(this, 0, Register.D)
	case 0xC3:
		set_bit(this, 0, Register.E)
	case 0xC4:
		set_bit(this, 0, Register.H)
	case 0xC5:
		set_bit(this, 0, Register.L)
	case 0xC6:
		set_bit(this, 0, Wide_Register.HL)
	case 0xC7:
		set_bit(this, 0, Register.A)

	case 0xC8:
		set_bit(this, 1, Register.B)
	case 0xC9:
		set_bit(this, 1, Register.C)
	case 0xCA:
		set_bit(this, 1, Register.D)
	case 0xCB:
		set_bit(this, 1, Register.E)
	case 0xCC:
		set_bit(this, 1, Register.H)
	case 0xCD:
		set_bit(this, 1, Register.L)
	case 0xCE:
		set_bit(this, 1, Wide_Register.HL)
	case 0xCF:
		set_bit(this, 1, Register.A)

	case 0xD0:
		set_bit(this, 2, Register.B)
	case 0xD1:
		set_bit(this, 2, Register.C)
	case 0xD2:
		set_bit(this, 2, Register.D)
	case 0xD3:
		set_bit(this, 2, Register.E)
	case 0xD4:
		set_bit(this, 2, Register.H)
	case 0xD5:
		set_bit(this, 2, Register.L)
	case 0xD6:
		set_bit(this, 2, Wide_Register.HL)
	case 0xD7:
		set_bit(this, 2, Register.A)

	case 0xD8:
		set_bit(this, 3, Register.B)
	case 0xD9:
		set_bit(this, 3, Register.C)
	case 0xDA:
		set_bit(this, 3, Register.D)
	case 0xDB:
		set_bit(this, 3, Register.E)
	case 0xDC:
		set_bit(this, 3, Register.H)
	case 0xDD:
		set_bit(this, 3, Register.L)
	case 0xDE:
		set_bit(this, 3, Wide_Register.HL)
	case 0xDF:
		set_bit(this, 3, Register.A)

	case 0xE0:
		set_bit(this, 4, Register.B)
	case 0xE1:
		set_bit(this, 4, Register.C)
	case 0xE2:
		set_bit(this, 4, Register.D)
	case 0xE3:
		set_bit(this, 4, Register.E)
	case 0xE4:
		set_bit(this, 4, Register.H)
	case 0xE5:
		set_bit(this, 4, Register.L)
	case 0xE6:
		set_bit(this, 4, Wide_Register.HL)
	case 0xE7:
		set_bit(this, 4, Register.A)

	case 0xE8:
		set_bit(this, 5, Register.B)
	case 0xE9:
		set_bit(this, 5, Register.C)
	case 0xEA:
		set_bit(this, 5, Register.D)
	case 0xEB:
		set_bit(this, 5, Register.E)
	case 0xEC:
		set_bit(this, 5, Register.H)
	case 0xED:
		set_bit(this, 5, Register.L)
	case 0xEE:
		set_bit(this, 5, Wide_Register.HL)
	case 0xEF:
		set_bit(this, 5, Register.A)

	case 0xF0:
		set_bit(this, 6, Register.B)
	case 0xF1:
		set_bit(this, 6, Register.C)
	case 0xF2:
		set_bit(this, 6, Register.D)
	case 0xF3:
		set_bit(this, 6, Register.E)
	case 0xF4:
		set_bit(this, 6, Register.H)
	case 0xF5:
		set_bit(this, 6, Register.L)
	case 0xF6:
		set_bit(this, 6, Wide_Register.HL)
	case 0xF7:
		set_bit(this, 6, Register.A)

	case 0xF8:
		set_bit(this, 7, Register.B)
	case 0xF9:
		set_bit(this, 7, Register.C)
	case 0xFA:
		set_bit(this, 7, Register.D)
	case 0xFB:
		set_bit(this, 7, Register.E)
	case 0xFC:
		set_bit(this, 7, Register.H)
	case 0xFD:
		set_bit(this, 7, Register.L)
	case 0xFE:
		set_bit(this, 7, Wide_Register.HL)
	case 0xFF:
		set_bit(this, 7, Register.A)

	case:
		fmt.eprintf("Unhandled Prefix CB code: %2x\n", opcode)
	}
}

bit :: proc {
	bit_narrow,
	bit_wide,
}

bit_narrow :: proc(this: ^CPU, bit: u8, register: Register) {

	r := get_register(this, register)

	b := r & 1 << bit

	set_flag(this, .Z, b == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, true)

	this.clock += 8
}

bit_wide :: proc(this: ^CPU, bit: u8, register: Wide_Register) {

	address := get_register(this, register)
	r := read_from_memory(this, address)

	b := r & 1 << bit

	set_flag(this, .Z, b == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, true)

	this.clock += 16
}

res :: proc {
	res_narrow,
	res_wide,
}

res_narrow :: proc(this: ^CPU, bit: u8, register: Register) {

	switch register {
	case .A:
		this.AF &= ~(1 << (8 + bit))
	case .B:
		this.BC &= ~(1 << (8 + bit))
	case .C:
		this.BC &= ~(1 << bit)
	case .D:
		this.DE &= ~(1 << (8 + bit))
	case .E:
		this.DE &= ~(1 << bit)
	case .H:
		this.HL &= ~(1 << (8 + bit))
	case .L:
		this.HL &= ~(1 << bit)
	}

	this.clock += 8
}

res_wide :: proc(this: ^CPU, bit: u8, register: Wide_Register) {
	address := get_register(this, register)

	value := read_from_memory(this, address)

	value &= ~(1 << bit)

	write_to_memory(this, address, value)

	this.clock += 16
}

rlc :: proc(this: ^CPU, register: Register) {

	a := get_register(this, register)

	msb := a & 0b10000000
	rot := (a << 1) | (a >> 7)

	set_register(this, register, rot)

	set_flag(this, .Z, rot == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, msb > 0)

	this.clock += 8
}

rrc :: proc(this: ^CPU, register: Register) {

	a := get_register(this, register)

	lsb := a & 0b00000001
	rot := (a >> 1) | (a << 7)

	set_register(this, register, rot)

	set_flag(this, .Z, rot == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, lsb > 0)

	this.clock += 8
}

rl :: proc {
	rl_n,
	rl_hl,
}

rl_n :: proc(this: ^CPU, register: Register) {
	//rotate left through carry
	r := get_register(this, register)
	carry := get_flag(this, .C)

	msb := r & 0b10000000

	res := r << 1
	res |= carry ? 0b00000001 : 0

	set_register(this, register, res)
	carry = msb > 0

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, carry)

	this.clock += 8
}

rl_hl :: proc(this: ^CPU, register: Wide_Register) {
	//rotate right through carry
	address := get_register(this, register)
	value := read_from_memory(this, address)

	carry := get_flag(this, .C)

	msb := value & 0b10000000

	res := value << 1
	res |= carry ? 0b00000001 : 0

	write_to_memory(this, address, res)
	carry = msb > 0

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, carry)

	this.clock += 16
}

rr :: proc {
	rr_n,
	rr_hl,
}

rr_n :: proc(this: ^CPU, register: Register) {
	//rotate right through carry
	r := get_register(this, register)
	carry := get_flag(this, .C)

	lsb := r & 1

	res := r >> 1
	res |= carry ? 0b10000000 : 0

	set_register(this, register, res)
	carry = lsb > 0

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, carry)

	this.clock += 8
}

rr_hl :: proc(this: ^CPU, register: Wide_Register) {
	//rotate right through carry
	address := get_register(this, register)
	value := read_from_memory(this, address)

	carry := get_flag(this, .C)

	lsb := value & 1

	res := value >> 1
	res |= carry ? 0b10000000 : 0

	write_to_memory(this, address, res)
	carry = lsb > 0

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, carry)

	this.clock += 16
}

set_bit :: proc {
	set_bit_r,
	set_bit_rr,
}

set_bit_r :: proc(this: ^CPU, bit: u8, register: Register) {

	r := get_register(this, register)

	val := r | (1 << bit)

	set_register(this, register, val)

	this.clock += 8
}

set_bit_rr :: proc(this: ^CPU, bit: u8, register: Wide_Register) {

	address := get_register(this, register)

	r := read_from_memory(this, address)

	val := r | (1 << bit)

	write_to_memory(this, address, val)

	this.clock += 16
}

//Shift right logical
srl :: proc {
	srl_n,
	srl_hl,
}

srl_n :: proc(this: ^CPU, register: Register) {

	r := get_register(this, register)

	res := r >> 1

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	set_register(this, register, res)

	this.clock += 8
}

srl_hl :: proc(this: ^CPU, register: Wide_Register) {

	address := get_register(this, register)
	value := read_from_memory(this, address)

	res := value >> 1

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	write_to_memory(this, address, res)

	this.clock += 16
}

sla :: proc {
	sla_n,
	sla_hl,
}

sla_n :: proc(this: ^CPU, register: Register) {
	//Shift left arithmetic

	r := get_register(this, register)

	msb := r & 0b10000000
	res := r << 1 | msb

	set_register(this, register, res)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, res > r)

	this.clock += 8
}

sla_hl :: proc(this: ^CPU, register: Wide_Register) {
	//Shift left arithmetic

	address := get_register(this, register)
	value := read_from_memory(this, address)

	msb := value & 0b10000000
	res := value << 1 | msb

	write_to_memory(this, address, res)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, res > value)

	this.clock += 16
}

sra :: proc {
	sra_n,
	sra_hl,
}

sra_n :: proc(this: ^CPU, register: Register) {
	//Shift right arithmetic

	r := get_register(this, register)

	msb := r & 0b10000000
	res := r >> 1 | msb

	set_register(this, register, res)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, res > r)

	this.clock += 8
}

sra_hl :: proc(this: ^CPU, register: Wide_Register) {
	//Shift left arithmetic

	address := get_register(this, register)
	value := read_from_memory(this, address)

	msb := value & 0b10000000
	res := value >> 1 | msb

	write_to_memory(this, address, res)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, res > value)

	this.clock += 16
}

swap :: proc {
	swap_n,
	swap_w,
}

swap_n :: proc(this: ^CPU, register: Register) {

	value := get_register(this, register)

	res := (value & 0x0F) << 4 | (value & 0xF0) >> 4

	set_register(this, register, value)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 8
}

swap_w :: proc(this: ^CPU, register: Wide_Register) {

	address := get_register(this, register)
	value := read_from_memory(this, address)

	res := (value & 0x0F) << 4 | (value & 0xF0) >> 4

	write_to_memory(this, address, value)

	set_flag(this, .Z, res == 0)
	set_flag(this, .N, false)
	set_flag(this, .H, false)
	set_flag(this, .C, false)

	this.clock += 16
}

//CPU Control instructions

call :: proc {
	call_imm,
	call_cond,
}

call_imm :: proc(this: ^CPU) {
	lo := fetch(this)
	hi := fetch(this)

	address := (u16(hi) << 8 | u16(lo))

	this.sp -= 2
	write_to_memory(this, this.sp, u8(this.pc & 0x00FF))
	write_to_memory(this, this.sp + 1, u8(this.pc & 0xFF00 >> 8))

	this.pc = address

	this.clock += 24
}

call_cond :: proc(this: ^CPU, flag: Flag, jump_if_set := true) {
	lo := fetch(this)
	hi := fetch(this)

	address := (u16(hi) << 8 | u16(lo))

	if (get_flag(this, flag) == jump_if_set) {
		this.sp -= 2
		write_to_memory(this, this.sp, u8(this.pc & 0x00FF))
		write_to_memory(this, this.sp + 1, u8(this.pc & 0xFF00 >> 8))

		this.pc = address

		this.clock += 24
	} else {
		this.clock += 12
	}
}

di :: proc(this: ^CPU) {

	this.ime = false

	this.clock += 4
}

ei :: proc(this: ^CPU) {

	this.ime = true

	this.clock += 4
}

ret :: proc {
	ret_imm,
	ret_cond,
}

ret_imm :: proc(this: ^CPU) {

	lo := read_from_memory(this, this.sp)
	hi := read_from_memory(this, this.sp + 1)

	this.sp += 2

	this.pc = (u16(hi) << 8 | u16(lo))

	this.clock += 16
}

ret_cond :: proc(this: ^CPU, flag: Flag, ret_if_set := true) {

	if get_flag(this, flag) == ret_if_set {
		lo := read_from_memory(this, this.sp)
		hi := read_from_memory(this, this.sp + 1)

		this.sp += 2

		this.pc = (u16(hi) << 8 | u16(lo))

		this.clock += 20
	} else {
		this.clock += 8
	}
}

reti :: proc(this: ^CPU) {

	this.ime = true

	lo := read_from_memory(this, this.sp)
	hi := read_from_memory(this, this.sp + 1)

	this.sp += 2

	this.pc = (u16(hi) << 8 | u16(lo))

	this.clock += 16

	this.in_interrupt = false
}

// Jump instructions
jp_nn :: proc(this: ^CPU, address: u16) {
	this.pc = address
	this.clock += 16
}

jp_hl :: proc(this: ^CPU) {
	this.pc = get_register(this, Wide_Register.HL)
	this.clock += 4
}

jp :: proc {
	jp_nn,
	jp_hl,
	jp_cond_a16,
}

jp_cond_a16 :: proc(this: ^CPU, flag: Flag, jump_if_set := true) {

	lo := fetch(this)
	hi := fetch(this)

	address := (u16(hi) << 8 | u16(lo))

	if (get_flag(this, flag) == jump_if_set) {
		this.pc = address
		this.clock += 16
	} else {
		this.clock += 12
	}
}

//overload for relative jumps
jr :: proc {
	jr_cond,
	jr_uncond,
}

//Unconditional relative jump
jr_uncond :: proc(this: ^CPU) {

	//offset can be negative, must treat it as signed
	offset := i8(fetch(this))
	this.pc += u16(offset)

	this.clock += 8
}

//Conditional relative jump
jr_cond :: proc(this: ^CPU, flag: Flag, jump_if_set: bool) {

	//offset can be negative, must treat it as signed
	offset := i8(fetch(this))

	if get_flag(this, flag) == jump_if_set {
		this.pc += u16(offset)
		this.clock += 12
	} else {
		this.clock += 8
	}
}

rst :: proc(this: ^CPU, address: u16) {

	this.sp -= 2
	write_to_memory(this, this.sp, u8(this.pc & 0x00FF))
	write_to_memory(this, this.sp + 1, u8(this.pc & 0xFF00 >> 8))

	this.pc = address
	this.clock += 16
}
