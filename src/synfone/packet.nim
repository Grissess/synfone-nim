import std/endians
import std/strbasics

type
  Command* {. pure, size: sizeof(uint32) .} = enum
    KeepAlive,
    Ping,
    Quit,
    Play,
    Caps,
    Pcm,
    PcmSyn,
    Articulation

  Packet* = object
    command*: Command
    data*: array[8, uint32]

  PacketBuffer* = array[sizeof(Packet), uint8]

  PlayOption* {. pure, size: sizeof(uint32) .} = enum
    SamePhase
  PlayFlags* = set[PlayOption]

proc toBuffer*(pkt: Packet): PacketBuffer =
  bigEndian32(result[0].addr, pkt.command.addr)
  for idx in 0..high(pkt.data):
    bigEndian32(result[4 + 4 * idx].addr, pkt.data[idx].addr)

proc toPacket*(buf: PacketBuffer): Packet =
  bigEndian32(result.command.addr, buf[0].addr)
  for idx in 0..high(result.data):
    bigEndian32(result.data[idx].addr, buf[4 + 4 * idx].addr)

proc datumAsFloat*(pkt: Packet, datum: int): float32 =
  cast[float32](pkt.data[datum])

proc dataAsString*(pkt: Packet, start: int, size: int = -1): string =
  var sz = size
  if sz == -1:
    sz = pkt.data.len - start

  result = newString(sz * sizeof(pkt.data[0]))
  copyMem result[0].addr, pkt.data[start].addr, sz * sizeof(pkt.data[0])
  result.strip(leading=false, chars={'\0'})

proc storeString*(pkt: Packet, start: int, size: int = -1, data: string) =
  # For you network junkies: every version known of the ITL Chorus had the same
  # "feature" where strings were stored into data as big-endian values, but
  # then swapped to "network byte order" on transmit, resulting in strange
  # things like "little endian FOURCCs". This library simply perpetuates that
  # feature.
  var sz = size
  if sz == -1:
    sz = pkt.data.len - start
  sz *= sizeof(pkt.data[0])
  var dataView = cast[ptr UncheckedArray[uint8]](pkt.data[start].addr)
  for idx in 0 ..< sz:
    dataView[idx] = if idx < data.len: data[idx].uint8 else: 0
