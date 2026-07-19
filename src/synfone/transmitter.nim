import std/net
import std/nativesockets
import std/monotimes
import std/oserrors
import std/sequtils
import std/math
import std/os
import std/xmlparser
import std/times
import std/parseopt
import std/parseutils

import packet
import interval

const
  all_hosts = parseIpAddress("ff02::1")
  default_port* = 13676.Port
  INTRINSICALLY_POLYPHONIC* = 0xffffffff'u32  # formerly OBLIGATE_POLYPHONE

type
  Host* = object
    address*: IpAddress
    port*: Port
    voices*: uint32  # NB: check this field for INTRINSICALLY_POLYPHONIC
    kind*: string
    uid*: string

  Target* = object
    address*: IpAddress
    port*: Port
    voice*: uint32
    # I don't feel too bad about pulling these out since they're GC'd and necessary for routing
    kind*: string
    uid*: string
    polyphone*: bool

  StreamBinding* = object
    stream*: NoteStream
    targets*: seq[Target]
    playhead*: int = 0

  Transmitter* = object
    socket*: Socket

  Playback* = object
    bindings*: seq[StreamBinding]
    timebase*: MonoTime
    factor*: float = 1.0

  Progress* = object
    time_now: float
    time_end: float
    next_time: float
    real_wait: float

func pitchToFrequency(pitch: float): float =
  440.0 * 2.0 ^ ((pitch - 69.0) / 12.0)

proc `+`*(left, right: Port): Port {. borrow .}

# XXX the stdlib only supports data pointers (not strings) in an overload that
# requires address be specified as a string (and uses gAI); for the overload
# using IpAddress, data must be a string, which we can't safely guarantee
# without a copy to a null-terminated location
# For now, let's just use the low-level routine on the FD directly
proc sendTo*(socket: Socket,
             address: IpAddress, port: Port,
             data: pointer, size: int,
             flags: int = 0): int =
  var sa: SockAddr_storage
  var sl: SockLen
  toSockAddr(address, port, sa, sl)

  result = sendto(getFd(socket), data, size.cint, flags.cint, cast[ptr SockAddr](sa.addr), sl)
  if result == -1:
    raiseOsError(osLastError())

# This one is an even worse offender; it takes a cstring despite no guarantees
# of NUL-termination. All packets are fixed size anyway (36 bytes as of this writing), so
# NUL-termination is unnecessary and interferes with conversion to a proper array.
proc recvBufferFrom*(socket: Socket,
                     address: var IpAddress, port: var Port,
                     buffer: var PacketBuffer,
                     flags: int = 0): int =
  var sa: SockAddr_storage
  var sl: SockLen = sizeof(sa).SockLen
  result = recvfrom(getFd(socket),
                    cast[cstring](buffer[0].addr), buffer.len.cint,  # oof
                    flags.cint,
                    cast[ptr SockAddr](sa.addr), sl.addr)
  if result == -1:
    raiseOsError(osLastError())
  
  sa.fromSockAddr(sl, address, port)

proc newTransmitter*(): Transmitter =
  Transmitter(
    socket: newSocket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP, buffered=false),
  )

proc findHosts*(tx: Transmitter, timeout: float = 1.0, port: Port = default_port): seq[Host] =
  var buffer = Packet(command: Command.Ping).toBuffer
  discard tx.socket.sendTo(all_hosts, port, buffer[0].addr, buffer.len)

  var address: IpAddress
  var port: Port

  while true:
    var handles = @[getFd(tx.socket)]
    var ready = selectRead(handles, (1000.0 * timeout).int)
    if ready == 0: break
    discard tx.socket.recvBufferFrom(address, port, buffer)
    var cmd = buffer.toPacket
    case cmd.command
    of Command.Ping:
      # great, it's alive; but we need its info, so send it unicast CAPS
      buffer = Packet(command: Command.Caps).toBuffer
      discard tx.socket.sendTo(address, port, buffer[0].addr, buffer.len)
    of Command.Caps:
      # a CAPS reply finalizes a new host
      var host = Host(
        address: address,
        port: port,
        voices: cmd.data[0],
        kind: cmd.dataAsString(1, 1),
        uid: cmd.dataAsString(2),
      )
      result.add host
    else: discard  # ignore everything else

proc toTargets*(hosts: seq[Host]): seq[Target] =
  for host in hosts:
    if host.voices == INTRINSICALLY_POLYPHONIC:
      result.add Target(
        address: host.address,
        port: host.port,
        voice: 0,
        kind: host.kind,
        uid: host.uid,
        polyphone: true,
      )
    else:
      for voice in 0 ..< host.voices:
        result.add Target(
          address: host.address,
          port: host.port,
          voice: voice,
          kind: host.kind,
          uid: host.uid,
          polyphone: false,
        )

proc defaultRoute*(targets: var seq[Target], binding: var StreamBinding) =
  # This is the default routing policy from old broadcast.py; you could extend
  # this by writing your own function of this sort, but a big TODO is making
  # this extensible without code some day
  var selidx = -1
  if binding.stream.group == "perc":
    selidx = targets.findIt(it.kind in ["DRUM", "SAMP"])
  else:
    selidx = targets.findIt(it.kind notin ["DRUM", "SAMP"])
  if selidx != -1:
    binding.targets.add targets[selidx]
    if not targets[selidx].polyphone:
      targets.delete selidx

proc newPlayback*(streams: seq[NoteStream]): Playback =
  Playback(
    bindings: streams.mapIt(StreamBinding(stream: it)),
  )

proc newPlayback*(iv: Interval): Playback =
  newPlayback(iv.streams)

proc routeStreams*(pb: var Playback, targets: var seq[Target],
                  policy: proc(targets: var seq[Target], binding: var StreamBinding) = defaultRoute) =
  for binding in pb.bindings.mitems:
    policy(targets, binding)

proc soonest*(pb: Playback): float =
  if pb.bindings.len == 0:
    return Inf
  pb.bindings.mapIt(
    if it.playhead < it.stream.notes.len:
      it.stream.notes[it.playhead].time
    else:
      Inf
  ).min system.cmp

proc endTime(pb: Playback): float =
  pb.bindings.mapIt(
    if it.stream.notes.len == 0:
      0.0
    else:
      let note = it.stream.notes[it.stream.notes.len - 1]
      note.time + note.duration
  ).max system.cmp

proc advanceTo*(pb: var Playback, time: float, emit: proc(b: StreamBinding, n: Note)) =
  for binding in pb.bindings.mitems:
    while binding.playhead < binding.stream.notes.len and
        binding.stream.notes[binding.playhead].time <= time:
      emit binding, binding.stream.notes[binding.playhead]
      inc binding.playhead

proc isDone*(pb: Playback): bool =
  pb.bindings.all do (binding: StreamBinding) -> bool:
    binding.playhead >= binding.stream.notes.len

proc play*(tx: Transmitter, pb: var Playback, seek: Duration = initDuration(), callback: proc(p: Progress) = nil) =
  # oops, we can only multiply durations by int64. Welp
  let augmented_seek = initDuration(nanoseconds=(seek.inNanoseconds.float * pb.factor).int64)
  pb.timebase = getMonoTime() - augmented_seek
  var progress = Progress(time_now: seek.inMicroseconds.float / 1000000.0, time_end: pb.endTime)
  # if we've sought, throw away the events at the beginning
  if seek.inMicroseconds > 0:
    var playtime = augmented_seek.inMicroseconds.float / 1000000.0
    pb.advanceTo(playtime) do (b: StreamBinding, n: Note):
      discard

  while not pb.isDone:
    var now = getMonoTime()
    var playtime = ((now - pb.timebase).inMicroseconds.float / 1000000.0) / pb.factor
    var factor = pb.factor
    pb.advanceTo(playtime) do (b: StreamBinding, n: Note):
      var real_play_time = factor * n.duration
      var rpt_secs = real_play_time.uint32
      var flags: PlayFlags
      if n.keep_phase:
        flags.incl PlayOption.SamePhase
      var packet = Packet(command: Command.Play, data: [
        rpt_secs,
        ((real_play_time - rpt_secs.float) * 1000000.0).uint32,
        n.pitch.pitchToFrequency.uint32,
        cast[uint32](n.amplitude.float32),
        0'u32,  # to be set
        cast[uint32](flags),
        0'u32, 0'u32  # reserved
      ])
      for target in b.targets:
        packet.data[4] = target.voice
        var buffer = packet.toBuffer
        discard tx.socket.sendTo(target.address, target.port, buffer[0].addr, buffer.len)
    var soonest = pb.soonest
    var wait = (soonest - playtime) * pb.factor
    progress.time_now = playtime
    progress.next_time = soonest
    progress.real_wait = wait
    if not callback.isNil:
      callback progress
    sleep (wait * 1000.0).int

proc main*(args: seq[string]) =
  var files: seq[string]
  var seek: float = 0.0
  var factor: float = 1.0

  for kind, key, val in getopt(args):
    case kind
    of cmdEnd: break
    of cmdArgument: files.add key
    of cmdShortOption, cmdLongOption:
      case key
      of "S", "seek": discard parseFloat(val, seek)
      of "f", "factor": discard parseFloat(val, factor)
      else: stderr.writeLine "Ignoring unknown option ", key

  var intervals: seq[Interval]
  for file in files:
    intervals.add intervalFromXml(loadXml(file))

  var tx = newTransmitter()
  var hosts = tx.findHosts() & tx.findHosts(port = default_port + 1.Port)
  if hosts.len == 0:
    stderr.writeLine "No hosts; stop."
    return
  stderr.writeLine $hosts.len, " hosts"
  for host in hosts:
    stderr.writeLine "- ", $host.address, ":", $host.port, " ", host.kind, " ", host.uid
  var targets = hosts.toTargets
  stderr.writeLine $targets.len, " targets"

  for idx, intv in intervals:
    var target_copy = targets
    var playback = newPlayback(intv)
    playback.factor = factor
    playback.routeStreams target_copy
    stderr.writeLine "start: ", files[idx]
    tx.play(playback, initDuration(microseconds=(seek * 1000000.0).int64)) do (prg: Progress):
      stdout.write "\r\x1b[2K", $prg.time_now, " / ", $prg.time_end, " -> ", $prg.next_time, " (", $prg.real_wait, ")"
      stdout.flushFile
    stderr.writeLine "finish: ", files[idx]

when isMainModule:
  import std/cmdline
  main(commandLineParams())
