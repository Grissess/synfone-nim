# synfone

This is the culmination of work on the old-but-tenacious [itl_chorus][itlc]
repository. As a bit of a happy accident, the protocol has remained
forward-compatible for a very long time, and this implementation is compatible
with it. It, however, is _not yet_ compatible with some of the extended
features:

- Articulation parameters ("ARTPs");
- PCM streaming;
- Advanced routing, especially without compiling/linking your own functions;
- Alternative clients, such as `DRUM`;
- Alternate ports;
- Compressed interval files.

That said, it works as a proof of concept, so feel free to get started and, by
all means, contribute.

[itlc]: https://github.com/Grissess/itl_chorus/tree/beta

## Usage

Documentation is sparse, but this should get you started:

The main binary (by default `synfone`) is built with three entrypoints,
specified as the first argument:

- `synfone interval` creates Interval files, like `mkiv.py`;
  - May take any number of MIDI file arguments, rendering to an adjacent `.iv`
    file, or--without arguments--reads from `stdin` and writes to `stdout`.
- `synfone transmitter` plays an Interval to the network, like `broadcast.py`;
  - Takes any number of interval files, and plays them in order after initial
    discovery;
  - `-S:time` seeks to the playback time (for each file; FIXME);
  - `-f:factor` sets the play time factor (for each file; FIXME)--`1.0` is the
    default, with lower numbers rendering "faster". Think of it as a multiplier
    on the duration of the piece.
- `syfone receiver` renders network note commands, like `client.py`.
  - `-n:voices` sets the number of indepedent voices;
  - `-r:rate` sets the sample rate;
  - `-u:uid` sets the (string) "UID" as reported in CAPS;
  - `--fpb=fpb` sets the frames per buffer (and thus the audio latency);
  - `--data-path=path` sets the "VoiceData path"; this is a file that other
    apps can `mmap` to access the live state of all voices. See the `VoiceData`
    type for details, but at present it can be used from C as:

```c
struct VoiceData {
    double pvel;  // "phase velocity"; equal to TAU * frequency / sample_rate
    double amplitude;
    double phase;
};
```

The first four bytes of the data-path file give the number of `VoiceData`
entries that follow.

This is not yet equivalent to the old ITL Chorus "render" protocol, since it's
missing a straight sample buffer. The format above is subject to change (e.g.
with offsets/pointers) to extend this.

Endianness is native, since it's assumed you'll be using this via shared
memory (and all cores have standard byte order).

Good luck, and let me know if you need help!

## License

GPL-3 or, at your option, any later version. See `COPYING` for details.
