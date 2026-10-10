#+feature dynamic-literals
package main
import rt "../../compiler/tuckrt"

Bag :: struct { items: [dynamic]string }
Tree_Leaf :: struct { value: int }
Tree_Branch :: struct { children: [dynamic]Tree }
Tree :: union { Tree_Leaf, Tree_Branch }

roundtrip :: proc(value: $T) -> T {
	return rt.tuckCopyValue(value)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	bag := Bag{[dynamic]string{rt.tuckStrOwned("one"), rt.tuckStrOwned("two")}}
	duplicate := roundtrip(bag)
	assert(duplicate.items[0] == "one")
	rt.tuckDropValue(bag)
	assert(duplicate.items[1] == "two")
	rt.tuckDropValue(duplicate)
	tree: Tree = Tree_Branch{[dynamic]Tree{Tree_Leaf{3}}}
	tree_copy := roundtrip(tree)
	rt.tuckDropValue(tree)
	rt.tuckDropValue(tree_copy)
	bag2 := Bag{[dynamic]string{rt.tuckStrOwned("payload")}}
	active := rt.tok(bag2)
	active_copy := roundtrip(active)
	absent := rt.tnone(Bag)
	absent.value = bag2 // Inactive payload is not owned, despite its bytes.
	absent_copy := roundtrip(absent)
	assert(len(absent_copy.value.items) == 0)
	rt.tuckDropValue(absent_copy)
	rt.tuckDropValue(absent)
	rt.tuckDropValue(active_copy)
	rt.tuckDropValue(active)
	rt.tuckTrackCheck()
}
