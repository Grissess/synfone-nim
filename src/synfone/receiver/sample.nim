import std/net
import std/streams
import std/locks
import std/algorithm
import std/parseopt
import std/parseutils
import std/options
import std/os
import std/tables

import ../packet
import ../sampler
import ../transmitter

{. localPassC: "-Wno-error=incompatible-pointer-types" .}
import nordaudio

type
  Voice = object
    samples*: seq[Sample]
    position*: uint
    amplitude*: float

  Chorus* = ref object
    sample_rate: float
    voices* {. guard: lock .}: seq[Voice]
    amplitude*: float
    lock: Lock

  Receiver* = ref object
    socket*: Socket
    sampler*: Sampler
    uid: string
    chorus*: Chorus
    is_quit: bool

proc samples*(voice: var Voice, samples: var openArray[Sample]): bool =
  for idx in 0 ..< samples.len:
    if voice.position >= voice.samples.len.uint:
      return true
    samples[idx] = voice.samples[voice.position] * voice.amplitude
    voice.position += 1
  false

proc samples*(chorus: var Chorus, samples: var openArray[Sample]) =
  samples.fill 0.0
  var mix_buffer = newSeq[Sample] samples.len
  var index = 0
  withLock chorus.lock:
    while index < chorus.voices.len:
      mix_buffer.fill 0.0
      if chorus.voices[index].samples mix_buffer:
        chorus.voices.del index
      else:
        index += 1
      for idx, sample in mix_buffer:
        samples[idx] += sample * chorus.amplitude

proc streamParameters*(chorus: Chorus): StreamParameters =
  result.device = getDefaultOutputDevice()
  result.suggestedLatency = getDeviceInfo(result.device).defaultLowOutputLatency
  result.channelCount = 1
  result.sampleFormat = paFloat32

proc streamCallback*(chorus: var Chorus): (StreamCallback, pointer) =
  proc callback(
      input: pointer, output: pointer,
      frameCount: culong,
      timeInfo: ptr StreamCallbackTimeInfo,
      statusFlags: StreamCallbackFlags,
      data: pointer): cint {. cdecl, thread .} =
    var ch = cast[ptr Chorus](data)
    var sample_ptr = cast[ptr UncheckedArray[Sample]](output)
    # NB: we'd have to multiply channels in here if we knew it was not 1
    ch[].samples sample_ptr.toOpenArray(0, (frameCount - 1).int)
    return paContinue.cint
  (callback, chorus.addr)

proc newReceiver*(chorus: Chorus, sampler: streams.Stream, uid: string = ""): Receiver =
  new result
  result.chorus = chorus
  result.uid = uid
  result.sampler = sampler.toSampler
  result.socket = newSocket(
    AF_INET6, SOCK_DGRAM, IPPROTO_UDP, buffered=false
  )
  result.socket.bindAddr default_port + 1.Port

proc process(rx: var Receiver) =
  var buffer: PacketBuffer
  var address: IpAddress
  var port: Port

  while not rx.is_quit:
    discard rx.socket.recvBufferFrom(address, port, buffer)
    var pkt = buffer.toPacket
    case pkt.command
    of Command.Ping:
      # reply--using the same buffer, since we can
      discard rx.socket.sendTo(address, port, buffer[0].addr, buffer.len)
    of Command.Quit:
      rx.is_quit = true
    of Command.Play:
      var freq = pkt.data[2]
      var sample = rx.sampler.get freq
      if sample.isSome:
        withLock rx.chorus.lock:
          rx.chorus.voices.add Voice(
            samples: sample.get,
            position: 0,
            amplitude: pkt.datumAsFloat(3),
          )
      echo if sample.isSome: "" else: "X", "PLAY ", $pkt.data[2], " ", $pkt.datumAsFloat(3)
    of Command.Caps:
      pkt.data[0] = INTRINSICALLY_POLYPHONIC
      pkt.storeString 1, 1, "SAMP"
      pkt.storeString 2, -1, rx.uid
      buffer = pkt.toBuffer
      discard rx.socket.sendTo(address, port, buffer[0].addr, buffer.len)
    else: discard  # none of the rest need any service yet

proc test(rx: var Receiver) =
  for freq, samples in rx.sampler.data:
    stderr.writeLine $freq, ": ", samples.len, " samples"
    for idx, sample in samples:
      let seconds = (sample.len.float / rx.chorus.sample_rate)
      stderr.writeLine $freq, ",", $idx, ": ", $sample.len, " samples, ", $seconds, "s"
      withLock rx.chorus.lock:
        rx.chorus.voices.add Voice(
          samples: sample,
          position: 0,
          amplitude: 1.0,
        )
      sleep((seconds * 1000.0).int)

proc main*(args: seq[string]) =
  var sample_rate: cdouble = 44100.0
  var frames_per_buffer: culong = 128
  var global_amplitude = 1.0
  var uid = ""
  var test = false
  var arguments: seq[string]

  for kind, key, val in getopt(args):
    case kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case key
      of "r", "rate": discard parseFloat(val, sample_rate)
      of "u", "uid": uid = val
      of "a", "amplitude": discard parseFloat(val, global_amplitude)
      of "t", "test": test = true
      of "fpb": discard parseUInt(val, frames_per_buffer)
      else: stderr.writeLine "Ignoring unknown option ", key
    of cmdArgument:
      arguments.add key

  if arguments.len != 1:
    stderr.writeLine "specify exactly one path to a stored sampler file"
    return

  stderr.writeLine "starting with rate ", $sample_rate, ", fpb ", $frames_per_buffer, ", uid ", uid

  var chorus = Chorus(sample_rate: sample_rate, amplitude: global_amplitude)
  var rx = newReceiver(chorus, newFileStream(arguments[0]), uid)

  discard nordaudio.initialize()
  var params = chorus.streamParameters()
  var (callback, data) = chorus.streamCallback()
  var stream: ptr nordaudio.Stream

  discard openStream(stream.addr, nil, params.addr, sample_rate, frames_per_buffer, 0, callback, data)
  discard startStream(stream)

  stderr.writeLine "ready"
  if test:
    rx.test
  else:
    rx.process

  discard stopStream(stream)
  discard closeStream(stream)
  discard nordaudio.terminate()

when isMainModule:
  import std/cmdline
  main(commandLineParams())
