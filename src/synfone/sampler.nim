import std/streams
import std/tables
import std/strmisc
import std/endians
import std/strutils
import std/random
import std/options
import std/random

import cborious

type
  Sample* = float32
  Frequency* = uint32

  Sampler* = ref object
    data*: Table[Frequency, seq[seq[Sample]]]

  # Should be a CBOR Map of Array of Bytestring
  SamplerExport = Table[Frequency, seq[seq[uint8]]]

  Endian = enum
    None, Little, Big

proc applyEndian(samples: var seq[Sample], endian: Endian = Big) =
  if endian == None: return
  var temp: Sample
  for sample in samples.mitems:
    case endian
    of Big: bigEndian32 temp.addr, sample.addr
    of Little: littleEndian32 temp.addr, sample.addr
    of None: discard
    sample = temp

func samplerImport(sexp: SamplerExport): Sampler =
  new result
  for freq, data in sexp:
    result.data[freq] = newSeq[seq[Sample]]()
    for samples in data:
      var converted = newSeq[Sample](samples.len /% sizeof(Sample))
      copyMem converted[0].addr, samples[0].addr, samples.len
      applyEndian converted, Big
      result.data[freq].add converted

func samplerExport(samp: Sampler): SamplerExport =
  for freq, data in samp.data:
    result[freq] = newSeq[seq[uint8]]()
    for samples in data:
      var swapped = samples
      applyEndian swapped, Big
      var converted = newSeq[uint8](swapped.len * sizeof(Sample))
      copyMem converted[0].addr, swapped[0].addr, converted.len
      result[freq].add converted

proc toSampler*(stream: Stream): Sampler =
  var load: SamplerExport
  stream.cborUnpack load
  load.samplerImport

proc save*(sampler: Sampler, stream: Stream) =
  var store = sampler.samplerExport
  stream.cborPack store

proc del*(sampler: var Sampler, freq: Frequency) =
  sampler.data.del freq

proc insert*(sampler: var Sampler, freq: Frequency, samples: seq[Sample]) =
  if freq notin sampler.data:
    sampler.data[freq] = newSeq[seq[Sample]]()
  sampler.data[freq].add samples

proc merge*(sampler: var Sampler, source: Sampler) =
  for freq, data in source.data:
    if freq notin sampler.data:
      sampler.data[freq] = newSeq[seq[Sample]]()
    for samples in data:
      sampler.data[freq].add samples

proc get*(sampler: Sampler, freq: Frequency, rand: var Rand): Option[seq[Sample]] =
  if freq in sampler.data:
    let choices = sampler.data[freq]
    result = some(rand.sample choices)

proc get*(sampler: Sampler, freq: Frequency): Option[seq[Sample]] =
  if freq in sampler.data:
    let choices = sampler.data[freq]
    result = some(sample choices)

proc main*(args: seq[string]) =
  var sampler = Sampler()

  for arg in args:
    let (pitch, sep, path) = arg.partition(":")
    if sep == "":
      # Load as a preexisting sampler file
      var new_sampler = newFileStream(pitch).toSampler
      sampler.merge new_sampler
    elif path == "":
      # Delete existing sampler entry
      var pitch_num = pitch.parseUInt.Frequency
      sampler.del pitch_num
    else:
      # Add a sampler entry
      var pitch_num = pitch.parseUInt.Frequency

      var endian: Endian = None
      var load_path = path
      if load_path.startswith '<':
        endian = Little
        load_path = load_path.substr 1
      elif load_path.startswith '>':
        endian = Big
        load_path = load_path.substr 1

      var data = newFileStream(load_path).readAll
      if data.len mod sizeof(Sample) != 0:
        stderr.writeLine "invalid sample length: ", load_path
        continue
      var samples = newSeq[Sample](data.len /% sizeof(Sample))
      copyMem samples[0].addr, data[0].addr, data.len
      applyEndian samples, endian

      sampler.insert pitch_num, samples

  # Write out and quit
  sampler.save newFileStream(stdout)

when isMainModule:
  import std/cmdline
  main(commandLineParams())
