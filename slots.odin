package file_manager

import "core:strings"

// Slot remembers where one listing (a column's entries or a sibling/trail block,
// keyed by its directory) sat in the static layout, the layout without the pan.
Slot :: struct {
	key:  string,
	last: f32,
	seen: bool,
}

// Stack_Offset is the spring-driven shift of one column's whole stack of listings,
// so they slide together and never cross each other.
Stack_Offset :: struct {
	value:    f32,
	velocity: f32,
}

tree_slots_begin :: proc(tree: ^Tree) {
	for &slot in tree.slots {slot.seen = false}
	resize(&tree.offsets, len(tree.columns))
}

// tree_slots_end forgets listings that left the layout.
tree_slots_end :: proc(tree: ^Tree) {
	kept := 0
	for index in 0 ..< len(tree.slots) {
		if tree.slots[index].seen {
			tree.slots[kept] = tree.slots[index]
			kept += 1
		} else {
			delete(tree.slots[index].key, tree.allocator)
		}
	}
	resize(&tree.slots, kept)
}

tree_slots_destroy :: proc(tree: ^Tree) {
	for slot in tree.slots {delete(slot.key, tree.allocator)}
	delete(tree.slots)
	delete(tree.offsets)
	tree.slots = nil
	tree.offsets = nil
}

// tree_slot_jump records the listing's static y and returns how far it moved since
// the last frame (0 for a listing not seen then) and whether it was seen.
tree_slot_jump :: proc(tree: ^Tree, key: string, static: f32) -> (jump: f32, known: bool) {
	if len(key) == 0 {return 0, false}
	for &slot in tree.slots {
		if slot.key != key {continue}
		slot.seen = true
		jump = slot.last-static
		slot.last = static
		return jump, true
	}
	append(&tree.slots, Slot{key = strings.clone(key, tree.allocator), last = static, seen = true})
	return 0, false
}
