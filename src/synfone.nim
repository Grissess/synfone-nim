import synfone/interval
import synfone/packet
import synfone/receiver
import synfone/transmitter

export interval
export packet
export receiver
export transmitter

when isMainModule:
  import std/cmdline
  proc usage() =
    echo """
synfone { interval | transmitter | receiver } ...
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
    of "receiver":
      receiver.main(cmds)
    else:
      usage()

  main()
