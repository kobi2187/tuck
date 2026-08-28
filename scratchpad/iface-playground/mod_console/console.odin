package tuck_console

import rt "../tuckrt"

TRec_console_line_5524 :: struct {
	line: string,
}

tuck_IoError :: enum { EndOfInput, IoFailed }

print :: proc(text: string) {
	rt.print(text)
}

printLine :: proc(text: string) {
	rt.printLine(text)
}

readLine :: proc() -> rt.TuckResult(TRec_console_line_5524) {
	r := rt.readLine()
	res: rt.TuckResult(TRec_console_line_5524)
	res.status = r.status
	res.err = r.err
	if r.status == .Ok {
		res.value = TRec_console_line_5524{line = r.value.line}
	}
	return res
}


