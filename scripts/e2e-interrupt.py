#!/usr/bin/env python3
"""Drive omfx under a pty and press Esc mid-turn.

Interrupt is the one property that cannot be tested without a terminal, which is
exactly why it was dead code for months: `recv(MSG_PEEK)` returns ENOTSOCK on a
tty, so the poll never fired and nothing noticed.

Prints one line the shell parses:  reached=<n> after_esc=<n>

Both figures are the highest number the agent had printed, with ANSI stripped:
the pane repaints constantly, so raw byte growth measures redraw traffic, not
whether the model is still talking.
"""

import os
import pty
import re
import select
import sys
import time

binary, workdir = sys.argv[1], sys.argv[2]

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workdir)
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary])

buf = b""


def pump(seconds):
    global buf
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                return


pump(2.5)
# Long enough that Esc always lands mid-stream, even on a fast model.
os.write(fd, b"count from 1 to 2000, one number per line, nothing else\r")
pump(4)

# The pane positions each row with a cursor move rather than a newline, so those
# become newlines here; otherwise every row concatenates and nothing is anchored.
CUP = re.compile(r"\x1b\[[0-9;]*[Hf]")
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][B0]|\x1b[=>]")


def highest(raw):
    plain = ANSI.sub("", CUP.sub("\n", raw.decode("utf8", "replace")))
    # A row that is only a number is the model counting. The composer echoes the
    # prompt (which contains "2000"), so a bare search would always read 2000.
    seen = [int(n) for n in re.findall(r"^\s*(\d{1,4})\s*$", plain, re.M)]
    return max(seen, default=0)


at_press = highest(buf)
os.write(fd, b"\x1b")  # Esc
pump(8)
after = highest(buf)

os.write(fd, b"\x03")
print("reached=%d after_esc=%d" % (at_press, after))
