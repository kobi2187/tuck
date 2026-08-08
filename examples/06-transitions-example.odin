package main

tuck_Config :: struct {
	url: string,
}

tuck_Feed :: struct {
	title: string,
}

tuck_PodcastPlayerLifecycle_Unloaded :: struct {
	config: tuck_Config,
}
tuck_PodcastPlayerLifecycle_Loading :: struct {
	config: tuck_Config,
	progress: int,
}
tuck_PodcastPlayerLifecycle_Ready :: struct {
	config: tuck_Config,
	feed: tuck_Feed,
}
tuck_PodcastPlayerLifecycle :: union {tuck_PodcastPlayerLifecycle_Unloaded, tuck_PodcastPlayerLifecycle_Loading, tuck_PodcastPlayerLifecycle_Ready}
tuck_PodcastPlayerLifecycleKind :: enum { Unloaded, Loading, Ready }
tag_tuck_PodcastPlayerLifecycle :: proc(v: tuck_PodcastPlayerLifecycle) -> tuck_PodcastPlayerLifecycleKind {
	switch _ in v {
	case tuck_PodcastPlayerLifecycle_Unloaded: return .Unloaded
	case tuck_PodcastPlayerLifecycle_Loading: return .Loading
	case tuck_PodcastPlayerLifecycle_Ready: return .Ready
	}
	return .Unloaded
}
canTransition_tuck_PodcastPlayerLifecycle :: proc(frm: tuck_PodcastPlayerLifecycleKind, to: tuck_PodcastPlayerLifecycleKind) -> bool {
	switch frm {
	case .Unloaded: return to == .Loading
	case .Loading: return to == .Ready || to == .Unloaded
	case .Ready: return to == .Unloaded
	}
	return false
}
transitionTo_tuck_PodcastPlayerLifecycle :: proc(self: ^tuck_PodcastPlayerLifecycle, target: tuck_PodcastPlayerLifecycle) {
	assert(canTransition_tuck_PodcastPlayerLifecycle(tag_tuck_PodcastPlayerLifecycle(self^), tag_tuck_PodcastPlayerLifecycle(target)), "Invalid transition")
	self^ = target
}

main :: proc() {
}
