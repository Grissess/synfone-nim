import std/math
import std/algorithm
import std/net
import std/monotimes
import std/times
import std/paths
import std/envvars
import std/parseopt
import std/parseutils
import std/memfiles
import std/files

import packet
from transmitter import default_port, recvBufferFrom, sendTo

# There are some const-cast issues with this binding, at least on my system
{. localPassC: "-Wno-error=incompatible-pointer-types" .}
import nordaudio

type
  VoiceData* = object
    pvel*: float  # frequency / sample_rate
    amplitude*: float  # in [0, 1]
    phase*: float  # in [0, TAU)

  Sample* = float32

  Generator* = proc(phase: float): Sample {. closure .}

  Voice* = ref object
    voice_data*: ptr VoiceData  # We can stash this in a mmap, for example
    generator*: Generator
    last_sample*: Sample
    expiry: MonoTime

  Chorus* = ref object
    voices*: seq[Voice]
    sample_rate: float

  Receiver* = ref object
    socket*: Socket
    uid: string
    chorus*: Chorus
    is_quit: bool

proc genSaw*(phase: float): Sample =
  2.0 * phase / TAU - 1.0

proc genSquare*(phase: float): Sample =
  if phase < (TAU / 2.0): 1.0 else: -1.0

proc newGenLut*(lut: seq[Sample]): Generator =
  proc(phase: float): Sample =
    lut[(phase / TAU).int]

proc samples*(voice: var Voice, samples: var openArray[Sample]) =
  var vd = voice.voice_data[]  # take a copy for this invocation
  var now = getMonoTime()
  if vd.pvel != 0.0 and voice.expiry < now:
    vd.pvel = 0.0
    voice.voice_data[].pvel = 0.0
  if vd.pvel == 0.0:
    if voice.last_sample == 0.0:
      fill(samples, 0.0)
    else:
      for idx in 0 ..< samples.len:
        var u = idx.Sample / (samples.len - 1).Sample
        samples[idx] = (1.0 - u) * voice.last_sample
  else:
    for idx in 0 ..< samples.len:
      samples[idx] = vd.amplitude * voice.generator(vd.phase)
      vd.phase = (vd.phase + vd.pvel) mod TAU
  voice.last_sample = samples[samples.len - 1]
  voice.voice_data[].phase = vd.phase  # update the one field we need to write

proc samples*(chorus: var Chorus, samples: var openArray[Sample]) =
  var mix_buffer = newSeq[Sample] samples.len
  fill(samples, 0.0)
  for voice in chorus.voices.mitems:
    voice.samples mix_buffer
    for idx, sample in mix_buffer:
      samples[idx] += sample / chorus.voices.len.Sample

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
      data: pointer): cint {. cdecl .} =
    var ch = cast[ptr Chorus](data)
    var sample_ptr = cast[ptr UncheckedArray[Sample]](output)
    # NB: we'd have to multiply channels in here if we knew it was not 1
    ch[].samples sample_ptr.toOpenArray(0, (frameCount - 1).int)
    return paContinue.cint
  (callback, chorus.addr)

proc newReceiver*(chorus: Chorus, uid: string = ""): Receiver =
  new result
  result.chorus = chorus
  result.uid = uid
  result.socket = newSocket(
    AF_INET6, SOCK_DGRAM, IPPROTO_UDP, buffered=false
  )
  result.socket.bindAddr default_port

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
      var voice = pkt.data[4]
      if voice < rx.chorus.voices.len.uint:
        var voice = rx.chorus.voices[voice]
        var offset = initDuration(seconds=pkt.data[0].int64, microseconds=pkt.data[1].int64)
        var flags = cast[PlayFlags](pkt.data[5])
        voice.expiry = getMonoTime() + offset
        voice.voice_data[].pvel = pkt.data[2].float * TAU / rx.chorus.sample_rate
        voice.voice_data[].amplitude = pkt.datumAsFloat(3)
        if not flags.contains PlayOption.SamePhase:
          voice.voice_data[].phase = 0.0
        echo "PLAY(", $pkt.data[4], ") ", $pkt.data[2], " ", $pkt.datumAsFloat(3), " ", $offset
    of Command.Caps:
      pkt.data[0] = rx.chorus.voices.len.uint32
      pkt.storeString 1, 1, "SYNF"
      pkt.storeString 2, -1, rx.uid
      buffer = pkt.toBuffer
      discard rx.socket.sendTo(address, port, buffer[0].addr, buffer.len)
    else: discard  # none of the rest need any service yet

proc main*(args: seq[string]) =
  var sample_rate: cdouble = 44100.0
  var frames_per_buffer: culong = 128
  var voices: int = 1
  var voice_data_path = ""
  var uid = ""
  if existsEnv("XDG_RUNTIME_DIR"):
    voice_data_path = $(getEnv("XDG_RUNTIME_DIR", "/run").Path / "synfone".Path)

  for kind, key, val in getopt(args):
    case kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case key
      of "r", "rate": discard parseFloat(val, sample_rate)
      of "n", "voices": discard parseInt(val, voices)
      of "u", "uid": uid = val
      of "fpb": discard parseUInt(val, frames_per_buffer)
      of "data-path": voice_data_path = val
      else: stderr.writeLine "Ignoring unknown option ", key
    of cmdArgument:
      stderr.writeLine "Ignoring argument ", key

  stderr.writeLine "starting with ", $voices, "voices, rate ", $sample_rate, ", fpb ", $frames_per_buffer, ", uid ", uid, ", vdp ", voice_data_path

  var memfile: MemFile
  var voice_data: ptr UncheckedArray[VoiceData]
  var voice_data_size = sizeof(VoiceData)*voices
  var internal_voice_data: seq[VoiceData]  # only if not mapped
  if voice_data_path.len > 0:
    memfile = open(voice_data_path, fmReadWrite, newFileSize=voice_data_size + sizeof(uint32))
    # tell external consumers how many data are relevant
    cast[ptr uint32](memfile.mem)[] = voices.uint32
    # bump the pointer (ew) and cast to a VoiceData array
    voice_data = cast[ptr UncheckedArray[VoiceData]](cast[int](memfile.mem) + sizeof(uint32))
  else:
    internal_voice_data = newSeq[VoiceData] voices
    voice_data = cast[ptr UncheckedArray[VoiceData]](internal_voice_data[0].addr)

  voice_data.toOpenArray(0, voices - 1).fill(VoiceData())
  var chorus = Chorus(sample_rate: sample_rate)
  for idx in 0 ..< voices:
    chorus.voices.add Voice(
      voice_data: voice_data[idx].addr,
      generator: genSaw,
    )
  var rx = newReceiver(chorus, uid)

  discard nordaudio.initialize()
  var params = chorus.streamParameters()
  var (callback, data) = chorus.streamCallback()
  var stream: ptr Stream

  discard openStream(stream.addr, nil, params.addr, sample_rate, frames_per_buffer, 0, callback, data)
  discard startStream(stream)

  rx.process

  discard stopStream(stream)
  discard closeStream(stream)
  discard nordaudio.terminate()

  if voice_data_path.len > 0:
    removeFile(voice_data_path.Path)

when isMainModule:
  import std/cmdline
  main(commandLineParams())
