# Package

version       = "0.1.0"
author        = "Graham Northup"
description   = "The successor to the ITL Chorus"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["synfone"]


# Dependencies

requires "nim >= 2.2.8"
requires "nim_midi"
requires "nordaudio"
requires "cborious"
