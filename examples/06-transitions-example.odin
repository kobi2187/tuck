#+feature dynamic-literals
package main

tuck_type_Config :: struct {
	url: string,
}

tuck_type_Feed :: struct {
	title: string,
}

tuck_type_PodcastPlayerLifecycle_Unloaded :: struct {
	config: tuck_type_Config,
}
tuck_type_PodcastPlayerLifecycle_Loading :: struct {
	config: tuck_type_Config,
	progress: int,
}
tuck_type_PodcastPlayerLifecycle_Ready :: struct {
	config: tuck_type_Config,
	feed: tuck_type_Feed,
}
tuck_type_PodcastPlayerLifecycle :: union {tuck_type_PodcastPlayerLifecycle_Unloaded, tuck_type_PodcastPlayerLifecycle_Loading, tuck_type_PodcastPlayerLifecycle_Ready}
tuck_type_PodcastPlayerLifecycleKind :: enum { Unloaded, Loading, Ready }
tag_tuck_type_PodcastPlayerLifecycle :: proc(v: tuck_type_PodcastPlayerLifecycle) -> tuck_type_PodcastPlayerLifecycleKind {
	switch _ in v {
	case tuck_type_PodcastPlayerLifecycle_Unloaded: return .Unloaded
	case tuck_type_PodcastPlayerLifecycle_Loading: return .Loading
	case tuck_type_PodcastPlayerLifecycle_Ready: return .Ready
	}
	return .Unloaded
}

tuck_type_PodcastPlayerLifecycle_eq :: proc(a, b: tuck_type_PodcastPlayerLifecycle) -> bool {
  if av, aok := a.(tuck_type_PodcastPlayerLifecycle_Unloaded); aok {
    _ = av
    bv, bok := b.(tuck_type_PodcastPlayerLifecycle_Unloaded)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    return true
  }
  if av, aok := a.(tuck_type_PodcastPlayerLifecycle_Loading); aok {
    _ = av
    bv, bok := b.(tuck_type_PodcastPlayerLifecycle_Loading)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.progress != bv.progress { return false }
    return true
  }
  if av, aok := a.(tuck_type_PodcastPlayerLifecycle_Ready); aok {
    _ = av
    bv, bok := b.(tuck_type_PodcastPlayerLifecycle_Ready)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.feed != bv.feed { return false }
    return true
  }
  return false
}
canTransition_tuck_type_PodcastPlayerLifecycle :: proc(frm: tuck_type_PodcastPlayerLifecycleKind, to: tuck_type_PodcastPlayerLifecycleKind) -> bool {
	switch frm {
	case .Unloaded: return to == .Loading
	case .Loading: return to == .Ready || to == .Unloaded
	case .Ready: return to == .Unloaded
	}
	return false
}
transitionTo_tuck_type_PodcastPlayerLifecycle :: proc(self: ^tuck_type_PodcastPlayerLifecycle, target: tuck_type_PodcastPlayerLifecycle) {
	assert(canTransition_tuck_type_PodcastPlayerLifecycle(tag_tuck_type_PodcastPlayerLifecycle(self^), tag_tuck_type_PodcastPlayerLifecycle(target)), "Invalid transition")
	self^ = target
}

main :: proc() {
}
