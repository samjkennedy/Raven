package raven

NS_PER_MS :: 1000000
MS_PER_S :: 1000

NS :: i64

read_bit :: proc(word: u8, bit: u8) -> bool {
	return word & (1 << bit) > 1
}

set_bit_common :: proc(word: u8, bit: u8, hi := true) -> (res: u8) {
	if hi {
		res = word | (1 << bit)
	} else {
		res = word & ~(1 << bit)
	}
	return
}
