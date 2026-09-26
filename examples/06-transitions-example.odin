#+feature dynamic-literals
package main

tuckˑtypeˑConfig :: struct {
	url: string,
}

tuckˑtypeˑFeed :: struct {
	title: string,
}

tuckˑtypeˑPodcastPlayerLifecycle_Unloaded :: struct {
	config: tuckˑtypeˑConfig,
}
tuckˑtypeˑPodcastPlayerLifecycle_Loading :: struct {
	config: tuckˑtypeˑConfig,
	progress: int,
}
tuckˑtypeˑPodcastPlayerLifecycle_Ready :: struct {
	config: tuckˑtypeˑConfig,
	feed: tuckˑtypeˑFeed,
}
tuckˑtypeˑPodcastPlayerLifecycle :: union {tuckˑtypeˑPodcastPlayerLifecycle_Unloaded, tuckˑtypeˑPodcastPlayerLifecycle_Loading, tuckˑtypeˑPodcastPlayerLifecycle_Ready}
tuckˑtypeˑPodcastPlayerLifecycleKind :: enum { Unloaded, Loading, Ready }
tag_tuckˑtypeˑPodcastPlayerLifecycle :: proc(v: tuckˑtypeˑPodcastPlayerLifecycle) -> tuckˑtypeˑPodcastPlayerLifecycleKind {
	switch _ in v {
	case tuckˑtypeˑPodcastPlayerLifecycle_Unloaded: return .Unloaded
	case tuckˑtypeˑPodcastPlayerLifecycle_Loading: return .Loading
	case tuckˑtypeˑPodcastPlayerLifecycle_Ready: return .Ready
	}
	return .Unloaded
}

tuckˑtypeˑPodcastPlayerLifecycle_eq :: proc(a, b: tuckˑtypeˑPodcastPlayerLifecycle) -> bool {
  if av, aok := a.(tuckˑtypeˑPodcastPlayerLifecycle_Unloaded); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPodcastPlayerLifecycle_Unloaded)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPodcastPlayerLifecycle_Loading); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPodcastPlayerLifecycle_Loading)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.progress != bv.progress { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPodcastPlayerLifecycle_Ready); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPodcastPlayerLifecycle_Ready)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.feed != bv.feed { return false }
    return true
  }
  return false
}
canTransition_tuckˑtypeˑPodcastPlayerLifecycle :: proc(frm: tuckˑtypeˑPodcastPlayerLifecycleKind, to: tuckˑtypeˑPodcastPlayerLifecycleKind) -> bool {
	switch frm {
	case .Unloaded: return to == .Loading
	case .Loading: return to == .Ready || to == .Unloaded
	case .Ready: return to == .Unloaded
	}
	return false
}
transitionTo_tuckˑtypeˑPodcastPlayerLifecycle :: proc(self: ^tuckˑtypeˑPodcastPlayerLifecycle, target: tuckˑtypeˑPodcastPlayerLifecycle) {
	assert(canTransition_tuckˑtypeˑPodcastPlayerLifecycle(tag_tuckˑtypeˑPodcastPlayerLifecycle(self^), tag_tuckˑtypeˑPodcastPlayerLifecycle(target)), "Invalid transition")
	self^ = target
}

main :: proc() {
}
