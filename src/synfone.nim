import synfone/interval
import synfone/packet
import synfone/transmitter
import synfone/sampler
import synfone/receiver/tone
import synfone/receiver/sample

export interval
export packet
export tone
export transmitter

when isMainModule:
  import std/cmdline
  proc usage() =
    echo """
synfone { interval | transmitter | sampler | tone | sample } ...
"""

  proc main() =
    var cmds = commandLineParams()
    if cmds.len == 0:
      usage()
      return

    var cmd = cmds[0]
    cmds.delete 0

    case cmd
    of "interval":
      interval.main(cmds)
    of "transmitter":
      transmitter.main(cmds)
    of "sampler":
      sampler.main(cmds)
    of "tone":
      tone.main(cmds)
    of "sample":
      sample.main(cmds)
    else:
      usage()

  main()
