package raven

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

ROM_Header :: struct {
	/*
	After displaying the Nintendo logo, the built-in boot ROM jumps to the address $0100, which should then jump to the actual main program in the cartridge. 
	Most commercial games fill this 4-byte area with a nop instruction followed by a jp $0150. 
	*/
	entry: [4]u8,

	/*
	This area contains a bitmap image that is displayed when the Game Boy is powered on. 
	It must match the following (hexadecimal) dump, otherwise the boot ROM won’t allow the game to run: 
	*/
	logo: [0x30]u8,

	/*
	These bytes contain the title of the game in upper case ASCII. 
	If the title is less than 16 characters long, the remaining bytes should be padded with $00s.
	*/
	title: string,

	/*
	In older cartridges this byte was part of the Title (see above). 
	The CGB and later models interpret this byte to decide whether to enable Color mode (“CGB Mode”) 
	or to fall back to monochrome compatibility mode (“Non-CGB Mode”).
	 */
	cgb_flag: u8,
	/*
	This area contains a two-character ASCII “licensee code” indicating the game’s publisher. 
	It is only meaningful if the [Old licensee<#014B — Old licensee is exactly $33 (which is the case for essentially all games made after the SGB was released); 
	otherwise, the old code must be considered. 
	*/
	new_licensee_code: string,
	/*This byte specifies whether the game supports SGB functions. 
	The SGB will ignore any command packets if this byte is set to a value other than $03 (typically $00).
	*/
	sgb_flag: u8,
	//This byte indicates what kind of hardware is present on the cartridge — most notably its mapper.
	cart_type: u8,
	/*
	This byte indicates how much ROM is present on the cartridge. 
	In most cases, the ROM size is given by 32 KiB × (1 << <value>):
	*/
	rom_size: u8,
	
	/*
	This byte indicates how much RAM is present on the cartridge, if any.

	If the cartridge type does not include “RAM” in its name, this should be set to 0. 
	This includes MBC2, since its 512 × 4 bits of memory are built directly into the mapper.
	 */
	ram_size: u8,

	//This byte specifies whether this version of the game is intended to be sold in Japan or elsewhere.
	destination_code: u8,

	/*
	This byte is used in older (pre-SGB) cartridges to specify the game’s publisher.
	However, the value $33 indicates that the [New licensee<#0144-0145 — New licensee must be considered instead. 
	(The SGB will ignore any command packets unless this value is $33.)
	*/
	old_licensee_code: u8,

	//This byte specifies the version number of the game. It is usually $00.
	mask_rom_version_number: u8,

	//This byte contains an 8-bit checksum computed from the cartridge header bytes $0134–014C.
	header_checksum: u8,

	/*
	These bytes contain a 16-bit (big-endian) checksum simply computed as the sum of all the bytes of the cartridge ROM (except these two checksum bytes).

	This checksum is not verified, except by Pokémon Stadium’s “GB Tower” emulator (presumably to detect Transfer Pak errors).
	*/
	global_checksum: u16
}

Cart :: struct {
	header: ROM_Header,
	rom: []u8,
}

load_cart_from_file :: proc(filepath: string) -> (cart: Cart, ok: bool) {

    rom: []u8

	rom, ok = os.read_entire_file(filepath, context.allocator)
	if !ok {
		// could not read file
		fmt.printf("Couldn't load file %v\n", filepath)
		return Cart{}, false
	}

	//Read header
	header := ROM_Header{}
	
	copy(header.entry[:], rom[0x100:0x104])
	copy(header.logo[:], rom[0x104:0x134])
	header.title = string(rom[0x134:0x0144])
	header.cgb_flag = rom[0x143]

	header.new_licensee_code = string([]u8{ rom[0x144], rom[0x145]})

	header.sgb_flag = rom[0x146]
	header.cart_type = rom[0x147]
	header.rom_size = rom[0x148]
	header.ram_size = rom[0x149]
	header.destination_code = rom[0x14A]
	header.old_licensee_code = rom[0x14B]
	header.mask_rom_version_number = rom[0x14C]
	header.header_checksum = rom[0x14D]
	header.global_checksum = u16(rom[0x14E]) << 8 | u16(rom[0x14F])

	//Compute header checksum
	checksum: u8 = 0
	for address in 0x0134..=0x014C {
		checksum = checksum - rom[address] - 1
	}
	if (header.header_checksum != (checksum & 0xFF)) {
		fmt.printf("Header checksum failed, got %2x instead of expected %2x", header.header_checksum, checksum)
		return Cart{}, false
	}

    cart = Cart{header, rom}

	return
}