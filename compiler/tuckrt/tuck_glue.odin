// Rule G fallback for an unresolved polymorphic leaf. Concrete shapes use
// compiler-generated glue; a generic T is specialized by Odin at invocation.
// Only owned values may be dropped. Copying never mutates the source.
package tuckrt
import "base:runtime"
import "base:intrinsics"
import "core:reflect"
import "core:mem"
import "core:strings"

tuckGResultShape :: proc(info: runtime.Type_Info_Struct) -> bool {
	return info.field_count == 3 && info.names[0] == "status" &&
	       info.names[1] == "err" && info.names[2] == "value" &&
	       info.types[0].id == typeid_of(TuckStatus)
}

tuckGCopyRaw :: proc(dst, src: rawptr, ti: ^runtime.Type_Info) {
	ti := runtime.type_info_base(ti)
	intrinsics.mem_copy(dst, src, ti.size)
	#partial switch info in ti.variant {
	case runtime.Type_Info_String:
		(^string)(dst)^ = strings.clone((^string)(src)^)
	case runtime.Type_Info_Dynamic_Array:
		source := (^runtime.Raw_Dynamic_Array)(src)
		target := (^runtime.Raw_Dynamic_Array)(dst)
		target^ = {}
		runtime.__dynamic_array_make(target, info.elem_size, info.elem.align,
		                            source.len, source.len)
		for i in 0 ..< source.len {
			tuckGCopyRaw(mem.ptr_offset((^u8)(target.data), i*info.elem_size),
			             mem.ptr_offset((^u8)(source.data), i*info.elem_size), info.elem)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count {
			tuckGCopyRaw(mem.ptr_offset((^u8)(dst), i*info.elem_size),
			             mem.ptr_offset((^u8)(src), i*info.elem_size), info.elem)
		}
	case runtime.Type_Info_Struct:
		inactive := tuckGResultShape(info) &&
		            ((^TuckStatus)(mem.ptr_offset((^u8)(src), int(info.offsets[0]))))^ != .Ok
		for i in 0 ..< int(info.field_count) {
			d := mem.ptr_offset((^u8)(dst), int(info.offsets[i]))
			s := mem.ptr_offset((^u8)(src), int(info.offsets[i]))
			if inactive && i == 2 {
				intrinsics.mem_zero(d, info.types[i].size)
			} else { tuckGCopyRaw(d, s, info.types[i]) }
		}
	case runtime.Type_Info_Union:
		payload := reflect.get_union_variant(any{src, ti.id})
		if payload.id != nil { tuckGCopyRaw(dst, src, type_info_of(payload.id)) }
	case:
		// Scalars, procedure references and explicit foreign/handle pointers.
	}
}

tuckGDropRaw :: proc(value: rawptr, ti: ^runtime.Type_Info) {
	ti := runtime.type_info_base(ti)
	#partial switch info in ti.variant {
	case runtime.Type_Info_String:
		delete((^string)(value)^)
	case runtime.Type_Info_Dynamic_Array:
		array := (^runtime.Raw_Dynamic_Array)(value)
		for i in 0 ..< array.len {
			tuckGDropRaw(mem.ptr_offset((^u8)(array.data), i*info.elem_size), info.elem)
		}
		mem.free(array.data, array.allocator)
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count {
			tuckGDropRaw(mem.ptr_offset((^u8)(value), i*info.elem_size), info.elem)
		}
	case runtime.Type_Info_Struct:
		if tuckGResultShape(info) &&
		   ((^TuckStatus)(mem.ptr_offset((^u8)(value), int(info.offsets[0]))))^ != .Ok { return }
		for i in 0 ..< int(info.field_count) {
			tuckGDropRaw(mem.ptr_offset((^u8)(value), int(info.offsets[i])), info.types[i])
		}
	case runtime.Type_Info_Union:
		payload := reflect.get_union_variant(any{value, ti.id})
		if payload.id != nil { tuckGDropRaw(value, type_info_of(payload.id)) }
	case:
	}
}

tuckCopyValue :: proc(value: $T) -> T {
	value := value
	out: T
	tuckGCopyRaw(&out, rawptr(&value), type_info_of(T))
	return out
}

tuckDropValue :: proc(value: $T) {
	value := value
	tuckGDropRaw(rawptr(&value), type_info_of(T))
}
