import os
import pty
import re
import sys

ansi_escape = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
prog_re = re.compile(r"\[(\d+/\d+)\]([^\r\n]*)")

class ProgressFilter:
    def __init__(self):
        self.buf = ""
        self.last_target = None

    def __call__(self, fd):
        data = os.read(fd, 2048)
        if not data:
            return b""
        text = data.decode("utf-8", "replace")
        self.buf += text
        lines = self.buf.split("\n")
        self.buf = lines.pop()
        for line in lines:
            line_clean = ansi_escape.sub("", line).replace("\r", "").strip()
            m = prog_re.search(line_clean)
            if m:
                target = m.group(1)
                if target != self.last_target:
                    self.last_target = target
                    sys.stdout.write(f"[{target}]{m.group(2)}\n")
                    sys.stdout.flush()
            elif not line_clean.startswith("[local]") and not re.search(r"^\d+s\s+\[local\]", line_clean):
                if line_clean:
                    sys.stdout.write(line_clean + "\n")
                    sys.stdout.flush()
        return b""

if __name__ == "__main__":
    cmd = sys.argv[1:] if len(sys.argv) > 1 else ["./build.sh"]
    ret = pty.spawn(cmd, ProgressFilter())
    sys.exit(ret >> 8)
