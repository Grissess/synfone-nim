import std/tables
import std/options
import std/algorithm
import std/streams
import std/syncio
import std/xmltree
import std/paths
import std/parseutils
import std/strtabs

import nim_midi

export types.Channel, Ticks

type
  Time* = float32
  BPM* = distinct float32

  BPMMapBuilder* = object
    tempos: OrderedTable[Ticks, BPM] = {Ticks(0): BPM(120.0)}.toOrderedTable
    ppqn*: Ticks = 96
  BPMMap* = object
    tempos*: OrderedTable[Ticks, BPM]
    ppqn*: Ticks
    changes*: seq[tuple[abs_tick: Ticks, origin: Time]]

  InvalidFormat = object of ValueError

proc addTempoChange*(bpb: var BPMMapBuilder, ticks: Ticks, bpm: BPM) =
  bpb.tempos[ticks] = bpm

proc processEvent(bpb: var BPMMapBuilder, ev: Event) =
  if ev.isTempo:
    # XXX nim_midi casts the BPM to a uint, which isn't quite accurate, so
    # we don't use that function here
    bpb.addTempoChange(ev.abs_time, BPM(60_000_000.0 / ev.getTempo.float))

proc toBPMMapBuilder*(mf: MidiFile): BPMMapBuilder =
  if (mf.header.division and 0x8000) != 0:
    raise newException(InvalidFormat, "SMPTE time code forms are not yet processed")
  result.ppqn = mf.header.division and 0x7FFF
  for track in mf.tracks:
    for ev in track.events:
      result.processEvent ev

proc build*(bpb: var BPMMapBuilder): BPMMap =
  result.tempos = bpb.tempos
  result.ppqn = bpb.ppqn

  bpb.tempos.sort do (l, r: (Ticks, BPM)) -> int:
    cmp(l[0], r[0])

  var accumulator: Time = 0.0
  var last_bpm = BPM(120.0)
  var last_tick: Ticks = 0

  for abs_tick, new_bpm in bpb.tempos.pairs:
    var ticks_passed = abs_tick - last_tick
    var time_passed = (60.0 * ticks_passed.float) / (last_bpm.float * bpb.ppqn.float)
    accumulator += time_passed
    last_tick = abs_tick
    last_bpm = new_bpm
    result.changes.add((abs_tick, accumulator))

proc toBPMMap*(mf: MidiFile): BPMMap =
  var builder = mf.toBPMMapBuilder
  builder.build

# The std/algorithms version loses some information--we want "the index where
# it would have been inserted", as Rust's does, since that implies the next
# greater index
# You could make this generic, but we don't need that right now
proc bSearch(chg: seq[(Ticks, Time)], before: Ticks): uint =
  var l: uint = 0
  var h: uint = chg.len.uint

  while l < h:
    var mid = (l + h) shr 1
    if chg[mid][0] > before:
      if h == mid: break
      h = mid
    else:
      if l == mid: break
      l = mid

  l

proc realTime*(bpm: BPMMap, abs_tick: Ticks): Time =
  # First, find the origin time of the most recent change in the past
  # This is in sort order, so we can binary search
  var origin_idx = bSearch(bpm.changes, abs_tick)
  var (origin_tick, origin_time) = bpm.changes[origin_idx]
  
  # By construction, we know that every origin_tick in changes is associated
  # with a BPM event
  var origin_bpm = bpm.tempos[origin_tick]

  # Now it's just linear interpolation
  result = origin_time + (60.0 * (abs_tick - origin_tick).float) / (origin_bpm.float * bpm.ppqn.float)

type
  RealTimeEvent = object
    real_time: Time
    event: Event

iterator allRealTimeEvents(mf: MidiFile, bpm: BPMMap): RealTimeEvent =
  for track in mf.tracks:
    for ev in track.events:
      yield RealTimeEvent(event: ev, real_time: bpm.realTime(ev.abs_time))

proc defaultGroupClass*(rte: RealTimeEvent): string =
  if rte.event.etype == EventType.MidiEvent:
    # GM says this is channel 10, but their indexing is 1-based;
    # that's a bug that got me for months
    if rte.event.mi_channel == 9:
      "perc"
    else:
      ""
  else:
    ""

type
  Note* = object
    time*: float
    duration*: float
    pitch*: float
    amplitude*: float
    keep_phase*: bool

  NoteStream* = object
    group*: string
    notes*: seq[Note]
  NoteTip = tuple[time: Time, channel: types.Channel, pitch: float, amplitude: float]
  NoteStreamBuilder* = object
    stream: NoteStream
    tip: Option[NoteTip]

  Interval* = object
    streams*: seq[NoteStream]
    bpm_map*: BPMMap
  IntervalBuilder* = object
    streams: seq[NoteStreamBuilder]
    group_class*: proc(rte: RealTimeEvent):string = defaultGroupClass

func willAccept(nsb: NoteStreamBuilder, rte: RealTimeEvent): bool =
  if rte.event.etype == EventType.MidiEvent:
    case rte.event.mi_status
    of NoteOn: nsb.tip.isNone
    of NoteOff:
      if nsb.tip.isNone:
        false
      else:
        var (_, channel, pitch, _) = nsb.tip.get
        channel == rte.event.mi_channel and pitch == rte.event.mi_par1.float
    else: false
  else: false

func accept(nsb: var NoteStreamBuilder, rte: RealTimeEvent) =
  if rte.event.etype == EventType.MidiEvent:
    case rte.event.mi_status
    of NoteOn:
      nsb.tip = some((rte.real_time, rte.event.mi_channel, rte.event.mi_par1.float, rte.event.mi_par2.float / 127.0))
    of NoteOff:
      let (time, _, pitch, amplitude) = nsb.tip.get
      nsb.stream.notes.add Note(time: time, duration: rte.real_time - time, pitch: pitch, amplitude: amplitude)
      nsb.tip = none(NoteTip)
    else: discard

proc build*(nsb: NoteStreamBuilder): NoteStream =
  if nsb.tip.isSome:
    let (time, channel, pitch, amplitude) = nsb.tip.get
    stderr.writeLine "WARN: unfinished note starting at ", $time, " channel ", $channel, " pitch ", $pitch, " amplitude ", $amplitude, " dropped"
  nsb.stream

proc addEvent*(ivb: var IntervalBuilder, rte: RealTimeEvent) =
  var class = ivb.group_class rte
  for nsb in ivb.streams.mitems:
    if nsb.stream.group == class and nsb.willAccept rte:
      nsb.accept rte
      return
  if rte.event.etype == EventType.MidiEvent and rte.event.mi_status == NoteOn:
    # Spill into a new stream; we won't ask if it .willAccept because a fresh
    # stream will always accept a NoteOn
    var nsb = NoteStreamBuilder()
    nsb.stream.group = class
    nsb.accept rte
    ivb.streams.add nsb

proc build*(ivb: IntervalBuilder, bpm_map: BPMMap): Interval =
  result.bpm_map = bpm_map
  for nsb in ivb.streams:
    result.streams.add nsb.build

proc toInterval*(mf: MidiFile): Interval =
  var bpm = mf.toBPMMap

  var rtes: seq[RealTimeEvent]
  for rte in allRealTimeEvents(mf, bpm):
    rtes.add rte

  rtes.sort do (l, r: RealTimeEvent) -> int:
    cmp(l.real_time, r.real_time)

  var ivb = IntervalBuilder()
  for rte in rtes:
    ivb.addEvent rte
  ivb.build bpm

proc asXml*(ns: NoteStream): XmlNode =
  var attrs = @{"type": "ns"}
  if ns.group != "":
    attrs.add ("group", ns.group)
  result = newXmlTree("stream", [], attrs.toXmlAttributes)
  for note in ns.notes:
    result.add newXmlTree("note", [], toXmlAttributes({
      "pitch": $note.pitch,
      "ampl": $note.amplitude,
      "vel": $(note.amplitude * 127.0),
      "time": $note.time,
      "dur": $note.duration,
    }))

proc asXml*(bpm: BPMMap): XmlNode =
  result = newXmlTree("bpms", [], {"ppqn": $bpm.ppqn}.toXmlAttributes)
  for abs_tick, abs_time in bpm.changes.items:
    var bpm_at = bpm.tempos[abs_tick]
    result.add newXmlTree("bpm", [], {
      "ticks": $abs_tick,
      "time": $abs_time,
      "bpm": $bpm_at.float,
    }.toXmlAttributes)

var noAttributes = toXmlAttributes([])
proc asXml*(iv: Interval, src: string): XmlNode =
  var meta = newXmlTree("meta", [
    newXmlTree("app", [newText("nim-synfone")], noAttributes),
    iv.bpm_map.asXml,
  ], noAttributes)
  var streams = newElement "streams"
  for stream in iv.streams:
    streams.add stream.asXml
  newXmlTree("iv", [meta, streams], {
    "version": "1.1",
    "src": src,
  }.toXmlAttributes)

proc noteStreamFromXml*(node: XmlNode): NoteStream =
  result.group = node.attrs.getOrDefault("group", "")
  for child in node:
    var attrs = child.attrs
    var note = Note()
    discard parseFloat(attrs["pitch"], note.pitch)
    if "ampl" in attrs:
      discard parseFloat(attrs["ampl"], note.amplitude)
    else:
      discard parseFloat(attrs["vel"], note.amplitude)
      note.amplitude /= 127.0
    discard parseFloat(attrs["time"], note.time)
    discard parseFloat(attrs["dur"], note.duration)
    if "par" in attrs and attrs["par"].len > 0:
      note.keep_phase = true
    result.notes.add note

proc bpmMapFromXml*(node: XmlNode): BPMMap =
  var builder = BPMMapBuilder()
  var ppqn: uint = 96
  if "ppqn" in node.attrs:
    discard parseUInt(node.attrs["ppqn"], ppqn)
  builder.ppqn = ppqn.Ticks
  for child in node:
    var tick: uint
    var bpm: float
    var attrs = child.attrs
    discard parseUInt(attrs["ticks"], tick)
    discard parseFloat(attrs["bpm"], bpm)
    builder.tempos[tick.Ticks] = bpm.BPM
  builder.build

proc intervalFromXml*(node: XmlNode): Interval =
  var meta = node.child("meta")
  if not meta.isNil:
    var bpms = meta.child("bpms")
    if not bpms.isNil:
      result.bpm_map = bpmMapFromXml bpms
  var streams = node.child("streams")
  for stream in streams:
    result.streams.add noteStreamFromXml(stream)

proc main*(args: seq[string]) =
  proc convert(s: var Stream, src: string): string =
    var mf = parseMidiFile(s)
    var iv = mf.toInterval
    stderr.writeLine src, ": compilation done: ", $iv.streams.len, " note streams"
    for idx, stream in iv.streams:
      stderr.writeLine " - stream ", $idx, (if stream.group != "": " group " & $stream.group else: ""), ": ", $stream.notes.len, " notes"
    xmlHeader & $iv.asXml(src)

  if args.len == 0:
    stderr.writeLine "(no args, expecting input on stdin)"
    var fs = newFileStream stdin
    stdout.write convert(fs.Stream, "stdin")
  else:
    for arg in args:
      var fs = newFileStream(arg)
      if fs.isNil:
        stderr.writeLine arg, ": could not be opened"
        continue
      var ofn = changeFileExt(arg.Path, "iv")
      var ofs = newFileStream(ofn.string, fmWrite)
      if ofs.isNil:
        stderr.writeLine ofn, ": could not be opened"
        fs.close
        continue
      ofs.write convert(fs.Stream, arg)
      ofs.flush
      ofs.close

when isMainModule:
  import std/cmdline
  main(commandLineParams())
