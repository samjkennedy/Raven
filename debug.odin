package raven

import "vendor:sdl2"

import "core:strings"
import "core:fmt"

DEBUG_FLUSH_SIZE :: 1

Debugger :: struct {
    emulator:               ^Emulator,
    break_points:           [dynamic]u16,
    enable_debugging:       bool,

    debug_string_builder:   strings.Builder,

    window:                 ^sdl2.Window,
    renderer:               ^sdl2.Renderer,
}

init_vram_window :: proc(this: ^Debugger) -> (ok: bool) { //TODO: Return window handle
    WINDOW_WIDTH :: WIDTH
    WINDOW_HEIGHT :: HEIGHT

    //TODO: Don't hardcode the centrepoint
    WINDOW_X :: i32((2560 - 800) / 2 - (WINDOW_WIDTH / 2))
    WINDOW_Y :: i32(200)

    this.window = sdl2.CreateWindow("VRAM", WINDOW_X, WINDOW_Y, WIDTH, HEIGHT, sdl2.WindowFlags{.SHOWN})
    if this.window == nil {
        fmt.println("sdl2.CreateWindow failed.")
        return false
    }
    this.renderer = sdl2.CreateRenderer(this.window, -1, {.ACCELERATED, .PRESENTVSYNC})
    if this.renderer == nil {
        fmt.println("sdl2.CreateRenderer failed.")
        return false
    }

    return true
}

draw_vram :: proc(this: ^Debugger, cpu: ^CPU) {
    //Clear screen
    color := Color{255, 255, 255, 255}

    sdl2.SetRenderDrawColor(this.renderer, color.r, color.g, color.b, color.a)
    sdl2.RenderClear(this.renderer)

    //TODO: Move this logic into ppu.odin and cache the tiles for faster reading
    x := i32(0)
    y := i32(0)
    for i := 0x8000; i <= 0x9FFF; i += 0x10 {
        col_start := x
        row_start := y
        for j := 0; j < 16; j += 2 {
            lo := read_from_memory(cpu, u16(i + j))
            hi := read_from_memory(cpu, u16(i + j + 1))

            for bit := u8(8); bit > 0; bit -= 1 {
                pixel := get_bit(hi, bit) << 1 | get_bit(lo, bit)

                switch pixel {
                    case 0b00: color = default_palette.white
                    case 0b01: color = default_palette.light
                    case 0b10: color = default_palette.dark
                    case 0b11: color = default_palette.black
                }
                sdl2.SetRenderDrawColor(this.renderer, color.r, color.g, color.b, color.a)

                sdl2.RenderDrawPoint(this.renderer, i32(x), i32(y))

                x += 1
            }
            x = col_start
            y += 1
        }
        x += 0x08
        y = row_start
        
        if (x >= WIDTH) {
            y += 0x08
            x = 0
        }
    }

    sdl2.RenderPresent(this.renderer)
}

get_bit :: proc(val: u8, bit: u8) -> u8 {
    return (val >> bit) & 1;
}

flush_debug_printer :: proc(this: ^Debugger, force := false) {
    s := strings.to_string(this.debug_string_builder)
    if force || len(s) > DEBUG_FLUSH_SIZE {
        fmt.print(s)
        strings.builder_reset(&this.debug_string_builder)
    }
}

concat :: proc(lo: u8, hi: u8) -> u16 {
    return (u16(hi) << 8 | u16(lo))
}

lookup :: proc(ins: [3]u8, cpu: ^CPU) -> (op: string) {
    switch ins[0] {
        case 0x00: return "NOP"
        case 0x01: return fmt.aprintf("LD BC, %4x", concat(ins[1], ins[2]))
        case 0x02: return "LD (BC), A"
        case 0x03: return "INC BC"
        case 0x04: return "INC B"
        case 0x05: return "DEC B"
        case 0x06: return fmt.aprintf("LD B, %2x", ins[1])
        case 0x07: return "RLCA"
        case 0x09: return "ADD HL, BC"
        case 0x0A: return "LD A, (BC)"
        case 0x0B: return "DEC BC"
        case 0x0C: return "INC C"
        case 0x0D: return "DEC C"
        case 0x0E: return fmt.aprintf("LD C, %2x", ins[1])
        case 0x0F: return "RRCA"

        case 0x11: return fmt.aprintf("LD DE, %4x", concat(ins[1], ins[2]))
        case 0x12: return "LD (DE), A"
        case 0x13: return "INC DE"
        case 0x16: return fmt.aprintf("LD D, %2x", ins[1])
        case 0x19: return "ADD HL, DE"
        case 0x1A: return "LD A, (DE)"
        case 0x1B: return "DEC DE"

        case 0x20: { 
            return fmt.aprintf("JR NZ, %4x", cpu.ins_pc + 2 + u16(i8(ins[1]))) // +2 because fetching the ops has advanced it already
        }
        case 0x21: return fmt.aprintf("LD HL, %4x", concat(ins[1], ins[2]))
        case 0x22: return "LD (HL+), A"
        case 0x23: return "INC HL"
        case 0x28: return fmt.aprintf("JP Z, %2x", ins[1])
        case 0x2A: return "LD (HL+), A"
        case 0x2B: return "DEC HL"
        case 0x2C: return "INC L"
        case 0x2f: return "CPL"

        case 0x32: return "LD (HL-), A"
        case 0x36: return fmt.aprintf("LD (HL), %2x", ins[1])
        case 0x38: return fmt.aprintf("JR C, %2x", ins[1])
        case 0x39: return "ADD HL,SP"
        case 0x3A: return "LD A,(HL-)"
        case 0x3B: return "DEC SP"
        case 0x3E: return fmt.aprintf("LD A, %2x", ins[1])

        case 0x40: return "LD B, B"
        case 0x41: return "LD B, C"
        case 0x42: return "LD B, D"
        case 0x43: return "LD B, E"
        case 0x44: return "LD B, H"
        case 0x45: return "LD B, L"
        case 0x46: return "LD B, (HL)"
        case 0x47: return "LD B, A"
        case 0x48: return "LD C, B"
        case 0x49: return "LD C, C"
        case 0x4A: return "LD C, D"
        case 0x4B: return "LD C, E"
        case 0x4C: return "LD C, H"
        case 0x4D: return "LD C, L"
        case 0x4E: return "LD C, (HL)"
        case 0x4F: return "LD C, A"
        
        case 0x50: return "LD D, B"
        case 0x51: return "LD D, C"
        case 0x52: return "LD D, D"
        case 0x53: return "LD D, E"
        case 0x54: return "LD D, H"
        case 0x55: return "LD D, L"
        case 0x56: return "LD D, (HL)"
        case 0x57: return "LD D, A"
        case 0x58: return "LD E, B"
        case 0x59: return "LD E, C"
        case 0x5A: return "LD E, D"
        case 0x5B: return "LD E, E"
        case 0x5C: return "LD E, H"
        case 0x5D: return "LD E, L"
        case 0x5E: return "LD E, (HL)"
        case 0x5F: return "LD E, A"
        
        case 0x60: return "LD H, B"
        case 0x61: return "LD H, C"
        case 0x62: return "LD H, D"
        case 0x63: return "LD H, E"
        case 0x64: return "LD H, H"
        case 0x65: return "LD H, L"
        case 0x66: return "LD H, (HL)"
        case 0x67: return "LD H, A"
        case 0x68: return "LD L, B"
        case 0x69: return "LD L, C"
        case 0x6A: return "LD L, D"
        case 0x6B: return "LD L, E"
        case 0x6C: return "LD L, H"
        case 0x6D: return "LD L, L"
        case 0x6E: return "LD L, (HL)"
        case 0x6F: return "LD L, A"
        
        case 0x70: return "LD (HL), B"
        case 0x71: return "LD (HL), C"
        case 0x72: return "LD (HL), D"
        case 0x73: return "LD (HL), E"
        case 0x74: return "LD (HL), H"
        case 0x75: return "LD (HL), L"
        case 0x76: return "HALT"
        case 0x77: return "LD (HL), A"
        case 0x78: return "LD A, B"
        case 0x79: return "LD A, C"
        case 0x7A: return "LD A, D"
        case 0x7B: return "LD A, E"
        case 0x7C: return "LD A, H"
        case 0x7D: return "LD A, L"
        case 0x7E: return "LD A, (HL)"
        case 0x7F: return "LD A, A"

        case 0x80: return "ADD A, B"
        case 0x81: return "ADD A, C"
        case 0x82: return "ADD A, D"
        case 0x83: return "ADD A, E"
        case 0x84: return "ADD A, H"
        case 0x85: return "ADD A, L"
        case 0x86: return "ADD A, (HL)"
        case 0x87: return "ADC A, A"
        case 0x88: return "ADC A, B"
        case 0x89: return "ADC A, C"
        case 0x8A: return "ADC A, D"
        case 0x8B: return "ADC A, E"
        case 0x8C: return "ADC A, H"
        case 0x8D: return "ADC A, L"
        case 0x8E: return "ADC A, (HL)"
        case 0x8F: return "ADC A, A"

        case 0x90: return "SUB A, B"
        case 0x91: return "SUB A, C"
        case 0x92: return "SUB A, D"
        case 0x93: return "SUB A, E"
        case 0x94: return "SUB A, H"
        case 0x95: return "SUB A, L"
        case 0x96: return "SUB A, (HL)"
        case 0x97: return "SBC A, A"
        case 0x98: return "SBC A, B"
        case 0x99: return "SBC A, C"
        case 0x9A: return "SBC A, D"
        case 0x9B: return "SBC A, E"
        case 0x9C: return "SBC A, H"
        case 0x9D: return "SBC A, L"
        case 0x9E: return "SBC A, (HL)"
        case 0x9F: return "SBC A, A"

        case 0xA0: return "AND A, B"
        case 0xA1: return "AND A, C"
        case 0xA2: return "AND A, D"
        case 0xA3: return "AND A, E"
        case 0xA4: return "AND A, H"
        case 0xA5: return "AND A, L"
        case 0xA6: return "AND A, (HL)"
        case 0xA7: return "XOR A, A"
        case 0xA8: return "XOR A, B"
        case 0xA9: return "XOR A, C"
        case 0xAA: return "XOR A, D"
        case 0xAB: return "XOR A, E"
        case 0xAC: return "XOR A, H"
        case 0xAD: return "XOR A, L"
        case 0xAE: return "XOR A, (HL)"
        case 0xAF: return "XOR A, A"

        case 0xB0: return "OR B"
        case 0xB1: return "OR C"
        case 0xB2: return "OR D"
        case 0xB3: return "OR E"
        case 0xB4: return "OR H"
        case 0xB5: return "OR L"
        case 0xB6: return "OR (HL)"
        case 0xB7: return "CP A"
        case 0xB8: return "CP B"
        case 0xB9: return "CP C"
        case 0xBA: return "CP D"
        case 0xBB: return "CP E"
        case 0xBC: return "CP H"
        case 0xBD: return "CP L"
        case 0xBE: return "CP (HL)"
        case 0xBF: return "CP A"

        case 0xC1: return "POP BC"
        case 0xC3: return fmt.aprintf("JP %4x", concat(ins[1], ins[2]))
        case 0xC9: return "RET"
        case 0xCA: return "RET NZ"
        case 0xCB: return fmt.aprintf("CB %2x", ins[1])
        case 0xCD: return fmt.aprintf("CALL %4x", concat(ins[1], ins[2]))

        case 0xD1: return "POP DE"
        case 0xDA: return "RET NC"

        case 0xE0: return fmt.aprintf("LDH (FF00+%2x), a", ins[1])
        case 0xE1: return "POP HL"
        case 0xE6: return fmt.aprintf("AND %2x", ins[1])
        case 0xEA: return fmt.aprintf("LD (%4x), a", concat(ins[1], ins[2]))
        case 0xEF: return "RST 28"
        
        case 0xF0: return fmt.aprintf("LDH a, (FF00+%2x)", ins[1])
        case 0xF1: return "POP AF"
        case 0xF3: return "DI"
        case 0xF8: return fmt.aprintf("LD HL, SP+%2x", ins[1])
        case 0xFB: return "EI"
        case 0xFE: return fmt.aprintf("CP A, %2x", ins[1])
        case: return "UNKNOWN"
    }
}

debug :: proc(this: ^Debugger, cpu: ^CPU) {
    if (!this.enable_debugging) {
        return
    }

    draw_vram(this, cpu)

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
    for i in 1..=tabs {
        strings.write_string(&ins_str, "   ")
    }
    strings.write_string(&ins_str, " ; ")
    strings.write_string(&ins_str, op)

    ins := strings.to_string(ins_str)

    fmt.wprintf(
        strings.to_writer(&this.debug_string_builder),
        "pc: %4x: sp: %4x, ime: %v, ie: %8b, if: %8b, A: %2x, B: %2x, C: %2x, D: %2x, E: %2x, H: %2x, L: %2x, flags: %v, clock: %4d, ins: %v\n",
        cpu.ins_pc, cpu.sp, ime, read_from_memory(cpu, IE_REGISTER), read_from_memory(cpu, IF_REGISTER), cpu.AF & 0xFF00 >> 8, cpu.BC & 0xFF00 >> 8, cpu.BC & 0x00FF, cpu.DE & 0xFF00 >> 8, cpu.DE & 0x00FF, cpu.HL & 0xFF00 >> 8, cpu.HL & 0x00FF, flags, cpu.clock, ins
    )
    flush_debug_printer(this) 
}
