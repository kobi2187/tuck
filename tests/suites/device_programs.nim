## Three programs for real, off-the-shelf parts (tests/metal/devices/),
## written to test the bare-metal designs: is the code beautiful, where are
## the frictions, does it work. Their write-up is
## docs/bare-metal/PROGRAMS-2026-11-22.md.
##
## Each program is split the same way: a pure module with every decision in
## it, which a host simulation runs on Nim, Odin and D, and the device code
## (registers, drivers, interrupt handlers, an actor), which is checked. The
## device code does not build for a board yet: actors do not build
## freestanding, and `bind` does not exist (the write-up says which).

import std/[os, strutils, sequtils]
import ../harness

const Dev = currentSourcePath().parentDir / ".." / "metal" / "devices"

proc eventsSay(t: var T, name: string, wanted: seq[string]) =
  let idx = t.needCmd(@["./tuck", "audit", t.curDir / "t.tuck", "--events"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc != 0: t.no name, "audit failed: " & text
  elif wanted.allIt(strutils.contains(text, it)): t.ok name
  else: t.no name, "the report missed a line. Got: " & text

proc irrigation(t: var T) =
  t.src readFile(Dev / "irrigation" / "sim.tuck")
  t.addFile "schedule.tuck", readFile(Dev / "irrigation" / "schedule.tuck")
  t.hostRuns "irrigation: a simulated week delivers 222 L, latching the alarms",
             222, "Open Mon 6:0\\s+Close Mon 6:17\\s+Open Wed 6:0\\s+Alarm Wed 6:1\\s+" &
             "Alarm Fri 3:1[\\s\\S]*delivered 222 L"
  t.src readFile(Dev / "irrigation" / "irrigation.tuck")
  for f in ["schedule.tuck", "bluepill.tuck", "ds3231.tuck"]:
    t.addFile f, readFile(Dev / "irrigation" / f)
  t.okCheck "irrigation: the device program checks"
  t.eventsSay "irrigation: the RTC alarm is a signal the Garden actor handles",
    @["Minute  [signal]", "raised by:  t.tuck:26 (onRtcAlarm, on EXTI0)",
      "handled by: t.tuck:57 (actor Garden)"]

proc recorder(t: var T) =
  t.src readFile(Dev / "recorder" / "sim.tuck")
  t.addFile "session.tuck", readFile(Dev / "recorder" / "session.tuck")
  t.hostRuns "recorder: 3 s of 128 kbit/s MP3 into 94 blocks, played back intact",
             94, "SCI_VOL 3598[\\s\\S]*recorded 48075 bytes in 94 blocks\\s+playback matches"
  t.src readFile(Dev / "recorder" / "recorder.tuck")
  for f in ["session.tuck", "board.tuck", "vs1063.tuck", "sdcard.tuck"]:
    t.addFile f, readFile(Dev / "recorder" / f)
  t.okCheck "recorder: the device program checks, transitions included"
  t.eventsSay "recorder: three buttons raise one stream event, a timer paces the work",
    @["Pressed{button: Button}  [stream, overflow: drop_newest]",
      "(onRecordButton, on EXTI0)", "(onPlayButton, on EXTI1)",
      "(onStopButton, on EXTI2)", "Tick  [signal]", "(onTimer, on TIM2)",
      "(actor Recorder)"]

proc drone(t: var T) =
  t.src readFile(Dev / "drone" / "sim.tuck")
  t.addFile "flight.tuck", readFile(Dev / "drone" / "flight.tuck")
  t.hostRuns "drone: CRSF decoded, a rate held, failsafe stops the motors", 0,
             "crsf: 2 good, 1 bad\\s+armed at 200 ms\\s+disarmed at 2000 ms\\s+" &
             "roll rate at 1.4 s: 319 deg/s[\\s\\S]*frame 33478, first pulses 210 105"
  t.src readFile(Dev / "drone" / "drone.tuck")
  for f in ["flight.tuck", "f405.tuck", "icm42688.tuck"]:
    t.addFile f, readFile(Dev / "drone" / f)
  t.okCheck "drone: the flight controller checks"
  t.eventsSay "drone: UART bytes stream, the gyro signals, one actor handles both",
    @["Byte{data: u8, at: int}  [stream, overflow: drop_newest]",
      "GyroReady  [signal]", "(onUsart1, on USART1)", "(onImuReady, on EXTI4)",
      "(actor Flight)"]

proc run*(t: var T) =
  t.irrigation()
  t.recorder()
  t.drone()
  t.finish()
